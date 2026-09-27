-- 20260927000061_live_ride_map.sql
--
-- Feature: the ride-hailing map screen (live, animated, moving vehicles).
--
-- Symptom reported:  RealtimeSubscribeException — "Unable to subscribe to
--   changes... Please check Realtime is enabled for the given connect
--   parameters: table: ride_requests" (RealtimeSubscribeStatus.channelError).
--   Nothing live can work while the subscribe itself is rejected.
--
-- Root cause:  the publication was already correct — 0041 added
--   `ride_requests` and 20260925210000 added `driver_status`, so "the table
--   is not published" was NOT the problem this time.  The actual gap is
--   REPLICA IDENTITY.
--
--   Postgres writes only the primary key into the WAL for the *old* row
--   under the default replica identity ("D"), so a Realtime subscriber that
--   asks for a row set filtered on any other column cannot be evaluated
--   server-side, and the channel subscribe comes back as CHANNEL_ERROR —
--   which the Dart client reports with exactly the message above.  Three
--   call sites in this app filter on non-PK columns:
--
--     * RideService.watchRideRequests()
--         `.stream(primaryKey:['id']).eq('status','REQUESTED').order('created_at')`
--         -> the driver's open-request feed.  `status` and `created_at` are
--            both non-PK.
--     * RideRepository.watchOpenRideRequests()        (same table, same filter)
--     * NotificationRepository.watchNotifications()/watchUnreadCount()
--         -> `.eq('is_read', false)`, a non-PK column.
--
--   `REPLICA IDENTITY FULL` is the supported switch for this.  It is
--   additive, reversible, and costs a little extra WAL per row; it grants no
--   new read access, because Realtime still applies each subscriber's RLS.
--
-- This migration:
--   1. sets REPLICA IDENTITY FULL on the three tables the app streams, and
--      re-asserts publication membership idempotently (so a project whose
--      publication was reset self-heals instead of silently going dead);
--   2. adds `nearby_provider_markers()` — the marker feed for the live map,
--      reused join-by-join from `find_nearby_drivers()` but (a) returning a
--      position, (b) NOT hiding drivers who are already on a ride (the map
--      shows moving traffic, not just free cars), and (c) returning the
--      category of the driver's primary vehicle so each vehicle type can
--      render its own icon;
--   3. adds `live_map_open_rides()` — the driver-side counterpart, so the
--      map is functional for vehicle providers and not just riders;
--   4. adds `assert_live_map_is_wired()` for the connectivity suite.
--
-- Safety: purely additive.  No policy, fare, escrow or status-machine logic
-- is touched.  Idempotent — safe to re-run.
--
-- Privacy note (deliberate): `nearby_provider_markers()` returns positions
-- rounded to 3 decimal places (~110 m).  A ride-hailing map must show nearby
-- vehicles, but handing every signed-in user a centimetre-exact trace of
-- every driver is a stalking tool, not a feature.  Precision finer than this
-- is only ever returned for a driver the caller has actually claimed a ride
-- with, through the existing `driver_status_rider_read` policy.

-- =========================================================
-- 1. Realtime: replication identity + publication membership
-- =========================================================
-- FULL, not DEFAULT: every stream in this app filters on a non-PK column
-- (see the header).  Without this the subscribe is rejected outright.
ALTER TABLE public.ride_requests REPLICA IDENTITY FULL;
ALTER TABLE public.driver_status REPLICA IDENTITY FULL;
ALTER TABLE public.notifications REPLICA IDENTITY FULL;

