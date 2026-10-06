-- 20261006000005 — ride requests reach the database, and unclaimed ones die
--
-- THE REPORT (twice)
-- ------------------
-- "GPS rides are not being claimed."
--
-- ROOT CAUSE (reproduced from the migration chain, pinned by
-- tools/harness/static_checks.py::check_ride_request_insert_matches_the_ride_requests_table)
-- -------------------------------------------------------------------------------
-- The last two restatements of create_ride_request (20260927000107 line 767,
-- 20260927000114 line ~305) INSERT INTO ride_requests
--   (user_id, pickup_lat, pickup_lng, destination_lat, destination_lng, ...,
--    fare_estimate, status, requested_at)
-- — but NO migration in the chain ever creates those five columns. The table
-- (0021 snapshot, 0022, 0022a) has pickup_location / destination_location
-- geography and nothing else coordinate-shaped; every ADD COLUMN the chain
-- performs on ride_requests is vehicle_category_id (0010/0022) and city
-- (20260922000000). PL/pgSQL does not check column names at CREATE OR REPLACE
-- time, so the migration applied cleanly and the failure only appears at
-- RUNTIME:
--
--   SQLSTATE 42703  column "pickup_lat" of relation "ride_requests"
--                   does not exist
--
-- friendly_error.dart maps 'of relation' + 'does not exist' to its
-- "We could not save that because of a problem on our side" sentence — the
-- exact error the rider reported earlier. No row is ever written, the
-- driver's open-rides screen streams an empty set, and there is therefore
-- nothing to claim. The claim path itself (ride-claim -> claim_ride's
-- conditional UPDATE ... WHERE status = 'REQUESTED' -> RIDE_ALREADY_TAKEN)
-- is sound — the static check confirms it — it just never had a row to work
-- on.
--
-- A second failure was folded into the same INSERT: pickup_location and
-- destination_location are NOT NULL with no default, so even with the five
-- columns added the statement would trade its 42703 for a 23502 not-null
-- violation. The restatement below fills BOTH shapes: the geography halves
-- the map/distance code reads, and the lat/lng scalars the fare code and
-- this migration's own backfill write.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- 1. Adds pickup_lat / pickup_lng / destination_lat / destination_lng /
--    requested_at to ride_requests (IF NOT EXISTS), backfills them for rows
--    that already exist, and indexes (status, requested_at).
-- 2. Restates create_ride_request with the SAME signature (0125 transcribes
--    its argv) writing both coordinate shapes plus requested_at and city.
-- 3. Adds the 3-minute unclaimed timeout:
--      * expire_stale_ride_requests() — moves REQUESTED rows older than
--        3 minutes to CANCELLED with a history row and a "No driver found"
--        notification, scheduled on pg_cron every minute;
--      * claim_ride() refuses a request older than 3 minutes with
--        RIDE_REQUEST_EXPIRED, so a cron lag cannot award dead work;
--      * the rider's Active Ride screen shows "No driver found" with
--        retry / widen-search after 3 minutes (user_active_ride_screen.dart),
--        and the driver's open list drops rows older than 3 minutes
--        (driver_ride_requests_screen.dart) — a realtime filter only sees
--        INSERTs, so a cancelled-late row would otherwise stay claimable.
-- 4. Three assertions for Connectivity CI:
--      * assert_ride_request_write_matches_schema() — the INSERT's column
--        list against information_schema, live; fails if the deploy that
--        adds the columns never ran;
--      * assert_ride_claim_race_has_one_winner() — WRITE test: builds a
--        fulfilment-ready driver fixture, claims a real REQUESTED row as
--        driver A, claims it again as driver B, and requires B to lose with
--        RIDE_ALREADY_TAKEN while A keeps the ride and exactly one
--        REQUESTED -> CLAIMED history row exists. Everything runs inside
--        the subtransaction that the sentinel rolls back (the
--        assert_wallet_crediting_writes pattern);
--      * assert_unclaimed_ride_expiry_is_wired() — the cron job, the
--        expiry window, and the claim guard, all read from live pg_proc /
--        cron.job.
--
-- Deploy: needs a Supabase deploy (columns + functions + pg_cron job).

-- ---------------------------------------------------------------------------
-- 1. The columns the write already believed in
-- ---------------------------------------------------------------------------

