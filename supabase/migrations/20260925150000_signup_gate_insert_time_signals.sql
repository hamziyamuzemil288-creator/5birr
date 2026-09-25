-- 0044 — signup gate: trust only signals that exist AT INSERT TIME.
--
-- Symptom this fixes: Google Sign-In and staff creation both still failed
-- after the role-guard fix, with the SAME trigger rejection, even though the
-- live function bodies were correct:
--   Google  -> AuthException: Database error saving new user (unexpected_failure)
--   Staff   -> 500 staff_account_creation_failed
--
-- ROOT CAUSE — the gate asked for state GoTrue writes AFTER the insert.
-- Verified against supabase/auth source:
--
--   * OAuth (internal/api/external.go, createAccountFromExternalIdentity):
--       user, _ = params.ToUserModel(isSSOUser)   // app_metadata.provider set here
--       a.signupNewUser(tx, user)                 // <-- INSERT happens here
--       ...
--       if !user.IsConfirmed() { user.Confirm(tx) } // email_confirmed_at set HERE
--     So at INSERT time email_confirmed_at IS NULL for every OAuth signup.
--     The gate's provider clause required
--         email_confirmed_at IS NOT NULL AND v_provider IS NOT NULL
--     which can never be true inside the trigger. Google sign-up was
--     therefore rejected by its own fix.
--
--   * Staff gateway (internal/api/admin.go, adminUserCreate):
--       user.AppMetaData = {"provider": ..., "providers": ...}   // staff_gateway NOT here
--       <INSERT happens>
--       user.UpdateAppMetaData(tx, params.AppMetaData)  // staff_gateway applied HERE
--       user.Confirm(tx)                                // email_confirmed_at HERE
--     The app_metadata.staff_gateway bypass was likewise invisible at insert.
--
-- Both rejections surface to the client as GoTrue's generic
-- "Database error creating/saving new user" because GoTrue collapses any
-- trigger exception into unexpected_failure — which is also why the edge
-- function's `msg.includes("EMAIL_OTP_REQUIRED")` branch could never fire
-- and every staff failure was reported as the generic code.
--
-- THE FIX
--   1. OAuth subjects are trusted on raw_app_meta_data->>'provider' alone,
--      which GoTrue populates before the INSERT (signup.go ToUserModel sets
--      AppMetaData["provider"] / ["providers"] on the model it then inserts).
--      app_metadata is server-controlled: a client cannot set it through
--      signUp data, so this cannot be forged. 'email' and 'phone' are
--      excluded on purpose — they must still pass the OTP gate.
--   2. Staff subjects can no longer be recognised by a flag that arrives
--      after the insert, so the gateway pre-authorises the synthetic address
--      through trust_staff_gateway_email(), which records a verification in
--      the same table otp_verified_recently() already trusts. It is
--      service-role only and refuses any address outside the gateway's own
--      synthetic domain, so it cannot be used to wave a real signup through
--      the email-verification gate.
--   3. assert_handle_new_user_contract() is re-emitted with GoTrue-faithful
--      fixtures. Its previous E/F rows set email_confirmed_at = now() and put
--      staff_gateway in the insert, which is MORE generous than production —
--      that mismatch is exactly why the local sweep reported success while
--      both live paths kept failing. The probe must not flatter the code it
--      is meant to test.

