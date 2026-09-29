-- 20260927000084_otp_bypass_is_a_toggle.sql
--
-- Let a signup pass the code screen while email verification is switched off.
--
-- THE SITUATION
-- -------------
-- Migration 82 opened registration: with `signup_otp_required = false`,
-- handle_new_user() no longer demands a verified email, so the ACCOUNT is
-- created and lands in PENDING_APPROVAL for an administrator. Admin approval
-- is the gate; identity is checked later, in-app, at the document step.
--
-- But the app installed on a phone still pushes /otp-verify before it calls
-- signUp(). That screen can only proceed once verify_email_otp() returns ok,
-- and there is no code to enter because no email provider is configured. So
-- the server is open and the client is still standing in the doorway. The
-- client half of the fix is written (the signup screen asks
-- signup_otp_required() whether to show the screen at all) but shipping it
-- needs a build.
--
-- This migration makes the door passable from the server side too, so
-- registration works with the build that is already in circulation.
--
-- WHAT IT DOES NOT DO — the part that matters
-- -------------------------------------------
-- It does NOT stamp verified_at. That is the whole safety property.
--
-- otp_verified_recently() reads verified_at, and handle_new_user() reads
-- otp_verified_recently() when the toggle is on. So an address that skipped
-- the code during this window carries no verification forward: the moment an
-- owner sets signup_otp_required back to true, that address must produce a
-- real code again like anyone else. If this function stamped verified_at,
-- switching the OTP back on would silently exempt every account created
-- during the bypass window — a "temporary" change that quietly outlives
-- itself, which is the failure mode that produced this situation in the
-- first place.
--
-- While the toggle is off, granting nothing here is the correct behaviour:
-- the account is created with or without this response.
--
-- SCOPE
-- -----
-- * Gated on the same setting as the rest of the flow. Toggle on and this
--   branch is unreachable; the original wrong-code and expiry logic runs
--   untouched.
-- * The bypassed row is consumed and relabelled so an administrator reading
--   email_otp_codes can see that this address was NOT verified rather than
--   seeing a silent absence.
-- * assert_otp_bypass_is_scoped() fails if verified_at is ever assigned on
--   this path, so the safety property is enforced rather than documented.
--
-- Idempotent.

CREATE OR REPLACE FUNCTION public.verify_email_otp(p_email text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text := lower(btrim(p_email));
  v_row public.email_otp_codes%rowtype;
  v_hash text;
BEGIN
  -- ── Email verification is switched off (migration 82) ──────────────────
  -- Complete the step so the flow can continue, WITHOUT recording a
  -- verification. `verified_at` is deliberately left NULL: see the header.
  IF NOT public.signup_otp_required() THEN
    UPDATE public.email_otp_codes
       SET consumed = true,
           -- A visible marker beats a silent gap: an administrator looking at
           -- this address sees it was bypassed, not that nothing happened.
           code_hash = 'bypassed:email_verification_disabled'
     WHERE email = v_email AND consumed = false;

    RETURN jsonb_build_object(
      'ok', true,
      'bypassed', true,
      'reason', 'email verification is disabled; identity is verified at the '
                'document step instead'
    );
  END IF;

  -- ── Original behaviour, unchanged below this line ─────────────────────
  UPDATE public.email_otp_codes
     SET consumed = true
   WHERE email = v_email AND consumed = false AND expires_at < now();

  SELECT * INTO v_row
    FROM public.email_otp_codes
   WHERE email = v_email AND consumed = false
   ORDER BY created_at DESC
   LIMIT 1;

  IF v_row.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NO_ACTIVE_CODE');
  END IF;

  v_hash := public.sha256_hex(btrim(p_code));

  IF v_row.code_hash <> v_hash THEN
    -- Wrong guess. Burn an attempt; verified_at stays NULL so a code that is
    -- never typed correctly can never satisfy the signup gate.
    UPDATE public.email_otp_codes
       SET attempts = attempts + 1,
           consumed = (attempts + 1 >= max_attempts)
     WHERE id = v_row.id;
    IF (v_row.attempts + 1 >= v_row.max_attempts) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'TOO_MANY_ATTEMPTS');
    END IF;
    RETURN jsonb_build_object('ok', false, 'error', 'WRONG_CODE');
  END IF;

  -- Correct code, on any attempt. This is the only path that stamps
  -- verified_at, which is what makes attempts arithmetic unnecessary.
  UPDATE public.email_otp_codes
     SET consumed = true, attempts = attempts + 1, verified_at = now()
   WHERE id = v_row.id;

  RETURN jsonb_build_object('ok', true);
