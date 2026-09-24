-- Local regression harness for 20260924000004_critical_security_hardening.sql.
-- Run from the project root with:
--   sudo -u postgres createdb critical_security_test
--   sudo -u postgres psql -d critical_security_test -f tools/test/critical_security_migration_test.sql
-- The migration copy must be available at /tmp/20260924000004_critical_security_hardening.sql.

\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS auth CASCADE;
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE DOMAIN public.geography AS text;
CREATE OR REPLACE FUNCTION public.st_makepoint(double precision, double precision)
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'POINT(' || $2 || ' ' || $1 || ')' $$;
CREATE OR REPLACE FUNCTION public.st_setsrid(text, integer)
RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'SRID=' || $2 || ';' || $1 $$;

CREATE TABLE auth.users (id uuid PRIMARY KEY DEFAULT gen_random_uuid());
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.system_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL,
  description text
);
INSERT INTO public.system_settings(key, value) VALUES ('captcha_enforced', 'true'::jsonb);
CREATE OR REPLACE FUNCTION public.get_setting_bool(p_key text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN value::text IN ('true', 'false') THEN value::text::boolean ELSE NULL END
  FROM public.system_settings WHERE key = p_key
$$;

CREATE TABLE public.user_documents (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  document_type text NOT NULL,
  storage_path text NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now(),
  verification_status text,
  qr_payload text,
  agent_verdict jsonb,
  verified_at timestamptz
);

CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  business_name text NOT NULL,
  business_description text,
  business_address text,
  location_lat double precision,
  location_lng double precision,
  service_category text,
  price_range text,
  is_active boolean NOT NULL DEFAULT true,
  subscription_paid boolean NOT NULL DEFAULT true,
  subscription_due_date date,
  provider_type text,
  owner_national_id text,
  status text DEFAULT 'PENDING_APPROVAL',
  category_id uuid,
  city text,
  kebele text,
  street_road text,
  registration_fee_paid boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id),
  category_id uuid,
  name text NOT NULL,
  description text,
  price numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'ETB',
  quantity integer,
  is_available boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  location public.geography,
  price_per_unit numeric(12,2) NOT NULL DEFAULT 0,
  unit text,
  listing_status text NOT NULL DEFAULT 'ACTIVE',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.vehicles (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id),
  category_id uuid,
  brand text,
  model text,
  plate_number text NOT NULL UNIQUE,
  color text,
  capacity integer,
  is_available boolean NOT NULL DEFAULT true,
  status text NOT NULL DEFAULT 'PENDING_APPROVAL',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.captcha_challenges (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  answer text NOT NULL,
  used_at timestamptz,
  solved_at timestamptz,
  consumed_at timestamptz,
  consumed_target text,
  expires_at timestamptz NOT NULL DEFAULT now() + interval '15 minutes',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE OR REPLACE FUNCTION public.staff_has_permission(uuid, text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE OR REPLACE FUNCTION public.provider_docs_satisfied(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT true $$;

\ir /tmp/20260924000004_critical_security_hardening.sql

-- Document insert cannot self-approve.
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', false);
INSERT INTO public.user_documents(user_id, document_type, storage_path, verification_status)
VALUES ('00000000-0000-0000-0000-000000000001', 'NATIONAL_ID', 'u/doc.jpg', 'AUTO_APPROVED');
DO $$
BEGIN
  IF (SELECT verification_status FROM public.user_documents LIMIT 1) <> 'MANUAL_REVIEW' THEN
    RAISE EXCEPTION 'document insert was not forced to MANUAL_REVIEW';
  END IF;
END $$;

-- A normal authenticated user cannot set a verification verdict.
DO $$
BEGIN
  BEGIN
    UPDATE public.user_documents
    SET verification_status = 'AUTO_APPROVED'
    WHERE user_id = '00000000-0000-0000-0000-000000000001';
    RAISE EXCEPTION 'document verdict forgery unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%DOCUMENT_VERIFICATION_REQUIRES_VERIFIER%' THEN RAISE; END IF;
  END;
END $$;

-- Provider RPC and direct-write trigger enforce activation and documents.
INSERT INTO public.provider_profiles(id, user_id, business_name, status, registration_fee_paid)
VALUES ('00000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000001', 'Test Provider', 'APPROVED', false);
DO $$
BEGIN
  BEGIN
    PERFORM public.create_provider_product(
      '00000000-0000-0000-0000-000000000010', 'Blocked', NULL, 10, NULL, 1
    );
    RAISE EXCEPTION 'unactivated product RPC unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;
DO $$
BEGIN
  BEGIN
    INSERT INTO public.vehicles(provider_id, plate_number)
    VALUES ('00000000-0000-0000-0000-000000000010', 'BLOCKED-1');
    RAISE EXCEPTION 'unactivated direct vehicle insert unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;
UPDATE public.provider_profiles SET registration_fee_paid = true
WHERE id = '00000000-0000-0000-0000-000000000010';
DO $$
DECLARE
  v_vehicle public.vehicles;
BEGIN
  PERFORM public.create_provider_product(
    '00000000-0000-0000-0000-000000000010', 'Allowed', NULL, 10, NULL, 1
  );
  v_vehicle := public.create_provider_vehicle(
    '00000000-0000-0000-0000-000000000010', 'Test', 'Model', 'ALLOWED-1', 'Red', 4, NULL
  );
  IF v_vehicle.status <> 'PENDING_APPROVAL' OR v_vehicle.is_available THEN
    RAISE EXCEPTION 'vehicle RPC did not create an unavailable pending vehicle';
  END IF;
END $$;

-- Public view has no identity columns.
DO $$
DECLARE
  leaked text;
BEGIN
  SELECT string_agg(column_name, ',') INTO leaked
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'public_provider_profiles'
    AND column_name IN (
      'owner_national_id', 'national_id', 'user_id', 'owner_name',
      'kebele', 'street_road', 'business_address'
    );
  IF leaked IS NOT NULL THEN
    RAISE EXCEPTION 'public provider view exposes restricted columns: %', leaked;
  END IF;
END $$;

-- CAPTCHA consumption is atomic and one-shot.
INSERT INTO public.captcha_challenges(answer, used_at, solved_at)
VALUES ('7', now(), now());
DO $$
DECLARE
  challenge_id uuid;
  first_result boolean;
  second_result boolean;
BEGIN
  SELECT id INTO challenge_id FROM public.captcha_challenges
  WHERE answer = '7' AND consumed_at IS NULL LIMIT 1;
  SELECT public.consume_captcha(challenge_id, 'otp:test@example.com') INTO first_result;
  SELECT public.consume_captcha(challenge_id, 'otp:test@example.com') INTO second_result;
  IF first_result IS DISTINCT FROM true OR second_result IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'CAPTCHA consumption was not one-shot';
  END IF;
END $$;

-- Missing CAPTCHA configuration fails closed.
DELETE FROM public.system_settings WHERE key = 'captcha_enforced';
DO $$
BEGIN
  BEGIN
    PERFORM public.captcha_required();
    RAISE EXCEPTION 'missing CAPTCHA configuration did not fail closed';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%CAPTCHA_CONFIG_UNAVAILABLE%' THEN RAISE; END IF;
  END;
END $$;

\echo 'critical security migration tests passed'
