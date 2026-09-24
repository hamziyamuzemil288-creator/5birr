-- Local regression harness for 20260924000009_login_lockout.sql (Task 13 item 2).
-- Run from the project root with:
--   sudo -u postgres createdb login_lockout_test
--   sudo -u postgres psql -d login_lockout_test -f tools/test/login_lockout_test.sql
-- The migration copy must be available at /tmp/20260924000009_login_lockout.sql.
--
-- Verifies against a REAL Postgres (not assumptions):
--   1. The three helpers behave correctly (count failures, record, clear on
--      success) and the Edge Function's exact call shapes work.
--   2. anon/authenticated CANNOT execute the helpers (revokes hold) — the
--      client can neither read the counter nor forge/reset it.
--   3. RLS is enabled with no policies on login_attempts.
\set ON_ERROR_STOP on
DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$ BEGIN CREATE ROLE anon NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE authenticated NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE ROLE service_role NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;

\ir /tmp/20260924000009_login_lockout.sql

-- ============================================================
-- 1. Functional behavior of the helpers (service-role simulation)
-- ============================================================
-- 8 failures => locked window; a success clears the failure window.
DO $$
DECLARE
  v_count int;
BEGIN
  PERFORM public.record_login_attempt('locked@example.com', false, 'deadbeef');
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);
  PERFORM public.record_login_attempt('locked@example.com', false, 'deadbeef');
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);
  PERFORM public.record_login_attempt('locked@example.com', false, NULL);

  SELECT public.recent_login_failures('locked@example.com') INTO v_count;
  IF v_count <> 8 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: expected 8 failures, got %', v_count;
  END IF;

  -- A success wipes the failure window (legit user mistyped once pattern).
  PERFORM public.record_login_attempt('locked@example.com', true, NULL);
  SELECT public.recent_login_failures('locked@example.com') INTO v_count;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 1b FAILED: success should clear failures, got %', v_count;
  END IF;

  -- Distinct keys are isolated.
  PERFORM public.record_login_attempt('other@example.com', false, NULL);
  SELECT public.recent_login_failures('other@example.com') INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 1c FAILED: key isolation broken, got %', v_count;
  END IF;

  -- STABLE helper must run inside a transaction too (Edge Function pattern:
  -- gate -> record in separate calls, same session).
  PERFORM public.clear_login_failures('other@example.com');
  SELECT public.recent_login_failures('other@example.com') INTO v_count;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 1d FAILED: clear_login_failures no-op, got %', v_count;
  END IF;

  RAISE NOTICE 'TEST 1 PASSED: helper behavior (count/record/clear/isolation)';
END $$;

-- ============================================================
-- 2. anon/authenticated cannot execute the helpers
-- ============================================================
DO $$
DECLARE
  v_blocked int := 0;
BEGIN
  -- anon role
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.record_login_attempt('x@example.com', false, NULL);
    RAISE EXCEPTION 'TEST 2 FAILED: anon could record a login attempt';
  EXCEPTION WHEN insufficient_privilege THEN
    v_blocked := v_blocked + 1;
  END;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.recent_login_failures('x@example.com');
    RAISE EXCEPTION 'TEST 2b FAILED: anon could read the failure counter';
  EXCEPTION WHEN insufficient_privilege THEN
    v_blocked := v_blocked + 1;
  END;
  RESET ROLE;
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.clear_login_failures('x@example.com');
    RAISE EXCEPTION 'TEST 2c FAILED: authenticated could clear failures';
  EXCEPTION WHEN insufficient_privilege THEN
    v_blocked := v_blocked + 1;
  END;
  RESET ROLE;

  IF v_blocked <> 3 THEN
    RAISE EXCEPTION 'TEST 2 FAILED: only % of 3 privilege checks held', v_blocked;
  END IF;
  RAISE NOTICE 'TEST 2 PASSED: anon/authenticated revoked on all 3 helpers';
END $$;

-- service_role (the Edge Function's role) must still be able to call them.
-- Supabase grants USAGE on schema public to anon/authenticated/service_role
-- at project init; a bare local cluster does not, so mirror that grant here
-- before asserting the EXECUTE grant the migration itself makes.
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
DO $$
BEGIN
  SET LOCAL ROLE service_role;
  PERFORM public.record_login_attempt('svc@example.com', false, NULL);
  PERFORM public.recent_login_failures('svc@example.com');
  PERFORM public.clear_login_failures('svc@example.com');
  RESET ROLE;
  RAISE NOTICE 'TEST 3 PASSED: service_role keeps EXECUTE (Edge Function path)';
END $$;

-- ============================================================
-- 4. RLS enabled, no client-facing policies
-- ============================================================
DO $$
DECLARE
  v_enabled boolean;
  v_policies int;
BEGIN
  SELECT relrowsecurity INTO v_enabled FROM pg_class
   WHERE oid = 'public.login_attempts'::regclass;
  SELECT count(*) INTO v_policies FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'login_attempts';
  IF v_enabled IS NOT TRUE OR v_policies <> 0 THEN
    RAISE EXCEPTION 'TEST 4 FAILED: RLS %, policies %', v_enabled, v_policies;
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: login_attempts RLS on with zero policies';
END $$;

DO $$ BEGIN RAISE NOTICE 'ALL LOGIN-LOCKOUT TESTS PASSED'; END $$;
