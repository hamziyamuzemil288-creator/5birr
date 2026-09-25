-- Reproduce the staff-create-gateway flow locally: auth.users insert with
-- app_metadata staff_gateway=true + confirmed email + user_metadata
-- full_name, then create_staff_gateway. Whichever statement raises here is
-- the production 500.
--
-- Run: sudo -u postgres createdb staff_gateway_test
--      sudo -u postgres psql -v ON_ERROR_STOP=0 -d staff_gateway_test < tools/test/staff_gateway_sql_test.sql

\set ON_ERROR_STOP off
DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  phone text
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.system_settings (key text PRIMARY KEY, value jsonb NOT NULL, description text);
INSERT INTO public.system_settings(key, value) VALUES ('captcha_enforced', 'true'::jsonb);
CREATE OR REPLACE FUNCTION public.get_setting_bool(p_key text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN value::text IN ('true','false') THEN value::text::boolean ELSE NULL END
  FROM public.system_settings WHERE key = p_key
$$;
CREATE OR REPLACE FUNCTION public.default_city() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT 'Addis Ababa' $$;

CREATE TABLE public.email_otp_codes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL,
  code_hash text NOT NULL,
  consumed boolean NOT NULL DEFAULT false,
  attempts integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.otp_verified_recently(p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT EXISTS (SELECT 1 FROM public.email_otp_codes
    WHERE email = lower(btrim(p_email)) AND consumed AND attempts > 0
      AND attempts <= 2 AND created_at > now() - interval '24 hours')
$$;

CREATE TYPE public.account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED');
CREATE TYPE public.app_role AS ENUM ('USER','ADMIN','SERVICE_PROVIDER','VEHICLE_PROVIDER','SUPPORT');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  full_name text,
  phone text,
  email text,
  national_id text,
  status public.account_status DEFAULT 'PENDING_APPROVAL',
  city text,
  kebele text,
  street_road text,
  updated_at timestamptz DEFAULT now()
);
CREATE TABLE public.user_roles (
  user_id uuid NOT NULL REFERENCES auth.users(id),
  role public.app_role NOT NULL,
  PRIMARY KEY (user_id, role)
);
CREATE TABLE public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.staff (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  name text NOT NULL,
  staff_code text NOT NULL UNIQUE,
  permissions text[] DEFAULT '{}',
  sales_target numeric DEFAULT 0,
  is_super_admin boolean DEFAULT false,
  is_ceo boolean DEFAULT false,
  is_active boolean DEFAULT true,
  branch text DEFAULT 'ADMIN',
  assigned_categories uuid[] DEFAULT '{}',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.staff_credentials (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL UNIQUE REFERENCES public.staff(id) ON DELETE CASCADE,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  username text NOT NULL CHECK (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  failed_attempts integer NOT NULL DEFAULT 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_staff_credentials_username ON public.staff_credentials (lower(username));
CREATE TABLE public.admin_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor uuid,
  action text NOT NULL,
  related uuid,
  category text,
  city text,
  images text[] DEFAULT '{}',
  metadata jsonb DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_actor uuid, p_action text, p_related uuid, p_category text, p_city text,
  p_images text[] DEFAULT '{}', p_metadata jsonb DEFAULT '{}'::jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.admin_history (actor, action, related, category, city, images, metadata)
  VALUES (p_actor, p_action, p_related, p_category, p_city, p_images, p_metadata)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.is_ceo(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = p_user_id AND is_ceo AND is_active)
$$;

-- The LATEST live trigger body: 0035 (staff gateway bypass) — pasted from migration.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
BEGIN
  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
  );
  IF NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
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
    INSERT INTO public.provider_profiles (user_id)
    SELECT new.id
    WHERE NOT EXISTS (SELECT 1 FROM public.provider_profiles WHERE user_id = new.id);
  END IF;
  RETURN new;
END;
$$;

CREATE TABLE public.provider_profiles (user_id uuid PRIMARY KEY);
CREATE TRIGGER trg_handle_new_user AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE OR REPLACE FUNCTION public.create_staff_gateway(
  p_actor_id uuid, p_auth_user_id uuid, p_username text, p_name text,
  p_staff_code text, p_permissions text[], p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false, p_branch text DEFAULT 'ADMIN',
  p_assigned_categories uuid[] DEFAULT '{}')
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_username text := lower(btrim(p_username));
  v_email text := v_username || '@staff-gateway.invalid';
  v_staff public.staff;
BEGIN
  IF NOT public.is_ceo(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_STAFF_GATEWAY';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff_credentials WHERE lower(username) = v_username) THEN
    RAISE EXCEPTION 'STAFF_USERNAME_TAKEN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_auth_user_id AND lower(email) = v_email) THEN
    RAISE EXCEPTION 'STAFF_AUTH_IDENTITY_MISMATCH';
  END IF;

  INSERT INTO public.staff
    (user_id, name, staff_code, permissions, sales_target, is_super_admin,
     branch, is_ceo, assigned_categories, created_by)
  VALUES
    (p_auth_user_id, btrim(p_name), btrim(p_staff_code), p_permissions,
     COALESCE(p_sales_target, 0), p_is_super_admin, p_branch, false,
     COALESCE(p_assigned_categories, '{}'::uuid[]), p_actor_id)
  RETURNING * INTO v_staff;

  INSERT INTO public.staff_credentials (staff_id, user_id, username)
  VALUES (v_staff.id, p_auth_user_id, v_username);

  INSERT INTO public.user_roles (user_id, role)
  VALUES (p_auth_user_id, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  UPDATE public.profiles
  SET full_name = btrim(p_name), email = v_email,
      status = 'APPROVED', updated_at = now()
  WHERE id = p_auth_user_id;

  DELETE FROM public.approval_requests
  WHERE subject_type = 'USER' AND subject_id = p_auth_user_id
    AND status = 'PENDING_APPROVAL';

  PERFORM public.log_admin_action(
    p_actor_id, 'STAFF_GATEWAY_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('username', v_username, 'permissions', to_jsonb(p_permissions)));
  RETURN v_staff;
END;
$$;

-- ============ SIMULATE THE EDGE FUNCTION SEQUENCE ============
INSERT INTO public.staff (id, user_id, name, staff_code, is_ceo)
VALUES ('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000000', 'CEO', 'CEO-1', true);

-- Step 1: auth admin.createUser equivalent — the exact payload the edge fn sends.
DO $$
DECLARE v_user auth.users%ROWTYPE;
BEGIN
  BEGIN
    INSERT INTO auth.users (email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
    VALUES ('probestaff1@staff-gateway.invalid', now(),
            '{"staff_gateway": true}'::jsonb,
            '{"full_name": "Probe Staff"}'::jsonb)
    RETURNING * INTO v_user;
    RAISE NOTICE 'STEP1 auth insert OK: %', v_user.id;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'STEP1 auth insert FAILED: % (%)', SQLERRM, SQLSTATE;
  END;
END $$;

-- Step 2: create_staff_gateway with that user (username probe1).
DO $$
DECLARE
  v_user_id uuid;
  v_staff public.staff;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = 'probestaff1@staff-gateway.invalid';
  BEGIN
    SELECT * INTO v_staff FROM public.create_staff_gateway(
      'aaaaaaaa-0000-0000-0000-000000000001', v_user_id, 'probe1', 'Probe Staff', 'PROBE-1',
      ARRAY['sales_transactions']::text[], 0, false, 'ADMIN', '{}'::uuid[]);
    RAISE NOTICE 'STEP2 create_staff_gateway OK: %', v_staff.id;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'STEP2 create_staff_gateway FAILED: % (%)', SQLERRM, SQLSTATE;
  END;
END $$;

-- Step 3: simulate the LIVE possibility that handle_new_user is still the
-- OLD 0031 referral version (no staff_gateway bypass) — the hypothesis for
-- the 500 if a later deploy re-pasted an older trigger.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
BEGIN
  v_is_admin_subject := new.email_confirmed_at IS NOT NULL
                        AND new.raw_user_meta_data IS NULL;
  IF NOT v_is_admin_subject
     AND NOT public.otp_verified_recently(new.email) THEN
    RAISE EXCEPTION 'EMAIL_OTP_REQUIRED: verify your email code before creating the account';
  END IF;
  INSERT INTO public.profiles (id, full_name, email, status)
  VALUES (new.id, COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'), new.email, 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;
  RETURN new;
END;
$$;

DO $$
DECLARE v_user auth.users%ROWTYPE;
BEGIN
  BEGIN
    INSERT INTO auth.users (email, email_confirmed_at, raw_app_meta_data, raw_user_meta_data)
    VALUES ('probestaff2@staff-gateway.invalid', now(),
            '{"staff_gateway": true}'::jsonb,
            '{"full_name": "Probe Staff 2"}'::jsonb)
    RETURNING * INTO v_user;
    RAISE NOTICE 'STEP3 old-trigger insert OK (unexpected)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'STEP3 old-trigger insert FAILED as predicted: % (%)', SQLERRM, SQLSTATE;
  END;
END $$;