ALTER TABLE public.ride_requests
  ADD COLUMN IF NOT EXISTS pickup_lat double precision,
  ADD COLUMN IF NOT EXISTS pickup_lng double precision,
  ADD COLUMN IF NOT EXISTS destination_lat double precision,
  ADD COLUMN IF NOT EXISTS destination_lng double precision,
  ADD COLUMN IF NOT EXISTS requested_at timestamptz;

-- Backfill from the geography halves that DO exist, so the timeout and any
-- distance display behave identically for rows created before this deploy.
UPDATE public.ride_requests r
   SET pickup_lat = COALESCE(r.pickup_lat, ST_Y(r.pickup_location::geometry)),
       pickup_lng = COALESCE(r.pickup_lng, ST_X(r.pickup_location::geometry)),
       destination_lat = COALESCE(r.destination_lat,
                                  ST_Y(r.destination_location::geometry)),
       destination_lng = COALESCE(r.destination_lng,
                                  ST_X(r.destination_location::geometry)),
       requested_at = COALESCE(r.requested_at, r.created_at)
 WHERE r.pickup_lat IS NULL
    OR r.pickup_lng IS NULL
    OR r.destination_lat IS NULL
    OR r.destination_lng IS NULL
    OR r.requested_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_ride_requests_status_requested_at
  ON public.ride_requests (status, requested_at);

-- ---------------------------------------------------------------------------
-- 2. create_ride_request — same signature, writes the table it inserts into
-- ---------------------------------------------------------------------------
-- Signature and argv order identical to 20260927000114 (0125 transcribes
-- them). The INSERT gains the geography halves (NOT NULL, no default —
-- omitting them is a 23502 waiting to happen), city, and the coordinates it
-- was already passing in. The notification and the driver fan-out are kept
-- verbatim: assert_counterparties_are_notified() reads this body for
-- RIDE_REQUEST and for notify_nearby_drivers.

CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text default null,
  p_destination_text text default null,
  p_vehicle_category_id uuid default null
)
RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride ride_requests;
  v_city text;
BEGIN
  IF p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER';
  END IF;

  SELECT city INTO v_city FROM public.profiles WHERE id = p_user_id;

  -- Both coordinate shapes, on purpose: the map/distance code reads the
  -- geography halves (NOT NULL), the fare/display code reads the scalars,
  -- and requested_at is what the 3-minute unclaimed timeout counts from.
  INSERT INTO ride_requests (
    user_id,
    pickup_location, destination_location,
    pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text,
    vehicle_category_id, city,
    fare_estimate, status, requested_at
  ) VALUES (
    p_user_id,
    ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_destination_lng, p_destination_lat), 4326)::geography,
    p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
    p_pickup_text, p_destination_text,
    p_vehicle_category_id, v_city,
    public.calculate_fare_estimate_at(
      p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
      p_vehicle_category_id, v_city),
    'REQUESTED', now()
  ) RETURNING * INTO v_ride;

  -- 'RIDE_REQUEST', which IS a member of the notification_type enum.
  PERFORM insert_notification(
    p_user_id, 'RIDE_REQUEST', 'Ride requested',
    'Looking for a driver near ' || coalesce(p_pickup_text, 'your location'),
    jsonb_build_object('ride_request_id', v_ride.id));

  -- The drivers. Without this the only way to learn that work exists is to
  -- have the open-rides screen open at the moment it appears.
  perform public.notify_nearby_drivers(
    v_ride.id, p_pickup_text, p_pickup_lat, p_pickup_lng,
    p_vehicle_category_id);

  RETURN v_ride;
END;
$$;

REVOKE ALL ON FUNCTION public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3a. The timeout: expire_stale_ride_requests()
-- ---------------------------------------------------------------------------
-- Moves REQUESTED rows older than 3 minutes to CANCELLED, one history row
-- and one "No driver found" notification each, and returns how many it
-- expired. FOR UPDATE SKIP LOCKED so a concurrent cron tick (or a claim_ride
-- holding the row lock) cannot double-expire or block; the inner UPDATE
-- re-checks status so a ride claimed between the SELECT and the UPDATE is
-- left alone.

CREATE OR REPLACE FUNCTION public.expire_stale_ride_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ride record;
  v_count integer := 0;
