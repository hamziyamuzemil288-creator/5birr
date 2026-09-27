-- Assert that trg_sync_profile_status still takes a vehicle out of service on
-- suspension and puts it back on reactivation.
--
-- The bug this guards: suspension is a three-part operation, and the
-- reactivation path only undid two of the three. suspend_provider() clears
-- vehicles.is_available; the revenue-driven restore (20260927000006) set
-- provider_profiles and profiles back to APPROVED but left the vehicle
-- flagged unavailable. claim_ride() rejects a vehicle that is not
-- available and find_nearby_drivers() filters them out, so a fully
-- approved, unsuspended, fully paid provider simply never appears in search
-- and can never take a ride — with the app showing them as APPROVED
-- throughout, so there is nothing on screen to explain it.
--
-- 20260927000007 adds the vehicle handling to the trigger. This asserts the
-- live function still has both halves, so a future redefinition of
-- sync_profile_status_from_provider() that keeps the profile-status mirror
-- but drops the vehicle update fails CI instead of re-stranding drivers.
--
-- The test is on the FUNCTION SOURCE, not the data, and deliberately not on
-- a data invariant: "an APPROVED provider's vehicle must be available" is
-- false by design, because a provider may switch their own vehicle off to
-- stop working. There is no way to tell that case apart from a stranded one
-- by looking at rows, so the only thing worth asserting is that the code
-- which disambiguates them is still there.

CREATE OR REPLACE FUNCTION public.assert_vehicle_sync_handled()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'sync_profile_status_from_provider';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  -- Both directions must be present, and each must be scoped to the
  -- provider's own vehicles. Matching on the assignment and the guard
  -- together avoids a bare "is_available" hit in prose passing as coverage.
  RETURN
    -- suspension: clear availability, only for vehicles that are APPROVED
    v_src ~* 'is_available\s*=\s*false'
    AND v_src ~* 'status\s*=\s*''APPROVED'''
    AND
    -- reactivation: restore availability, likewise scoped
    v_src ~* 'is_available\s*=\s*true'
    AND v_src ~* 'NEW\.status\s*=\s*''APPROVED'''
    AND v_src ~* 'OLD\.status\s+IS\s+DISTINCT\s+FROM\s+''APPROVED''';
END;
$$;

COMMENT ON FUNCTION public.assert_vehicle_sync_handled() IS
  'True when sync_profile_status_from_provider() still returns vehicles to '
  'service on reactivation, not just the account.';

GRANT EXECUTE ON FUNCTION public.assert_vehicle_sync_handled() TO authenticated;
