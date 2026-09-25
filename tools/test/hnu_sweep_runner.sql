-- Six-path signup matrix for handle_new_user (pure SQL, no psql meta).
-- Expects: prelude stubs + one trigger revision already applied.
-- Prints one "PASS/FAIL path" notice per path; hard-fails at the end only if
-- a must-pass path failed (bash driver counts failures via exit code).

-- ── A: email signup, OTP verified → must pass ──────────────────────────
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('verified@example.com', crypt('x', gen_salt('bf')), NULL,
          '{}'::jsonb,
          jsonb_build_object('full_name','Sweep A','phone','+251911000001','city','Addis Ababa'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email = 'verified@example.com';
  IF v_n = 1 THEN RAISE NOTICE 'PASS A_email_otp_verified'; ELSE
    RAISE NOTICE 'FAIL A_email_otp_verified (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL A_email_otp_verified (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'sweep-%@test.local';
DELETE FROM auth.users WHERE email = 'verified@example.com';

-- ── B: email signup, unverified → must be REJECTED with EMAIL_OTP_REQUIRED
DO $$
BEGIN
  BEGIN
    INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data)
    VALUES ('sweep-b@test.local', crypt('x', gen_salt('bf')), NULL,
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
DELETE FROM auth.users WHERE email LIKE 'sweep-%@test.local';

-- ── C: dashboard admin subject (confirmed, no metadata) → must pass ─────
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('sweep-c@test.local', crypt('x', gen_salt('bf')), now(),
          '{}'::jsonb, NULL);
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email = 'sweep-c@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS C_dashboard_admin_subject'; ELSE
    RAISE NOTICE 'FAIL C_dashboard_admin_subject (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL C_dashboard_admin_subject (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'sweep-%@test.local';

-- ── D: provider signup with referral code → must pass ──────────────────
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('sweep-d@test.local', crypt('x', gen_salt('bf')), NULL,
          '{}'::jsonb,
          jsonb_build_object('full_name','Sweep D Provider',
                             'provider_type','VEHICLE_PROVIDER',
                             'business_name','Sweep D Business',
                             'national_id','SWEEP-D-ID',
                             'referral_code','SWEEPD'));
  SELECT count(*) INTO v_n FROM public.provider_profiles pp
    JOIN auth.users u ON u.id = pp.user_id
   WHERE u.email = 'sweep-d@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS D_provider_signup_with_referral'; ELSE
    RAISE NOTICE 'FAIL D_provider_signup_with_referral (pp=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL D_provider_signup_with_referral (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE email LIKE 'sweep-%@test.local';

-- E: Google OAuth signup (provider-verified email) → must pass on 0025+,
-- must FAIL on pre-0025 revisions — the bash driver interprets the notice.
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('sweep-e@test.local', crypt('x', gen_salt('bf')), now(),
          jsonb_build_object('provider','google','providers',jsonb_build_array('google')),
          jsonb_build_object('full_name','Sweep E Google','avatar_url','x'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email = 'sweep-e@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS E_google_oauth_signup'; ELSE
    RAISE NOTICE 'FAIL E_google_oauth_signup (profiles=%)', v_n; END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL E_google_oauth_signup (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE auth.users.email LIKE 'sweep-%@test.local';

-- F: staff-gateway shape → must pass on 0035+ — driver interprets notice.
DO $$
DECLARE v_n int;
BEGIN
  INSERT INTO auth.users (email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data)
  VALUES ('sweep-f@test.local', crypt('x', gen_salt('bf')), now(),
          jsonb_build_object('staff_gateway','true'),
          jsonb_build_object('full_name','Sweep F Staff'));
  SELECT count(*) INTO v_n FROM public.profiles p
    JOIN auth.users u ON u.id = p.id
   WHERE u.email = 'sweep-f@test.local';
  IF v_n = 1 THEN RAISE NOTICE 'PASS F_staff_gateway'; ELSE
    RAISE NOTICE 'FAIL F_staff_gateway (profiles=%)', v_n;
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'FAIL F_staff_gateway (%)', SQLERRM;
END $$;
DELETE FROM auth.users WHERE auth.users.email LIKE 'sweep-%@test.local';
DELETE FROM auth.users WHERE auth.users.email = 'verified@example.com';
