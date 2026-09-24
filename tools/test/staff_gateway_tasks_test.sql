-- Local regression harness for Task 12 staff gateway/task migration.
-- Run from project root with:
--   sudo -u postgres createdb staff_gateway_test
--   sudo -u postgres psql -d staff_gateway_test -f tools/test/staff_gateway_tasks_test.sql
-- The migration copy must be available at /tmp/20260924000005_staff_gateway_tasks.sql.

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
CREATE TYPE public.app_role AS ENUM ('USER','VEHICLE_PROVIDER','SERVICE_PROVIDER','ADMIN');
CREATE TYPE public.account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED','SUSPENDED','INACTIVE');
CREATE TYPE public.recharge_status AS ENUM ('PENDING','APPROVED','REJECTED');
CREATE TABLE auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text UNIQUE,
  email_confirmed_at timestamptz,
  raw_user_meta_data jsonb,
  raw_app_meta_data jsonb,
  phone text
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text NOT NULL,
  phone text,
  email text,
  national_id text,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  city text,
  kebele text,
  street_road text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.user_roles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE(user_id, role)
);
CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  sector text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  name text NOT NULL,
  staff_code text NOT NULL UNIQUE,
  permissions text[] NOT NULL DEFAULT '{}',
  sales_target numeric(12,2) NOT NULL DEFAULT 0,
  is_super_admin boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  branch text NOT NULL DEFAULT 'ADMIN',
  is_ceo boolean NOT NULL DEFAULT false,
  assigned_categories uuid[] NOT NULL DEFAULT '{}',
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  business_name text,
  provider_type public.app_role,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  category_id uuid REFERENCES public.categories(id),
  city text,
  kebele text,
  street_road text
);
CREATE TABLE public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.support_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  subject text,
  description text,
  status text NOT NULL DEFAULT 'OPEN',
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.appeal_cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  description text,
  status text NOT NULL DEFAULT 'OPEN',
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.wallet_recharge_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL,
  amount numeric NOT NULL,
  status public.recharge_status NOT NULL DEFAULT 'PENDING',
  approved_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.payment_proofs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id),
  storage_path text NOT NULL,
  verification_status text NOT NULL DEFAULT 'PENDING',
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.admin_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id uuid NOT NULL,
  action text NOT NULL,
  target_type text,
  target_id uuid,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.admin_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  actor_name text,
  action_type text NOT NULL,
  related_record_id uuid,
  category text,
  city text,
  image_paths text[] NOT NULL DEFAULT '{}',
  metadata jsonb NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  type text NOT NULL,
  title text NOT NULL,
  body text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE OR REPLACE FUNCTION public.default_city() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'Addis Ababa' $$;
CREATE OR REPLACE FUNCTION public.otp_verified_recently(text) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE OR REPLACE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'ADMIN')
$$;
CREATE OR REPLACE FUNCTION public.is_ceo(uuid DEFAULT auth.uid()) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = $1 AND is_ceo AND is_active)
  OR (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = $1 AND role = 'ADMIN')
      AND NOT EXISTS (SELECT 1 FROM public.staff WHERE user_id = $1))
$$;
CREATE OR REPLACE FUNCTION public.is_super_admin(uuid DEFAULT auth.uid()) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = $1 AND is_super_admin AND is_active)
$$;
CREATE OR REPLACE FUNCTION public.staff_has_permission(uuid, text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = $1 AND is_active AND (is_ceo OR $2 = ANY(permissions)))
$$;
CREATE OR REPLACE FUNCTION public.staff_scope_allows_category(uuid, uuid DEFAULT auth.uid()) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$ SELECT true $$;
CREATE OR REPLACE FUNCTION public.log_admin_action(uuid, text, uuid, text, text, text[], jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v uuid; BEGIN INSERT INTO public.admin_history(actor_id,action_type,related_record_id,category,city,image_paths,metadata) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id INTO v; RETURN v; END $$;

\ir /tmp/20260924000005_staff_gateway_tasks.sql
CREATE TRIGGER test_handle_new_user
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- CEO and a gateway user.
INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data,raw_app_meta_data)
VALUES ('00000000-0000-0000-0000-000000000001','ceo@example.com',now(),NULL,'{}'),
       ('00000000-0000-0000-0000-000000000002','sam@staff-gateway.invalid',now(),'{"full_name":"Sam"}','{"staff_gateway":true}');
