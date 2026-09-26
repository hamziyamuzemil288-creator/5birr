-- Verifies 20260925210000_driver_live_location.sql against a real Postgres.
--
-- The load-bearing claims this file proves:
--   1. The migration BACKFILLS driver_status.current_ride_id for rides already
--      in flight (the pre-existing driver had never been attached), picking the
--      newest open ride when several exist.
--   2. It CLEARS a pointer left on a terminal (cancelled/completed) ride, so a
--      stale pointer cannot keep a rider's RLS read alive.
--   3. Going forward, a claim attaches the driver, an intermediate status keeps
--      the attachment, and a terminal status releases it — for every path that
--      changes ride_requests, because this is a trigger, not a call-site edit.
--   4. An unclaimed ride touches no driver, and an unrelated column update does
--      not disturb the attachment.
--
-- Why this matters: without current_ride_id the rider's embed
-- driver_status!current_ride_id(...) matches no row and the RLS policy that
-- gates the driver's live location never grants — the rider's map cannot track
-- the current location.
--
-- Run:
--   sudo -u postgres createdb driver_live_location_test
--   stage="$(mktemp -d)/supabase/migrations"; mkdir -p "$stage"
--   cp supabase/migrations/20260925210000_driver_live_location.sql "$stage/"
--   chmod -R a+rX "$(dirname "$stage")"
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -d driver_live_location_test \
--     -v repo_root="$(dirname "$(dirname "$stage")")" \
--     -f <staged copy of this file>
-- (or just: bash tools/test/driver_live_location_driver.sh)

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

CREATE TYPE public.ride_status AS ENUM
  ('REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING', 'DRIVER_EN_ROUTE', 'ARRIVED',
   'TRIP_STARTED', 'STARTED', 'COMPLETED', 'CANCELLED');

CREATE TABLE public.ride_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status public.ride_status NOT NULL DEFAULT 'REQUESTED',
  claimed_by_provider_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- current_location is only ever written through the RPC as geography; the
