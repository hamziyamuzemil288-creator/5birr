-- ============================================================================
-- Staff permission enforcement (Plan B)
-- ============================================================================
-- Until now the staff table (20260922000001) stored permission arrays but
-- nothing enforced them: every admin action was gated only by is_admin()
-- (i.e. user_roles.role = 'ADMIN'). This migration makes sub-admin
-- permissions real, server-side:
--
--   1. Helpers  staff_has_permission() / admin_can()
--   2. Guard swaps on the 11 admin-action RPCs:
--        registrations          -> approve/reject/request_correction/suspend/
--                                  unsuspend provider, approve/reject user
--        payment_verification   -> verify_payment_proof
--        sales_transactions     -> admin_cash_recharge, admin_wallet_adjustment,
--                                  approve_wallet_recharge
--      plus a security fix: approve_provider's self-approval check compared
--      the CLIENT-SUPPLIED p_admin_id against the provider owner; it now uses
--      auth.uid() (identity cannot be spoofed by params).
--   3. Additive RLS so permitted staff can actually READ the rows their
--      screens display (all previous policies were owner-or-admin only), and
--      WRITE only what their permission covers (support ticket resolution,
--      notification sending, category management).
--
-- Super admins (staff.is_super_admin) and true ADMINs (user_roles) keep full
-- access. Nothing is narrowed for existing admins.
-- ============================================================================

