-- Guard the signup OTP gate against regression.
--
-- 20260927000001_otp_verified_at.sql replaced the `attempts <= 2` arithmetic
-- in otp_verified_recently with an explicit `verified_at` stamp, because
-- `attempts` counts guesses rather than successes: a user who mistyped their
-- six-digit code twice and then typed it correctly was told { ok: true } by
-- verify_email_otp and then rejected at account creation with
-- EMAIL_OTP_REQUIRED.
--
-- This asserts the SHAPE of the deployed function rather than its behaviour.
-- A true behavioural test would have to insert OTP rows and call the gate,
-- which the connectivity suite deliberately does not do — it is read-only.
-- This is the same technique assert_ride_transition_covers_chain uses, which
-- reads pg_proc.prosrc rather than executing the state machine.
--
-- What this catches: someone re-deriving the predicate from `attempts`, or a
-- migration restoring the old arithmetic, which would silently reinstate a
-- signup-blocking bug with no test failure anywhere.
--
-- What this does NOT catch: verify_email_otp forgetting to stamp verified_at
-- on its success branch. That is covered behaviourally by
-- tools/test/otp_verified_at_test.sql, which needs a local Postgres and is
-- not run in CI.

CREATE OR REPLACE FUNCTION public.assert_otp_gate_uses_verified_at()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  SELECT pg_get_functiondef('public.otp_verified_recently(text)'::regprocedure)
    INTO v_src;

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  -- Must key off the explicit success stamp...
  IF v_src NOT LIKE '%verified_at%' THEN
    RETURN false;
  END IF;

  -- ...and must no longer do arithmetic on `attempts`, which is the exact
  -- defect this replaced.
  --
  -- Match the COMPARISON, not the bare word. pg_get_functiondef returns the
  -- body verbatim, comments included, and this function's own comment says
  -- "...burned through its attempts, is not" — a bare \battempts\b test would
  -- match that prose and fail spuriously. `max_attempts` likewise belongs to
  -- verify_email_otp's attempt limit and is allowed to appear.
  IF v_src ~* '\battempts\s*(<|>|<=|>=|=|\+)' THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_otp_gate_uses_verified_at() IS
  'True when otp_verified_recently keys off verified_at and no longer infers '
  'success from `attempts`. Structural guard, not behavioural.';

GRANT EXECUTE ON FUNCTION public.assert_otp_gate_uses_verified_at() TO authenticated;
