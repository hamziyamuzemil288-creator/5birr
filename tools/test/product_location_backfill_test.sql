-- Verifies 0049 (product location backfill) against a real Postgres.
--
-- The claim being tested: 0049 does not change search LOGIC, it supplies the
-- missing DATA that the already-deployed proximity filter needs. Concretely,
-- before it a listing with location = NULL bypasses ST_DWithin entirely
-- (`p.location IS NULL` short-circuits the AND), so the radius never applies;
-- after it, listings belonging to a provider with business GPS are filtered
-- by real distance.
--
-- It also asserts the two things the migration must NOT do: invent a
-- location for a provider who has no GPS, and touch a product that already
-- had a location.
--
-- Run: see tools/test/staff_identity_delete_test.sql for the staging pattern
--      (the postgres user cannot traverse the repo checkout).

\set ON_ERROR_STOP on

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_name text,
  location_lat double precision,
  location_lng double precision
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id),
  location geography(Point,4326)
);

-- Addis Ababa. 111 km away is a different city entirely.
\set ADDIS_LAT 9.032
\set ADDIS_LNG 38.7469

INSERT INTO public.provider_profiles (business_name, location_lat, location_lng) VALUES
  ('Addis seller', 9.0320, 38.7469),
  ('Far seller',   8.0000, 38.0000),
  ('No GPS seller', NULL, NULL);

-- Three products:
--   near      -> provider has GPS in Addis, product has none  (backfilled)
--   far       -> provider has GPS far away, product has none  (backfilled, then filtered OUT)
--   existing  -> product already has its own location        (must be untouched)
--   noGpsProd -> provider has no GPS at all                  (must stay NULL)
INSERT INTO public.products (name, provider_id, location)
SELECT 'near', id, NULL FROM public.provider_profiles WHERE business_name = 'Addis seller';
INSERT INTO public.products (name, provider_id, location)
SELECT 'far', id, NULL FROM public.provider_profiles WHERE business_name = 'Far seller';
INSERT INTO public.products (name, provider_id, location)
SELECT 'existing', id,
       ST_SetSRID(ST_MakePoint(38.7469, 9.0320), 4326)::geography
  FROM public.provider_profiles WHERE business_name = 'Addis seller';
INSERT INTO public.products (name, provider_id, location)
SELECT 'noGpsProd', id, NULL FROM public.provider_profiles WHERE business_name = 'No GPS seller';

-- The proximity predicate exactly as 0044's search_products writes it.
CREATE OR REPLACE FUNCTION public.proximity(p_lat double precision, p_lng double precision, p_radius_km numeric)
RETURNS TABLE(name text, distance_km numeric) LANGUAGE plpgsql STABLE AS $$
  DECLARE v_location geography(Point,4326);
  DECLARE v_radius numeric := COALESCE(p_radius_km, 50);
  BEGIN
    IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
      v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
    END IF;
    RETURN QUERY
      SELECT pr.name,
             CASE WHEN v_location IS NOT NULL AND pr.location IS NOT NULL
               THEN ROUND((ST_Distance(pr.location, v_location) / 1000.0)::numeric, 2)
               ELSE null END
      FROM public.products pr
      WHERE (v_location IS NULL OR pr.location IS NULL
             OR ST_DWithin(pr.location, v_location, v_radius * 1000))
      ORDER BY 2 NULLS FIRST;
  END;
$$;

\i :repo_root/supabase/migrations/20260925200000_product_location_backfill.sql

DO $$
DECLARE
  v_count int; v_names text[];
BEGIN
  -- 1. The provider WITH gps had their product backfilled.
  SELECT count(*) INTO v_count FROM public.products
   WHERE name = 'near' AND location IS NOT NULL;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL: near product not backfilled'; END IF;
  RAISE NOTICE 'PASS product backfilled from provider business GPS';

  -- 2. The far provider's product was also backfilled — with THEIR location,
  --    not with a nearby one. This is the point of the migration.
  SELECT count(*) INTO v_count FROM public.products
   WHERE name = 'far' AND location IS NOT NULL
     AND ST_DWithin(location,
         ST_SetSRID(ST_MakePoint(38.7469, 9.0320), 4326)::geography, 1000);
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL: far product was snapped to the searcher'; END IF;
  RAISE NOTICE 'PASS distant product keeps its real distance (not snapped nearby)';

  -- 3. A provider with NO gps is left NULL. Inventing a location would be a
  --    lie the map would then display.
  SELECT count(*) INTO v_count FROM public.products
   WHERE name = 'noGpsProd' AND location IS NOT NULL;
  IF v_count <> 0 THEN RAISE EXCEPTION 'FAIL: a location was invented for a provider with no GPS'; END IF;
  RAISE NOTICE 'PASS provider without GPS is left unlocated (no invented coordinates)';

  -- 4. A pre-existing location is untouched.
  SELECT count(*) INTO v_count FROM public.products
   WHERE name = 'existing'
     AND ST_Distance(location, ST_SetSRID(ST_MakePoint(38.7469, 9.0320), 4326)::geography) < 1;
  IF v_count <> 1 THEN RAISE EXCEPTION 'FAIL: existing product location was moved'; END IF;
  RAISE NOTICE 'PASS pre-existing product location is untouched';

  -- 5. THE PAYOFF: with a radius, the backfilled far product is now EXCLUDED
  --    by ST_DWithin. Before the backfill it had location = NULL, the
  --    predicate short-circuited, and it was returned to everyone.
  SELECT array_agg(name ORDER BY name) INTO v_names
    FROM public.proximity(9.032, 38.7469, 5);
  -- 'far' ABSENT is the pass condition: that is the whole point of 0049.
  IF 'far' = ANY(v_names) THEN
    RAISE EXCEPTION 'FAIL: far product still inside a 5km radius: %', v_names;
  END IF;
  RAISE NOTICE 'PASS proximity filter now EXCLUDES the distant product (was previously always returned)';

  -- 6. And a tight radius keeps the near one.
  SELECT array_agg(name ORDER BY name) INTO v_names
    FROM public.proximity(9.032, 38.7469, 5);
  IF NOT ('near' = ANY(v_names) AND 'existing' = ANY(v_names)) THEN
    RAISE EXCEPTION 'FAIL: near products dropped out of the 5km radius: %', v_names;
  END IF;
  RAISE NOTICE 'PASS nearby products are still returned';

  -- 7. Radius now actually changes the answer, which is the observable
  --    difference between "radius honoured" and "radius ignored".
  SELECT array_agg(name ORDER BY name) INTO v_names
    FROM public.proximity(9.032, 38.7469, 500);
  IF NOT ('far' = ANY(v_names)) THEN
    RAISE EXCEPTION 'FAIL: widening the radius to 500km did not admit the far product';
  END IF;
  RAISE NOTICE 'PASS widening the radius admits the distant product (radius is honoured)';

  -- 8. The unlocated product is still reachable — backfill must not hide it.
  SELECT array_agg(name ORDER BY name) INTO v_names
    FROM public.proximity(9.032, 38.7469, 5);
  IF NOT ('noGpsProd' = ANY(v_names)) THEN
    RAISE EXCEPTION 'FAIL: backfill hid the unlocated product entirely';
  END IF;
  RAISE NOTICE 'PASS product without a location remains reachable (client ranks it last)';

  RAISE NOTICE 'ALL PRODUCT LOCATION BACKFILL TESTS PASSED';
END $$;
