-- =============================================================================
-- 20261008000001 — a rider's own ride request must be able to notify
--
-- THE REPORT (rider, 2026-10-08)
-- ------------------------------
--   "Could not request this ride. Something went wrong. Please try again.
--    (Ref AL-A65813)"
--
-- ROOT CAUSE (every link traced, none assumed)
-- --------------------------------------------
-- create_ride_request() is called by an authenticated rider over PostgREST.
-- In that context:
--
--   * is_server_write() is FALSE — 20260927000019's own comment records why:
--     "PostgREST connects as `authenticator` and SET ROLE never changes it",
--     so session_user is `authenticator` (not postgres/supabase_admin) and the
--     role GUC is `authenticated` (not service_role);
--   * is_admin() is FALSE — the caller is an ordinary signed-in rider;
--   * and the body then does, in this order:
--       insert into ride_requests (...)            -- row written
--       perform insert_notification(... RIDE_REQUEST ...)  -- direct INSERT
--       perform public.notify_nearby_drivers(...)
--
-- `insert_notification()` writes straight into `notifications`, where
-- `trg_notifications_security` -> `prevent_notification_injection()` raises
-- NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS for exactly the case above (the
-- guard's two exemptions — server write, verified admin — neither applies).
-- The RAISE aborts the whole transaction, so the ride row written one line
-- earlier is rolled back: no request ever reaches the database, nothing can
-- be claimed, and the client shows its generic fallback sentence with a
-- reference code — because friendly_error.dart recognises none of
-- "notifications_cannot_be_created_by_clients" (it maps network, auth, 403,
-- PGRST202/203, 42703, 23502/23503/23505, ride_already_taken, ride_request_
-- expired … and then falls through to "Something went wrong. Please try
-- again."). The message the rider saw is therefore the expected rendering of
-- this exact error, not a network fault and not an RLS denial.
--
-- The same defect kills the driver fan-out silently: notify_nearby_drivers()
-- -> notify_best_effort() -> insert_notification() raises identically, and
-- notify_best_effort's EXCEPTION WHEN OTHERS swallows it as a WARNING — so
-- even after this migration the riders' notices are queued while the drivers'
-- notices are simply delivered instead of lost.
--
-- WHY THIS IS THE FIX THE SCHEMA ALREADY ASKED FOR
-- ------------------------------------------------
-- 20260927000058 built the correct path and documented it:
--
--   notify_user(): "Writes straight to notifications when it is called by the
--   server, and queues for the scheduler when it is called from a client
--   write, because prevent_notification_injection refuses the latter by
--   design."
--
--   assert_meaningful_events_are_notified()'s own note: "A hand-written
--   INSERT INTO notifications in one of these is the drift this catches: it
--   would bypass the queue and so fail on the client paths."
--
-- create_ride_request (20260927000107 → 000114 → 20261006000005 → 000011) is
-- precisely that drift: a client path calling insert_notification() directly.
-- The fix routes both call sites through the queue-aware helpers:
--
--   * the rider's own "Ride requested" notice -> notify_user_safe(), which
--     dedupes on an idem key and NEVER raises, so a notification can no
--     longer roll back the ride it is describing;
--   * the driver fan-out -> notify_user(), which writes directly on a server
--     call (edge functions, pg_cron) and queues on a client call.
--
-- On the client path both land in notification_outbox, which pg_cron drains
-- every minute as `postgres` — a server write, which the guard permits. The
-- guard itself is NOT changed: assert_notification_outbox_is_drained() and
-- assert_client_guards_are_server_safe() keep passing exactly as they are.
--
-- WHAT IS NOT CHANGED
-- -------------------
-- * prevent_notification_injection(), is_server_write(), is_admin().
-- * The signature or the INSERT of create_ride_request — the eight parameter
--   names, the column list and requested_at are untouched, so
--   assert_ride_request_write_matches_schema(), the customer-RPC reachability
--   report and the client's Dart call all still match.
-- * notify_nearby_drivers()' fan-out and its swallow.
--
-- Deploy: needs a Supabase deploy (two function bodies + one assertion).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The ride request itself: notify through the queue-aware, non-raising path
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text DEFAULT NULL,
  p_destination_text text DEFAULT NULL,
  p_vehicle_category_id uuid DEFAULT NULL
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

  -- NOT insert_notification(): this function is called by a signed-in rider,
  -- so the notification guard would raise NOTIFICATIONS_CANNOT_BE_CREATED_BY_
  -- CLIENTS and roll the ride back. notify_user_safe() queues on that path
  -- (drained by cron as the server), dedupes on the ride id, and cannot raise
  -- — a failed notice must never un-create the ride it describes.
  PERFORM public.notify_user_safe(
    'ride-request:' || v_ride.id,
    p_user_id, 'RIDE_REQUEST', 'Ride requested',
    'Looking for a driver near ' || coalesce(p_pickup_text, 'your location'),
    jsonb_build_object('ride_request_id', v_ride.id));

  PERFORM public.notify_nearby_drivers(
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
-- 2. The driver fan-out: same routing, still best-effort
-- ---------------------------------------------------------------------------
-- notify_user() chooses direct-vs-queue by is_server_write(), so an edge
-- function calling this as service_role behaves exactly as before, while a
-- rider's create_ride_request queues instead of raising into the swallow.

CREATE OR REPLACE FUNCTION public.notify_best_effort(
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_data jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Nothing to address: callers legitimately do not know the counterparty
  -- yet, and must not have to pre-check.
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN public.notify_user(p_user_id, p_type, p_title, p_body, p_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'notify_best_effort(%) failed and was swallowed: %',
      p_type, SQLERRM;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_best_effort(
  uuid, public.notification_type, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_best_effort(
  uuid, public.notification_type, text, text, jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Assertion for Connectivity CI: the drift must not come back
-- ---------------------------------------------------------------------------
-- Source-level, like assert_counterparties_are_notified: it reads the LIVE
-- bodies, so a restatement that re-introduces a direct INSERT into
-- notifications on this client path fails the run instead of a rider.

CREATE OR REPLACE FUNCTION public.assert_ride_create_notifies_through_the_queue()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ride text;
  v_fan  text;
  v_bad  text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_ride
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';

  IF v_ride IS NULL THEN
    RETURN false;
  END IF;

  IF v_ride ILIKE '%insert_notification%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request calls insert_notification() directly; on a rider''s '
      'own call the notification guard raises NOTIFICATIONS_CANNOT_BE_CREATED_'
      'BY_CLIENTS and rolls the whole ride back'];
  END IF;

  IF v_ride NOT ILIKE '%notify_user%' THEN
    v_bad := v_bad || ARRAY[
      'create_ride_request no longer routes its rider notice through '
      'notify_user(), so the client path writes into notifications directly'];
  END IF;

  SELECT prosrc INTO v_fan
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'notify_best_effort';

  IF v_fan IS NULL OR v_fan NOT ILIKE '%notify_user%' THEN
    v_bad := v_bad || ARRAY[
      'notify_best_effort no longer routes through notify_user(), so the '
      'driver fan-out raises into its own swallow and no driver is told'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the ride path bypasses the notification queue: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_ride_create_notifies_through_the_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_ride_create_notifies_through_the_queue()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_ride_create_notifies_through_the_queue() IS
  'Fails when create_ride_request or notify_best_effort writes notifications '
  'directly again: the rider''s own call is a client path, and a direct INSERT '
  'there is rolled back by prevent_notification_injection, which is why no ride '
  'request ever reached the database.';