-- trigger never reads it, so a stub column keeps the status logic under test.
CREATE TABLE public.driver_status (
  provider_id uuid PRIMARY KEY,
  is_online boolean NOT NULL DEFAULT false,
  current_location text,
  current_ride_id uuid REFERENCES public.ride_requests(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---- Pre-existing state the migration must fix on apply ----
-- P1: driver on an open ride, never attached.
INSERT INTO public.ride_requests (id, status, claimed_by_provider_id)
  VALUES ('00000000-0000-0000-0000-0000000000a1', 'CLAIMED',
          '11111111-1111-1111-1111-111111111111');
-- P2: driver with an older open ride AND a newer open ride -> newest wins.
INSERT INTO public.ride_requests (id, status, claimed_by_provider_id, created_at)
  VALUES ('00000000-0000-0000-0000-0000000000b1', 'CLAIMED',
          '22222222-2222-2222-2222-222222222222', now() - interval '1 hour'),
         ('00000000-0000-0000-0000-0000000000b2', 'TRIP_STARTED',
          '22222222-2222-2222-2222-222222222222', now());
-- P3: driver whose pointer points at a CANCELLED ride -> must be cleared.
INSERT INTO public.ride_requests (id, status, claimed_by_provider_id)
  VALUES ('00000000-0000-0000-0000-0000000000c1', 'CANCELLED',
          '33333333-3333-3333-3333-333333333333');

INSERT INTO public.driver_status (provider_id, is_online, current_ride_id) VALUES
  ('11111111-1111-1111-1111-111111111111', true,  NULL),
  ('22222222-2222-2222-2222-222222222222', true,  NULL),
  ('33333333-3333-3333-3333-333333333333', false,
   '00000000-0000-0000-0000-0000000000c1'),
  ('44444444-4444-4444-4444-444444444444', true,  NULL);

\i :repo_root/supabase/migrations/20260925210000_driver_live_location.sql

DO $$
DECLARE v_ride uuid; v_count int;
BEGIN
  -- 1. Backfill attached the open ride.
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '11111111-1111-1111-1111-111111111111';
  IF v_ride IS DISTINCT FROM '00000000-0000-0000-0000-0000000000a1'::uuid THEN
    RAISE EXCEPTION 'FAIL backfill: driver 1 current_ride_id = %', v_ride;
  END IF;
  RAISE NOTICE 'PASS backfill attaches an in-flight driver to their open ride';

  -- 2. Newest open ride wins when several exist.
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '22222222-2222-2222-2222-222222222222';
  IF v_ride IS DISTINCT FROM '00000000-0000-0000-0000-0000000000b2'::uuid THEN
    RAISE EXCEPTION 'FAIL backfill: driver 2 picked % (expected the newest)', v_ride;
  END IF;
  RAISE NOTICE 'PASS backfill picks the newest open ride';

  -- 3. A pointer on a terminal ride is cleared, not left dangling.
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '33333333-3333-3333-3333-333333333333';
  IF v_ride IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL cleanup: stale pointer on a CANCELLED ride survived';
  END IF;
  RAISE NOTICE 'PASS cleanup clears a pointer left on a cancelled ride';

  -- 4. A driver with no active ride stays unattached.
  SELECT count(*) INTO v_count FROM public.driver_status
   WHERE provider_id = '44444444-4444-4444-4444-444444444444'
     AND current_ride_id IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: an idle driver was attached to something';
  END IF;
  RAISE NOTICE 'PASS an idle driver is left unattached';
END $$;

-- ---- Trigger behavior going forward ----
DO $$
DECLARE v_ride uuid;
BEGIN
  -- New claim: driver exists first (as in production), then the ride is claimed.
  INSERT INTO public.driver_status (provider_id, is_online)
    VALUES ('55555555-5555-5555-5555-555555555555', true);
  INSERT INTO public.ride_requests (id, status, claimed_by_provider_id)
    VALUES ('00000000-0000-0000-0000-0000000000e1', 'CLAIMED',
            '55555555-5555-5555-5555-555555555555');

  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '55555555-5555-5555-5555-555555555555';
  IF v_ride IS DISTINCT FROM '00000000-0000-0000-0000-0000000000e1'::uuid THEN
    RAISE EXCEPTION 'FAIL claim: current_ride_id = %', v_ride;
  END IF;
  RAISE NOTICE 'PASS a claim attaches the driver (AFTER INSERT trigger)';

  -- Intermediate status keeps the attachment.
  UPDATE public.ride_requests SET status = 'ARRIVED'
   WHERE id = '00000000-0000-0000-0000-0000000000e1';
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '55555555-5555-5555-5555-555555555555';
  IF v_ride IS DISTINCT FROM '00000000-0000-0000-0000-0000000000e1'::uuid THEN
    RAISE EXCEPTION 'FAIL intermediate status dropped the attachment: %', v_ride;
  END IF;
  RAISE NOTICE 'PASS an intermediate status keeps the driver attached';

  -- An unrelated column update must not disturb the pointer.
  UPDATE public.ride_requests SET created_at = created_at + interval '1 second'
   WHERE id = '00000000-0000-0000-0000-0000000000e1';
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '55555555-5555-5555-5555-555555555555';
  IF v_ride IS DISTINCT FROM '00000000-0000-0000-0000-0000000000e1'::uuid THEN
    RAISE EXCEPTION 'FAIL unrelated update disturbed the attachment: %', v_ride;
  END IF;
  RAISE NOTICE 'PASS an unrelated column update leaves the attachment alone';

  -- Completion releases the driver.
  UPDATE public.ride_requests SET status = 'COMPLETED'
   WHERE id = '00000000-0000-0000-0000-0000000000e1';
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '55555555-5555-5555-5555-555555555555';
  IF v_ride IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL completion did not release the driver';
  END IF;
  RAISE NOTICE 'PASS completion releases the driver';

  -- Cancellation releases the driver.
  INSERT INTO public.driver_status (provider_id, is_online)
    VALUES ('66666666-6666-6666-6666-666666666666', true);
  INSERT INTO public.ride_requests (id, status, claimed_by_provider_id)
    VALUES ('00000000-0000-0000-0000-0000000000f1', 'CLAIMED',
            '66666666-6666-6666-6666-666666666666');
  UPDATE public.ride_requests SET status = 'CANCELLED'
   WHERE id = '00000000-0000-0000-0000-0000000000f1';
  SELECT current_ride_id INTO v_ride FROM public.driver_status
   WHERE provider_id = '66666666-6666-6666-6666-666666666666';
  IF v_ride IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL cancellation did not release the driver';
  END IF;
  RAISE NOTICE 'PASS cancellation releases the driver';

  -- An unclaimed ride must not attach anyone.
  INSERT INTO public.ride_requests (id, status)
    VALUES ('00000000-0000-0000-0000-0000000000d1', 'REQUESTED');
  IF EXISTS (SELECT 1 FROM public.driver_status
              WHERE current_ride_id = '00000000-0000-0000-0000-0000000000d1') THEN
    RAISE EXCEPTION 'FAIL an unclaimed ride attached a driver';
  END IF;
  RAISE NOTICE 'PASS an unclaimed ride attaches no driver';

  RAISE NOTICE 'ALL DRIVER LIVE LOCATION TESTS PASSED';
END $$;
