-- 5BIRR — Restore signup for email-confirmation-enabled projects
-- Migration 0025_fix_signup_email_confirmation_flow.sql
-- Applied: 2026-09-18
--
-- SYMPTOM
--   Both USER and VEHICLE_PROVIDER signup fail with:
--     "new row violates row-level security policy for table \"profiles\""
--     (PostgrestException 42501)
--
-- ROOT CAUSE
--   The project has email confirmation ENABLED (verified live: a fresh
--   auth.signup attempt returns over_email_send_rate_limit, today's signup
--   user has email_confirmed_at = NULL and 0 rows in auth.sessions).
--   With confirmation enabled, Supabase auth.signUp() returns NO session.
--   The app then performed a client-side `profiles` upsert with no JWT:
--   PostgREST executed it as role `authenticated` with auth.uid() = NULL,
--   so the INSERT policy (id = auth.uid()) evaluated false → 42501.
--   (Verified: the identical insert succeeds when JWT claims are present,
--   so the hardening policies themselves were correct.)
--   Vehicle-provider signup additionally could not create its
--   provider_profiles row for the same no-session reason.
--
-- FIX
--   Do all signup writes inside the SECURITY DEFINER auth trigger, which
--   needs no session and is unaffected by RLS:
--     1. handle_new_user() now stores phone + national_id from the signup
--        metadata into the profile (previously lost, since the client-side
--        upsert that carried them always failed).
--     2. handle_new_user() now creates the provider_profiles row when the
--        signup metadata contains provider_type (vehicle/service signup).
--        The provider role + provider approval request follow via the
--        existing trg_provider_profiles_auto_setup trigger.
--   The app (auth_provider.dart) stops doing client-side writes after
--   signUp() and passes everything via signUp(data: ...) metadata instead.
--
-- SECURITY POSTURE (unchanged)
--   - All SELECT policies untouched (users still cannot read others'
--     sensitive data — the goal of the hardening pass).
--   - Only full_name/phone/email/national_id are taken from metadata;
--     status is forced to PENDING_APPROVAL; role assignment and approval
--     flow are system-driven exactly as before.
--   - User-initiated inserts are still blocked by the same RLS policies
--     and BEFORE INSERT guards as before (status escalation, cross-user
--     writes).

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- 1. Create the profile with the complete signup data (skip if the row
  --    already exists). status is always PENDING_APPROVAL.
  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'PENDING_APPROVAL'::account_status
  )
  ON CONFLICT (id) DO NOTHING;

  -- 2. Assign the USER role (skip if already present).
  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 3. Create an approval request so admins can review this user.
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'PENDING_APPROVAL'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  -- 4. Provider signups: create the provider profile from metadata.
  --    trg_provider_profiles_auto_setup then assigns the provider role and
  --    opens the provider approval request, exactly as a client-side
  --    insert would have.
  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;

  RETURN new;
END;
$$;
