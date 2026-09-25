-- 0043 — repair assert_handle_new_user_contract()'s own test harness.
--
-- The 20260925120000 probe reported all six signup paths as failing with
-- "function gen_salt(unknown) does not exist", which looked like a broken
-- signup chain. It was not: the deployed handle_new_user and
-- prevent_role_escalation were both correct (verified by reading them back
-- from the live database). The probe itself was at fault.
--
-- CAUSE: the sweep inserts throwaway auth.users rows with
--   crypt('x', gen_salt('bf'))
-- but the function is SECURITY DEFINER with SET search_path = public, and on
-- Supabase pgcrypto lives in the `extensions` schema. Public-only search_path
-- cannot resolve gen_salt, so every path aborted before the trigger under
-- test ever ran. Same NULL-vs-error class of mistake as the search radius:
-- something in the harness, not in the subject.
--
-- FIX: the sweep never needs a real password hash — it only needs a non-NULL
-- encrypted_password to look like a credential-bearing signup subject. A
-- literal placeholder removes the pgcrypto dependency entirely and keeps the
-- probe working on any schema layout. Each path's rows are still deleted
-- immediately after the path completes.
--
-- No change to handle_new_user or prevent_role_escalation: both are already
-- correct on the live database and are left exactly as deployed.

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
            'hnu-sweep-placeholder', NULL,
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
              'hnu-sweep-placeholder', NULL,
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
            'hnu-sweep-placeholder', now(),
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
            'hnu-sweep-placeholder', NULL,
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
            'hnu-sweep-placeholder', now(),
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
            'hnu-sweep-placeholder', now(),
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
