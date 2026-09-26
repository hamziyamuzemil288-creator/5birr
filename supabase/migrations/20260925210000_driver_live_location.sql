-- 20260925210000_driver_live_location.sql
--
-- Symptom: on the rider's "Active Ride" screen the driver pin never appears
-- and never moves — the rider cannot track the current location, even though
-- the driver's device pushes GPS on every fix.
--
-- Root cause (three compounding gaps, all on the driver->rider path):
--   1. `driver_status.current_ride_id` was NEVER written. Neither
--      `claim_ride` nor `transition_ride_status` nor any trigger set it, so
--      the rider's embed `driver_status!current_ride_id(...)` always matched
--      zero rows and the RLS policy `driver_status_rider_read` (0032), which
--      keys on that same column, never granted.
--   2. `driver_status` was not in the `supabase_realtime` publication
--      (0041 deliberately left it out), so even a direct subscription would
--      never receive GPS pushes.
--   3. `RideService.watchRide` streams the `ride_requests` row, which carries
--      no `driver_status` embed — a ride event therefore WIPED the driver pin
--      instead of refreshing it. GPS pushes never touch `ride_requests`, so no
--      event fired for a moving driver anyway.
--
-- This migration fixes (1) and (2); the Dart side is fixed alongside it
-- (ride_service.dart + user_active_ride_screen.dart) for (3).
--
-- Safety:
--   * Purely additive: one trigger + one published table + a backfill/cleanup.
--   * Idempotent: safe to re-run.
--   * Only ever touches the `current_ride_id` column of a driver's own
--     `driver_status` row; no fare, escrow, status-machine, or policy logic.

-- =========================================================
-- 1. Keep driver_status.current_ride_id in sync with the ride lifecycle
-- =========================================================
-- A trigger (not edits to claim_ride/transition_ride_status) so every path
-- that changes a ride's status — the SQL functions, the ride-transition Edge
-- Function, admin actions — stays correct without touching money or FSM code.
CREATE OR REPLACE FUNCTION public.sync_driver_current_ride()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_terminal boolean;
BEGIN
  -- Nothing to attach when no provider has claimed the ride.
  IF NEW.claimed_by_provider_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_terminal := NEW.status::text IN ('CANCELLED', 'COMPLETED');

  IF v_terminal THEN
    UPDATE public.driver_status
       SET current_ride_id = NULL,
           updated_at = now()
     WHERE provider_id = NEW.claimed_by_provider_id
       AND current_ride_id = NEW.id;
  ELSE
    UPDATE public.driver_status
       SET current_ride_id = NEW.id,
           updated_at = now()
     WHERE provider_id = NEW.claimed_by_provider_id
       AND current_ride_id IS DISTINCT FROM NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_driver_current_ride ON public.ride_requests;
CREATE TRIGGER trg_sync_driver_current_ride
  AFTER INSERT OR UPDATE OF status, claimed_by_provider_id
  ON public.ride_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_driver_current_ride();

-- =========================================================
-- 2. Backfill in-flight rides, and clear stale pointers
-- =========================================================
-- Attach each driver to their newest open (claimed, non-terminal) ride.
UPDATE public.driver_status ds
   SET current_ride_id = x.id,
       updated_at = now()
  FROM (
    SELECT DISTINCT ON (r.claimed_by_provider_id)
           r.claimed_by_provider_id, r.id
      FROM public.ride_requests r
     WHERE r.claimed_by_provider_id IS NOT NULL
       AND r.status::text NOT IN ('CANCELLED', 'COMPLETED')
     ORDER BY r.claimed_by_provider_id, r.created_at DESC
  ) x
 WHERE x.claimed_by_provider_id = ds.provider_id
   AND ds.current_ride_id IS DISTINCT FROM x.id;

-- A pointer left on a now-terminal ride (cancelled/completed before this
-- migration) must not keep the rider's RLS read alive.
UPDATE public.driver_status ds
   SET current_ride_id = NULL,
       updated_at = now()
 WHERE ds.current_ride_id IS NOT NULL
   AND NOT EXISTS (
     SELECT 1 FROM public.ride_requests r
      WHERE r.id = ds.current_ride_id
        AND r.status::text NOT IN ('CANCELLED', 'COMPLETED')
   );

-- =========================================================
-- 3. Publish driver_status so GPS pushes stream to the rider
-- =========================================================
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.driver_status;
  EXCEPTION
    WHEN duplicate_object THEN NULL; -- already in the publication
    WHEN undefined_object THEN NULL; -- publication not present on this project
  END;
END $$;

-- Realtime filters on a non-PK column (current_ride_id) on UPDATE need the
-- full row in the WAL record; the default replica identity only ships the PK.
-- driver_status is one small row per online driver, so the extra WAL is
-- negligible.
ALTER TABLE public.driver_status REPLICA IDENTITY FULL;

-- Refresh PostgREST's schema cache (the trigger/publish are invisible to it).
NOTIFY pgrst, 'reload schema';