INSERT INTO public.user_roles(user_id,role) VALUES ('00000000-0000-0000-0000-000000000001','ADMIN');
UPDATE public.profiles
SET full_name = 'CEO', email = 'ceo@example.com', status = 'APPROVED'
WHERE id = '00000000-0000-0000-0000-000000000001';

-- Public signup cannot activate gateway metadata.
DO $$ BEGIN
  BEGIN
    INSERT INTO auth.users(id,email,email_confirmed_at,raw_user_meta_data,raw_app_meta_data)
    VALUES ('00000000-0000-0000-0000-000000000099','fake@staff-gateway.invalid',NULL,'{"staff_gateway":true}','{}');
    RAISE EXCEPTION 'public metadata bypass unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%EMAIL_OTP_REQUIRED%' THEN RAISE; END IF;
  END;
END $$;

-- CEO creates a gateway account and the task RPC can see it.
SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',false);
SELECT (public.create_staff_gateway(
  '00000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000002',
  'sam', 'Sam', 'ST-001', ARRAY['support_chat']
)).id IS NOT NULL AS gateway_created;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff_credentials WHERE username='sam') THEN
    RAISE EXCEPTION 'gateway mapping missing';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id='00000000-0000-0000-0000-000000000002' AND role='ADMIN') THEN
    RAISE EXCEPTION 'gateway ADMIN role missing';
  END IF;
END $$;

-- Duplicate usernames are rejected.
DO $$ BEGIN
  BEGIN
    PERFORM public.create_staff_gateway('00000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000002','sam','Other','ST-002',ARRAY[]::text[]);
    RAISE EXCEPTION 'duplicate username unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%STAFF_USERNAME_TAKEN%' THEN RAISE; END IF;
  END;
END $$;

-- Create two work items: one terminal ticket and one open ticket.
INSERT INTO public.support_tickets(id,user_id,subject,status,resolved_at)
VALUES ('00000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000001','Closed ticket','RESOLVED',now()),
       ('00000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000001','Open ticket','OPEN',NULL);

SELECT set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',false);
DO $$ DECLARE feed_count int; open_count int; closed_count int; BEGIN
  SELECT count(*) INTO feed_count FROM public.staff_task_feed();
  SELECT count(*) INTO open_count FROM public.staff_task_feed() WHERE NOT is_completed;
  SELECT count(*) INTO closed_count FROM public.staff_task_feed() WHERE task_key='support:00000000-0000-0000-0000-000000000010';
  IF feed_count <> 2 OR open_count <> 2 OR closed_count <> 1 THEN
    RAISE EXCEPTION 'unexpected feed counts %, %, %',feed_count,open_count,closed_count;
  END IF;
END $$;

-- Non-terminal work cannot be acknowledged.
DO $$ BEGIN
  BEGIN
    PERFORM public.staff_mark_task_done('support:00000000-0000-0000-0000-000000000011');
    RAISE EXCEPTION 'open task was marked done';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%TASK_MUST_REACH_TERMINAL_STATE_FIRST%' THEN RAISE; END IF;
  END;
END $$;

-- Terminal work can be acknowledged and progress changes exactly once.
SELECT public.staff_mark_task_done('support:00000000-0000-0000-0000-000000000010');
DO $$ DECLARE p record; BEGIN
  SELECT * INTO p FROM public.staff_progress();
  IF p.completed_tasks <> 1 OR p.remaining_tasks <> 1 OR p.total_tasks <> 2 OR p.progress_percent <> 50 THEN
    RAISE EXCEPTION 'unexpected progress %, %, %, %',p.completed_tasks,p.remaining_tasks,p.total_tasks,p.progress_percent;
  END IF;
END $$;

-- Five failures lock the gateway; success clears an unlocked counter.
SELECT public.staff_gateway_record_login('sam',false);
SELECT public.staff_gateway_record_login('sam',false);
SELECT public.staff_gateway_record_login('sam',false);
SELECT public.staff_gateway_record_login('sam',false);
SELECT public.staff_gateway_record_login('sam',false);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.staff_credentials WHERE username='sam' AND locked_until > now()) THEN
    RAISE EXCEPTION 'gateway lockout missing';
  END IF;
END $$;

\echo 'STAFF_GATEWAY_TASKS_TEST_PASSED'
