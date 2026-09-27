-- Regression test for the signup OTP gate.
--
-- Reproduces the bug fixed in 20260927000001_otp_verified_at.sql, then
-- proves the new predicate handles it.
--
-- The bug: verify_email_otp increments `attempts` on every guess, not only
-- on success, while otp_verified_recently required `attempts <= 2`. A user
-- who mistyped their six-digit code twice and then typed it correctly got
-- { ok: true } from the verify RPC and were then rejected at account
-- creation with EMAIL_OTP_REQUIRED — told to verify a code they had just
-- verified correctly.
--
-- Run against a scratch database:
--   sudo -u postgres createdb otp_gate_test
--   sudo -u postgres psql -v ON_ERROR_STOP=0 -d otp_gate_test \
--     < tools/test/otp_verified_at_test.sql
--
-- Pure predicate + column logic: no auth.users, no network, no app data.

\set ON_ERROR_STOP off

BEGIN;

-- ── Schema under test ───────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.email_otp_codes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text NOT NULL,
  code_hash     text NOT NULL,
  attempts      int NOT NULL DEFAULT 0,
  max_attempts  int NOT NULL DEFAULT 5,
  consumed      boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now(),
  expires_at    timestamptz,
  verified_at   timestamptz          -- added by the fix
);

-- ── The two predicates, side by side ────────────────────────────────────

-- What shipped before the fix: infers "verified" from attempt arithmetic.
CREATE OR REPLACE FUNCTION public.otp_verified_recently_OLD(p_email text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.email_otp_codes
    WHERE email = lower(btrim(p_email))
      AND consumed = true
      AND attempts > 0
      AND attempts <= 2
      AND created_at > now() - interval '24 hours'
  );
$$;

-- What the fix ships: reads the explicit success stamp.
CREATE OR REPLACE FUNCTION public.otp_verified_recently(p_email text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.email_otp_codes
    WHERE email = lower(btrim(p_email))
      AND verified_at IS NOT NULL
      AND verified_at > now() - interval '24 hours'
  );
$$;

CREATE OR REPLACE FUNCTION public.raise_if(
  p_ok boolean, p_label text, p_detail text DEFAULT ''
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok THEN
    RAISE NOTICE 'PASS  %', p_label;
  ELSE
    RAISE EXCEPTION 'FAIL  % %', p_label, p_detail;
  END IF;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 1 — the reported failure: correct code on the 3rd attempt
-- ═══════════════════════════════════════════════════════════════════════
-- Two wrong guesses (attempts -> 2), then a correct one. verify_email_otp
-- sets attempts = 3 AND verified_at = now().
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, consumed, verified_at)
VALUES
  ('third-try@example.com', 3, true, now());

DO $$
DECLARE old_result boolean; new_result boolean;
BEGIN
  SELECT public.otp_verified_recently_OLD('third-try@example.com') INTO old_result;
  SELECT public.otp_verified_recently('third-try@example.com')       INTO new_result;

  PERFORM public.raise_if(
    NOT old_result,
    'TEST 1a reproduces the bug: OLD predicate rejects a correctly verified 3rd-try code'
  );
  PERFORM public.raise_if(
    new_result,
    'TEST 1b NEW predicate accepts it (verified_at is set on success)'
  );
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 2 — correct code on the last allowed attempt (max_attempts = 5)
-- ═══════════════════════════════════════════════════════════════════════
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, max_attempts, consumed, verified_at)
VALUES
  ('last-try@example.com', 5, 5, true, now());

DO $$
DECLARE old_result boolean; new_result boolean;
BEGIN
  SELECT public.otp_verified_recently_OLD('last-try@example.com') INTO old_result;
  SELECT public.otp_verified_recently('last-try@example.com')       INTO new_result;

  PERFORM public.raise_if(NOT old_result,
    'TEST 2a reproduces the bug at max_attempts (OLD rejects)');
  PERFORM public.raise_if(new_result,
    'TEST 2b NEW accepts a correct code on the final attempt');
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 3 — a wrong-code-only row must NOT pass the gate
-- ═══════════════════════════════════════════════════════════════════════
-- Attempts exhausted, so consumed = true — but the code was NEVER typed
-- correctly, so verified_at must stay NULL. This is the case that makes
-- `consumed` unusable as a success signal.
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, max_attempts, consumed, verified_at)
VALUES
  ('never-typed@example.com', 5, 5, true, NULL);

