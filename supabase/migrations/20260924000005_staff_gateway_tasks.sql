-- Task 12: staff gateway credentials, actionable task feed, and progress.
-- Passwords remain exclusively in Supabase Auth. This migration stores only
-- username mappings, lockout state, and task acknowledgements.

CREATE TABLE IF NOT EXISTS public.staff_credentials (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL UNIQUE REFERENCES public.staff(id) ON DELETE CASCADE,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  username text NOT NULL CHECK (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts >= 0),
  locked_until timestamptz,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_credentials_username
  ON public.staff_credentials (lower(username));
CREATE INDEX IF NOT EXISTS idx_staff_credentials_lockout
  ON public.staff_credentials (locked_until);

CREATE TABLE IF NOT EXISTS public.staff_task_completions (
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  task_key text NOT NULL,
  source_type text NOT NULL,
  source_id uuid NOT NULL,
  completed_at timestamptz NOT NULL DEFAULT now(),
  terminal_at timestamptz,
  PRIMARY KEY (staff_id, task_key)
);
CREATE INDEX IF NOT EXISTS idx_staff_task_completions_recent
  ON public.staff_task_completions (staff_id, completed_at DESC);

ALTER TABLE public.staff_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff_task_completions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_credentials_self_read ON public.staff_credentials;
CREATE POLICY staff_credentials_self_read ON public.staff_credentials FOR SELECT
  USING (
    user_id = auth.uid()
    OR public.is_ceo()
    OR public.is_super_admin()
  );

DROP POLICY IF EXISTS staff_task_completions_read ON public.staff_task_completions;
CREATE POLICY staff_task_completions_read ON public.staff_task_completions FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.staff s
            WHERE s.id = staff_id AND s.user_id = auth.uid())
    OR public.is_ceo()
    OR public.is_super_admin()
  );

-- Only the Edge Function using service_role may create credential mappings or
-- update login counters. No client receives direct table-write access.
REVOKE ALL ON public.staff_credentials FROM anon, authenticated;
REVOKE ALL ON public.staff_task_completions FROM anon, authenticated;
GRANT SELECT ON public.staff_credentials TO authenticated;
GRANT SELECT ON public.staff_task_completions TO authenticated;

-- Staff gateway accounts are created by the Edge Function with server-only
-- app_metadata. Extend the existing signup trigger's trusted bypass so the
-- gateway Auth user is not rejected as an unverified public signup; ordinary
-- user_metadata remains incapable of activating this path.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
BEGIN
  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
  );
  IF NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  END IF;

  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city, kebele, street_road)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'PENDING_APPROVAL'::account_status,
    COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
    NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
    NULLIF(new.raw_user_meta_data ->> 'street_road', '')
  ) ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'PENDING_APPROVAL'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  -- Preserve the provider half of the existing signup trigger. Gateway users
  -- have no provider metadata, so this branch is inert for them.
  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(new.raw_user_meta_data ->> 'business_name', new.raw_user_meta_data ->> 'full_name', 'New Provider'),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', '')
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;
  RETURN new;
END;
$$;

