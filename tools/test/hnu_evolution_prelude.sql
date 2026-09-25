-- Shared stub prelude for the handle_new_user evolution replay (local only).
-- Mirrors the supabase/tests pattern: minimal auth.users + the exact table
-- surface the trigger functions reference. No PostGIS/pgvector needed.
DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticator NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE auth.users (
  instance_id uuid NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'::uuid,
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  aud varchar(255) DEFAULT 'authenticated',
  role varchar(255) DEFAULT 'authenticated',
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb DEFAULT '{}'::jsonb,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  confirmation_token text DEFAULT '',
  recovery_token text DEFAULT '',
  email_change text DEFAULT '',
  email_change_token_new text DEFAULT '',
  email_change_token_current text DEFAULT ''
);

CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TYPE public.account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED');
CREATE TYPE public.app_role AS ENUM ('USER','ADMIN','SERVICE_PROVIDER','VEHICLE_PROVIDER','SUPPORT');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
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

CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  business_name text NOT NULL,
  provider_type public.app_role,
  owner_national_id text,
  status public.account_status DEFAULT 'PENDING_APPROVAL',
  city text,
  kebele text,
  street_road text,
  referral_code text,
  referred_by_staff_id uuid,
  referred_by_name text
);

CREATE TABLE public.user_roles (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
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
  user_id uuid,
  name text NOT NULL,
  staff_code text UNIQUE,
  is_active boolean DEFAULT true
);

CREATE TABLE public.referral_codes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  code text UNIQUE,
  is_active boolean DEFAULT true
);

-- Companion helpers every body calls.
CREATE TABLE public.system_settings (key text PRIMARY KEY, value jsonb NOT NULL, description text);
CREATE OR REPLACE FUNCTION public.default_city() RETURNS text
LANGUAGE sql STABLE AS $$ SELECT 'Addis Ababa' $$;

CREATE OR REPLACE FUNCTION public.otp_verified_recently(p_email text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER AS $$
  -- Sweep paths that arrive OTP-verified in production: A (user email
  -- signup) and D (provider signup — same verify-then-signUp mobile flow).
  SELECT lower(btrim(p_email)) IN ('verified@example.com', 'sweep-d@test.local')
$$;

-- The trigger itself, bound once to auth.users. Every evolution revision
-- replaces the FUNCTION only, so the binding never changes.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$ BEGIN RETURN new; END $$;

CREATE TRIGGER on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
