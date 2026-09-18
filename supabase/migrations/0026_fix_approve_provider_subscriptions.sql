-- 5BIRR — Fix approve_provider(): admin provider approval always failed
-- Migration 0026_fix_approve_provider_subscriptions.sql
-- Applied: 2026-09-18
--
-- BUG
--   approve_provider() referenced provider_profiles.subscription_start_date,
--   which does not exist in the live schema (the column was dropped/renamed
--   during the earlier schema evolution). Every admin provider-approval
--   attempt failed with:
--     ERROR: record "v_provider" has no field "subscription_start_date"
--   so newly-approved providers never reached APPROVED status and never got
--   a wallet or subscription row.
--
-- FIX
--   Keep the existing admin/self-approval guards, but create the wallet and
--   the initial ACTIVE subscription with the first due date one month out
--   (matching deduct_subscription_fee(), which advances next_due_date by one
--   month and sets status = 'ACTIVE' on each charge).

CREATE OR REPLACE FUNCTION public.approve_provider(p_provider_id uuid, p_admin_id uuid)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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
$function$;
