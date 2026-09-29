-- 20260927000082_signup_otp_is_a_toggle.sql
--
-- TEMPORARY: let registration complete without the email OTP, so every new
-- account lands in the admin approval queue instead of failing at signup.
--
-- WHY A TOGGLE AND NOT A DELETION
-- ------------------------------
-- The OTP is not broken code. It is blocked on configuration that does not
-- exist yet: `supabase/functions/send-otp` sends through Resend and fails
-- closed with `email_provider_not_configured` until RESEND_API_KEY and
-- OTP_FROM_EMAIL are set. Meanwhile `handle_new_user()` raises
-- EMAIL_OTP_REQUIRED, and because GoTrue collapses any trigger exception
-- into `unexpected_failure`, EVERY registration fails with an opaque
-- "Database error saving new user" — with no account created and nothing in
-- the admin queue to approve.
--
-- So the gate is made conditional on a setting, `signup_otp_required`,
-- seeded FALSE here. Re-enabling the OTP later is then one statement:
--
--   update public.system_settings
--      set value = 'true'::jsonb
--    where key = 'signup_otp_required';
--
-- — no code change, no redeploy, no client release. Deleting the gate
-- instead would mean re-deriving it later from scratch, which is how the
-- insert-time trust rules in 0044 got lost the first time.
--
-- WHAT IS NOT CHANGED
-- -------------------
--  * handle_new_user() still creates the profile in PENDING_APPROVAL and
--    still files the approval request. Admin approval remains the only gate
--    on a new account, which is the intended flow.
--  * The OAuth and staff-gateway trust rules are untouched.
--  * otp_verified_recently() is untouched, so the OTP path that this
--    re-enables is exactly the one that was verified.
--  * No RLS policy is weakened and no table is written outside the
--    migration-time settings seed, which restores its own guard.
--
-- FAIL-CLOSED: if the setting row is ever deleted, signup_otp_required()
-- returns TRUE and the OTP gate is back. A missing row must not be the
-- reason a stranger's account skips email verification.

-- ===========================================================================
-- 1. The setting
-- ===========================================================================
-- MIGRATION-TIME SEED BYPASS ONLY, the same pattern 0028 and 0038 use:
-- system_settings carries trg_system_settings_security ->
-- prevent_system_settings_self_modification() -> is_admin() -> auth.uid(),
-- and a migration connection has no JWT, so the guard fires no matter how
-- privileged the migration role is. The table owner may disable its own row
-- triggers for the scope of this transaction; the trigger is re-enabled
-- below and no RLS or trigger DEFINITION is touched. App-level writes stay
-- guarded exactly as before.
--
-- ON CONFLICT DO NOTHING, deliberately: once an owner has switched the OTP
-- back ON, re-running this migration must not silently switch it off again.
BEGIN;
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

INSERT INTO public.system_settings (key, value, description)
VALUES (
  'signup_otp_required',
  'false'::jsonb,
  'When true, a new account must verify an email OTP before it can be '
  'created. Temporarily false so registration completes and goes to admin '
  'approval while the OTP email provider (Resend) is unconfigured. Flip to '
  'true once RESEND_API_KEY and OTP_FROM_EMAIL exist.'
)
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;
COMMIT;

-- ===========================================================================
-- 2. What the client asks
-- ===========================================================================
-- SECURITY DEFINER because the guard above denies SELECT-by-INSERT to
-- everyone without a session, and this is read pre-authentication. It
-- returns one boolean and nothing else — no settings are exposed, and no
-- other get_setting_* reader is opened to anon by this.
CREATE OR REPLACE FUNCTION public.signup_otp_required()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT (s.value #>> '{}')::boolean
       FROM public.system_settings s
      WHERE s.key = 'signup_otp_required'),
    true   -- no row: the gate is ON. Fail closed.
  );
$$;

COMMENT ON FUNCTION public.signup_otp_required() IS
  'True when a new account must verify an email OTP first. Read by the '
  'signup screen before it decides whether to show the code screen. False '
  'means registration completes immediately and the account waits for admin '
  'approval instead.';

REVOKE ALL ON FUNCTION public.signup_otp_required() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.signup_otp_required() TO anon, authenticated;

-- ===========================================================================
-- 3. The gate itself
-- ===========================================================================
-- Byte-for-byte the 0044 body except for the one clause below. The insert
-- BEFORE trigger fires with no JWT, so this cannot consult the caller's
-- identity — it consults the setting, which is the only thing that decides
-- whether email is proven at signup time.
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

  -- TEMPORARY (00082): the whole clause is behind signup_otp_required().
  -- With the email provider unconfigured this raise is the only thing
  -- standing between a new visitor and an account, and it takes registration
  -- down completely — including the admin approval queue that is supposed
  -- to be the gate. Setting it to true restores the previous behaviour
  -- exactly.
  IF public.signup_otp_required()
     AND NOT v_is_admin_subject
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

-- ===========================================================================
-- 4. The contract probe, with path B made toggle-aware
-- ===========================================================================
-- assert_handle_new_user_contract() asserts that an unverified email signup
-- is REJECTED. That was true unconditionally and is now true only while the
-- OTP is switched on. Left as it was, the probe would report a false
-- failure for exactly the state this migration puts the database in, and a
-- diagnostic that cries wolf gets ignored exactly when it matters.
--
-- Everything else in the probe is unchanged, including the deliberate
-- fixtures: paths A/D seed a real consumed verification row rather than
-- asserting state they did not create.
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
  v_gate_on boolean;