-- The function is called only after the Edge Function has authenticated the
-- CEO and created a Supabase Auth user. The RPC re-checks the CEO identity and
-- derives the synthetic email mapping from the normalized username.
CREATE OR REPLACE FUNCTION public.create_staff_gateway(
  p_actor_id uuid,
  p_auth_user_id uuid,
  p_username text,
  p_name text,
  p_staff_code text,
  p_permissions text[],
  p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false,
  p_branch text DEFAULT 'ADMIN',
  p_assigned_categories uuid[] DEFAULT '{}'
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_username text := lower(btrim(p_username));
  v_email text := v_username || '@staff-gateway.invalid';
  v_staff public.staff;
BEGIN
  IF NOT public.is_ceo(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_STAFF_GATEWAY';
  END IF;
  IF v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' THEN
    RAISE EXCEPTION 'INVALID_STAFF_USERNAME';
  END IF;
  IF p_branch NOT IN ('ADMIN', 'ME') OR (p_is_super_admin AND p_branch <> 'ADMIN') THEN
    RAISE EXCEPTION 'INVALID_STAFF_BRANCH';
  END IF;
  IF p_is_super_admin AND EXISTS (
    SELECT 1 FROM public.staff
    WHERE is_super_admin AND is_active AND user_id <> p_auth_user_id
  ) THEN
    RAISE EXCEPTION 'SUPER_ADMIN_ALREADY_EXISTS';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff_credentials WHERE lower(username) = v_username) THEN
    RAISE EXCEPTION 'STAFF_USERNAME_TAKEN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_auth_user_id AND lower(email) = v_email) THEN
    RAISE EXCEPTION 'STAFF_AUTH_IDENTITY_MISMATCH';
  END IF;

  INSERT INTO public.staff
    (user_id, name, staff_code, permissions, sales_target, is_super_admin,
     branch, is_ceo, assigned_categories, created_by)
  VALUES
    (p_auth_user_id, btrim(p_name), btrim(p_staff_code), p_permissions,
     COALESCE(p_sales_target, 0), p_is_super_admin, p_branch, false,
     COALESCE(p_assigned_categories, '{}'::uuid[]), p_actor_id)
  RETURNING * INTO v_staff;

  INSERT INTO public.staff_credentials (staff_id, user_id, username)
  VALUES (v_staff.id, p_auth_user_id, v_username);

  INSERT INTO public.user_roles (user_id, role)
  VALUES (p_auth_user_id, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- The Auth trigger may have created a normal user profile. Gateway accounts
  -- are staff identities, not pending public registrations.
  UPDATE public.profiles
  SET full_name = btrim(p_name), email = v_email,
      status = 'APPROVED', updated_at = now()
  WHERE id = p_auth_user_id;
  DELETE FROM public.approval_requests
  WHERE subject_type = 'USER' AND subject_id = p_auth_user_id
    AND status = 'PENDING_APPROVAL';

  PERFORM public.log_admin_action(
    p_actor_id, 'STAFF_GATEWAY_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('username', v_username,
                             'permissions', to_jsonb(p_permissions))
  );
  RETURN v_staff;
END;
$$;

-- Called by the login Edge Function after GoTrue accepts/rejects a password.
-- Five failures lock the account for 15 minutes; success clears the counter.
CREATE OR REPLACE FUNCTION public.staff_gateway_record_login(
  p_username text,
  p_success boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.staff_credentials;
BEGIN
  SELECT * INTO v_row
  FROM public.staff_credentials
  WHERE lower(username) = lower(btrim(p_username))
  FOR UPDATE;
  IF v_row.id IS NULL THEN
    RETURN false;
  END IF;
  IF p_success THEN
    UPDATE public.staff_credentials
    SET failed_attempts = 0, locked_until = NULL,
        last_login_at = now(), updated_at = now()
    WHERE id = v_row.id;
    RETURN true;
  END IF;
  IF v_row.locked_until IS NOT NULL AND v_row.locked_until > now() THEN
    RETURN false;
  END IF;
  UPDATE public.staff_credentials
  SET failed_attempts = failed_attempts + 1,
      locked_until = CASE
        WHEN failed_attempts + 1 >= 5 THEN now() + interval '15 minutes'
        ELSE locked_until
      END,
      updated_at = now()
  WHERE id = v_row.id;
  RETURN true;
END;
$$;

-- Return actual permission-gated work items, not manually invented tasks.
-- Terminal work remains visible until the staff member acknowledges it, so
-- the dashboard can expose a real Completed list and an auditable completion.
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
  v_view_all boolean;
BEGIN
  IF p_staff_id IS NULL THEN
    SELECT * INTO v_staff FROM public.staff
    WHERE user_id = v_actor AND is_active LIMIT 1;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND_OR_INACTIVE';
  END IF;
  IF p_staff_id IS NOT NULL AND p_staff_id <> v_staff.id
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
  )
  SELECT * FROM tasks
  ORDER BY is_completed, is_terminal, created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_mark_task_done(
  p_task_key text,
  p_staff_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
  v_task record;
BEGIN
  IF p_staff_id IS NULL THEN
    SELECT * INTO v_staff FROM public.staff
    WHERE user_id = v_actor AND is_active LIMIT 1;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND user_id = v_actor AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_CAN_ONLY_MARK_OWN_TASKS';
  END IF;

  SELECT * INTO v_task
  FROM public.staff_task_feed(v_staff.id)
  WHERE task_key = p_task_key
  LIMIT 1;
  IF v_task.task_key IS NULL THEN
    RAISE EXCEPTION 'TASK_NOT_FOUND_OR_NOT_PERMITTED';
  END IF;
  IF NOT v_task.is_terminal THEN
    RAISE EXCEPTION 'TASK_MUST_REACH_TERMINAL_STATE_FIRST';
  END IF;

  INSERT INTO public.staff_task_completions
    (staff_id, task_key, source_type, source_id, completed_at, terminal_at)
  VALUES
    (v_staff.id, v_task.task_key, v_task.source_type, v_task.source_id,
     now(), v_task.terminal_at)
  ON CONFLICT (staff_id, task_key) DO UPDATE
    SET completed_at = EXCLUDED.completed_at,
        terminal_at = EXCLUDED.terminal_at;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.staff_progress(
  p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE (
  completed_tasks bigint,
  remaining_tasks bigint,
  total_tasks bigint,
  progress_percent numeric,
  average_resolution_hours numeric,
  completed_last_30_days bigint,
  last_activity_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF p_staff_id IS NULL THEN
    SELECT * INTO v_staff FROM public.staff
    WHERE user_id = v_actor AND is_active LIMIT 1;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL OR (
    p_staff_id IS NOT NULL AND p_staff_id <> v_staff.id
    AND NOT (public.is_ceo() OR public.is_super_admin())
  ) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_PROGRESS';
  END IF;

  RETURN QUERY
  WITH feed AS (
    SELECT * FROM public.staff_task_feed(v_staff.id)
  )
  SELECT
    count(*) FILTER (WHERE is_completed),
    count(*) FILTER (WHERE NOT is_completed),
    count(*),
    CASE WHEN count(*) = 0 THEN 0
         ELSE round(100.0 * count(*) FILTER (WHERE is_completed) / count(*), 1)
    END,
    COALESCE(avg(extract(epoch FROM (terminal_at - created_at)) / 3600.0)
      FILTER (WHERE is_completed AND terminal_at IS NOT NULL), 0),
    count(*) FILTER (WHERE is_completed AND completed_at >= now() - interval '30 days'),
    max(completed_at)
  FROM feed;
END;
$$;

REVOKE ALL ON FUNCTION public.create_staff_gateway(uuid, uuid, text, text, text, text[], numeric, boolean, text, uuid[]) FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.staff_gateway_record_login(text, boolean) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_staff_gateway(uuid, uuid, text, text, text, text[], numeric, boolean, text, uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.staff_gateway_record_login(text, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public.staff_task_feed(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_mark_task_done(text, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_progress(uuid) TO authenticated;

-- Keep the gateway username mapping current when an administrator revokes a
-- staff row. The Auth account is intentionally not deleted here; revocation
-- remains reversible and the login function refuses inactive staff.
CREATE OR REPLACE FUNCTION public.sync_staff_gateway_revocation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_active = false AND (OLD.is_active IS DISTINCT FROM false) THEN
    UPDATE public.staff_credentials
    SET locked_until = now() + interval '100 years', updated_at = now()
    WHERE staff_id = NEW.id;
  ELSIF NEW.is_active = true AND (OLD.is_active IS DISTINCT FROM true) THEN
    UPDATE public.staff_credentials
    SET failed_attempts = 0, locked_until = NULL, updated_at = now()
    WHERE staff_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_staff_gateway_revocation ON public.staff;
CREATE TRIGGER trg_staff_gateway_revocation
AFTER UPDATE OF is_active ON public.staff
FOR EACH ROW EXECUTE FUNCTION public.sync_staff_gateway_revocation();
