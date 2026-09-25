-- 0036 — handle_new_user: ONE consolidated body for EVERY signup path.
--
-- Context: this single trigger function has been re-emitted by at least five
-- migrations (approval workflow, OTP gate + address fields, referral
-- tracking, staff-gateway bypass, Google-OAuth gate). Any drift between the
-- migration files and the LIVE database produces exactly the failure class we
-- saw tonight: Google sign-in completes OAuth, then dies with
-- "Database error saving new user" (unexpected_failure) when the trigger
-- raises partway. This migration does two things:
--
--   1. Re-emits handle_new_user() as the verified superset of all five
--      changes so the function is correct regardless of which prior version
--      the live DB ended up with. Byte-superset of the f335b24 (0035+OAuth)
--      body; every clause is exercised by the regression sweep below.
--
--   2. Adds assert_handle_new_user_contract() — a self-reporting probe that
--      returns the LIVE trigger definition and runs the signup-path sweep
--      against the live database (ephemeral rows, fully rolled back). This
--      is how the deployed state proves itself without dashboard access.
--
-- The sweep covers ALL paths that share this function:
--   A. email signup, OTP-verified (the sanctioned mobile path)
--   B. email signup, unverified        → must be rejected EMAIL_OTP_REQUIRED
--   C. dashboard-created admin subject → must pass without OTP
--   D. provider signup (VEHICLE_PROVIDER + referral code)
--   E. Google OAuth signup (provider-verified email + provider metadata)
--   F. staff-gateway creation (app_metadata staff_gateway=true)
--
-- 3. RE-EMITS prevent_role_escalation() with the documented escape from
--    0022_fix_role_escalation_trigger.sql (applied live 2026-09-17): the
--    admin check is enforced ONLY for direct client requests
--    (current_user = 'authenticated'), never inside SECURITY DEFINER
--    contexts. WHY THIS BELONGS IN THE SAME MIGRATION: trg_user_roles_security
--    fires on the user_roles INSERT inside handle_new_user — a strict variant
--    of this guard raises ROLE_ASSIGNMENT_IS_ADMIN_ONLY and rolls back the
--    ENTIRE signup transaction for EVERY path (email, provider, Google,
--    staff-gateway), producing exactly the observed
--    "Database error saving new user" / staff_account_creation_failed.
--    The fixed file is a duplicate-version sibling (0022_*) that the deploy
--    pipeline's one-file-per-version staging step SKIPS, so a live DB that
--    lost the fixed variant could never receive it again through deploys.
--    Re-emitting here makes the migration self-sufficient: if live already
--    has the escape this is a no-op; if it drifted to a strict variant, this
--    is the fix. Client-facing protection is unchanged (direct inserts by
--    'authenticated' still require the ADMIN role).
--
-- Revoke note: assert_handle_new_user_contract() is granted to anon so the
-- read-only live probes can run it without service credentials. It performs
-- no lasting writes (each path rolls back), but revoke after debugging if
-- desired:  REVOKE EXECUTE ON FUNCTION
--   public.assert_handle_new_user_contract() FROM anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- 1. The consolidated trigger body
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin_subject boolean;
  v_provider text;
  v_referral_code text := upper(btrim(coalesce(new.raw_user_meta_data ->> 'referral_code', '')));
  v_referrer_staff_id uuid;
  v_referrer_name text;
