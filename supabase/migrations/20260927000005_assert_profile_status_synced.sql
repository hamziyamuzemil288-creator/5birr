-- Assert that no account is gated by a status the provider table disagrees
-- with.
--
-- The asymmetry this guards: suspend_provider() set BOTH provider_profiles
-- and profiles to SUSPENDED, while unsuspend_provider() restored only
-- provider_profiles. profiles.status was therefore left SUSPENDED forever,
-- and since the app router gates on profiles.status, that account was locked
-- out of its own app permanently while the admin panel showed APPROVED.
--
-- trg_sync_profile_status (20260927000004) closes it by mirroring the
-- transition. This asserts the invariant actually holds in the live data, so
-- a future change that suspends or unsuspends by another route and forgets
-- to keep both columns in step fails CI instead of quietly locking a user
-- out.
--
-- Read-only: reads two tables and counts mismatches. Returns the count, so
-- a failure names how many accounts are affected rather than just that one
-- is.

CREATE OR REPLACE FUNCTION public.count_status_mismatches()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT count(*)::integer
  FROM public.provider_profiles pp
  JOIN public.profiles p ON p.id = pp.user_id
   WHERE
     -- provider suspended, account still believes it is active
     (pp.status = 'SUSPENDED' AND p.status = 'APPROVED')
     -- or the reverse: unsuspend only half-landed
     OR (pp.status = 'APPROVED' AND p.status = 'SUSPENDED');
$$;

COMMENT ON FUNCTION public.count_status_mismatches() IS
  'Number of accounts whose profiles.status disagrees with '
  'provider_profiles.status about suspension. Must be 0.';

CREATE OR REPLACE FUNCTION public.assert_profile_status_synced()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.count_status_mismatches() = 0;
$$;

COMMENT ON FUNCTION public.assert_profile_status_synced() IS
  'True when no account is gated by a stale suspension status.';

-- Count only. The join is on status, never on identity columns, so the
-- result cannot reveal who an account belongs to.
GRANT EXECUTE ON FUNCTION public.count_status_mismatches() TO authenticated;
GRANT EXECUTE ON FUNCTION public.assert_profile_status_synced() TO authenticated;
