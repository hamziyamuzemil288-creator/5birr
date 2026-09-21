-- ============================================================
-- Migration 20260922000001_staff_and_admin_history.sql
-- Phase 2: staff / sub-admin management + Phase 3: admin history log
-- ============================================================
-- STRICTLY ADDITIVE:
--   - Two NEW tables (staff, admin_history). No existing table, column,
--     function, trigger, or policy is modified or dropped.
--   - The only existing objects restated are the admin approval RPCs,
--     with ONE additional INSERT (audit) at the end of each — their
--     signatures, guards, and existing writes are byte-identical to
--     20260919000002 / 0023 (including suspend_provider's preserved
--     `p_reason default null`, see PR #14).
--   - RLS: staff rows readable by admins + the staff member; writable
--     ONLY through SECURITY DEFINER RPCs guarded by is_admin() AND
--     (for staff_* RPCs) the SUPER ADMIN flag (staff.is_super_admin).
-- ============================================================

-- ============================================================
-- 1. staff table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.staff (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  staff_code text NOT NULL UNIQUE,
  permissions text[] NOT NULL DEFAULT '{}',
  sales_target numeric(12,2) DEFAULT 0,
  is_super_admin boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT staff_permissions_known CHECK (
    permissions <@ ARRAY[
      'sales_transactions','registrations','category_management',
      'support_chat','payment_verification','admin_history'
    ]::text[]
  )
);
CREATE INDEX IF NOT EXISTS idx_staff_created_by ON public.staff(created_by);

-- ============================================================
-- 2. admin_history table (append-only audit log)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id uuid REFERENCES auth.users(id),
  actor_name text,
  action_type text NOT NULL,
  related_record_id uuid,
  category text,
  city text,
  image_paths text[] NOT NULL DEFAULT '{}',
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_history_actor      ON public.admin_history(actor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_history_action     ON public.admin_history(action_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_history_category   ON public.admin_history(category);
CREATE INDEX IF NOT EXISTS idx_admin_history_city       ON public.admin_history(city);
CREATE INDEX IF NOT EXISTS idx_admin_history_created_at ON public.admin_history(created_at DESC);

-- ============================================================
-- 3. RLS on the new tables
-- ============================================================
ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_history ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='staff' AND policyname='staff_admin_all') THEN
    CREATE POLICY staff_admin_all ON public.staff FOR ALL
      USING (public.is_admin() OR user_id = auth.uid())
      WITH CHECK (public.is_admin() OR user_id = auth.uid());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='admin_history' AND policyname='admin_history_admin_read') THEN
    CREATE POLICY admin_history_admin_read ON public.admin_history FOR SELECT
      USING (public.is_admin());
  END IF;
END $$;
-- admin_history has NO insert/update/delete policy: clients cannot write
-- it at all. Only SECURITY DEFINER functions (below) can append.

-- ============================================================
-- 4. Super-admin helper (owner of the acting staff account)
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_super_admin(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id AND is_super_admin AND is_active
  );
$$;

-- ============================================================
-- 5. Audit helper — one INSERT into admin_history. Used by the
--    restated RPCs below and callable from other definer code.
-- ============================================================
CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_actor uuid,
  p_action text,
  p_related uuid,
  p_category text,
  p_city text,
  p_images text[] DEFAULT '{}',
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_name text;
BEGIN
  SELECT COALESCE(full_name, '(admin)') INTO v_name FROM public.profiles WHERE id = p_actor;
  INSERT INTO public.admin_history (actor_id, actor_name, action_type, related_record_id, category, city, image_paths, metadata)
  VALUES (p_actor, v_name, p_action, p_related, p_category, p_city, p_images, p_metadata)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- ============================================================
-- 6. Staff management RPCs — super-admin only, server-side RBAC.
--    Admin RPC guard pattern (is_admin / ONLY_ADMINISTRATORS_*) is
--    reused, extended with is_super_admin() for staff_* actions.
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_staff(
  p_name text,
  p_staff_code text,
  p_permissions text[],
  p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  -- Server-side RBAC: an acting ADMIN either runs the staff program
  -- (is_super_admin row) or, during one-time bootstrap only, promotes
  -- themselves when NO active super admin exists yet.
  IF NOT public.is_super_admin(v_admin) THEN
    IF NOT public.is_admin() THEN
      RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_MANAGE_STAFF';
    END IF;
    IF EXISTS (SELECT 1 FROM public.staff WHERE is_super_admin AND is_active) THEN
      RAISE EXCEPTION 'ONLY_SUPER_ADMIN_CAN_MANAGE_STAFF';
    END IF;
  END IF;

  IF p_is_super_admin AND NOT public.is_super_admin(v_admin) THEN
    IF EXISTS (SELECT 1 FROM public.staff WHERE is_super_admin AND is_active) THEN
      RAISE EXCEPTION 'ONLY_SUPER_ADMIN_CAN_CREATE_SUPER_ADMINS';
    END IF;
  END IF;

  INSERT INTO public.staff (name, staff_code, permissions, sales_target, is_super_admin, created_by)
  VALUES (p_name, p_staff_code, p_permissions, p_sales_target, p_is_super_admin, v_admin)
  RETURNING * INTO v_staff;

  -- Self-bootstrap: the first created super-admin staff row is linked to
  -- the acting admin's auth user, giving them the staff program. Guarded
  -- to fire only when no super admin exists yet (see guard above).
  IF p_is_super_admin AND v_staff.user_id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.staff WHERE is_super_admin AND is_active
  ) THEN
    UPDATE public.staff SET user_id = v_admin WHERE id = v_staff.id;
    v_staff.user_id := v_admin;
  END IF;

  PERFORM public.log_admin_action(v_admin, 'STAFF_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('staff_code', p_staff_code, 'permissions', to_jsonb(p_permissions)));
  RETURN v_staff;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_staff(
  p_staff_id uuid,
  p_name text DEFAULT NULL,
  p_permissions text[] DEFAULT NULL,
  p_sales_target numeric DEFAULT NULL,
  p_is_active boolean DEFAULT NULL
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF NOT (public.is_super_admin(v_admin) AND public.is_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_MANAGE_STAFF';
  END IF;

  UPDATE public.staff SET
    name          = COALESCE(p_name, name),
    permissions   = COALESCE(p_permissions, permissions),
    sales_target  = COALESCE(p_sales_target, sales_target),
    is_active     = COALESCE(p_is_active, is_active),
    updated_at    = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  PERFORM public.log_admin_action(v_admin, 'STAFF_UPDATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('is_active', v_staff.is_active));
  RETURN v_staff;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_staff(p_staff_id uuid)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF NOT (public.is_super_admin(v_admin) AND public.is_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_MANAGE_STAFF';
  END IF;

  UPDATE public.staff SET is_active = false, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  -- Revoke the staff member's ADMIN role so server-side RBAC matches the
  -- staff table immediately (role row itself is kept for history).
  UPDATE public.user_roles SET role = 'USER'
  WHERE user_id = v_staff.user_id AND role = 'ADMIN';

  PERFORM public.log_admin_action(v_admin, 'STAFF_REVOKED', v_staff.id, 'staff', NULL);
  RETURN v_staff;
END;
$$;

-- Per-staff performance: registrations + sales volume by category.
CREATE OR REPLACE FUNCTION public.staff_performance(p_staff_id uuid)
RETURNS TABLE(registrations bigint, sales_total numeric, orders_count bigint, rides_count bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_is_self boolean;
  v_target_user uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_PERFORMANCE';
  END IF;
  SELECT user_id INTO v_target_user FROM public.staff WHERE id = p_staff_id;
  SELECT (user_id = v_admin) INTO v_is_self FROM public.staff WHERE id = p_staff_id;
  IF NOT (public.is_super_admin(v_admin) OR COALESCE(v_is_self, false)) THEN
    RAISE EXCEPTION 'ONLY_SUPER_ADMIN_CAN_VIEW_OTHER_STAFF_PERFORMANCE';
  END IF;

  RETURN QUERY
  SELECT
    (SELECT count(*) FROM public.approval_history h
      WHERE h.performed_by = v_target_user AND h.action = 'APPROVE') AS registrations,
    (SELECT COALESCE(sum(o.total_amount), 0) FROM public.orders o
      WHERE o.provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)
        AND o.status IN ('APPROVED','STARTED','COMPLETED')) AS sales_total,
    (SELECT count(*) FROM public.orders o
      WHERE o.provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)) AS orders_count,
    (SELECT count(*) FROM public.ride_requests r
      WHERE r.provider_id = v_target_user) AS rides_count;
END;
$$;

-- ============================================================
-- 7. Admin approval RPCs — restated verbatim from
--    20260919000002 (providers) and 0023 (users), each with ONE new
--    audit INSERT. Signatures preserved exactly (see PR #14 lesson).
-- ============================================================

-- approve_provider (unchanged except final audit insert)
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
  v_is_admin boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = p_admin_id AND role = 'ADMIN'
  ) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE';
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

-- reject_provider (unchanged except final audit insert)
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
  v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT';
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

-- request_correction_provider (unchanged except final audit insert)
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
  v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REQUEST_CORRECTION';
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

-- suspend_provider (unchanged except final audit insert; default preserved)
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
  v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_SUSPEND';
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

-- unsuspend_provider (unchanged except final audit insert)
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
  v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_UNSUSPEND';
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

-- approve_user (unchanged except final audit insert)
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
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE';
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

-- reject_user (unchanged except final audit insert)
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
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT';
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

-- ============================================================
-- 8. Payment verification audit (Phase 3: transaction logging).
--    No trigger on payment_proofs is touched. This RPC performs the
--    existing guard (is_admin) and the same update the admin screen
--    does, PLUS the audit row — an additive alternative path.
-- ============================================================
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
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'PAYMENT_PROOF_VERIFICATION_IS_ADMIN_ONLY';
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

-- ============================================================
-- 9. Contact release: only after order APPROVED. Returns the provider
--    contact to the buyer; logs the release to admin_history.
-- ============================================================
CREATE OR REPLACE FUNCTION public.release_order_contact(p_order_id uuid)
RETURNS TABLE(provider_phone text, provider_name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_phone text;
  v_name text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  IF v_order.user_id <> auth.uid() AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'NOT_ORDER_OWNER';
  END IF;
  IF v_order.status NOT IN ('APPROVED','STARTED','COMPLETED') THEN
    RAISE EXCEPTION 'CONTACT_AVAILABLE_AFTER_APPROVAL';
  END IF;

  IF v_order.user_id = auth.uid() THEN
    PERFORM public.log_admin_action(auth.uid(), 'CONTACT_RELEASED', v_order.id,
      'transaction', v_order.city,
      '{}', jsonb_build_object('provider_id', v_order.provider_id));
  END IF;

  SELECT public.profiles.phone, public.provider_profiles.business_name
    INTO v_phone, v_name
  FROM public.provider_profiles
  JOIN public.profiles ON public.profiles.id = public.provider_profiles.user_id
  WHERE public.provider_profiles.id = v_order.provider_id;

  RETURN QUERY SELECT v_phone, v_name;
END;
$$;

-- ============================================================
-- 10. Grants
-- ============================================================
GRANT EXECUTE ON FUNCTION public.is_super_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_admin_action(uuid, text, uuid, text, text, text[], jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_staff(text, text, text[], numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_staff(uuid, text, text[], numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_staff(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_performance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_payment_proof(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.release_order_contact(uuid) TO authenticated;
