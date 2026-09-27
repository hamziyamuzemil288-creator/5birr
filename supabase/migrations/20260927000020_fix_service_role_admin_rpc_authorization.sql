-- Let the server-mediated admin actions authorize again.
--
-- The bug
-- ------
-- 20260922000010 introduced staff permission enforcement with this guard on
-- every admin RPC:
--
--   IF NOT public.admin_can('sales_transactions')
--      OR p_admin_id IS DISTINCT FROM auth.uid() THEN
--     RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
--   END IF;
--
-- It is correct for an RPC the app calls directly with the signed-in user's
-- own JWT, and the app does call four of them that way
-- (admin_cash_recharge, admin_wallet_adjustment, approve_user, reject_user --
-- each passing Supabase.instance.client.auth.currentUser.id, which is exactly
-- auth.uid()). Those work.
--
-- It cannot work for an RPC reached through an Edge Function, and six of them
-- are reached that way. _shared/client.ts builds a second client on
-- SUPABASE_SERVICE_ROLE_KEY precisely so the function can act after it has
-- done its own authorization:
--
--   const { user } = await requireRole(req, "ADMIN");   // verifies the JWT
--   const admin = getAdminClient();                     // service_role
--   await admin.rpc("approve_wallet_recharge", { p_admin_id: user.id, ... });
--
-- Under service_role there is no signed-in user, so auth.uid() is NULL. Then:
--
--   admin_can(...)          = is_admin() OR staff_has_permission(NULL, ...)
--                          = false, because is_admin() is `user_id = auth.uid()`
--   p_admin_id IS DISTINCT FROM NULL   = true, for any non-null p_admin_id
--
-- Both halves of the OR are true, so the guard raises. It raises before
-- touching a single row, which means the failure is total and silent: no
-- ledger entry, no audit row, just an error surfaced to the admin.
--
-- Broken today, and confirmed by reading the call sites:
--
--   admin-wallet-recharge -> approve_wallet_recharge
--   provider-approval     -> approve_provider, reject_provider,
--                            request_correction_provider, suspend_provider,
--                            unsuspend_provider
--
-- So it is not only wallet recharges. The entire provider approval pipeline --
-- the thing every new seller has to pass through -- cannot complete either.
--
-- The fix
-- ------
-- Trust the service-role path, because the Edge Function's requireRole is the
-- real gate, and keep the client path exactly as strict as it was.
--
-- requireRole is a genuine check, not a claim the client controls: it calls
-- auth.getUser() on a client built from the caller's own Authorization header,
-- then reads user_roles server-side and requires the ADMIN role. Only after
-- that does it use the service-role client. So p_admin_id on that path is the
-- id of an admin this server just verified.
--
-- The four directly-called RPCs are deliberately left untouched. For a client
-- call is_server_write() is false, so they take exactly the branch they took
-- before -- same permission check, same identity assertion. This migration can
-- only ever widen access for server-initiated calls; it cannot loosen a client.
--
-- approve_provider's self-approval check is also repaired. It compared
-- auth.uid() against the provider's owner; under service_role auth.uid() is
-- NULL and `NULL = user_id` is NULL, so the check never fired. Comparing
-- p_admin_id instead is equivalent on the client path (where p_admin_id has
-- already been pinned to auth.uid()) and actually works on the service path.

-- ---------------------------------------------------------------------------
-- Wallets
-- ---------------------------------------------------------------------------
create or replace function public.approve_wallet_recharge(
  p_recharge_id uuid,
  p_admin_id uuid
)
returns public.wallet_recharge_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recharge wallet_recharge_requests;
  v_wallet wallets;
  v_txn wallet_transactions;
  v_credit numeric;
  v_reg_fee numeric;
  v_first boolean;
  v_user_id uuid;
