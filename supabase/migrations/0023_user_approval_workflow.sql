-- 5BIRR — User approval workflow for ALL new signups
-- Migration 0023_user_approval_workflow.sql
--
-- Adds:
--   1. approve_user()  — SECURITY DEFINER, admin-only guard (mirrors approve_provider)
--   2. reject_user()   — SECURITY DEFINER, admin-only guard (mirrors reject_provider)
--   3. Updates handle_new_user() trigger to also insert an approval_requests row
--      with subject_type = 'USER' for every new signup.

-- =========================================================
-- approve_user — set profile status to APPROVED, log + notify
-- =========================================================
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
  -- Admin-only guard (same pattern as approve_provider)
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

  -- Update corresponding approval_requests row
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

  RETURN v_profile;
END;
$$;

-- =========================================================
-- reject_user — set profile status to REJECTED, log + notify
-- =========================================================
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
  -- Admin-only guard (same pattern as reject_provider)
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

  -- Update corresponding approval_requests row
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

  RETURN v_profile;
END;
$$;

-- =========================================================
-- Update handle_new_user trigger to also create an
-- approval_requests row with subject_type = 'USER'.
-- =========================================================
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1. Create a default profile (skip if the client already inserted one)
  INSERT INTO public.profiles (id, full_name, phone, email, status)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    new.phone,
    new.email,
    'PENDING_APPROVAL'::account_status
  )
  ON CONFLICT (id) DO NOTHING;

  -- 2. Assign the USER role (skip if already present)
  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 3. Create an approval request so admins can review this user
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'PENDING_APPROVAL'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  RETURN new;
END;
$$;
