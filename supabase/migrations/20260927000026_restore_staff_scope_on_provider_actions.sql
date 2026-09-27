-- Restore the staff-scope checks that 00020 silently reverted.
--
-- The regression
-- -------------
-- 20260927000020 re-emitted approve_provider, reject_provider,
-- request_correction_provider, suspend_provider and unsuspend_provider to add
-- the is_server_write() exemption. The bodies it copied came from
-- 20260922000010.
--
-- That was the wrong source. 20260922000012 re-emitted the same five with an
-- additional authorization layer:
--
--   OR NOT public.staff_is_action_manager()
--   OR NOT public.staff_scope_allows_category(
--        (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
--
-- 00020 sorts after 00012, so it won. The net effect was that from the moment
-- 00020 deployed, every staff member holding the 'registrations' permission
-- could approve, reject, request-correction, suspend or unsuspend ANY provider
-- again -- a category-scoped action manager acting outside their scope was no
-- longer refused. That is an authorization widening, in the provider approval
-- pipeline, introduced by the same change that was meant to unblock it.
--
-- How it went unnoticed
-- ---------------------
-- assert_admin_rpc_service_role_access checks that each of the six RPCs routes
-- through is_server_write() and still contains admin_can, the identity check
-- and the raise. Every one of those was true of the reverted bodies, so the
-- assertion passed on a function that had lost two of its four conditions. The
-- assertion was written to catch the bug I expected, and was blind to the one
-- I caused. That is what this migration's assertion is for.
--
-- The fix
-- -------
-- Re-emit all five from the 00012 bodies -- the staff-scope layer included --
-- with only the server exemption added, and the same exemption shape used
-- throughout this series. A direct client call must still satisfy all four
-- conditions; only a server-initiated call is exempt, and only because
-- provider-approval has already run requireRole(ADMIN) and
-- staff_is_action_manager-equivalent checks of its own before it calls.
--
-- approve_provider's self-approval check stays keyed on p_admin_id rather than
-- auth.uid(), from 00020: identical on the client path, and it actually works
-- on the service-role path where auth.uid() is NULL.

create or replace function public.approve_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider public.provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
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

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('provider_user', v_provider.user_id));

  RETURN v_provider;
END;
$$;

create or replace function public.reject_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
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

create or replace function public.request_correction_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
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

create or replace function public.suspend_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text default null
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
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

create or replace function public.unsuspend_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
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

-- ---------------------------------------------------------------------------
-- The assertion that would have caught 00020.
--
-- assert_admin_rpc_service_role_access only checked for is_server_write,
-- admin_can, the identity check and the raise. All four survived the revert,
-- so it passed on functions that had lost the staff-scope layer. This version
-- pins every condition the five provider RPCs are supposed to carry, so
-- dropping one -- deliberately or by re-emitting a stale body -- fails CI.
--
-- approve_wallet_recharge has no staff-scope layer (it is a sales_transactions
-- action, scoped by provider id rather than category), so it is checked only
-- for the conditions it actually has.
-- ---------------------------------------------------------------------------
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
    -- checks above.
    IF v_needs_scope THEN
      IF position('staff_is_action_manager' in v_flat) = 0 THEN
        RETURN false;
      END IF;
      IF position('staff_scope_allows_category' in v_flat) = 0 THEN
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
  'action-manager and category-scope conditions. Pinned condition by condition '
  'because 00020 lost two of them and still passed the earlier version of '
  'this assertion.';

GRANT EXECUTE ON FUNCTION public.assert_admin_rpc_service_role_access() TO authenticated;