begin
  -- Server-initiated (admin-wallet-recharge, which has already run
  -- requireRole(ADMIN)) is trusted and identifies the approving admin through
  -- p_admin_id. A direct client call must still prove both halves.
  if not public.is_server_write() then
    if not public.admin_can('sales_transactions') or p_admin_id is distinct from auth.uid() then
      raise exception 'INSUFFICIENT_PERMISSION';
    end if;
  end if;

  select * into v_recharge from wallet_recharge_requests where id = p_recharge_id for update;
  if v_recharge.id is null then
    raise exception 'RECHARGE_REQUEST_NOT_FOUND';
  end if;
  if v_recharge.status = 'APPROVED' then
    return v_recharge;
  end if;
  if v_recharge.status != 'PENDING' then
    raise exception 'RECHARGE_REQUEST_IS_NOT_PENDING';
  end if;

  select * into v_wallet from wallets where id = v_recharge.wallet_id for update;
  if v_wallet.id is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;

  select pp.registration_fee_paid into v_first
    from provider_profiles pp where pp.id = v_recharge.provider_id;
  if v_first is null then
    raise exception 'PROVIDER_NOT_FOUND';
  end if;

  v_credit := v_recharge.amount;
  if not v_first then
    -- One-time activation: withhold the registration fee from this first
    -- approved recharge and activate the provider.
    v_reg_fee := coalesce(get_setting_numeric('provider_registration_fee'), 100);
    if v_recharge.amount < v_reg_fee then
      raise exception 'REGISTRATION_FEE_REQUIRED';
    end if;
    v_credit := v_recharge.amount - v_reg_fee;
  end if;

  update wallets set balance = balance + v_credit, updated_at = now()
   where id = v_wallet.id
   returning * into v_wallet;

  insert into wallet_transactions (
    wallet_id, provider_id, transaction_type,
    gross_amount, platform_fee, net_amount,
    balance_after, status, idempotency_key
  ) values (
    v_wallet.id, v_recharge.provider_id, 'RECHARGE',
    v_recharge.amount, v_recharge.amount - v_credit, v_credit,
    v_wallet.balance, 'COMPLETED', 'recharge:' || v_recharge.id::text
  ) returning * into v_txn;

  if not v_first then
    update provider_profiles
       set registration_fee_paid = true, updated_at = now()
     where id = v_recharge.provider_id;
  end if;

  update wallet_recharge_requests
     set status = 'APPROVED', approved_by = p_admin_id, approved_at = now(), updated_at = now()
   where id = p_recharge_id
   returning * into v_recharge;

  select user_id into v_user_id from provider_profiles where id = v_recharge.provider_id;

  if not v_first then
    perform insert_notification(
      v_user_id, 'APPROVAL', 'Account activated',
      'Your ' || v_recharge.amount::text || ' birr payment was received. ' ||
        'The one-time 100 birr registration fee was applied and ' ||
        v_credit::text || ' birr was credited to your wallet. You are ready to trade!',
      jsonb_build_object('recharge_id', p_recharge_id, 'credited', v_credit, 'registration_fee', v_recharge.amount - v_credit)
    );
  else
    perform insert_notification(
      v_user_id, 'APPROVAL', 'Recharge Approved',
      v_recharge.amount::text || ' birr credited to your wallet.',
      jsonb_build_object('recharge_id', p_recharge_id, 'credited', v_credit)
    );
  end if;

  insert into audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (p_admin_id, 'WALLET_RECHARGE_APPROVED', 'wallets', v_wallet.id,
          jsonb_build_object(
            'recharge_id', p_recharge_id,
            'amount', v_recharge.amount,
            'credited', v_credit,
            'registration_fee_withheld', case when not v_first then v_recharge.amount - v_credit else 0 end,
            'provider_activated', not v_first
          ));

  return v_recharge;
end;
$$;

-- ---------------------------------------------------------------------------
-- Provider approval pipeline (all reached through provider-approval)
-- ---------------------------------------------------------------------------
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
    IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  -- Keyed on p_admin_id rather than auth.uid(): identical on the client path
  -- (p_admin_id was just pinned to auth.uid()) and, unlike auth.uid(), it is
  -- not NULL under service_role -- auth.uid() made this check silently inert.
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
    IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
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
    IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
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
    IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
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
    IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
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
-- Assertion: the six server-mediated RPCs must route through the helper, and
-- every one of them must still refuse a direct client call. Both halves are
-- required, so neither "delete the guard" nor "keep the broken guard" passes.
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
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'approve_wallet_recharge',
    'approve_provider',
    'reject_provider',
    'request_correction_provider',
    'suspend_provider',
    'unsuspend_provider'
  ] LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_flat IS NULL THEN
      RETURN false;
    END IF;

    IF position('is_server_write' in v_flat) = 0 THEN
      RETURN false;
    END IF;

    -- The client branch must survive: the permission check and the identity
    -- assertion both have to remain inside it.
    IF position('insufficient_permission' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('admin_can' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('is distinct from auth.uid()' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_admin_rpc_service_role_access() IS
  'True when the six Edge-Function-mediated admin RPCs exempt server writes '
  'via is_server_write() while still enforcing the permission and identity '
  'checks for direct client calls.';

GRANT EXECUTE ON FUNCTION public.assert_admin_rpc_service_role_access() TO authenticated;
