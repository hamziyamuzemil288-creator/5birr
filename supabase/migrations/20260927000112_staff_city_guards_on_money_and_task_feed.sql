-- =============================================================================
-- 20260927000112_staff_city_guards_on_money_and_task_feed.sql
--
-- The last two category-guarded call sites, plus the scoped READ policies
-- that were left city-blind by 20260922000012.
--
-- 0010 guarded the registration queue.
-- 0011 guarded the five provider lifecycle actions.
-- This guards:
--
--   * verify_payment_proof  -- the money path
--   * staff_task_feed       -- the staff portal's own work queue
--   * provider_profiles_staff_registration_read and
--     orders_staff_reports_read -- the RLS read policies
--
-- THE SAME RULE THROUGHOUT
-- ------------------------
-- The city guard is added to exactly the branches that ALREADY carry the
-- category guard, and to nothing else. Two branches of staff_task_feed --
-- support tickets and appeals -- carry only a permission check and no
-- category scope, because neither table is categorized. Adding a city scope
-- there while the category scope is absent would make city STRICTER than
-- category on the same screen, which is a different and unrequested policy
-- decision. The two axes are kept peer for peer.
--
-- City sources, per branch:
--   REGISTRATION  provider -> provider_profiles.city
--                 user      -> profiles.city          (coalesced, provider first)
--   WALLET_RECHARGE           provider_profiles.city
--   PAYMENT_PROOF             orders.city             (coalesced after pp)
--   verify_payment_proof      orders.city
--
-- Every one of these is nullable in the live schema, and
-- staff_scope_allows_city treats NULL and blank as "unscoped row, visible to
-- everyone", so a row with no city is never hidden from a permitted person.
--
-- AGAIN: NOTHING CHANGES FOR ANY ACCOUNT UNTIL A CEO ASSIGNS A CITY.
-- ---------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 1. verify_payment_proof
-- -----------------------------------------------------------------------------
-- Body from 20260922000012, unchanged except for one OR clause. The category
-- is resolved through payment_proofs -> orders -> provider_profiles; the city
-- is resolved through the same join, one hop shorter, because orders carries
-- the city the order was actually placed in -- which is the city the money
-- belongs to, rather than the city the provider happens to be registered in.
CREATE OR REPLACE FUNCTION public.verify_payment_proof(
  p_proof_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_txn uuid;
BEGIN
  IF NOT public.admin_can('payment_verification')
     OR NOT public.staff_scope_allows_category(
          (SELECT pp.category_id
             FROM public.payment_proofs proof
             JOIN public.orders o ON o.id = proof.order_id
             JOIN public.provider_profiles pp ON pp.id = o.provider_id
            WHERE proof.id = p_proof_id))
     -- NEW: the city the order was placed in.
     OR NOT public.staff_scope_allows_city(
          (SELECT o.city
             FROM public.payment_proofs proof
             JOIN public.orders o ON o.id = proof.order_id
            WHERE proof.id = p_proof_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;
  IF p_decision NOT IN ('VERIFIED','REJECTED') THEN
    RAISE EXCEPTION 'INVALID_VERIFICATION_DECISION';
  END IF;

  SELECT order_id, transaction_id INTO v_order.id, v_txn
  FROM public.payment_proofs WHERE id = p_proof_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'PROOF_NOT_FOUND';
  END IF;

  UPDATE public.payment_proofs
  SET verification_status = p_decision, verified_by = auth.uid(), verified_at = now()
  WHERE id = p_proof_id;

  SELECT * INTO v_order FROM public.orders WHERE id = v_order.id;

  IF p_decision = 'VERIFIED' AND v_order.status = 'PAYMENT_VERIFICATION' THEN
    UPDATE public.orders SET status = 'APPROVED', updated_at = now() WHERE id = v_order.id;
    INSERT INTO order_status_history (order_id, from_status, to_status, changed_by)
    VALUES (v_order.id, 'PAYMENT_VERIFICATION', 'APPROVED', auth.uid())
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO notifications (user_id, type, title, body)
  VALUES (
    v_order.user_id,
    CASE WHEN p_decision = 'VERIFIED' THEN 'APPROVAL'::notification_type ELSE 'REJECTION'::notification_type END,
    CASE WHEN p_decision = 'VERIFIED' THEN 'Payment verified' ELSE 'Payment rejected' END,
    COALESCE(p_note, CASE WHEN p_decision = 'VERIFIED'
      THEN 'Your payment has been verified. The provider contact details are now available.'
      ELSE 'Your payment proof could not be verified. Please re-upload.' END)
  );

  PERFORM public.log_admin_action(auth.uid(),
    'PAYMENT_PROOF_' || p_decision, v_order.id, 'transaction', v_order.city,
    '{}', jsonb_build_object('proof_id', p_proof_id, 'note', p_note));
END;
$$;

GRANT EXECUTE ON FUNCTION public.verify_payment_proof(uuid, text, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. staff_task_feed
-- -----------------------------------------------------------------------------
-- Body from 20260927000052, unchanged except for three WHERE clauses on the
-- three branches that already carry the category scope.
CREATE OR REPLACE FUNCTION public.staff_task_feed(
  p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE (
  task_key text,
  source_type text,
  source_id uuid,
  title text,
  description text,
  required_permission text,
  status text,
  is_terminal boolean,
  is_completed boolean,
  action_route text,
  category_id uuid,
  created_at timestamptz,
  terminal_at timestamptz,
  completed_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
  v_caller public.staff;
  v_view_all boolean;
BEGIN
  -- The CALLER's own staff row is the authority to view any queue. Resolving
  -- it separately from the target is what makes the comparison below
  -- meaningful (see the header note: comparing p_staff_id against a row that
  -- was looked up BY p_staff_id can never differ).
  SELECT * INTO v_caller FROM public.staff
  WHERE user_id = v_actor AND is_active LIMIT 1;

  IF p_staff_id IS NULL THEN
    v_staff := v_caller;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND_OR_INACTIVE';
  END IF;
  IF p_staff_id IS NOT NULL
     AND (v_caller.id IS NULL OR p_staff_id <> v_caller.id)
     AND NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_OTHER_STAFF_TASKS';
  END IF;

  -- is_admin() alone includes linked staff, so task visibility intentionally
  -- uses only the true CEO and Super Admin exceptions here.
  v_view_all := public.is_ceo() OR public.is_super_admin();

  RETURN QUERY
  WITH tasks AS (
    SELECT
      'approval:' || a.subject_type::text || ':' || a.subject_id::text AS task_key,
      'REGISTRATION'::text AS source_type,
      a.subject_id AS source_id,
      CASE WHEN a.subject_type = 'PROVIDER'
           THEN 'Approve provider registration'
           ELSE 'Approve user registration' END::text AS title,
      COALESCE(pp.business_name, us.full_name, 'Registration request')::text AS description,
      'registrations'::text AS required_permission,
      a.status::text AS status,
      a.status IN ('APPROVED', 'REJECTED', 'SUSPENDED', 'INACTIVE') AS is_terminal,
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key =
                    'approval:' || a.subject_type::text || ':' || a.subject_id::text) AS is_completed,
      CASE WHEN a.subject_type = 'PROVIDER'
           THEN '/admin/approvals' ELSE '/admin/users' END::text AS action_route,
      pp.category_id,
      a.created_at,
      CASE WHEN a.status IN ('APPROVED', 'REJECTED', 'SUSPENDED', 'INACTIVE')
           THEN a.created_at ELSE NULL END AS terminal_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key =
             'approval:' || a.subject_type::text || ':' || a.subject_id::text) AS completed_at
    FROM (
      SELECT DISTINCT ON (subject_type, subject_id) *
      FROM public.approval_requests
      ORDER BY subject_type, subject_id, created_at DESC
    ) a
    LEFT JOIN public.profiles us ON a.subject_type = 'USER' AND us.id = a.subject_id
    LEFT JOIN public.provider_profiles pp ON a.subject_type = 'PROVIDER' AND pp.id = a.subject_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'registrations'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))
      -- NEW: the registration's city. A PROVIDER subject carries it on
      -- provider_profiles, a USER subject on profiles; coalesced so one clause
      -- serves both, provider first.
      AND (v_view_all OR public.staff_scope_allows_city(
             coalesce(pp.city, us.city), v_staff.user_id))

    UNION ALL
    SELECT
      'support:' || t.id::text, 'SUPPORT_TICKET', t.id,
      COALESCE(NULLIF(t.subject, ''), 'Support ticket'),
      COALESCE(t.description, ''), 'support_chat', t.status,
      t.status IN ('RESOLVED', 'CLOSED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'support:' || t.id::text),
      '/admin/support-tickets', NULL, t.created_at, t.resolved_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'support:' || t.id::text)
    FROM public.support_tickets t
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'support_chat'))

    UNION ALL
    SELECT
      'appeal:' || a.id::text, 'APPEAL', a.id,
      'Resolve user appeal',
      COALESCE(a.description, ''), 'support_chat', a.status,
      a.status IN ('RESOLVED', 'CLOSED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'appeal:' || a.id::text),
      '/admin/appeals', NULL, a.created_at, a.resolved_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'appeal:' || a.id::text)
    FROM public.appeal_cases a
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'support_chat'))

    UNION ALL
    SELECT
      'recharge:' || r.id::text, 'WALLET_RECHARGE', r.id,
      'Review wallet recharge',
      format('ETB %s recharge request', r.amount), 'payment_verification', r.status::text,
      r.status IN ('APPROVED', 'REJECTED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'recharge:' || r.id::text),
      '/admin/payments', pp.category_id, r.created_at,
      COALESCE(r.approved_at, r.updated_at),
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'recharge:' || r.id::text)
    FROM public.wallet_recharge_requests r
    LEFT JOIN public.provider_profiles pp ON pp.id = r.provider_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'payment_verification'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))
      -- NEW: the recharging provider's city.
      AND (v_view_all OR public.staff_scope_allows_city(pp.city, v_staff.user_id))

    UNION ALL
    SELECT
      'payment-proof:' || p.id::text, 'PAYMENT_PROOF', p.id,
      'Verify order payment proof',
      COALESCE(p.storage_path, 'Payment proof'), 'payment_verification',
      p.verification_status, p.verification_status IN ('VERIFIED', 'REJECTED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'payment-proof:' || p.id::text),
      '/admin/payments', pp.category_id, p.created_at, p.verified_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'payment-proof:' || p.id::text)
    FROM public.payment_proofs p
    JOIN public.orders o ON o.id = p.order_id
    LEFT JOIN public.provider_profiles pp ON pp.id = o.provider_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'payment_verification'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))
      -- NEW: the order's city, falling back to the provider's own.
      AND (v_view_all OR public.staff_scope_allows_city(
             coalesce(o.city, pp.city), v_staff.user_id))
  )
  SELECT * FROM tasks t
  -- A cancelled row means "this must leave THIS person's queue": filter the
  -- task out entirely. The completion row itself stays (audit history), and
  -- staff_progress() reads this same feed, so cancelled tasks drop out of
  -- the denominator too -- they were never completed, and are no longer due.
  WHERE NOT EXISTS (
    SELECT 1 FROM public.staff_task_completions c
    WHERE c.staff_id = v_staff.id
      AND c.disposition = 'CANCELLED'
      AND c.task_key = t.task_key
  )
  ORDER BY t.is_completed, t.is_terminal, t.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.staff_task_feed(uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. The scoped READ policies, which were city-blind since 20260922000012
-- -----------------------------------------------------------------------------
-- 0011 and 0012 close every DECISION path. These close the READ paths, so a
-- city-scoped manager does not merely fail to act on another city's rows --
-- they are not handed the rows in the first place. Both policies already
-- branch on the category scope, so the city condition is added as a peer.
DROP POLICY IF EXISTS provider_profiles_staff_registration_read ON public.provider_profiles;
DO $$ BEGIN
  CREATE POLICY provider_profiles_staff_registration_read ON public.provider_profiles FOR SELECT
  USING (
    status = 'APPROVED' OR user_id = auth.uid() OR public.is_admin()
    OR (
      public.staff_has_permission(auth.uid(), 'registrations')
      AND public.staff_scope_allows_category(category_id)
      AND public.staff_scope_allows_city(city)
    )
    OR (
      public.staff_has_permission(auth.uid(), 'payment_verification')
      AND public.staff_scope_allows_category(category_id)
      AND public.staff_scope_allows_city(city)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DROP POLICY IF EXISTS orders_staff_reports_read ON public.orders;
DO $$ BEGIN
  CREATE POLICY orders_staff_reports_read ON public.orders FOR SELECT
  USING (
    public.is_admin()
    OR (
      public.staff_has_permission(auth.uid(), 'view_reports')
      AND public.staff_scope_allows_category(
            (SELECT pp.category_id FROM public.provider_profiles pp
              WHERE pp.id = orders.provider_id))
      -- NEW: the order's own city.
      AND public.staff_scope_allows_city(orders.city)
    )
  );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- -----------------------------------------------------------------------------
-- 4. Pin it, so the next restatement of the feed cannot quietly drop it
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_staff_city_scope_covers_the_task_feed()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_feed text;
  v_proof text;
  v_cat_guard int;
  v_city_guard int;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_feed
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'staff_task_feed';

  IF v_feed IS NULL THEN
    RAISE EXCEPTION 'staff_task_feed is missing';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_proof
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'verify_payment_proof';

  IF v_proof IS NULL THEN
    RAISE EXCEPTION 'verify_payment_proof is missing';
  END IF;

  -- The feed carries three category scopes; it must carry three city scopes,
  -- one on each of those branches and NOT on the two uncategorized ones.
  SELECT count(*) INTO v_cat_guard FROM (
    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x
  ) d WHERE x <> '';
  SELECT count(*) INTO v_city_guard FROM (
    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_city(')) AS x
  ) d WHERE x <> '';

  IF v_city_guard < v_cat_guard THEN
    RAISE EXCEPTION
      'staff_task_feed carries % category scope(s) but only % city scope(s). '
      'Every categorized branch needs both, or the city axis is a filter the '
      'money queue bypasses.', v_cat_guard, v_city_guard;
  END IF;

  IF position('staff_scope_allows_city' in v_proof) = 0 THEN
    RAISE EXCEPTION 'verify_payment_proof no longer enforces the city scope -- a city-scoped person could verify another city''s payment';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_staff_city_scope_covers_the_task_feed() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_staff_city_scope_covers_the_task_feed()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
