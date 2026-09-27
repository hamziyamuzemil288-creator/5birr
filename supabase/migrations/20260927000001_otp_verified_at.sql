-- Fix the signup OTP gate rejecting a correctly-verified code.
--
-- The bug
-- -------
-- `verify_email_otp` increments `attempts` on EVERY try, not only successful
-- ones:
--
--   wrong code  -> set attempts = attempts + 1, consumed = (attempts+1 >= max_attempts)
--   right code  -> set consumed = true, attempts = attempts + 1
--
-- but `otp_verified_recently`, which `handle_new_user()` uses to decide
-- whether to let a signup through, required:
--
--   and attempts > 0
--   and attempts <= 2        -- 1 = verified, 2 = verified then row touched again
--
-- `max_attempts` defaults to 5, so a user who mistypes their six-digit code
-- once and then types it correctly lands on attempts = 2 and passes — but a
-- user who needs a third try reaches attempts = 3 and fails the gate.
--
-- The failure is silent and confusing: `verify_email_otp` returns
-- { ok: true }, the app navigates on believing the address is verified, and
-- the very next statement (creating the auth user) is rejected with
-- EMAIL_OTP_REQUIRED. The user is told to verify a code they just verified
-- correctly. That sits on the primary signup path.
--
-- The inline comment shows the intent: attempts was being read as a proxy
-- for "was this row successfully verified". It is not — it counts guesses.
--
-- The fix
-- -------
-- Record success explicitly in a `verified_at` column set only by the
-- success branch, and have the gate read that instead of doing arithmetic on
-- `attempts`. `consumed` cannot be used for this: it is also set when a row
-- is superseded by a resend, and when attempts are exhausted, neither of
-- which means the address was ever verified.
--
-- `trust_staff_gateway_email` pre-authorises a row to let staff accounts
-- through the same gate, so it is updated to stamp `verified_at` too —
-- otherwise staff gateway creation would start failing.
--
-- The backfill re-stamps rows that the OLD predicate considered verified, so
-- anyone mid-signup when this deploys is not rejected by the stricter,
-- newly-column-based check.

-- ── Column ──────────────────────────────────────────────────────────────
ALTER TABLE public.email_otp_codes
  ADD COLUMN IF NOT EXISTS verified_at timestamptz;

COMMENT ON COLUMN public.email_otp_codes.verified_at IS
  'Set only by a successful verify_email_otp call. Distinguishes "the user '
  'entered the right code" from "the row was consumed by a resend or by '
  'exhausted attempts", which consumed alone cannot express.';

-- ── Backfill rows the previous predicate already accepted ───────────────
-- consumed AND 1 <= attempts <= 2 is exactly what otp_verified_recently
-- used to require, so this preserves in-flight signups across the deploy.
UPDATE public.email_otp_codes
   SET verified_at = created_at
 WHERE verified_at IS NULL
   AND consumed = true
   AND attempts > 0
   AND attempts <= 2
   AND created_at > now() - interval '24 hours';

-- ── Staff gateway still needs to satisfy the gate ───────────────────────
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
  --
  -- coalesce matters: a NULL p_email would make the LIKE evaluate to NULL,
  -- and `IF NULL` is false, so without it a null argument would skip the
  -- check entirely and fall through to the insert.
  IF v_email NOT LIKE '%@staff-gateway.invalid' THEN
    RAISE EXCEPTION 'STAFF_TRUST_DOMAIN_NOT_ALLOWED: %', p_email;
  END IF;

  -- One live row per email; drop any earlier authorization for this address.
  DELETE FROM public.email_otp_codes WHERE email = v_email;

  INSERT INTO public.email_otp_codes
    (email, code_hash, created_at, expires_at, consumed, attempts, max_attempts, verified_at)
  VALUES
    (v_email, 'staff-gateway', now(), now() + interval '10 minutes', true, 1, 5, now());

  RETURN true;
END;
$$;

-- ── The gate: read verified_at, not attempt arithmetic ───────────────────
CREATE OR REPLACE FUNCTION public.otp_verified_recently(p_email text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  -- "Was this address successfully verified recently", and nothing else.
  -- A correct code on the fifth attempt is verified; a row that was merely
  -- superseded by a resend, or burned through its attempts, is not.
  SELECT EXISTS (
    SELECT 1 FROM public.email_otp_codes
    WHERE email = lower(btrim(p_email))
      AND verified_at IS NOT NULL
      AND verified_at > now() - interval '24 hours'
  );
$$;

-- ── verify_email_otp: stamp success on the success branch only ──────────
-- Re-emitted in full because CREATE OR REPLACE swaps the whole body. The
-- only behavioural change is verified_at on the success path; the
-- wrong-code path deliberately leaves it NULL.
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

-- Grants are unchanged from the original definitions; re-stated so this
-- migration is self-contained if applied to a database where they drifted.
REVOKE ALL ON FUNCTION public.verify_email_otp(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_email_otp(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_email_otp(text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.request_email_otp(text, text) TO service_role;
REVOKE ALL ON FUNCTION public.trust_staff_gateway_email(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.trust_staff_gateway_email(text) TO service_role;