-- ─────────────────────────────────────────────────────────────────────────
-- 1. trust_staff_gateway_email — service-role-only pre-authorisation
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trust_staff_gateway_email(p_email text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(coalesce(p_email, '')));
BEGIN
  -- Hard scope limit: only the synthetic, non-deliverable domain the staff
  -- gateway itself mints. Without this the function would be a general
  -- "skip email verification" primitive for any address.
  IF v_email NOT LIKE '%@staff-gateway.invalid' THEN
    RAISE EXCEPTION 'STAFF_TRUST_DOMAIN_NOT_ALLOWED: %', v_email;
  END IF;

  -- One live row per email; drop any earlier authorization for this address.
  DELETE FROM public.email_otp_codes WHERE email = v_email;

  INSERT INTO public.email_otp_codes
    (email, code_hash, created_at, expires_at, consumed, attempts, max_attempts)
  VALUES
    (v_email, 'staff-gateway', now(), now() + interval '10 minutes', true, 1, 5);

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.trust_staff_gateway_email(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.trust_staff_gateway_email(text) TO service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 2. handle_new_user — the same consolidated body, with insert-time trust
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

  -- Signup gate. Only signals that GoTrue has already written by the time
  -- this AFTER INSERT trigger runs may be trusted:
  --   * raw_app_meta_data->>'provider' is set on the model BEFORE the insert
  --     (signup.go ToUserModel / admin.go adminUserCreate), so it is the one
  --     durable marker of a real third-party OAuth subject. email/phone are
  --     excluded: they must still prove an OTP.
  --   * staff_gateway is honoured for any caller that does manage to set it
  --     at insert time, but the deployed gateway cannot (admin.go applies
  --     app_metadata after the insert) and pre-authorises through
  --     trust_staff_gateway_email() instead.
  --   * email_confirmed_at is deliberately NOT used as a trust signal: GoTrue
  --     confirms OAuth and admin-created users in a later UPDATE, so it is
  --     null here for exactly the two paths that need to pass.
  v_is_admin_subject := (
    (new.email_confirmed_at IS NOT NULL AND new.raw_user_meta_data IS NULL)
    OR COALESCE(new.raw_app_meta_data ->> 'staff_gateway', '') = 'true'
    OR (v_provider IS NOT NULL AND v_provider NOT IN ('email', 'phone'))
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
-- 3. The contract probe, with fixtures that match what GoTrue really writes
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
  DELETE FROM public.provider_profiles WHERE user_id IN (
    SELECT id FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local');
  DELETE FROM public.profiles WHERE id IN (
    SELECT id FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local');
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
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
        'default_city', to_jsonb(pg_get_functiondef('public.default_city()'::regprocedure) IS NOT NULL),
        'trust_staff_gateway_email', to_jsonb(pg_get_functiondef('public.trust_staff_gateway_email(text)'::regprocedure) IS NOT NULL)
      )
    );

  -- ── Path A: email signup, OTP verified → must succeed ──────────────────
  -- GoTrue shape: email_confirmed_at NULL, app_metadata.provider = 'email'.
  BEGIN
    v_email := 'hnu-sweep-a-' || floor(random()*1e9)::text || '@test.local';
    -- "OTP verified" is a claim about database state, so the fixture has to
    -- actually create that state: a consumed verification row is precisely
    -- what otp_verified_recently() reads. Without this row the fixture is
    -- really exercising the UNVERIFIED path (identical to path B) and then
    -- reports a false failure against a signup flow that works in production.
    INSERT INTO public.email_otp_codes
      (email, code_hash, created_at, expires_at, consumed, attempts, max_attempts)
    VALUES (v_email, 'sweep-placeholder', now(), now() + interval '10 minutes',
            true, 1, 5);
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            'hnu-sweep-placeholder', NULL,
            jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
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
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
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
              jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
              jsonb_build_object('full_name', 'Sweep B'),
              now(), now(), '', '', '', '', '');
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
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
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
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path D: provider signup (OTP verified) ────────────────────────────
  BEGIN
    v_email := 'hnu-sweep-d-' || floor(random()*1e9)::text || '@test.local';
    -- Same requirement as path A: a provider signup is an OTP-verified email
    -- signup with extra user_metadata, so seed the consumed verification row
    -- the gate reads instead of asserting the state without creating it.
    INSERT INTO public.email_otp_codes
      (email, code_hash, created_at, expires_at, consumed, attempts, max_attempts)
    VALUES (v_email, 'sweep-placeholder', now(), now() + interval '10 minutes',
            true, 1, 5);
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            'hnu-sweep-placeholder', NULL,
            jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
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
      'detail', 'provider_profiles rows = ' || v_provider_rows);
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'D_provider_signup_with_referral',
      'pass', false, 'detail', SQLERRM);
  END;
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path E: Google OAuth signup, EXACTLY as GoTrue writes it ──────────
  -- provider present, email_confirmed_at NULL (Confirm() happens after the
  -- insert in internal/api/external.go).
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
            'hnu-sweep-placeholder', NULL,
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
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@test.local';
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@test.local';

  -- ── Path F: staff gateway, EXACTLY as admin.createUser writes it ───────
  -- app_metadata = provider/providers only (staff_gateway arrives after the
  -- insert), email_confirmed_at NULL, pre-authorised by the gateway through
  -- trust_staff_gateway_email().
  BEGIN
    v_email := 'hnu-sweep-f-' || floor(random()*1e9)::text || '@staff-gateway.invalid';
    PERFORM public.trust_staff_gateway_email(v_email);
    INSERT INTO auth.users (instance_id, id, aud, role, email,
                            encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token,
                            recovery_token, email_change, email_change_token_new,
                            email_change_token_current)
    VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
            'authenticated', 'authenticated', v_email,
            'hnu-sweep-placeholder', NULL,
            jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
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
  DELETE FROM auth.users WHERE email LIKE 'hnu-sweep-%@staff-gateway.invalid';
  DELETE FROM public.email_otp_codes WHERE email LIKE 'hnu-sweep-%@staff-gateway.invalid';

  -- ── Path G: the staff trust RPC must refuse any real address ──────────
  BEGIN
    BEGIN
      PERFORM public.trust_staff_gateway_email('someone@real-domain.com');
      v_tests := v_tests || jsonb_build_object('path', 'G_staff_trust_scoped_to_synthetic_domain',
        'pass', false, 'detail', 'accepted a non-gateway address');
    EXCEPTION WHEN OTHERS THEN
      v_tests := v_tests || jsonb_build_object('path', 'G_staff_trust_scoped_to_synthetic_domain',
        'pass', SQLERRM LIKE 'STAFF_TRUST_DOMAIN_NOT_ALLOWED%',
        'detail', SQLERRM);
    END;
  END;

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
