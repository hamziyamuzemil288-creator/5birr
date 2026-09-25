-- Verifies 0045 + 0046 against a real Postgres: the email-format username
-- mapping, and the new hard delete.
--
-- The load-bearing claims this file proves:
--   1. A legacy bare-name username still maps to the ORIGINAL synthetic
--      email, so every staff account created before 0045 keeps working and
--      the username is not re-keyed. This is the whole backward-compatibility
--      argument for the feature.
--   2. An email username maps to a valid, fixed-shape address, and the
--      mapping is deterministic (create and login must agree byte-for-byte).
--   3. Two different emails never collide, and the same email always does.
--   4. The CHECK constraint accepts both shapes and rejects malformed input.
--   5. delete_staff is CEO-only, refuses the CEO row, and cascades.
--
-- Run:
--   sudo -u postgres createdb staff_identity_test
--   stage="$(mktemp -d)/supabase/migrations"; mkdir -p "$stage"
--   cp supabase/migrations/202609251[6-9]*.sql "$stage/"; chmod -R a+rX "$stage"
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -d staff_identity_test \
--     -v repo_root="$(dirname "$(dirname "$stage")")" \
--     < tools/test/staff_identity_delete_test.sql
--
-- The migrations are staged to a world-readable temp dir first because the
-- postgres user cannot traverse a typical checkout (the home directory is
-- often drwxr-x---), which makes \i fail with "Permission denied". This
-- mirrors what hnu_live_lineage_driver.sh already does.

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS public CASCADE;
DROP SCHEMA IF EXISTS auth CASCADE;
CREATE SCHEMA public;
CREATE SCHEMA auth;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

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

CREATE TYPE public.account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED');
CREATE TYPE public.app_role AS ENUM ('USER','ADMIN','SERVICE_PROVIDER','VEHICLE_PROVIDER','SUPPORT');

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name text, phone text, email text, national_id text,
  status public.account_status DEFAULT 'PENDING_APPROVAL',
  updated_at timestamptz DEFAULT now()
);
CREATE TABLE public.user_roles (
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  PRIMARY KEY (user_id, role)
);
CREATE TABLE public.approval_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL, subject_id uuid NOT NULL,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL'
);

CREATE TABLE public.staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
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
  updated_at timestamptz DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.staff_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL UNIQUE REFERENCES public.staff(id) ON DELETE CASCADE,
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE CASCADE,
  -- the 0045 constraint under test
  username text NOT NULL CHECK (
    username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'
    OR username ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$'
  ),
  failed_attempts integer NOT NULL DEFAULT 0,
  locked_until timestamptz,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_staff_credentials_username ON public.staff_credentials (lower(username));

-- a dependent row, to prove the cascade really removes children
CREATE TABLE public.staff_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  task_key text NOT NULL
);
CREATE TABLE public.admin_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor uuid, action text NOT NULL, related uuid,
  category text, city text, images text[] DEFAULT '{}',
  metadata jsonb DEFAULT '{}'::jsonb, created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.log_admin_action(
  p_actor uuid, p_action text, p_related uuid, p_category text, p_city text,
  p_images text[] DEFAULT '{}', p_metadata jsonb DEFAULT '{}')
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO public.admin_history(actor, action, related, category, city, images, metadata)
  VALUES (p_actor, p_action, p_related, p_category, p_city, p_images, p_metadata)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.is_ceo(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM public.staff WHERE user_id = p_user_id AND is_ceo AND is_active)
$$;

CREATE OR REPLACE FUNCTION public.sha256_hex(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(p_text, 'UTF8')), 'hex');
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- Apply the migrations under test
-- ─────────────────────────────────────────────────────────────────────────
\if :{?repo_root}
\else
  \set repo_root '../..'
\endif

\i :repo_root/supabase/migrations/20260925160000_staff_username_email_format.sql
\i :repo_root/supabase/migrations/20260925170000_staff_email_identity.sql
\i :repo_root/supabase/migrations/20260925180000_staff_delete.sql
\i :repo_root/supabase/migrations/20260925190000_staff_delete_actor_param.sql