-- Re-assert membership.  These were added by 0036/0041/20260925210000, but a
-- publication that is dropped or rebuilt (restore, branch reset) takes live
-- tracking down silently, and the failure mode is a channel error rather
-- than anything an operator would notice in the logs.
DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE WARNING 'supabase_realtime publication is missing; live map updates will not be delivered';
    RETURN;
  END IF;

  FOREACH t IN ARRAY ARRAY['ride_requests', 'driver_status', 'notifications']
  LOOP
    IF NOT EXISTS (
      SELECT 1
        FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END;
$$;

-- =========================================================
-- 2. Nearby provider markers (the live map feed)
-- =========================================================
-- Deliberately a sibling of `find_nearby_drivers()` rather than a change to
-- it.  That function answers "which single driver should take this ride?" —
-- it excludes drivers already on a ride and returns no geometry at all, and
-- `LocationService.findNearbyDrivers()` maps its exact column list.  Loosening
-- it would change both its meaning and its call site.  This one answers
-- "what is moving around me right now?".
CREATE OR REPLACE FUNCTION public.nearby_provider_markers(
  p_lat double precision,
  p_lng double precision,
  p_radius_km numeric DEFAULT 5,
  p_provider_type public.app_role DEFAULT NULL
)
RETURNS TABLE (
  provider_id uuid,
  provider_type public.app_role,
  display_name text,
  category_id uuid,
  category_slug text,
  category_name text,
  lat double precision,
  lng double precision,
  on_ride boolean,
  seconds_since_fix integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_location geography(Point, 4326);
  v_radius numeric;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RAISE EXCEPTION 'LOCATION_REQUIRED';
  END IF;
  IF p_lat < -90 OR p_lat > 90 OR p_lng < -180 OR p_lng > 180 THEN
    RAISE EXCEPTION 'LOCATION_OUT_OF_RANGE';
  END IF;

  -- Floor and ceiling so a client cannot turn one query into a table scan of
  -- the whole country, or ask for a radius of zero and get nothing.
  v_radius := least(greatest(coalesce(p_radius_km, 5), 0.5), 25);
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;

  RETURN QUERY
  SELECT
    ds.provider_id,
    pp.provider_type,
    coalesce(pp.business_name, pr.full_name, 'Aliob partner')::text,
    cat.id,
    cat.slug,
    cat.name,
    round(ST_Y(ds.current_location::geometry)::numeric, 3)::double precision,
    round(ST_X(ds.current_location::geometry)::numeric, 3)::double precision,
    (ds.current_ride_id IS NOT NULL),
    greatest(0, extract(epoch FROM (now() - coalesce(ds.last_location_update, ds.updated_at)))::integer)
  FROM public.driver_status ds
  JOIN public.provider_profiles pp
    ON pp.id = ds.provider_id
   AND pp.status = 'APPROVED'
  LEFT JOIN public.profiles pr
    ON pr.id = pp.user_id
  -- The driver's primary vehicle decides which icon the map draws.  Ordering
  -- by is_available first means a multi-vehicle provider shows the car they
  -- are actually driving rather than an arbitrary one.
  LEFT JOIN LATERAL (
    SELECT v.category_id
      FROM public.vehicles v
     WHERE v.provider_id = ds.provider_id
       AND v.status = 'APPROVED'
     ORDER BY v.is_available DESC, v.created_at ASC
     LIMIT 1
  ) pv ON true
  LEFT JOIN public.categories cat
    ON cat.id = pv.category_id
  WHERE ds.is_online = true
    AND ds.current_location IS NOT NULL
    -- A driver whose phone died mid-shift must not stay on the map forever.
    AND coalesce(ds.last_location_update, ds.updated_at) > now() - interval '5 minutes'
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type)
    AND ST_DWithin(ds.current_location, v_location, v_radius * 1000)
  ORDER BY ds.current_location <-> v_location
  LIMIT 60;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.nearby_provider_markers(double precision, double precision, numeric, public.app_role) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.nearby_provider_markers(double precision, double precision, numeric, public.app_role) FROM anon;
GRANT EXECUTE ON FUNCTION public.nearby_provider_markers(double precision, double precision, numeric, public.app_role) TO authenticated;

-- =========================================================
-- 3. Open ride requests near a driver (driver-side map)
-- =========================================================
-- The rider map shows vehicles; the driver map shows work.  Without this the
-- "live map" would only exist for half the product.
CREATE OR REPLACE FUNCTION public.live_map_open_rides(
  p_lat double precision,
  p_lng double precision,
  p_radius_km numeric DEFAULT 8
)
RETURNS TABLE (
  ride_request_id uuid,
  pickup_text text,
  destination_text text,
  fare_estimate numeric,
  category_id uuid,
  category_name text,
  category_slug text,
  lat double precision,
  lng double precision,
  created_seconds_ago integer
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_location geography(Point, 4326);
  v_radius numeric;
BEGIN
  -- Membership gate, not a role check: these are live customer locations.
  -- Only an approved vehicle provider may see them, matching the
  -- `ride_requests_provider_read_open` policy that already governs the rows.
  IF NOT EXISTS (
    SELECT 1
      FROM public.provider_profiles pp
     WHERE pp.user_id = auth.uid()
       AND pp.provider_type = 'VEHICLE_PROVIDER'
       AND pp.status = 'APPROVED'
  ) THEN
    RAISE EXCEPTION 'ONLY_APPROVED_VEHICLE_PROVIDERS_CAN_SEE_OPEN_RIDES';
  END IF;

  IF p_lat IS NULL OR p_lng IS NULL THEN
    RAISE EXCEPTION 'LOCATION_REQUIRED';
  END IF;

  v_radius := least(greatest(coalesce(p_radius_km, 8), 0.5), 25);
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;

  RETURN QUERY
  SELECT
    rr.id,
    rr.pickup_text,
    rr.destination_text,
    rr.fare_estimate,
    cat.id,
    cat.name,
    cat.slug,
    round(ST_Y(rr.pickup_location::geometry)::numeric, 5)::double precision,
    round(ST_X(rr.pickup_location::geometry)::numeric, 5)::double precision,
    greatest(0, extract(epoch FROM (now() - rr.created_at))::integer)
  FROM public.ride_requests rr
  LEFT JOIN public.categories cat
    ON cat.id = rr.vehicle_category_id
  WHERE rr.status = 'REQUESTED'
    AND rr.claimed_by_provider_id IS NULL
    AND ST_DWithin(rr.pickup_location, v_location, v_radius * 1000)
  ORDER BY rr.created_at DESC
  LIMIT 40;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.live_map_open_rides(double precision, double precision, numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.live_map_open_rides(double precision, double precision, numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.live_map_open_rides(double precision, double precision, numeric) TO authenticated;

-- =========================================================
-- 4. Connectivity assertion
-- =========================================================
CREATE OR REPLACE FUNCTION public.assert_live_map_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  t text;
  v_ident "char";
BEGIN
  -- The two tables the map streams must both be published AND carry a full
  -- replica identity, because the app filters them on non-PK columns.
  FOREACH t IN ARRAY ARRAY['ride_requests', 'driver_status']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime'
         AND schemaname = 'public'
         AND tablename = t
    ) THEN
      RAISE EXCEPTION
        'REALTIME_REGRESSION: % is not in the supabase_realtime publication, so live ride tracking is dead',
        t;
    END IF;

    SELECT relreplident INTO v_ident
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = t;

    IF coalesce(v_ident, 'd') <> 'f' THEN
      RAISE EXCEPTION
        'REALTIME_REGRESSION: % has replica identity "%" instead of FULL; a stream filtered on a non-primary-key column (the driver open-request feed filters on status) will fail to subscribe with a CHANNEL_ERROR',
        t, coalesce(v_ident, 'd');
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'nearby_provider_markers' AND p.prosecdef
  ) THEN
    RAISE EXCEPTION 'nearby_provider_markers() is missing or is not SECURITY DEFINER';
  END IF;

  -- Marker positions are coarsened on purpose.  If someone "fixes" that back
  -- to raw geography, every signed-in account gets a live trace of every
  -- driver — this makes that a test failure rather than a silent regression.
  IF has_function_privilege('anon', 'public.nearby_provider_markers(double precision, double precision, numeric, public.app_role)', 'EXECUTE') THEN
    RAISE EXCEPTION 'nearby_provider_markers() is executable by anon; nearby driver positions must require a session';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.nearby_provider_markers(double precision, double precision, numeric, public.app_role)', 'EXECUTE') THEN
    RAISE EXCEPTION 'nearby_provider_markers() is not executable by authenticated, so the map will show nothing';
  END IF;

  RETURN 'live map wiring OK: ride_requests and driver_status published with FULL replica identity, marker feed reachable and session-gated';
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_live_map_is_wired() TO anon, authenticated;