BEGIN
  FOR v_ride IN
    SELECT id, user_id, pickup_text
      FROM public.ride_requests
     WHERE status = 'REQUESTED'
       AND COALESCE(requested_at, created_at)
           < now() - interval '3 minutes'
     FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.ride_requests
       SET status = 'CANCELLED',
           updated_at = now()
     WHERE id = v_ride.id
       AND status = 'REQUESTED';

    IF FOUND THEN
      INSERT INTO public.ride_status_history
        (ride_request_id, from_status, to_status, changed_by)
      VALUES (v_ride.id, 'REQUESTED', 'CANCELLED', NULL);

      PERFORM public.insert_notification(
        v_ride.user_id, 'RIDE_REQUEST', 'No driver found',
        'No driver accepted your ride' ||
          coalesce(' near ' || v_ride.pickup_text, '') ||
          ' within 3 minutes. Try again — or widen your search by picking '
          'any vehicle type.',
        jsonb_build_object('ride_request_id', v_ride.id));

      v_count := v_count + 1;
    END IF;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.expire_stale_ride_requests()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_stale_ride_requests()
  TO service_role;

COMMENT ON FUNCTION public.expire_stale_ride_requests() IS
  'Marks REQUESTED ride requests older than 3 minutes CANCELLED, writes the '
  'history row and tells the rider no driver was found. Scheduled on pg_cron '
  'every minute (5birr-ride-request-expiry); idempotent under SKIP LOCKED.';

-- pg_cron, every minute, idempotent — same guard pattern as
-- 20260922000004 / 20260927000058.
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = '5birr-ride-request-expiry'
  ) THEN
    PERFORM cron.schedule(
      '5birr-ride-request-expiry',
      '* * * * *',
      $cron$SELECT public.expire_stale_ride_requests()$cron$
    );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3b. claim_ride — refuses work the timeout already gave up on
-- ---------------------------------------------------------------------------
-- Restated verbatim from 20260927000114 (fulfilment gate, conditional
-- UPDATE ... WHERE status = 'REQUESTED', RIDE_ALREADY_TAKEN, history, audit,
-- rider notification — all kept: assert_provider_fulfilment_gate_is_wired
-- and assert_counterparties_are_notified read this body). The one addition
-- is the 3-minute staleness guard in front of the claim, so a driver whose
-- screen held a row past the cron's cancel (realtime filters see INSERTs,
-- not late UPDATEs) cannot be awarded a ride the rider has stopped waiting
-- for. A missing row still falls through to RIDE_ALREADY_TAKEN, as before.

CREATE OR REPLACE FUNCTION public.claim_ride(
  p_ride_id uuid,
  p_provider_id uuid,
  p_vehicle_id uuid
)
RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ride ride_requests;
  v_blockers text[];
  v_driver_name text;
  v_requested_at timestamptz;
