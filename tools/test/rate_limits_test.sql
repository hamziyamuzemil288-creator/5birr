-- Test harness for 0049 (check_rate_limit / rate_limits).
--
-- Run as the service role or via `supabase test db`. The assertions here are
-- the ones that would have caught the two real defects in the 0024 proposal:
-- the moving-window arithmetic, and the absence of any default-deny posture.
--
-- The RLS assertions deliberately run as `anon`/`authenticated` by switching
-- role inside a transaction, which is how PostgREST evaluates a client call.

BEGIN;

-- ── 1. Schema and posture ────────────────────────────────────────────────────
DO $$
DECLARE
  v_rls boolean;
BEGIN
  SELECT relrowsecurity INTO v_rls
    FROM pg_class WHERE oid = 'public.rate_limits'::regclass;
  IF v_rls IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: rate_limits must have RLS enabled';
  END IF;
  RAISE NOTICE 'PASS: RLS enabled';

  IF EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'rate_limits'
  ) THEN
    RAISE EXCEPTION 'FAIL: rate_limits must have NO policies (default-deny)';
  END IF;
  RAISE NOTICE 'PASS: no policies (default-deny)';
END $$;

-- ── 2. Clients must not be able to touch the table directly ────────────────
DO $$
DECLARE
  v_user uuid := '11111111-1111-1111-1111-111111111111';
  v_err  text;
BEGIN
  BEGIN
    SET LOCAL ROLE anon;
    SELECT count(*) INTO STRICT v_err FROM public.rate_limits;
    RAISE EXCEPTION 'FAIL: anon SELECT on rate_limits should be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: anon SELECT denied';
  END;
  RESET ROLE;
END $$;

DO $$
DECLARE
  v_err text;
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    INSERT INTO public.rate_limits (user_id, endpoint, window_start)
    VALUES (gen_random_uuid(), 'forged', now());
    RAISE EXCEPTION 'FAIL: authenticated INSERT on rate_limits should be denied';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: authenticated INSERT denied';
  END;
  RESET ROLE;
END $$;

-- ── 3. authenticated must not be able to call check_rate_limit ──────────────
-- The user_id parameter is caller-supplied, so this grant would let any
-- signed-up user burn someone else's budget.
DO $$
BEGIN
  BEGIN
    SET LOCAL ROLE authenticated;
    PERFORM public.check_rate_limit(
      '11111111-1111-1111-1111-111111111111'::uuid, 'forged-endpoint');
    RAISE EXCEPTION 'FAIL: authenticated must not be able to execute check_rate_limit';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS: authenticated EXECUTE denied';
  END;
  RESET ROLE;
END $$;

-- ── 4. Fixed-window counting (service role path) ────────────────────────────
DO $$
DECLARE
  v_user uuid := '22222222-2222-2222-2222-222222222222';
  v_ok   boolean;
BEGIN
  -- 3 allowed in a 60s window, 4th refused.
  FOR i IN 1..3 LOOP
    v_ok := public.check_rate_limit(v_user, 'test-endpoint', 3, 60);
    IF v_ok IS NOT TRUE THEN
      RAISE EXCEPTION 'FAIL: call % should have been allowed', i;
    END IF;
  END LOOP;

  v_ok := public.check_rate_limit(v_user, 'test-endpoint', 3, 60);
  IF v_ok IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL: 4th call should exceed the budget of 3';
  END IF;
  RAISE NOTICE 'PASS: fixed window allows exactly p_max_requests';
END $$;

-- ── 5. Endpoints and users are independent budgets ──────────────────────────
DO $$
DECLARE
  v_a uuid := '33333333-3333-3333-3333-333333333331';
  v_b uuid := '33333333-3333-3333-3333-333333333332';
BEGIN
  IF public.check_rate_limit(v_a, 'endpoint-one', 1, 60) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: first call for endpoint-one should pass';
  END IF;
  IF public.check_rate_limit(v_a, 'endpoint-two', 1, 60) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: endpoint-two has its own budget and should pass';
  END IF;
  IF public.check_rate_limit(v_b, 'endpoint-one', 1, 60) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: user B has its own budget and should pass';
  END IF;
  RAISE NOTICE 'PASS: budgets are per-user and per-endpoint';
END $$;

-- ── 6. Malformed input refuses rather than failing open ─────────────────────
DO $$
DECLARE
  v_user uuid := '44444444-4444-4444-4444-444444444444';
BEGIN
  IF public.check_rate_limit(NULL, 'x', 5, 60) IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL: NULL user must be refused';
  END IF;
  IF public.check_rate_limit(v_user, '', 5, 60) IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL: empty endpoint must be refused';
  END IF;
  RAISE NOTICE 'PASS: malformed input refused';
END $$;

-- ── 7. Defaults apply for nonsensical budgets ───────────────────────────────
DO $$
DECLARE
  v_user uuid := '55555555-5555-5555-5555-555555555555';
BEGIN
  -- max_requests of 0 would divide the budget to nothing; the function must
  -- substitute its documented default rather than lock the user out or
  -- divide by zero.
  IF public.check_rate_limit(v_user, 'defaulted', 0, 0) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL: non-positive args should fall back to defaults';
  END IF;
  RAISE NOTICE 'PASS: defaults applied for non-positive arguments';
END $$;

-- ── 8. Cleanup helper actually prunes ───────────────────────────────────────
DO $$
DECLARE
  v_user uuid := '66666666-6666-6666-6666-666666666666';
  v_gone integer;
BEGIN
  INSERT INTO public.rate_limits (user_id, endpoint, window_start, request_count)
  VALUES (v_user, 'stale-endpoint', now() - interval '30 days', 5);
  v_gone := public.purge_expired_rate_limits();
  IF v_gone < 1 THEN
    RAISE EXCEPTION 'FAIL: purge_expired_rate_limits deleted % rows, expected >= 1', v_gone;
  END IF;
  IF EXISTS (SELECT 1 FROM public.rate_limits WHERE user_id = v_user) THEN
    RAISE EXCEPTION 'FAIL: stale row survived the purge';
  END IF;
  RAISE NOTICE 'PASS: expired windows pruned';
END $$;

ROLLBACK;