BEGIN
  v_gate_on := public.signup_otp_required();

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
      'signup_otp_required', v_gate_on,
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

  -- ── Path B: email signup, NOT verified ────────────────────────────────
  -- The gate is a toggle (00082). ON  → the account must be refused.
  -- OFF → the account must be created, because that is the state the owner
  -- chose while the OTP email provider is unconfigured; the profile still
  -- lands in PENDING_APPROVAL with an approval request, which is the gate
  -- that actually protects the account.
  BEGIN
    v_email := 'hnu-sweep-b-' || floor(random()*1e9)::text || '@test.local';
    IF v_gate_on THEN
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
        v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified',
          'pass', false, 'detail', 'trigger did NOT raise EMAIL_OTP_REQUIRED while signup_otp_required is true');
      EXCEPTION
        WHEN OTHERS THEN
          v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified',
            'pass', SQLERRM LIKE 'EMAIL_OTP_REQUIRED%',
            'detail', SQLERRM);
      END;
    ELSE
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
      SELECT count(*) INTO v_profiles FROM public.profiles p
        JOIN auth.users u ON u.id = p.id WHERE u.email = v_email;
      v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified',
        'pass', v_profiles = 1,
        'detail', 'signup_otp_required is false: profile created and awaiting admin approval, expected');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'B_email_unverified',
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
  DELETE FROM auth.users WHERE email LIKE '%@staff-gateway.invalid';
  DELETE FROM public.email_otp_codes WHERE email LIKE '%@staff-gateway.invalid';

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

  -- ── Path H: the toggle must be readable by an anonymous signup ────────
  -- Without this the app cannot know whether to show the code screen, and
  -- the failure mode is the worst one: the screen is skipped while the
  -- server still refuses every account, so registration looks broken with
  -- no error anywhere.
  BEGIN
    IF NOT has_function_privilege('anon', 'public.signup_otp_required()', 'EXECUTE') THEN
      v_tests := v_tests || jsonb_build_object('path', 'H_toggle_readable_by_anon',
        'pass', false, 'detail', 'anon cannot call signup_otp_required()');
    ELSE
      v_tests := v_tests || jsonb_build_object('path', 'H_toggle_readable_by_anon',
        'pass', true,
        'detail', 'anon may read signup_otp_required (currently ' || v_gate_on || ')');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tests := v_tests || jsonb_build_object('path', 'H_toggle_readable_by_anon',
      'pass', false, 'detail', 'outer: ' || SQLERRM);
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

-- ===========================================================================
-- 5. Guard: the gate is still a gate, and still reversible
-- ===========================================================================
-- Source-level, because that is the only signal available without a
-- privileged client. It fails if the setting row disappears (which would
-- silently flip behaviour in either direction depending on a default
-- nobody read), if handle_new_user stops consulting the toggle — the state
-- where the owner believes the OTP is off and every signup is failing —
-- or if the anonymous reader is revoked and the app goes back to showing a
-- code screen that no email ever reaches.
CREATE OR REPLACE FUNCTION public.assert_signup_otp_toggle_is_consistent()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_src text;
  v_required boolean;
BEGIN
  SELECT (s.value #>> '{}')::boolean
    INTO v_required
    FROM public.system_settings s
   WHERE s.key = 'signup_otp_required';

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'OTP_TOGGLE_REGRESSION: the signup_otp_required setting is missing; signup_otp_required() falls back to TRUE and every new account needs an OTP that cannot be delivered';
  END IF;

  SELECT regexp_replace(lower(pg_get_functiondef(
           'public.handle_new_user()'::regprocedure)), '\s+', ' ', 'g')
    INTO v_src;

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'OTP_TOGGLE_REGRESSION: handle_new_user() is missing';
  END IF;

  -- The gate must consult the toggle. Without this clause the setting is
  -- decorative and the owner has no way to open registration.
  IF position('signup_otp_required' in v_src) = 0 THEN
    RAISE EXCEPTION
      'OTP_TOGGLE_REGRESSION: handle_new_user() does not read signup_otp_required, so the OTP gate cannot be switched off — registration stays broken while the email provider is unconfigured';
  END IF;

  -- ...and it must still refuse an unverified email signup when the toggle
  -- is on, or "temporary" became "permanent" without anyone noticing.
  IF position('otp_verified_recently' in v_src) = 0
     OR position('email_otp_required' in v_src) = 0 THEN
    RAISE EXCEPTION
      'OTP_TOGGLE_REGRESSION: handle_new_user() no longer refuses an unverified email signup; turning signup_otp_required back on would not restore the OTP gate';
  END IF;

  -- The app has to be able to ask, before it shows a code screen.
  IF NOT has_function_privilege('anon', 'public.signup_otp_required()', 'EXECUTE') THEN
    RAISE EXCEPTION
      'OTP_TOGGLE_REGRESSION: anon cannot call signup_otp_required(); the signup screen cannot tell whether to ask for a code';
  END IF;

  RETURN 'signup OTP toggle OK: setting = '
         || coalesce(v_required::text, 'null')
         || ', handle_new_user() reads it and still refuses unverified signups when it is on, and anon can read it';
END;
$$;

COMMENT ON FUNCTION public.assert_signup_otp_toggle_is_consistent() IS
  'True when the signup OTP gate is a working toggle: the setting exists, '
  'handle_new_user() reads it AND still refuses unverified signups, and an '
  'anonymous signup can ask which mode it is in.';

GRANT EXECUTE ON FUNCTION public.assert_signup_otp_toggle_is_consistent()
  TO anon, authenticated;

notify pgrst, 'reload schema';
