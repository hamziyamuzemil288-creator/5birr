-- =============================================================================
-- 20260927000111_staff_city_guards_on_provider_actions.sql
--
-- The city scope, applied to every provider lifecycle decision.
--
-- WHERE THIS LEAVES OFF
-- ----------------------
-- 00110 put the guard on the registration QUEUE. That made the city scope
-- real for reading, and left the five actions that actually change a provider
-- untouched -- so a Hawassa manager could not *see* an Addis Ababa provider
-- in the queue but could still approve one by id, if they had it. A scope
-- that filters a list and does not filter its buttons is half a scope.
--
-- These five already carry the category scope, so this is the identical
-- operation applied to the identical block:
--
--   OR NOT public.staff_scope_allows_category(
--        (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
--
-- becomes
--
--   OR NOT public.staff_scope_allows_category(...)
--   OR NOT public.staff_scope_allows_city(
--        (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id))
--
-- NOTHING ELSE IN ANY BODY IS TOUCHED
-- ----------------------------------
-- approve_provider is re-emitted from 20260927000087, NOT from 00026. 00026
-- is the older text and predates the welcome-on-approval notification; basing
-- this on it would silently delete a user-facing feature, which is the exact
-- failure mode 00026's own header warns about when it describes the 00020
-- regression ("a restatement that drops one does not fail loudly -- it just
-- silently drops a protection"). The four actions below are unchanged since
-- 00026 and are copied from it verbatim.
--
-- Every guard sits INSIDE `IF NOT public.is_server_write()`, so the
-- provider-approval Edge Function -- which has already run its own role
-- checks -- is completely unaffected. This migration cannot break that path.
--
-- NOTHING CHANGES FOR ANYONE UNTIL A CITY IS ASSIGNED
-- ----------------------------------------------------
-- staff_scope_allows_city returns TRUE when the staff row's city IS NULL, and
-- every staff row has a NULL city today. So all five functions evaluate
-- exactly as they did an hour ago, for every account, until a CEO assigns a
-- city to someone.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. approve_provider  (body from 20260927000087, + one guard clause)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider public.provider_profiles;
  v_name text;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       -- NEW: the city scope. Inert until a CEO assigns a staff member a city.
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  IF p_admin_id = (SELECT user_id FROM public.provider_profiles WHERE id = p_provider_id) THEN
    RAISE EXCEPTION 'CANNOT_APPROVE_OWN_ACCOUNT';
  END IF;

  UPDATE public.provider_profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;

  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  -- Completion gate: the profile is what the login router checks.
  UPDATE public.profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = v_provider.user_id;

  -- Close the approval request so the admin list stops showing it.
  UPDATE public.approval_requests
    SET status = 'APPROVED'
    WHERE subject_type = 'PROVIDER'
      AND subject_id = p_provider_id
      AND status = 'PENDING_APPROVAL';

  -- Wallet (created on approval; idempotent)
  INSERT INTO public.wallets (provider_id, balance)
  VALUES (p_provider_id, 0)
  ON CONFLICT (provider_id) DO NOTHING;

  -- Initial subscription: ACTIVE from approval, first payment due in one
  -- month (deduct_subscription_fee() advances next_due_date from here).
  INSERT INTO public.subscriptions (provider_id, status, next_due_date)
  VALUES (p_provider_id, 'ACTIVE', now() + interval '1 month')
  ON CONFLICT (provider_id) DO NOTHING;

  INSERT INTO public.approval_history (subject_type, subject_id, action, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    v_provider.user_id,
    'APPROVAL',
    'Application approved',
    'Your provider account is now active.'
  );

  -- The welcome. business_name is the provider's own trading name, so this
  -- addresses them the way their customers will see them; full_name is the
  -- fallback when the profile was created without one. COALESCE rather than a
  -- NULL-guarded string, because '<name>' in a welcome is worse than no name.
  v_name := COALESCE(
    NULLIF(btrim(v_provider.business_name), ''),
    (SELECT NULLIF(btrim(full_name), '') FROM public.profiles WHERE id = v_provider.user_id)
  );

  PERFORM public.notify_user_once(
    'provider-approved:' || p_provider_id::text,
    v_provider.user_id,
    'APPROVAL',
    'Welcome to Aliob',
    CASE
      WHEN v_name IS NULL THEN
        'Your account is approved and ready to go.'
      ELSE
        'Welcome to Aliob, ' || v_name || '. Your account is approved and ready to go.'
    END,
    jsonb_build_object('provider_id', p_provider_id, 'event', 'provider_approved')
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('provider_user', v_provider.user_id));

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_provider(uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. reject_provider  (body from 00026, + one guard clause)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'REJECTED', updated_at = now()
    WHERE id = v_provider.user_id;

  UPDATE public.approval_requests
    SET status = 'REJECTED'
    WHERE subject_type = 'PROVIDER'
      AND subject_id = p_provider_id
      AND status = 'PENDING_APPROVAL';

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'REJECT', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
    SELECT user_id, 'REJECTION', 'Application rejected', p_reason
    FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
    VALUES (p_admin_id, 'REJECT_PROVIDER', 'provider_profiles', p_provider_id,
            jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'REJECT_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reject_provider(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. request_correction_provider  (body from 00026, + one guard clause)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_correction_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'REJECTED', updated_at = now()
    WHERE id = v_provider.user_id;

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'REQUEST_CORRECTION', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
    SELECT user_id, 'CORRECTION_REQUIRED', 'Correction requested', 'Please update your submission: ' || p_reason
    FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
    VALUES (p_admin_id, 'REQUEST_CORRECTION', 'provider_profiles', p_provider_id,
            jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'REQUEST_CORRECTION_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_correction_provider(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. suspend_provider  (body from 00026, + one guard clause)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.suspend_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text default null
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  UPDATE provider_profiles SET status = 'SUSPENDED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'SUSPENDED', updated_at = now()
    WHERE id = v_provider.user_id;

  UPDATE vehicles SET is_available = false WHERE provider_id = p_provider_id AND status = 'APPROVED';

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
    VALUES ('PROVIDER', p_provider_id, 'SUSPEND', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
    SELECT user_id, 'PROVIDER_INACTIVE', 'Account suspended', coalesce(p_reason, 'Your provider account has been suspended.')
    FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
    VALUES (p_admin_id, 'SUSPEND_PROVIDER', 'provider_profiles', p_provider_id,
            jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'SUSPEND_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.suspend_provider(uuid, uuid, text) TO authenticated;

-- -----------------------------------------------------------------------------
-- 5. unsuspend_provider  (body from 00026, + one guard clause)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.unsuspend_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  UPDATE provider_profiles SET status = 'APPROVED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'APPROVED', updated_at = now()
    WHERE id = v_provider.user_id;

  PERFORM public.log_admin_action(p_admin_id, 'UNSUSPEND_PROVIDER', p_provider_id,
    'registration', v_provider.city);

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unsuspend_provider(uuid, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 6. Pin the new condition, so a later restatement that drops it fails CI
-- -----------------------------------------------------------------------------
-- The existing assertion already pins the category scope for these five. It
-- was written after 00020 silently reverted that layer, so it pins conditions
-- one at a time rather than trusting the body. The city condition is now a
-- peer of the category condition and is pinned the same way.
CREATE OR REPLACE FUNCTION public.assert_admin_rpc_service_role_access()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_name text;
  v_needs_scope boolean;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'approve_wallet_recharge',
    'approve_provider',
    'reject_provider',
    'request_correction_provider',
    'suspend_provider',
    'unsuspend_provider'
  ] LOOP
    v_needs_scope := v_name <> 'approve_wallet_recharge';

    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_flat IS NULL THEN
      RETURN false;
    END IF;

    -- Server exemption present...
    IF position('is_server_write' in v_flat) = 0 THEN
      RETURN false;
    END IF;

    -- ...and the client branch still enforcing every condition it should.
    IF position('insufficient_permission' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('admin_can' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('is distinct from auth.uid()' in v_flat) = 0 THEN
      RETURN false;
    END IF;

    -- The staff-scope layer, which 00020 dropped while passing all of the
    -- checks above, plus the city scope added in 00111.
    IF v_needs_scope THEN
      IF position('staff_is_action_manager' in v_flat) = 0 THEN
        RETURN false;
      END IF;
      IF position('staff_scope_allows_category' in v_flat) = 0 THEN
        RETURN false;
      END IF;
      -- NEW. Pinning it here means the next migration that re-emits one of
      -- these five from a stale copy loses CI instead of silently narrowing
      -- the scope -- which is exactly how the category layer was lost once.
      IF position('staff_scope_allows_city' in v_flat) = 0 THEN
        RETURN false;
      END IF;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_admin_rpc_service_role_access() IS
  'True when the six Edge-Function-mediated admin RPCs exempt server writes '
  'via is_server_write() while still enforcing the full client-side check: '
  'permission, identity, and -- for the five provider actions -- the staff '
  'action-manager, category-scope and city-scope conditions. Pinned condition '
  'by condition because 00020 lost two of them and still passed the earlier '
  'version of this assertion.';

GRANT EXECUTE ON FUNCTION public.assert_admin_rpc_service_role_access() TO authenticated;

-- -----------------------------------------------------------------------------
-- 7. The read side: a staff member's own scope, so the app can show it
-- -----------------------------------------------------------------------------
-- A scope nobody can see is a scope the user cannot understand. This is what
-- the admin sidebar shows next to a city-scoped person's name: which city
-- they are confined to, and that they are confined at all.
CREATE OR REPLACE FUNCTION public.my_staff_scope_summary()
RETURNS TABLE (
  is_staff boolean,
  is_unrestricted boolean,
  cities text[],
  permissions text[],
  job_role text,
  city text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_staff public.staff;
BEGIN
  SELECT * INTO v_staff FROM public.staff WHERE user_id = auth.uid();

  RETURN QUERY
  SELECT v_staff.id IS NOT NULL,
         public.staff_city_scope() = '{}'::text[],
         public.staff_city_scope(),
         coalesce(v_staff.permissions, '{}'::text[]),
         v_staff.job_role,
         v_staff.city;
END;
$$;

COMMENT ON FUNCTION public.my_staff_scope_summary() IS
  'What the signed-in account is actually scoped to. is_unrestricted is true '
  'for the CEO, a super admin, any ADMIN-role user, and for a staff member '
  'who has not been assigned a city yet.';

REVOKE ALL ON FUNCTION public.my_staff_scope_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_staff_scope_summary()
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
