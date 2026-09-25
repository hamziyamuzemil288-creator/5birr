-- LIVE-LINEAGE probe: fingerprint sweep + six-path signup matrix for the
-- handle_new_user regression (Google sign-in "Database error saving new
-- user" + staff-create-gateway 500 staff_account_creation_failed).
--
-- This file no longer assembles the database itself — the assembled lineage
-- lives in ONE place: tools/test/hnu_live_lineage_driver.sh (CI-verified:
-- 0021_live_schema_snapshot.sql -> 0022_complete_schema.sql -> every later
-- migration in filename order; siblings 0020_auth_profile_trigger /
-- 0021_provider_role_trigger / 0022_fix_role_escalation_trigger skipped by
-- one-file-per-version staging; 0022a/b/c/d skipped as "CLI-ignored,
-- non-numeric prefix" — Deploy Supabase run 36160977520 stage log).
--
-- The driver runs this file's contents against (1) the verbatim lineage —
-- EXPECTED: every trusted path FAILS with ROLE_ASSIGNMENT_IS_ADMIN_ONLY
-- (in GoTrue's signup transaction auth.uid() is unset, has_role('ADMIN') is
-- false, and the strict trg_user_roles_security guard rolls back the whole
-- signup for EVERY path) — and (2) the same lineage + the consolidated
-- migration's handle_new_user + prevent_role_escalation — EXPECTED: all
-- trusted paths PASS, B still rejected, G still blocked.
--
-- Run via: bash tools/test/hnu_live_lineage_driver.sh

-- ============================================================
-- LIVE-STATE FINGERPRINTS — what is actually deployed after the lineage
-- ============================================================
\echo
\echo '=== F1: live handle_new_user (pre-fix body = R4 gate) ==='
SELECT prosrc FROM pg_proc WHERE oid = 'public.handle_new_user()'::regprocedure;
\echo '=== F2: live prevent_role_escalation (MUST show the strict form) ==='
SELECT prosrc FROM pg_proc WHERE oid = 'public.prevent_role_escalation()'::regprocedure;
\echo '=== F3: trigger binding ==='
SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
 WHERE tgrelid = 'auth.users'::regclass AND NOT tgisinternal;
\echo '=== F4: user_roles guard binding ==='
SELECT tgname, pg_get_triggerdef(oid) FROM pg_trigger
 WHERE tgrelid = 'public.user_roles'::regclass;

-- ============================================================
-- SWEEP-SECTION START (driver extracts everything below to re-run the
-- matrix standalone after applying the consolidated fix)
-- ============================================================

-- A: email signup, OTP verified -> must pass. Faithful production chain:
-- request_email_otp -> verify_email_otp (the real RPCs) -> signUp. Unique
-- per-run email so the 60s request rate-limit can never false-fail a rerun.
DO $$
DECLARE v_email text; v_n int;
BEGIN
  v_email := 'hnu-sweep-a-' || floor(random()*1e9)::text || '@test.local';
  PERFORM public.request_email_otp(v_email, '654321');
  IF (public.verify_email_otp(v_email, '654321') ->> 'ok') IS DISTINCT FROM 'true' THEN
    RAISE NOTICE 'FAIL A_email_otp_verified (OTP round-trip did not verify)';
    RETURN;
  END IF;
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES (v_email, crypt('x', gen_salt('bf')), NULL,
          '{}'::jsonb,
          jsonb_build_object('full_name','Sweep A','phone','+251911000001','city','Addis Ababa'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email = v_email;
  IF v_n = 1 THEN RAISE NOTICE 'PASS A_email_otp_verified'; ELSE
    RAISE NOTICE 'FAIL A_email_otp_verified (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL A_email_otp_verified (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- B: email signup, unverified -> must be REJECTED with EMAIL_OTP_REQUIRED
DO $$
BEGIN
  BEGIN
    INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data)
    VALUES ('hnu-sweep-b-' || floor(random()*1e9)::text || '@test.local',
            crypt('x', gen_salt('bf')), NULL,
            '{}'::jsonb, jsonb_build_object('full_name','Sweep B'));
    RAISE NOTICE 'FAIL B_email_unverified_rejected (no exception raised)';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'EMAIL_OTP_REQUIRED%' THEN
      RAISE NOTICE 'PASS B_email_unverified_rejected';
    ELSE
      RAISE NOTICE 'FAIL B_email_unverified_rejected (wrong error: %)', SQLERRM;
    END IF;
  END;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- C: dashboard admin subject (confirmed, no metadata) -> must pass
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('hnu-sweep-c-' || floor(random()*1e9)::text || '@test.local',
          crypt('x', gen_salt('bf')), now(), '{}'::jsonb, NULL);
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email LIKE 'hnu-sweep-c-%@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS C_dashboard_admin_subject'; ELSE
    RAISE NOTICE 'FAIL C_dashboard_admin_subject (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL C_dashboard_admin_subject (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- D: provider signup with referral code -> must pass (same OTP chain as A)
DO $$
DECLARE v_email text; v_n int;
BEGIN
  v_email := 'hnu-sweep-d-' || floor(random()*1e9)::text || '@test.local';
  PERFORM public.request_email_otp(v_email, '654321');
  IF (public.verify_email_otp(v_email, '654321') ->> 'ok') IS DISTINCT FROM 'true' THEN
    RAISE NOTICE 'FAIL D_provider_signup_with_referral (OTP round-trip did not verify)';
    RETURN;
  END IF;
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES (v_email, crypt('x', gen_salt('bf')), NULL,
          '{}'::jsonb,
          jsonb_build_object('full_name','Sweep D Provider',
                             'provider_type','VEHICLE_PROVIDER',
                             'business_name','Sweep D Business',
                             'national_id','SWEEP-D-ID',
                             'referral_code','SWEEPD'));
  SELECT count(*) INTO v_n FROM public.provider_profiles pp
    JOIN auth.users u ON u.id = pp.user_id
   WHERE u.email = v_email;
  IF v_n = 1 THEN RAISE NOTICE 'PASS D_provider_signup_with_referral'; ELSE
    RAISE NOTICE 'FAIL D_provider_signup_with_referral (pp=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL D_provider_signup_with_referral (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- E: Google OAuth signup (provider-verified email) -> must pass on the fix,
-- FAILS on the live lineage (reproduction)
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('hnu-sweep-e-' || floor(random()*1e9)::text || '@test.local',
          crypt('x', gen_salt('bf')), now(),
          jsonb_build_object('provider','google','providers',jsonb_build_array('google')),
          jsonb_build_object('full_name','Sweep E Google','avatar_url','x'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email LIKE 'hnu-sweep-e-%@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS E_google_oauth_signup'; ELSE
    RAISE NOTICE 'FAIL E_google_oauth_signup (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL E_google_oauth_signup (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- F: staff-gateway shape -> must pass on the fix,
-- FAILS on the live lineage (reproduction)
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('hnu-sweep-f-' || floor(random()*1e9)::text || '@test.local',
          crypt('x', gen_salt('bf')), now(),
          jsonb_build_object('staff_gateway','true'),
          jsonb_build_object('full_name','Sweep F Staff'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email LIKE 'hnu-sweep-f-%@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS F_staff_gateway'; ELSE
    RAISE NOTICE 'FAIL F_staff_gateway (profiles=%)', v_n;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL F_staff_gateway (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

-- G: the admin-only guarantee on user_roles must STILL hold for direct
-- client requests after the fix. Create a confirmed dashboard-shaped subject,
-- then simulate the production JWT context (request.jwt.claim.sub set, no
-- ADMIN role) and try the insert: it must raise ROLE_ASSIGNMENT_IS_ADMIN_ONLY
-- exactly as it does for a real user.
DO $$
DECLARE v_email text; v_uid uuid;
BEGIN
  v_email := 'hnu-sweep-g-' || floor(random()*1e9)::text || '@test.local';
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES (v_email, crypt('x', gen_salt('bf')), now(), '{}'::jsonb, NULL)
  RETURNING id INTO v_uid;
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', v_uid::text, true);
    INSERT INTO public.user_roles (user_id, role) VALUES (v_uid, 'ADMIN'::app_role);
    RAISE NOTICE 'FAIL G_role_guard_blocks_client (insert succeeded)';
  EXCEPTION
    WHEN insufficient_privilege THEN
      -- Two independent layers can block a direct client here, and either is
      -- a pass: RLS (user_roles_admin_write WITH CHECK (is_admin()) — checked
      -- BEFORE the BEFORE ROW trigger, SQLSTATE 42501) or the strict trigger
      -- guard (ROLE_ASSIGNMENT_IS_ADMIN_ONLY). Production has both.
      IF SQLERRM LIKE '%row-level security%' OR SQLERRM LIKE 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY%' THEN
        RAISE NOTICE 'PASS G_role_guard_blocks_client (% blocked)',
          CASE WHEN SQLERRM LIKE '%row-level security%' THEN 'RLS' ELSE 'trigger' END;
      ELSE
        RAISE NOTICE 'FAIL G_role_guard_blocks_client (unexpected: %)', SQLERRM;
      END IF;
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY%' THEN
        RAISE NOTICE 'PASS G_role_guard_blocks_client (trigger blocked)';
      ELSE
        RAISE NOTICE 'FAIL G_role_guard_blocks_client (wrong error: %)', SQLERRM;
      END IF;
  END;
  RESET role;
END $$;
DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';