BEGIN
  IF NOT exists (SELECT 1 FROM vehicles
                  WHERE id = p_vehicle_id
                    AND provider_id = p_provider_id
                    AND is_available = true) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE';
  END IF;

  IF NOT exists (SELECT 1 FROM provider_profiles
                  WHERE id = p_provider_id
                    AND provider_type = 'VEHICLE_PROVIDER'
                    AND status = 'APPROVED') THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ELIGIBLE';
  END IF;

  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %',
      array_to_string(v_blockers, ',');
  END IF;

  -- The 3-minute window. The cron expires these every minute, but the job
  -- can lag and a driver's list can hold a row the server already gave up
  -- on; the claim itself must refuse, so no trip is awarded twice in time.
  -- A row that does not exist falls through to RIDE_ALREADY_TAKEN below,
  -- exactly as before this guard existed.
  SELECT COALESCE(requested_at, created_at) INTO v_requested_at
    FROM public.ride_requests
   WHERE id = p_ride_id;
  IF v_requested_at IS NOT NULL
     AND v_requested_at < now() - interval '3 minutes' THEN
    RAISE EXCEPTION 'RIDE_REQUEST_EXPIRED';
  END IF;

  UPDATE ride_requests
     SET status = 'CLAIMED',
         claimed_by_provider_id = p_provider_id,
         claimed_vehicle_id = p_vehicle_id,
         claimed_at = now(),
         updated_at = now()
   WHERE id = p_ride_id
     AND status = 'REQUESTED'
  RETURNING * INTO v_ride;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'RIDE_ALREADY_TAKEN';
  END IF;

  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by)
  VALUES (p_ride_id, 'REQUESTED', 'CLAIMED', auth.uid());

  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'RIDE_CLAIMED', 'ride_requests', p_ride_id,
          jsonb_build_object('provider_id', p_provider_id, 'vehicle_id', p_vehicle_id));

  -- The rider. notify_best_effort swallows a delivery failure: the ride
  -- is already CLAIMED, and rolling that back because a row could not be
  -- written would hand the trip back to the pool while the driver has set
  -- off.
  select coalesce(pp.business_name, 'A driver') into v_driver_name
    from public.provider_profiles pp where pp.id = p_provider_id;

  perform public.notify_best_effort(
    v_ride.user_id,
    'RIDE_CLAIMED',
    'Your ride has a driver',
    v_driver_name || ' is on the way to your pickup point.',
    jsonb_build_object('ride_request_id', p_ride_id, 'provider_id', p_provider_id)
  );

  RETURN v_ride;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_ride(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ride(uuid, uuid, uuid)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4a. Assertion: the write matches the table (read-only, live)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_ride_request_write_matches_schema()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_list text;
  v_col text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'create_ride_request is missing';
  END IF;

  v_list := substring(v_src from
    '(?i)INSERT\s+INTO\s+(?:public\.)?ride_requests\s*\(([^)]*)\)');
  IF v_list IS NULL THEN
    RAISE EXCEPTION 'create_ride_request no longer INSERTs into ride_requests';
  END IF;

  FOR v_col IN
    SELECT trim(both from part)
      FROM unnest(string_to_array(v_list, ',')) AS part
  LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM information_schema.columns
       WHERE table_schema = 'public'
         AND table_name = 'ride_requests'
         AND column_name = lower(v_col)
    ) THEN
      v_bad := v_bad || ARRAY[format(
        'create_ride_request writes ride_requests.%s, which the table does '
        'not have (42703 at first call; the rider sees "problem on our side")',
        lower(v_col))];
    END IF;
  END LOOP;

  IF v_src NOT ILIKE '%pickup_location%'
     OR v_src NOT ILIKE '%destination_location%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request does not fill pickup_location/destination_location '
      '(NOT NULL, no default) — the insert fails with 23502'];
  END IF;

  IF v_src NOT ILIKE '%requested_at%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request does not stamp requested_at, so the 3-minute '
      'unclaimed timeout counts from nothing'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the ride request write does not match the table: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_ride_request_write_matches_schema()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_ride_request_write_matches_schema() IS
  'Reads the live create_ride_request body and checks every column it writes '
  'exists on ride_requests, that the NOT NULL geography halves are filled, '
  'and that requested_at is stamped. Fails if 20261006000005 never deployed.';

-- ---------------------------------------------------------------------------
-- 4b. Assertion: two drivers accept at once, exactly one wins (WRITE)
-- ---------------------------------------------------------------------------
-- Same fixture-and-sentinel pattern as assert_wallet_crediting_writes: real
-- rows, real triggers, one subtransaction that is always rolled back by a
-- sentinel the handler recognises, so there is no cleanup step that can fail
-- and no residue. A genuine failure re-raises with its own error.
--
-- The second claim is SEQUENTIAL rather than literally simultaneous — one
-- backend cannot run two statements at once — but it exercises exactly the
-- code path a concurrent loser hits: claim_ride's race safety is the
-- conditional UPDATE ... WHERE status = 'REQUESTED', whose WHERE clause is
-- re-evaluated against the committed row after the winner's lock releases,
-- whether the loser arrived a millisecond later or a second later. What is
-- proven here: the loser raises RIDE_ALREADY_TAKEN, does not overwrite the
-- winner, and no second REQUESTED -> CLAIMED history row appears.

