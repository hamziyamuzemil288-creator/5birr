-- TASK B (provider signup image never reaches admin): completion-gate fix
-- 20260919000002_provider_approval_profile_sync.sql
--
-- ROOT CAUSES (two independent defects; evidence in the PR description):
--   1. UPLOADS NEVER HAD A DESTINATION. Every storage bucket was created
--      2026-09-18 21:18:59 (migration 0033). reis signed up 20:58:13 and the
--      signup flow wrote his two user_documents rows at 20:58:20 — 21 minutes
--      BEFORE the bucket existed. Storage uploads fail without a bucket, and
--      the app swallowed the error, so the admin never had images to view.
--      (Fixed already by 0033; new signups can now store documents. This file
--      does NOT touch storage. reis's rows point at never-uploaded files and
--      must be re-submitted from the app.)
--   2. APPROVAL DID NOT COMPLETE THE GATE. approve_provider() updated only
--      provider_profiles.status. approve_user() (regular users) updates
--      profiles.status AND closes the approval_requests row, but the provider
--      variants never did. Live proof: reis was approved 2026-09-18 22:07:27
--      (admin_actions + approval_history + notification + ACTIVE subscription
--      all exist), yet profiles.status stayed PENDING_APPROVAL, so the login
--      gate keeps him locked out, and his approval_requests row still shows
--      PENDING_APPROVAL so the admin list keeps showing him as pending.
--
-- FIX: mirror the approve_user() contract in the provider variants —
--   approve_provider():  profiles.status -> APPROVED, close approval_requests
--   reject_provider():   profiles.status -> REJECTED, close approval_requests
--   request_correction_provider(): profiles.status -> REJECTED (correction
--                        state; same as the provider_profiles side)
--   suspend_provider():  profiles.status -> SUSPENDED
--   unsuspend_provider(): profiles.status -> APPROVED (restore)
-- Full function bodies restated (CREATE OR REPLACE) — no other logic changed.
-- Idempotent. No DDL on tables, no policy changes, no data writes.

-- ============================================================
-- approve_provider
-- ============================================================
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
  -- Admin-only guard (unchanged)
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = p_admin_id AND role = 'ADMIN'
  ) INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE';
  END IF;

  -- Prevent approving your own provider account (unchanged)
  IF EXISTS (
    SELECT 1 FROM public.provider_profiles
    WHERE id = p_provider_id AND user_id = p_admin_id
  ) THEN
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

  RETURN v_provider;
END;
$$;

-- ============================================================
-- reject_provider
-- ============================================================
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

  -- Completion gate (mirror of the approve path).
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

  RETURN v_provider;
END;
$$;

-- ============================================================
-- request_correction_provider
-- ============================================================
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

  -- Correction state mirrors the provider_profiles side (REJECTED) on the
  -- profile gate; the user re-submits and the admin re-reviews.
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

  RETURN v_provider;
END;
$$;

-- ============================================================
-- suspend_provider / unsuspend_provider
-- ============================================================
create or replace function public.suspend_provider(
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
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_SUSPEND';
  END IF;

  UPDATE provider_profiles SET status = 'SUSPENDED', updated_at = now()
  WHERE id = p_provider_id
  RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  -- Completion gate (mirror of the approve path).
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

  -- Completion gate (restore access).
  UPDATE public.profiles SET status = 'APPROVED', updated_at = now()
  WHERE id = v_provider.user_id;

  UPDATE vehicles SET is_available = true WHERE provider_id = p_provider_id AND status = 'APPROVED';

  INSERT INTO approval_history (subject_type, subject_id, action, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
  SELECT user_id, 'APPROVAL', 'Account reactivated', 'Your provider account has been reactivated.'
  FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'UNSUSPEND_PROVIDER', 'provider_profiles', p_provider_id);

  RETURN v_provider;
END;
$$;