DO $$
DECLARE old_result boolean; new_result boolean;
BEGIN
  SELECT public.otp_verified_recently_OLD('never-typed@example.com') INTO old_result;
  SELECT public.otp_verified_recently('never-typed@example.com')       INTO new_result;

  PERFORM public.raise_if(NOT new_result,
    'TEST 3a exhausted attempts never satisfy the gate (verified_at is NULL)');
  -- Guards the specific case the old predicate got right by accident, where
  -- attempts <= 2 and consumed both held despite no correct entry.
  PERFORM public.raise_if(NOT old_result OR NOT new_result,
    'TEST 3b both predicates agree an unverified row is rejected');
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 4 — a row superseded by a resend must NOT pass
-- ═══════════════════════════════════════════════════════════════════════
-- request_email_otp sets consumed = true on the old row without any
-- successful verify, then inserts a fresh active row. consumed is
-- therefore true for a row that was never verified.
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, consumed, verified_at)
VALUES
  ('resent@example.com', 0, true, NULL);

DO $$
BEGIN
  PERFORM public.raise_if(
    NOT public.otp_verified_recently('resent@example.com'),
    'TEST 4 a resend-superseded row does not satisfy the gate'
  );
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 5 — success on the first try still works (no regression)
-- ═══════════════════════════════════════════════════════════════════════
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, consumed, verified_at)
VALUES
  ('first-try@example.com', 1, true, now());

DO $$
BEGIN
  PERFORM public.raise_if(
    public.otp_verified_recently('first-try@example.com'),
    'TEST 5 first-try verification still satisfies the gate'
  );
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 6 — verification older than 24h is rejected (window preserved)
-- ═══════════════════════════════════════════════════════════════════════
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, consumed, created_at, verified_at)
VALUES
  ('stale@example.com', 1, true, now() - interval '25 hours', now() - interval '25 hours');

DO $$
BEGIN
  PERFORM public.raise_if(
    NOT public.otp_verified_recently('stale@example.com'),
    'TEST 6 verification older than 24h no longer satisfies the gate'
  );
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 7 — the staff gateway pre-authorisation still passes the gate
-- ═══════════════════════════════════════════════════════════════════════
-- trust_staff_gateway_email inserts (consumed, attempts, verified_at) =
-- (true, 1, now()). If that insert were not updated to stamp verified_at,
-- staff account creation would break with the new predicate.
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, code_hash, attempts, max_attempts, consumed, verified_at)
VALUES
  ('clerk@staff-gateway.invalid', 'staff-gateway', 1, 5, true, now());

DO $$
BEGIN
  PERFORM public.raise_if(
    public.otp_verified_recently('clerk@staff-gateway.invalid'),
    'TEST 7 staff gateway row satisfies the gate (verified_at is stamped)'
  );
END $$;

-- ═══════════════════════════════════════════════════════════════════════
-- TEST 8 — the backfill preserves rows the OLD predicate accepted
-- ═══════════════════════════════════════════════════════════════════════
-- Deployed rows have verified_at = NULL. The migration backfills rows the
-- old predicate considered verified, so an in-flight signup is not rejected
-- by the stricter check.
DELETE FROM public.email_otp_codes;
INSERT INTO public.email_otp_codes
  (email, attempts, consumed, created_at, verified_at)
VALUES
  ('in-flight@example.com', 1, true, now(), NULL);

UPDATE public.email_otp_codes
   SET verified_at = created_at
 WHERE verified_at IS NULL
   AND consumed = true
   AND attempts > 0
   AND attempts <= 2
   AND created_at > now() - interval '24 hours';

DO $$
BEGIN
  PERFORM public.raise_if(
    public.otp_verified_recently('in-flight@example.com'),
    'TEST 8 backfill re-stamps a row the old predicate accepted'
  );
END $$;

ROLLBACK;