END;
$$;

COMMENT ON FUNCTION public.verify_email_otp(text, text) IS
  'Verifies an emailed OTP. While signup_otp_required is false the call '
  'completes without a code and WITHOUT stamping verified_at, so switching '
  'the OTP back on restores the gate for every address. That single '
  'property is asserted by assert_otp_bypass_is_scoped().';

REVOKE ALL ON FUNCTION public.verify_email_otp(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_email_otp(text, text) TO anon, authenticated;

-- ===========================================================================
-- The guard on the guard
-- ===========================================================================
-- The bypass is only safe because it stamps nothing. That is invisible in
-- review — the function looks correct whether or not someone later adds
-- `verified_at = now()` to the bypass branch, and the consequence is not a
-- crash but a security property quietly disappearing. So it is asserted.
CREATE OR REPLACE FUNCTION public.assert_otp_bypass_is_scoped()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_src text;
  v_stamps int;
BEGIN
  SELECT regexp_replace(lower(pg_get_functiondef(
           'public.verify_email_otp(text, text)'::regprocedure)), '\s+', ' ', 'g')
    INTO v_src;

  IF v_src IS NULL THEN
    RAISE EXCEPTION
      'OTP_BYPASS_UNSCOPED: verify_email_otp() is missing, so the bypass and the real check cannot both be reviewed';
  END IF;

  -- The bypass must exist and must be tied to the toggle. A build still in
  -- circulation that cannot complete the code step is a registration
  -- dead-end; an ungated one is the security problem.
  IF position('signup_otp_required' in v_src) = 0 THEN
    RAISE EXCEPTION
      'OTP_BYPASS_UNSCOPED: verify_email_otp() no longer consults signup_otp_required, so it can no longer tell a switched-off gate from a real verification';
  END IF;

  -- THE invariant. Exactly one place in the body may stamp verified_at: the
  -- correct-code branch. A second assignment means the bypass started
  -- recording verifications, and every address that skipped the code would
  -- be exempt from the OTP gate for 24 hours after the OTP is switched back
  -- on. That is the failure this whole design exists to prevent.
  v_stamps := (
    SELECT count(*)
      FROM regexp_matches(v_src, 'verified_at\s*=\s*now\(\)', 'g')
  );

  IF v_stamps > 1 THEN
    RAISE EXCEPTION
      'OTP_BYPASS_UNSCOPED: verify_email_otp() stamps verified_at in % places; only the correct-code branch may. The bypass must record nothing, or addresses that skipped the code stay exempt from the OTP gate after it is switched back on',
      v_stamps;
  END IF;

  IF v_stamps = 0 THEN
    RAISE EXCEPTION
      'OTP_BYPASS_UNSCOPED: verify_email_otp() never stamps verified_at, so switching signup_otp_required back on would not restore the OTP gate at all';
  END IF;

  RETURN 'OTP bypass scoped OK: gated on signup_otp_required, and verified_at '
         'is stamped in exactly ' || v_stamps || ' place (the correct-code branch only)';
END;
$$;

COMMENT ON FUNCTION public.assert_otp_bypass_is_scoped() IS
  'True when verify_email_otp() can complete a bypassed signup WITHOUT '
  'recording a verification — so re-enabling the OTP gate restores it for '
  'every address.';

GRANT EXECUTE ON FUNCTION public.assert_otp_bypass_is_scoped() TO anon, authenticated;

notify pgrst, 'reload schema';