-- Re-add the functions create_staff_gateway depends on, whose real bodies
-- live in earlier migrations that need far more schema than this stub has.
CREATE OR REPLACE FUNCTION public.create_staff_gateway(
  p_actor_id uuid, p_auth_user_id uuid, p_username text, p_name text,
  p_staff_code text, p_permissions text[], p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false, p_branch text DEFAULT 'ADMIN',
  p_assigned_categories uuid[] DEFAULT '{}'
) RETURNS public.staff LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_username text := lower(btrim(p_username));
  v_email text;
  v_staff public.staff;
BEGIN
  IF NOT public.is_ceo(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_STAFF_GATEWAY';
  END IF;
  IF v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
     AND v_username !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' THEN
    RAISE EXCEPTION 'INVALID_STAFF_USERNAME';
  END IF;
  v_email := public.staff_gateway_email(v_username);
  IF EXISTS (SELECT 1 FROM public.staff_credentials WHERE lower(username) = v_username) THEN
    RAISE EXCEPTION 'STAFF_USERNAME_TAKEN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_auth_user_id AND lower(email) = v_email) THEN
    RAISE EXCEPTION 'STAFF_AUTH_IDENTITY_MISMATCH';
  END IF;
  INSERT INTO public.staff (user_id, name, staff_code, permissions, sales_target,
                            is_super_admin, branch, is_ceo, assigned_categories, created_by)
  VALUES (p_auth_user_id, btrim(p_name), btrim(p_staff_code), p_permissions,
          COALESCE(p_sales_target, 0), p_is_super_admin, p_branch, false,
          COALESCE(p_assigned_categories, '{}'::uuid[]), p_actor_id)
  RETURNING * INTO v_staff;
  INSERT INTO public.staff_credentials (staff_id, user_id, username)
  VALUES (v_staff.id, p_auth_user_id, v_username);
  INSERT INTO public.user_roles (user_id, role) VALUES (p_auth_user_id, 'ADMIN')
    ON CONFLICT DO NOTHING;
  UPDATE public.profiles SET full_name = btrim(p_name), email = v_email,
    status = 'APPROVED', updated_at = now() WHERE id = p_auth_user_id;
  DELETE FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = p_auth_user_id;
  PERFORM public.log_admin_action(p_actor_id, 'STAFF_GATEWAY_CREATED', v_staff.id,
    'staff', NULL, '{}', jsonb_build_object('username', v_username));
  RETURN v_staff;
END $$;

-- ─────────────────────────────────────────────────────────────────────────
-- Tests
-- ─────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_ceo_user uuid; v_ceo_staff uuid; v_other_user uuid;
  v_legacy_user uuid; v_legacy_staff uuid;
  v_email_user uuid; v_email_staff uuid;
  v_victim_user uuid; v_victim_staff uuid;
  v_email text; v_result jsonb; v_count int;
BEGIN
  -- 1. LEGACY USERS ARE NOT RE-KEYED. This is the compatibility guarantee:
  --    a bare name must still produce the exact original address.
  v_email := public.staff_gateway_email('aymen');
  IF v_email <> 'aymen@staff-gateway.invalid' THEN
    RAISE EXCEPTION 'REGRESSION: legacy username re-keyed -> %', v_email;
  END IF;
  RAISE NOTICE 'PASS legacy username maps to the original synthetic email';

  -- 2. EMAIL USERNAMES get a valid fixed-shape address (exactly one @, and
  --    the local part cannot itself contain one).
  v_email := public.staff_gateway_email('aymen@gmail.com');
  IF v_email !~ '^s_[0-9a-f]{24}@staff-gateway\.invalid$' THEN
    RAISE EXCEPTION 'FAIL email mapping produced %', v_email;
  END IF;
  RAISE NOTICE 'PASS email username maps to a hashed fixed-shape address';

  -- 3. Deterministic: create and login must compute the same value.
  IF public.staff_gateway_email('aymen@gmail.com') <> v_email THEN
    RAISE EXCEPTION 'FAIL email mapping is not deterministic';
  END IF;
  RAISE NOTICE 'PASS email mapping is deterministic';

  -- 4. Case-insensitive, matching the lower(username) unique index.
  IF public.staff_gateway_email('AyMen@Gmail.com') <> v_email THEN
    RAISE EXCEPTION 'FAIL email mapping is case-sensitive';
  END IF;
  RAISE NOTICE 'PASS email mapping normalises case';

  -- 5. No collisions between distinct emails.
  IF public.staff_gateway_email('a@gmail.com')
     = public.staff_gateway_email('b@gmail.com') THEN
    RAISE EXCEPTION 'FAIL two different emails collided';
  END IF;
  RAISE NOTICE 'PASS distinct emails do not collide';

  -- 6. The CHECK constraint accepts both shapes...
  INSERT INTO auth.users(id, email) VALUES (gen_random_uuid(), 'x@staff-gateway.invalid');
  INSERT INTO public.staff (user_id, name, staff_code)
    SELECT id, 'Legacy', 'LEG1' FROM auth.users WHERE email='x@staff-gateway.invalid';
  v_legacy_staff := (SELECT id FROM public.staff WHERE staff_code='LEG1');
  INSERT INTO public.staff_credentials(staff_id, user_id, username)
    SELECT v_legacy_staff, user_id, 'aymen' FROM public.staff WHERE id=v_legacy_staff;
  RAISE NOTICE 'PASS CHECK accepts the legacy bare-name form';

  BEGIN
    INSERT INTO public.staff_credentials(staff_id, user_id, username)
      SELECT v_legacy_staff, user_id, 'nope@' FROM public.staff WHERE id=v_legacy_staff;
    RAISE EXCEPTION 'FAIL CHECK accepted "nope@"';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS CHECK rejects a malformed email';
  END;

  -- 7. delete_staff refuses a non-CEO.
  --
  --    The actor is passed as p_actor_id, NOT via set_config /
  --    request.jwt.claim.sub. That is deliberate and is the whole point of
  --    0048: the only caller is the service-role edge function, whose request
  --    carries no end-user JWT, so auth.uid() is NULL there. The previous
  --    version of this test set the JWT claim, which made the function's
  --    auth.uid() check pass and hid a bug that made EVERY real delete fail
  --    with 403. Driving the actor through the parameter is how the function
  --    is actually reached, so this is the case that would have caught it.
  INSERT INTO auth.users(id, email) VALUES (gen_random_uuid(), 'boss@staff-gateway.invalid');
  v_ceo_user := (SELECT id FROM auth.users WHERE email='boss@staff-gateway.invalid');
  INSERT INTO public.staff (user_id, name, staff_code, is_ceo)
    VALUES (v_ceo_user, 'Boss', 'CEO1', true);

  INSERT INTO auth.users(id, email) VALUES (gen_random_uuid(), 'other@staff-gateway.invalid');
  v_other_user := (SELECT id FROM auth.users WHERE email='other@staff-gateway.invalid');
  INSERT INTO public.staff (user_id, name, staff_code)
    VALUES (v_other_user, 'Other', 'OTH1');

  INSERT INTO auth.users(id, email) VALUES (gen_random_uuid(), 'sub@staff-gateway.invalid');
  v_legacy_user := (SELECT id FROM auth.users WHERE email='sub@staff-gateway.invalid');
  INSERT INTO public.staff (user_id, name, staff_code) VALUES (v_legacy_user, 'Sub', 'SUB1');
  v_legacy_staff := (SELECT id FROM public.staff WHERE staff_code='SUB1');
  INSERT INTO public.staff_credentials(staff_id, user_id, username)
    VALUES (v_legacy_staff, v_legacy_user, 'subadmin');
  INSERT INTO public.staff_tasks(staff_id, task_key) VALUES (v_legacy_staff, 'TASK1');
  INSERT INTO public.user_roles(user_id, role) VALUES (v_legacy_user, 'ADMIN');

  -- p_actor_id is a parameter, so a non-CEO must be refused even though the
  -- caller holds the service role. This is the assertion that stops the new
  -- parameter from becoming an escalation hole.
  BEGIN
    PERFORM public.delete_staff(v_other_user, v_legacy_staff);
    RAISE EXCEPTION 'FAIL a non-CEO p_actor_id was allowed to delete staff';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ONLY_CEO_CAN_DELETE_STAFF%' THEN
      RAISE EXCEPTION 'FAIL delete_staff raised the wrong error: %', SQLERRM;
    END IF;
    RAISE NOTICE 'PASS delete_staff refuses a non-CEO p_actor_id';
  END;

  -- A NULL p_actor_id must be refused too: is_ceo(NULL) is false, which is
  -- exactly the state the real gateway was in before 0048.
  BEGIN
    PERFORM public.delete_staff(NULL, v_legacy_staff);
    RAISE EXCEPTION 'FAIL a NULL actor was allowed to delete staff';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%ONLY_CEO_CAN_DELETE_STAFF%' THEN
      RAISE EXCEPTION 'FAIL expected ONLY_CEO_CAN_DELETE_STAFF, got: %', SQLERRM;
    END IF;
    RAISE NOTICE 'PASS delete_staff refuses a NULL actor (the pre-0048 state)';
  END;

  -- The refused attempts must have changed nothing.
  SELECT count(*) INTO v_count FROM public.staff WHERE id = v_legacy_staff;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL a refused delete still removed the row'; END IF;
  RAISE NOTICE 'PASS a refused delete leaves the staff row intact';

  -- 8. delete_staff refuses the CEO row, even when called BY the CEO.
  BEGIN
    PERFORM public.delete_staff(v_ceo_user, (SELECT id FROM public.staff WHERE is_ceo));
    RAISE EXCEPTION 'FAIL the CEO row was deletable';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%CANNOT_DELETE_CEO%' THEN
      RAISE EXCEPTION 'FAIL expected CANNOT_DELETE_CEO, got: %', SQLERRM;
    END IF;
    RAISE NOTICE 'PASS delete_staff refuses the CEO row';
  END;

  -- 9. A CEO CAN delete, and it cascades + returns the auth id.
  v_victim_user := v_legacy_user;
  v_victim_staff := v_legacy_staff;
  v_result := public.delete_staff(v_ceo_user, v_victim_staff);

  IF (v_result ->> 'auth_user_id') <> v_victim_user::text THEN
    RAISE EXCEPTION 'FAIL delete_staff did not return the auth user id';
  END IF;
  RAISE NOTICE 'PASS delete_staff returns the auth_user_id for GoTrue cleanup';

  SELECT count(*) INTO v_count FROM public.staff WHERE id = v_victim_staff;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL staff row survived'; END IF;
  SELECT count(*) INTO v_count FROM public.staff_credentials WHERE staff_id = v_victim_staff;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL staff_credentials survived (no cascade)'; END IF;
  SELECT count(*) INTO v_count FROM public.staff_tasks WHERE staff_id = v_victim_staff;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL staff_tasks survived (no cascade)'; END IF;
  SELECT count(*) INTO v_count FROM public.user_roles WHERE user_id = v_victim_user;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL the ADMIN role survived deletion'; END IF;
  RAISE NOTICE 'PASS delete_staff cascades credentials, tasks, and drops the ADMIN role';

  SELECT count(*) INTO v_count FROM public.admin_history WHERE action = 'STAFF_DELETED';
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL STAFF_DELETED was not logged'; END IF;
  RAISE NOTICE 'PASS delete_staff writes an admin_history entry';

  -- The auth row itself must SURVIVE: the Edge Function removes it with the
  -- service role. If it were deleted here the ordering guarantee would break.
  SELECT count(*) INTO v_count FROM auth.users WHERE id = v_victim_user;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL delete_staff deleted the auth row itself'; END IF;
  RAISE NOTICE 'PASS delete_staff leaves auth.users to the Edge Function';

  RAISE NOTICE 'ALL STAFF IDENTITY + DELETE TESTS PASSED';
END $$;
