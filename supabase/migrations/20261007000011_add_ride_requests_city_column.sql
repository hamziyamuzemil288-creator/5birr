-- =============================================================================
-- 20261007000011 — Add missing city column to ride_requests
--
-- ROOT CAUSE: Migration 20261006000005 was recorded as applied in the
-- supabase_migrations history table, but the actual ALTER TABLE statement
-- that adds the city column was never executed on the live database.
--
-- This is the same class of problem as migration 20261007000009: the
-- migration version is marked as applied, but the SQL was never run.
--
-- IMPACT: The create_ride_request() function writes ride_requests.city, but
-- the column does not exist. This causes:
--   - SQLSTATE 42703 "column ride_requests.city does not exist" at runtime
--   - The connectivity test "the ride request write matches the ride_requests
--     table" fails because the INSERT column list doesn't match the table
--   - The "two drivers accepting at once" test fails downstream because
--     create_ride_request throws before the ride is created
--
-- FIX: Add the city column with IF NOT EXISTS so this migration is safe to
-- run whether or not the column already exists.
-- =============================================================================

-- Add the city column if it doesn't already exist.
-- This is the column that migration 20261006000005 was supposed to add
-- but never actually executed on the live database.

alter table public.ride_requests
  add column if not exists city text;

-- The create_ride_request function is already restated in 20261006000005
-- to write city. If that function was properly applied, it already includes
-- city in its INSERT. If not, we need to restate it here.
-- 
-- Check: does the current create_ride_request function include city?
-- The function in 20261006000005 (the version with the city fix) includes:
--   INSERT INTO ride_requests (..., city, ...) VALUES (..., v_city, ...)
--
-- If the function was applied from the OLD version (without city), it won't
-- have city in its INSERT. We need to restate it.
--
-- However, we can't easily check the function body from here. Let's restate
-- it with the city column included, using CREATE OR REPLACE.
-- This is safe because CREATE OR REPLACE doesn't change the function signature.

create or replace function public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text default null,
  p_destination_text text default null,
  p_vehicle_category_id uuid default null
)
returns ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride ride_requests;
  v_city text;
begin
  if p_user_id <> auth.uid() then
    raise exception 'CANNOT_CREATE_FOR_ANOTHER_USER';
  end if;

  select city into v_city from public.profiles where id = p_user_id;

  insert into ride_requests (
    user_id,
    pickup_location, destination_location,
    pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text,
    vehicle_category_id, city,
    fare_estimate, status, requested_at
  ) values (
    p_user_id,
    st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
    st_setsrid(st_makepoint(p_destination_lng, p_destination_lat), 4326)::geography,
    p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
    p_pickup_text, p_destination_text,
    p_vehicle_category_id, v_city,
    public.calculate_fare_estimate_at(
      p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
      p_vehicle_category_id, v_city),
    'REQUESTED', now()
  ) returning * into v_ride;

  perform insert_notification(
    p_user_id, 'RIDE_REQUEST', 'Ride requested',
    'Looking for a driver near ' || coalesce(p_pickup_text, 'your location'),
    jsonb_build_object('ride_request_id', v_ride.id));

  perform public.notify_nearby_drivers(
    v_ride.id, p_pickup_text, p_pickup_lat, p_pickup_lng,
    p_vehicle_category_id);

  return v_ride;
end;
$$;

revoke all on function public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) from public, anon;
grant execute on function public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) to authenticated, service_role;
