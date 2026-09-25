-- Task 15: Google OAuth signup gate parity.
--
-- Google accounts arrive at handle_new_user() with email_confirmed_at set
-- (Google proved the address) AND raw_user_meta_data populated (Supabase
-- writes the provider profile into it: full_name, avatar_url...). Both
-- existing trusted-subject clauses fail:
--   • clause 1 needs raw_user_meta_data IS NULL (dashboard-only shape)
--   • clause 2 needs app_metadata.staff_gateway (edge-function-only shape)
-- so a Google signup would be rejected with EMAIL_OTP_REQUIRED even though
-- the address is already verified by the provider.
--
-- This migration adds a THIRD trusted clause: the user comes from an OAuth
-- provider (any provider — Google today, others later). OAuth verification
-- replaces the email OTP: there is no password to protect and the address
-- is provider-proven. The account still lands PENDING_APPROVAL with the
-- standard approval request — admin approval remains the account gate for
-- everyone. Re-emits the full 0035 trigger body (the newest live version)
-- with only the gate condition widened and the provider-profile branch
-- preserving the referral columns from 0031.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
  v_referral_code text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer_staff_id uuid;
  v_referrer_name text;
BEGIN
  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
    -- OAuth signups (Task 15): the provider verified the email, and
    -- raw_user_meta_data carries the provider profile (never NULL), so
    -- neither existing clause can match. Provider-proven email replaces
    -- the OTP gate; admin approval still gates the account below.
    OR new.email_confirmed_at IS NOT NULL
       AND jsonb_typeof(new.raw_app_meta_data -> 'provider') = 'string'
       AND (new.raw_app_meta_data ->> 'provider') <> ''
  );
  IF NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  END IF;

  IF v_referral_code <> '' THEN
    SELECT c.staff_id, s.name
      INTO v_referrer_staff_id, v_referrer_name
      FROM public.referral_codes c
      JOIN public.staff s ON s.id = c.staff_id
     WHERE upper(btrim(c.code)) = v_referral_code
       AND c.is_active
       AND s.is_active
     LIMIT 1;
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

  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road,
       referral_code, referred_by_staff_id, referred_by_name)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', ''),
      CASE WHEN v_referrer_staff_id IS NULL AND v_referral_code <> '' THEN v_referral_code END,
      v_referrer_staff_id,
      v_referrer_name
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;
  RETURN new;
END;
$$;