-- ------------------------------------------------------------
-- 1. Permission helpers (SECURITY DEFINER so the staff read
--    inside the function bypasses RLS without recursing).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_has_permission(
  p_user_id uuid DEFAULT auth.uid(),
  -- A param after one with a default must also have one (42P13); the NULL
  -- guard in the body fails closed, so an omitted permission never grants.
  p_permission text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT p_permission IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id
      AND is_active
      AND (is_super_admin OR p_permission = ANY (permissions))
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_can(
  p_permission text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_admin() OR public.staff_has_permission(auth.uid(), p_permission);
$$;

GRANT EXECUTE ON FUNCTION public.staff_has_permission(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_can(text) TO authenticated;

-- ------------------------------------------------------------
-- 2. RPC guard swaps (full bodies re-emitted verbatim except
--    the guard blocks and the one identity fix noted above).
-- ------------------------------------------------------------

-- 2a. Provider registration actions -> 'registrations'
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
  -- Caller permission + identity assertion: p_admin_id must be the caller
  -- (legacy param, kept for audit rows) and cannot name someone else.
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  IF auth.uid() = (SELECT user_id FROM public.provider_profiles WHERE id = p_provider_id) THEN
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
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
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
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
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
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
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
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
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

-- 2b. User registration actions -> 'registrations'
create or replace function public.approve_user(
  p_user_id uuid,
  p_admin_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_profile public.profiles;
begin
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE public.profiles
  SET    status = 'APPROVED', updated_at = now()
  WHERE  id = p_user_id
  RETURNING * INTO v_profile;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  UPDATE public.approval_requests
  SET    status = 'APPROVED'
  WHERE  subject_type = 'USER'
  AND    subject_id = p_user_id
  AND    status = 'PENDING_APPROVAL';

  INSERT INTO public.approval_history
    (subject_type, subject_id, action, performed_by)
  VALUES
    ('USER', p_user_id, 'APPROVE', p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_user_id,
    'APPROVAL',
    'Account approved',
    'Your account has been approved. You can now use the app.'
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_USER', 'profiles', p_user_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_USER', p_user_id,
    'registration', v_profile.city);

  RETURN v_profile;
END;
$$;

create or replace function public.reject_user(
  p_user_id uuid,
  p_admin_id uuid,
  p_reason text
) returns public.profiles
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_profile public.profiles;
begin
  IF NOT public.admin_can('registrations') OR p_admin_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE public.profiles
  SET    status = 'REJECTED', updated_at = now()
  WHERE  id = p_user_id
  RETURNING * INTO v_profile;

  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  UPDATE public.approval_requests
  SET    status = 'REJECTED'
  WHERE  subject_type = 'USER'
  AND    subject_id = p_user_id
  AND    status = 'PENDING_APPROVAL';

  INSERT INTO public.approval_history
    (subject_type, subject_id, action, reason, performed_by)
  VALUES
    ('USER', p_user_id, 'REJECT', p_reason, p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    p_user_id,
    'REJECTION',
    'Application rejected',
    p_reason
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (
    p_admin_id, 'REJECT_USER', 'profiles', p_user_id,
    jsonb_build_object('reason', p_reason)
  );

  PERFORM public.log_admin_action(p_admin_id, 'REJECT_USER', p_user_id,
    'registration', v_profile.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_profile;
END;
$$;

-- 2c. Payment proof verification -> 'payment_verification'
CREATE OR REPLACE FUNCTION public.verify_payment_proof(
  p_proof_id uuid,
  p_decision text,            -- 'VERIFIED' | 'REJECTED'
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_txn uuid;
BEGIN
  IF NOT public.admin_can('payment_verification') THEN
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

  -- Move the order along the existing status path on approval.
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

-- 2d. Wallet / sales actions -> 'sales_transactions'
CREATE OR REPLACE FUNCTION public.admin_cash_recharge(p_provider_id uuid, p_amount numeric, p_reason text, p_admin_id uuid)
 RETURNS wallets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_balance_before numeric; BEGIN IF NOT public.admin_can('sales_transactions') OR p_admin_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'INSUFFICIENT_PERMISSION'; END IF; IF p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_MUST_BE_POSITIVE'; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; v_balance_before := v_wallet.balance; UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, 'ADMIN_CASH', p_amount, 0, p_amount, v_wallet.balance, 'COMPLETED', 'admin-cash:' || p_provider_id::text || ':' || now()::text); INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, 'CASH_RECHARGE', p_amount, p_reason, v_balance_before, v_wallet.balance); INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'APPROVAL', 'Cash Recharge', p_amount::text || ' ETB credited' FROM provider_profiles pp WHERE pp.id = p_provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_CASH_RECHARGE', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount)); RETURN v_wallet; END; $function$
;

CREATE OR REPLACE FUNCTION public.admin_wallet_adjustment(p_provider_id uuid, p_amount numeric, p_reason text, p_admin_id uuid)
 RETURNS wallets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_balance_before numeric; v_action_type text; BEGIN IF NOT public.admin_can('sales_transactions') OR p_admin_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'INSUFFICIENT_PERMISSION'; END IF; IF p_amount = 0 THEN RAISE EXCEPTION 'AMOUNT_CANNOT_BE_ZERO'; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; v_balance_before := v_wallet.balance; IF p_amount > 0 THEN v_action_type := 'ADJUSTMENT_CREDIT'; ELSE v_action_type := 'ADJUSTMENT_DEBIT'; END IF; IF p_amount < 0 AND v_wallet.balance + p_amount < 0 THEN IF NOT get_setting_bool('allow_negative_wallet') THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE'; END IF; END IF; UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, 'ADJUSTMENT', abs(p_amount), 0, abs(p_amount), v_wallet.balance, 'COMPLETED', 'adjustment:' || p_provider_id::text || ':' || now()::text); INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, v_action_type, abs(p_amount), p_reason, v_balance_before, v_wallet.balance); INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'ADMIN_MESSAGE', 'Wallet Adjustment', 'Adjusted by ' || p_amount::text || ' ETB' FROM provider_profiles pp WHERE pp.id = p_provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_WALLET_ADJUSTMENT', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount)); RETURN v_wallet; END; $function$
;

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
  if not public.admin_can('sales_transactions') or p_admin_id is distinct from auth.uid() then
    raise exception 'INSUFFICIENT_PERMISSION';
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

-- ------------------------------------------------------------
-- 3. staff table: permitted staff must be able to see the staff
--    directory rows (names/permissions) to operate; keep the
--    existing admin/self policy and add a read-only one.
-- ------------------------------------------------------------
DO $$ BEGIN CREATE POLICY staff_staff_read ON public.staff FOR SELECT
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'registrations'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- admin_history: 'admin_history' permission holders read the audit trail.
DO $$ BEGIN CREATE POLICY admin_history_staff_read ON public.admin_history FOR SELECT
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'admin_history'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ------------------------------------------------------------
-- 4. Read gates so permitted staff see what their screens show
--    (all previously owner-or-admin only). Additive OR-policies.
-- ------------------------------------------------------------
-- registrations: profiles + documents + provider profiles
DO $$ BEGIN CREATE POLICY profiles_staff_registration_read ON public.profiles FOR SELECT
  USING (id = auth.uid() OR public.is_admin() OR public.staff_has_permission(auth.uid(), 'registrations'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY user_documents_staff_registration_read ON public.user_documents FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin() OR public.staff_has_permission(auth.uid(), 'registrations'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY provider_profiles_staff_registration_read ON public.provider_profiles FOR SELECT
  USING (status = 'APPROVED' OR user_id = auth.uid() OR public.is_admin()
         OR public.staff_has_permission(auth.uid(), 'registrations')
         OR public.staff_has_permission(auth.uid(), 'payment_verification'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- payment_verification: recharge queue rows (+ provider rows above)
DO $$ BEGIN CREATE POLICY wallet_recharge_requests_staff_read ON public.wallet_recharge_requests FOR SELECT
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'payment_verification'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- support_chat: tickets read + resolve, and customer profile rows
DO $$ BEGIN CREATE POLICY support_tickets_staff_read ON public.support_tickets FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY support_tickets_staff_update ON public.support_tickets FOR UPDATE
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'))
  WITH CHECK (public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY profiles_staff_support_read ON public.profiles FOR SELECT
  USING (id = auth.uid() OR public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- sales_transactions: wallet ledger + balances
DO $$ BEGIN CREATE POLICY wallet_transactions_staff_read ON public.wallet_transactions FOR SELECT
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'sales_transactions'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY wallets_staff_read ON public.wallets FOR SELECT
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'sales_transactions'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ------------------------------------------------------------
-- 5. Write gates for staff-permitted direct-table actions.
--    Receiver-side notification access is untouched: these
--    INSERT policies only open the SENDER side that the admin
--    screen uses today.
-- ------------------------------------------------------------
DO $$ BEGIN CREATE POLICY notifications_staff_insert ON public.notifications FOR INSERT
  WITH CHECK (public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY categories_staff_write ON public.categories FOR ALL
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'category_management'))
  WITH CHECK (public.is_admin() OR public.staff_has_permission(auth.uid(), 'category_management'));
EXCEPTION WHEN duplicate_object THEN null; END $$;
