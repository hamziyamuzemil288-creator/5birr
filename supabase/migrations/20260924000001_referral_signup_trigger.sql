-- Task 8 — resolve the referral code at signup.
--
-- Re-emits handle_new_user() (full body, latest version from 20260923000005)
-- with one addition: when signup metadata carries a referral_code, the
-- provider_profiles insert records the raw code, the resolved staff id and
-- the staff name snapshot. Resolution rules (Task 8 spec):
--   • no/blank code            → all three columns NULL (self-registered)
--   • code matches active code → staff id + name stored (sales-registered)
--   • code unknown/inactive    → raw code kept, staff columns NULL ("Other")
-- The lookup runs inside this security-definer trigger, so the anonymous
-- signup never needs to read referral_codes directly.
--
-- The OTP gate, profile/role/approval-request inserts, and provider_docs
-- behavior are byte-identical to 20260923000005 — only the provider-profile
-- INSERT gains the three columns plus a shared lookup CTE-less SELECT.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_admin_subject boolean;
  v_referral_code text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer_staff_id uuid;
  v_referrer_name text;
begin
  -- Exemption: accounts created in the Supabase dashboard (true Admin /
  -- support-created accounts) have no signup OTP. The dashboard sets
  -- email_confirmed_at directly (the SMTP path would have confirmed it);
  -- app signups never do (email confirmation is disabled in this project).
  v_is_admin_subject := new.email_confirmed_at is not null
                        and new.raw_user_meta_data is null;

  if not v_is_admin_subject
     and not public.otp_verified_recently(new.email) then
    raise exception 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  end if;

  -- Resolve the referral code once per signup (provider rows only use it,
  -- but resolving here keeps the flow single-purpose and cheap).
  if v_referral_code <> '' then
    select c.staff_id, s.name
      into v_referrer_staff_id, v_referrer_name
      from public.referral_codes c
      join public.staff s on s.id = c.staff_id
     where upper(btrim(c.code)) = v_referral_code
       and c.is_active
       and s.is_active
     limit 1;
  end if;

  -- 1. Create the profile with the complete signup data (skip if the row
  --    already exists). status is always PENDING_APPROVAL.
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
  --    insert would have. Documents are NOT collected at signup anymore
  --    (Task 7): the gate moves to the first protected action.
  --    Task 8: referral_code / referred_by_staff_id / referred_by_name —
  --    NULLs mark self-registered; an unmatched code keeps the raw text
  --    with NULL staff id ("Other").
  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city, kebele, street_road,
       referral_code, referred_by_staff_id, referred_by_name)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,        COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city()),
      NULLIF(new.raw_user_meta_data ->> 'kebele', ''),
      NULLIF(new.raw_user_meta_data ->> 'street_road', ''),
      CASE WHEN v_referral_code = '' THEN NULL ELSE v_referral_code END,
      v_referrer_staff_id,
      v_referrer_name
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;

  RETURN new;
END;
$$;