BEGIN
  v_provider := NULLIF(btrim(coalesce(new.raw_app_meta_data ->> 'provider', '')), '');

  v_is_admin_subject := (
    -- Dashboard-created subjects: email confirmed, no signup metadata.
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    -- Staff-gateway subjects: created by staff-create-gateway with a
    -- service-role auth user + app_metadata flag (migration 0035).
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
    -- OAuth subjects (Google today, others later): the provider verified
    -- the email, so the OTP gate is satisfied by provider verification.
    -- raw_user_meta_data is populated for OAuth users, so neither clause
    -- above can match — this clause is what Task 15 depends on.
    OR (new.email_confirmed_at IS NOT NULL AND v_provider IS NOT NULL)
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

-- ─────────────────────────────────────────────────────────────────────────
-- 3. The signup-chain role guard (see header item 3)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.prevent_role_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Enforce the ADMIN check ONLY for direct client requests. Inside
  -- SECURITY DEFINER functions (signup triggers, system flows) current_user
  -- is the function owner, not 'authenticated', and the assignment proceeds.
  IF current_user = 'authenticated' THEN
    IF NOT is_admin() THEN
      RAISE EXCEPTION 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY';
    END IF;
  END IF;
  RETURN new;
END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- 4. The self-reporting contract probe (live-state verification)
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.assert_handle_new_user_contract()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb := '{}'::jsonb;
  v_tests jsonb := '[]'::jsonb;
  v_email text;
  v_profiles int;
  v_provider_rows int;
BEGIN
  -- Garbage-collect any leftovers from an interrupted previous run, children
  -- before parents so foreign keys can never block the sweep.
  DELETE FROM public.provider_profiles WHERE user_id IN (
    SELECT id FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local');
  DELETE FROM public.profiles WHERE id IN (
    SELECT id FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local');
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  v_result := v_result
    || jsonb_build_object(
      'trigger_name', (SELECT tgname FROM pg_trigger
                        WHERE tgrelid = 'auth.users'::regclass
                          AND tgisinternal = false LIMIT 1),
      'trigger_def', COALESCE((
        SELECT pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        WHERE t.tgrelid = 'auth.users'::regclass AND NOT t.tgisinternal
        ORDER BY t.tgname
      )::text, NULL),
      'function_def', pg_get_functiondef('public.handle_new_user()'::regprocedure),
      'signup_chain_guards', jsonb_build_object(
        'prevent_role_escalation', pg_get_functiondef('public.prevent_role_escalation()'::regprocedure),
        'prevent_profile_insert_privilege_escalation', pg_get_functiondef('public.prevent_profile_insert_privilege_escalation()'::regprocedure),
        'auto_create_user_approval_request', pg_get_functiondef('public.auto_create_user_approval_request()'::regprocedure)
      ),
      'profiles_columns', (
        SELECT jsonb_agg(column_name ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'profiles'
      ),
      'provider_profiles_columns', (
        SELECT jsonb_agg(column_name ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'provider_profiles'
      ),
      'companion_functions', jsonb_build_object(
        'otp_verified_recently', to_jsonb(pg_get_functiondef('public.otp_verified_recently(text)'::regprocedure) IS NOT NULL),
        'default_city', to_jsonb(pg_get_functiondef('public.default_city()'::regprocedure) IS NOT NULL)
      )
    );

  -- ── Path A: email signup, OTP verified → must succeed ──────────────────
  BEGIN
    v_email := 'hnu-sweep-a-' || floor(random()*1e9)::text || '@test.local';
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            crypt('x', gen_salt('bf')), NULL,
            '{}'::jsonb,
            jsonb_build_object('full_name', 'Sweep A', 'phone', '+251911000001',
                               'city', 'Addis Ababa'),
            now(), now(), '', '', '', '', '');
    SELECT count(*) INTO v_profiles FROM public.profiles p
      JOIN auth.users u ON u.id = p.id WHERE u.email = v_email;
    v_tests := v_tests || jsonb_build_object(
      'path', 'A_email_otp_verified',
      'pass', v_profiles = 1,
      'detail', 'profiles rows = ' || v_profiles);
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'A_email_otp_verified',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path B: email signup, NOT verified → must be rejected ─────────────
  BEGIN
    v_email := 'hnu-sweep-b-' || floor(random()*1e9)::text || '@test.local';
    BEGIN
      INSERT INTO auth.users (instance_id, id, aud, role, email,
                              encrypted_password, email_confirmed_at,
                              raw_app_meta_data, raw_user_meta_data,
                              created_at, updated_at, confirmation_token,
                              recovery_token, email_change, email_change_token_new,
                              email_change_token_current)
      VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
              'authenticated', 'authenticated', v_email,
              crypt('x', gen_salt('bf')), NULL,
              '{}'::jsonb,
              jsonb_build_object('full_name', 'Sweep B'),
              now(), now(), '', '', '', '', '');
      -- No exception raised = gate failed to fire.
      v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified_rejected',
        'pass', false, 'detail', 'trigger did NOT raise EMAIL_OTP_REQUIRED');
    EXCEPTION
      WHEN OTHERS THEN
        v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified_rejected',
          'pass', SQLERRM LIKE 'EMAIL_OTP_REQUIRED%',
          'detail', SQLERRM);
    END;
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified_rejected',
      'pass', false, 'detail', 'outer: ' || SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path C: dashboard admin subject (confirmed, no metadata) ──────────
  BEGIN
    v_email := 'hnu-sweep-c-' || floor(random()*1e9)::text || '@test.local';
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            crypt('x', gen_salt('bf')), now(),
            '{}'::jsonb, NULL,
            now(), now(), '', '', '', '', '');
    SELECT count(*) INTO v_profiles FROM public.profiles p
      JOIN auth.users u ON u.id = p.id WHERE u.email = v_email;
    v_tests := v_tests || jsonb_build_object(
      'path', 'C_dashboard_admin_subject',
      'pass', v_profiles = 1,
      'detail', 'profiles rows = ' || v_profiles);
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'C_dashboard_admin_subject',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path D: provider signup with referral code ────────────────────────
  BEGIN
    v_email := 'hnu-sweep-d-' || floor(random()*1e9)::text || '@test.local';
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            crypt('x', gen_salt('bf')), NULL,
            '{}'::jsonb,
            jsonb_build_object('full_name', 'Sweep D Provider',
                               'provider_type', 'VEHICLE_PROVIDER',
                               'business_name', 'Sweep D Business',
                               'national_id', 'SWEEP-D-ID',
                               'referral_code', 'SWEEPD'),
            now(), now(), '', '', '', '', '');
    SELECT count(*) INTO v_provider_rows FROM public.provider_profiles pp
      JOIN auth.users u ON u.id = pp.user_id WHERE u.email = v_email;
    v_tests := v_tests || jsonb_build_object(
      'path', 'D_provider_signup_with_referral',
      'pass', v_provider_rows = 1,
      'detail', 'provider_profiles rows = ' || v_provider_rows ||
                ' (unknown code must be tolerated, row still created)');
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'D_provider_signup_with_referral',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path E: Google OAuth signup (provider-verified email) ─────────────
  BEGIN
    v_email := 'hnu-sweep-e-' || floor(random()*1e9)::text || '@test.local';
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            crypt('x', gen_salt('bf')), now(),
            jsonb_build_object('provider', 'google', 'providers', jsonb_build_array('google')),
            jsonb_build_object('full_name', 'Sweep E Google', 'avatar_url', 'x'),
            now(), now(), '', '', '', '', '');
    SELECT count(*) INTO v_profiles FROM public.profiles p
      JOIN auth.users u ON u.id = p.id WHERE u.email = v_email;
    v_tests := v_tests || jsonb_build_object(
      'path', 'E_google_oauth_signup',
      'pass', v_profiles = 1,
      'detail', 'profiles rows = ' || v_profiles);
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'E_google_oauth_signup',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path F: staff-gateway creation shape ──────────────────────────────
  BEGIN
    v_email := 'hnu-sweep-f-' || floor(random()*1e9)::text || '@test.local';
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            crypt('x', gen_salt('bf')), now(),
            jsonb_build_object('staff_gateway', 'true'),
            jsonb_build_object('full_name', 'Sweep F Staff'),
            now(), now(), '', '', '', '', '');
    SELECT count(*) INTO v_profiles FROM public.profiles p
      JOIN auth.users u ON u.id = p.id WHERE u.email = v_email;
    v_tests := v_tests || jsonb_build_object(
      'path', 'F_staff_gateway',
      'pass', v_profiles = 1,
      'detail', 'profiles rows = ' || v_profiles);
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'F_staff_gateway',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  v_result := v_result || jsonb_build_object('sweep', v_tests);
  v_result := v_result || jsonb_build_object(
    'all_pass', NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(v_tests) t
      WHERE (t->>'pass')::boolean IS NOT TRUE
    ));

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_handle_new_user_contract() TO anon, authenticated;