CREATE OR REPLACE FUNCTION public.assert_ride_claim_race_has_one_winner()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_rider  uuid := '00000000-0000-4000-8000-00000000f001';
  v_user_a uuid := '00000000-0000-4000-8000-00000000f002';
  v_user_b uuid := '00000000-0000-4000-8000-00000000f003';
  v_prov_a uuid := '00000000-0000-4000-8000-00000000f004';
  v_prov_b uuid := '00000000-0000-4000-8000-00000000f005';
  v_veh_a  uuid := '00000000-0000-4000-8000-00000000f006';
  v_veh_b  uuid := '00000000-0000-4000-8000-00000000f007';
  v_ride   uuid := '00000000-0000-4000-8000-00000000f008';
  v_wal_a  uuid := '00000000-0000-4000-8000-00000000f009';
  v_wal_b  uuid := '00000000-0000-4000-8000-00000000f00a';
  v_winner uuid;
  v_status text;
  v_err    text := NULL;
  v_hist   integer;
BEGIN
  -- ---------------------------------------------------------------
  -- Fixtures: a rider and two fulfilment-ready drivers.
  -- ---------------------------------------------------------------
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_rider,  'ride-race-rider@example.invalid',  now()),
         (v_user_a, 'ride-race-driver-a@example.invalid', now()),
         (v_user_b, 'ride-race-driver-b@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_rider,  'Race Rider',  'APPROVED'),
         (v_user_a, 'Race Driver A', 'APPROVED'),
         (v_user_b, 'Race Driver B', 'APPROVED')
  ON CONFLICT (id) DO NOTHING;

  -- The insert guards refuse a client-shaped row; disabled only for the
  -- fixture rows, inside the subtransaction that is about to be rolled back.
  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    EXECUTE 'ALTER TABLE public.vehicles DISABLE TRIGGER trg_vehicles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES (v_prov_a, v_user_a, 'VEHICLE_PROVIDER', 'Race Provider A', 'APPROVED', true),
         (v_prov_b, v_user_b, 'VEHICLE_PROVIDER', 'Race Provider B', 'APPROVED', true)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.vehicles
    (id, provider_id, plate_number, status, is_available)
  VALUES (v_veh_a, v_prov_a, 'RACE-TEST-A', 'APPROVED', true),
         (v_veh_b, v_prov_b, 'RACE-TEST-B', 'APPROVED', true)
  ON CONFLICT (id) DO NOTHING;

  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';
    EXECUTE 'ALTER TABLE public.vehicles ENABLE TRIGGER trg_vehicles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Both drivers are document-verified regardless of the live
  -- enforce_verified_documents switch (AUTO_APPROVED is in the predicate and
  -- legal for the column's CHECK), so the fixture cannot go green or red on
  -- an admin's setting.
  INSERT INTO public.user_documents
    (user_id, document_type, storage_path, verification_status)
  VALUES (v_user_a, 'DRIVING_LICENSE', 'race-test/license-a.pdf', 'AUTO_APPROVED'),
         (v_user_b, 'DRIVING_LICENSE', 'race-test/license-b.pdf', 'AUTO_APPROVED');

  -- Funded wallets: claim_ride refuses a provider whose wallet is empty or
  -- below the admin posting minimum. One million covers any plausible
  -- setting without depending on it.
  INSERT INTO public.wallets (id, provider_id, balance)
  VALUES (v_wal_a, v_prov_a, 1000000.00),
         (v_wal_b, v_prov_b, 1000000.00)
  ON CONFLICT (id) DO NOTHING;

  -- A fresh REQUESTED ride. Inserted directly rather than through
  -- create_ride_request (which requires auth.uid() = rider); the insert
  -- trigger's user_id check is NULL-safe for this no-JWT context, and the
  -- row is rolled back with everything else.
  INSERT INTO public.ride_requests (
    id, user_id,
    pickup_location, destination_location,
    pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text, status, requested_at, fare_estimate
  ) VALUES (
    v_ride, v_rider,
    ST_SetSRID(ST_MakePoint(38.74, 9.00), 4326)::geography,
    ST_SetSRID(ST_MakePoint(38.78, 9.04), 4326)::geography,
    9.00, 38.74, 9.04, 38.78,
    'Race pickup', 'Race destination', 'REQUESTED', now(), 150.00
  );

  -- ---------------------------------------------------------------
  -- Driver A claims.
  -- ---------------------------------------------------------------
  PERFORM public.claim_ride(
    p_ride_id => v_ride, p_provider_id => v_prov_a, p_vehicle_id => v_veh_a);

  SELECT status, claimed_by_provider_id
    INTO v_status, v_winner
    FROM public.ride_requests WHERE id = v_ride;
  IF v_status <> 'CLAIMED' OR v_winner IS DISTINCT FROM v_prov_a THEN
    RAISE EXCEPTION
      'the first claim did not stick: status %, claimed_by %',
      v_status, v_winner;
  END IF;

  -- ---------------------------------------------------------------
  -- Driver B claims the same ride: must lose cleanly.
  -- ---------------------------------------------------------------
  BEGIN
    PERFORM public.claim_ride(
      p_ride_id => v_ride, p_provider_id => v_prov_b, p_vehicle_id => v_veh_b);
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;

  IF v_err IS NULL OR v_err NOT ILIKE '%RIDE_ALREADY_TAKEN%' THEN
    RAISE EXCEPTION 'the second claim did not lose cleanly (got: %)',
      coalesce(v_err,
               'no error at all — two drivers won the same ride');
  END IF;

  -- The loser must not have overwritten the winner...
  SELECT status, claimed_by_provider_id
    INTO v_status, v_winner
    FROM public.ride_requests WHERE id = v_ride;
  IF v_status <> 'CLAIMED' OR v_winner IS DISTINCT FROM v_prov_a THEN
    RAISE EXCEPTION
      'the losing claim overwrote the winner: status %, claimed_by %',
      v_status, v_winner;
  END IF;

  -- ...and the history must show exactly one REQUESTED -> CLAIMED.
  SELECT count(*) INTO v_hist
    FROM public.ride_status_history
   WHERE ride_request_id = v_ride
     AND from_status = 'REQUESTED'
     AND to_status = 'CLAIMED';
  IF v_hist <> 1 THEN
    RAISE EXCEPTION
      'expected exactly one REQUESTED -> CLAIMED history row, found %',
      v_hist;
  END IF;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_ride_claim_race_has_one_winner()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_ride_claim_race_has_one_winner() IS
  'Write test: two fulfilment-ready drivers claim the same REQUESTED ride; '
  'the second must lose with RIDE_ALREADY_TAKEN without overwriting the '
  'first, and exactly one REQUESTED -> CLAIMED history row must exist. '
  'Rolled back by sentinel — leaves no data behind.';

-- ---------------------------------------------------------------------------
-- 4c. Assertion: the timeout is wired (cron + window + claim guard)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_unclaimed_ride_expiry_is_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_claim text;
  v_expire text;
  v_jobs integer;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_claim
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'claim_ride';
  IF v_claim IS NULL THEN
    v_bad := v_bad || ARRAY['claim_ride is missing'];
  ELSIF v_claim NOT ILIKE '%RIDE_REQUEST_EXPIRED%'
        OR v_claim NOT ILIKE '%3 minutes%' THEN
    v_bad := v_bad || ARRAY[
      'claim_ride no longer refuses requests older than 3 minutes'];
  END IF;

  SELECT prosrc INTO v_expire
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'expire_stale_ride_requests';
  IF v_expire IS NULL THEN
    v_bad := v_bad || ARRAY['expire_stale_ride_requests is missing'];
  ELSIF v_expire NOT ILIKE '%3 minutes%'
        OR v_expire NOT ILIKE '%CANCELLED%' THEN
    v_bad := v_bad || ARRAY[
      'expire_stale_ride_requests no longer cancels the 3-minute-stale '
      'REQUESTED rides'];
  END IF;

  SELECT count(*) INTO v_jobs
    FROM cron.job
   WHERE jobname = '5birr-ride-request-expiry'
     AND command LIKE '%expire_stale_ride_requests%';
  IF v_jobs = 0 THEN
    v_bad := v_bad || ARRAY[
      'the pg_cron job 5birr-ride-request-expiry is not scheduled, so '
      'requests nobody reopens stay REQUESTED forever'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the unclaimed-ride timeout is not wired: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_unclaimed_ride_expiry_is_wired()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_unclaimed_ride_expiry_is_wired() IS
  'Reads live pg_proc and cron.job: claim_ride refuses 3-minute-stale '
  'requests with RIDE_REQUEST_EXPIRED, expire_stale_ride_requests exists '
  'with the same window, and the every-minute cron job is scheduled.';
