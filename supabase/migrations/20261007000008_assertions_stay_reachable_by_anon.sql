-- =============================================================================
-- 20261007000008_assertions_stay_reachable_by_anon.sql
-- =============================================================================
--
-- WHY THIS FILE EXISTS
--
-- The connectivity suite runs as the `anon` role: SupabaseClient is built from
-- the anon key with no session, and every check in
-- tools/integration_test/connectivity_test.dart calls an assertion RPC by name.
-- Migration 20260927000091 (already deployed) turns that into a single,
-- whole-family guard: assert_every_assertion_is_reachable() walks every
-- zero-argument `assert_*` function in `public` and RETURNS A FAIL STRING if
-- any of them is not executable by anon — because PostgREST reports such a
-- function as PGRST202 "could not find the function ... in the schema cache",
-- which reads like a missing migration instead of a missing privilege.
--
-- Four assertion functions added by this batch were written with
--   REVOKE ALL ON FUNCTION <f>() FROM public, anon;
--   GRANT EXECUTE ON FUNCTION <f>() TO authenticated, service_role;
-- (i.e. exactly the mistake 20260927000091 was written to catch):
--
--   20261007000002  assert_provider_payment_methods_phone_guard
--   20261007000005  assert_charge_paths_use_the_shared_fee_resolvers
--   20261007000006  assert_app_version_gate_is_wired
--   20261007000007  assert_error_logs_carry_a_reference
--
-- So after a clean deploy the suite would have gone green on those twelve
-- pending assertions and then failed on
-- `assert_every_assertion_is_reachable` — the one test whose whole job is to
-- say "an assertion you added can never run". This migration closes that gap.
-- The grant statements live here (not in the four files) because a missing
-- GRANT is runtime state and any later migration can repair it; it is the one
-- part of this batch's cleanup that does not have to be edited in place.
--
-- SAFETY: each target is a read-only STABLE/SECURITY DEFINER assertion that
-- measures database posture and returns text or boolean. Making them callable
-- by anon (the role the suite uses) is the contract the other 111 zero-argument
-- assertions already meet. Nothing here widens a write path.
--
-- Idempotent: GRANT is a no-op if the privilege is already held, and the guard
-- at the end only reads the catalog.

GRANT EXECUTE ON FUNCTION public.assert_provider_payment_methods_phone_guard()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_charge_paths_use_the_shared_fee_resolvers()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_app_version_gate_is_wired()
  TO anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.assert_error_logs_carry_a_reference()
  TO anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- The same check assert_every_assertion_is_reachable() runs, run here at deploy
-- time so an unreachable assertion fails the deploy that introduced it rather
-- than the connectivity run that follows it. Mirrors that function exactly:
-- zero-argument `assert_*` in the public schema, `has_function_privilege` for
-- anon on the no-argument signature.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_name text;
  v_missing text := '';
  v_count integer := 0;
BEGIN
  FOR v_name IN
    SELECT p.proname
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname LIKE 'assert\_%'
       AND p.pronargs = 0
     ORDER BY p.proname
  LOOP
    v_count := v_count + 1;
    IF NOT has_function_privilege('anon',
         format('public.%I()', v_name), 'EXECUTE') THEN
      v_missing := v_missing || v_name || ', ';
    END IF;
  END LOOP;

  IF v_count = 0 THEN
    RAISE EXCEPTION
      'ASSERTION_FAMILY_EMPTY: no zero-argument assert_* function exists, so '
      'the connectivity suite has nothing to run and the grants above prove '
      'nothing';
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'ASSERTION_NOT_REACHABLE_BY_ANON: the connectivity suite runs as anon, '
      'but these assertion functions are not executable by it: %. A function '
      'hidden from anon is reported by PostgREST as PGRST202 "could not find '
      'the function in the schema cache" — it reads like a missing migration '
      'and is not. GRANT EXECUTE ... TO anon, authenticated, service_role.',
      rtrim(v_missing, ', ');
  END IF;

  RAISE NOTICE 'all % zero-argument assert_* functions are executable by anon',
    v_count;
END
$$;

NOTIFY pgrst, 'reload schema';
