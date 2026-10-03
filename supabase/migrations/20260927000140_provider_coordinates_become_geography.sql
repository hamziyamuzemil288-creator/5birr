-- 20260927000140 — give provider_profiles a real geography point.
--
-- WHY
-- ---
-- The live provider_profiles table stores a business position as two plain
-- doubles (location_lat, location_lng) — see the 0021 live snapshot — while
-- every other located row on this project (products, vehicles, ride_requests,
-- driver_status, provider_stores) stores a PostGIS geography point. Migration
-- 0032 had to work around that gap by rebuilding
-- ST_SetSRID(ST_MakePoint(lng, lat), 4326)::geography inline, in three
-- different functions, every time it needed to measure or filter a provider's
-- distance. That is both a data-shape wart and a correctness hazard: each copy
-- is an independent place for the lng/lat argument order to drift, and the
-- doubles cannot be indexed by GiST, so proximity filtering cannot use an
-- index.
--
-- WHAT THIS DOES
-- --------------
-- 1. Adds provider_profiles.location geography(Point,4326).
-- 2. Backfills it from the existing doubles (same point expression the client
--    writes and the product backfill uses: 'SRID=4326;POINT(lng lat)').
-- 3. Keeps it in sync with the doubles via a BEFORE trigger, so the Flutter
--    client (provider_business_profile_screen.dart) can keep writing
--    location_lat/location_lng unchanged and the geography follows.
-- 4. Indexes it with GiST for the ST_DWithin / ORDER BY ST_Distance reads.
-- 5. Recreates get_nearby_providers, search_providers, check_delivery_zone and
--    get_provider_public_location to read the single geography column.
--
-- The doubles are deliberately NOT dropped: the client reads and writes them,
-- and public_provider_profiles exposes them. This migration materializes the
-- canonical point without breaking those callers.
--
-- SAFETY
--   * Additive and idempotent — safe to re-run.
--   * No fee, escrow-transition, approval, or FSM logic is touched.
--   * Function signatures and return shapes are unchanged, so PostgREST and the
--     Flutter callers keep working.

-- =========================================================
-- 1. The column, its data, and its guard
-- =========================================================
ALTER TABLE public.provider_profiles
  ADD COLUMN IF NOT EXISTS location geography(Point,4326);

-- Backfill from the doubles for any row that predates the column.
UPDATE public.provider_profiles
   SET location = ST_SetSRID(ST_MakePoint(location_lng, location_lat), 4326)::geography
 WHERE location_lat IS NOT NULL
   AND location_lng IS NOT NULL;

-- Keep the geography in step with the doubles the client writes.
CREATE OR REPLACE FUNCTION public.sync_provider_profile_location()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF NEW.location_lat IS NOT NULL AND NEW.location_lng IS NOT NULL THEN
    NEW.location := ST_SetSRID(
      ST_MakePoint(NEW.location_lng, NEW.location_lat), 4326)::geography;
  ELSE
    NEW.location := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_provider_profile_location ON public.provider_profiles;
CREATE TRIGGER trg_sync_provider_profile_location
  BEFORE INSERT OR UPDATE OF location_lat, location_lng
  ON public.provider_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_provider_profile_location();

-- The point the proximity RPCs filter and order on.
CREATE INDEX IF NOT EXISTS idx_provider_profiles_location
  ON public.provider_profiles USING gist (location)
  WHERE location IS NOT NULL;

-- =========================================================
-- 2. Readers now read the one geography column
-- =========================================================

CREATE OR REPLACE FUNCTION public.get_nearby_providers(
  p_lat double precision, p_lng double precision,
  p_radius_km NUMERIC DEFAULT 5,
  p_provider_type app_role DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_limit int DEFAULT 20
)
RETURNS TABLE (
  id uuid, user_id uuid, provider_type app_role, business_name text,
  status account_status, rating NUMERIC, distance_km NUMERIC,
  service_area_radius_km NUMERIC, category_id uuid, category_name text
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name, pp.status,
    0::NUMERIC AS rating,
    CASE WHEN pp.location IS NOT NULL
      THEN ROUND((ST_Distance(pp.location, v_location) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    NULL::NUMERIC AS service_area_radius_km,
    pp.category_id, c.name AS category_name
  FROM provider_profiles pp
  LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED'
    AND pp.location IS NOT NULL
    AND ST_DWithin(pp.location, v_location, p_radius_km * 1000)
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type)
    AND (p_category_id IS NULL OR pp.category_id = p_category_id)
  ORDER BY ST_Distance(pp.location, v_location)
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.search_providers(
  p_query text DEFAULT NULL,
  p_provider_type app_role DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_radius_km NUMERIC DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  id uuid, user_id uuid, provider_type app_role, business_name text,
  owner_national_id text, status account_status, category_id uuid,
  category_name text, distance_km NUMERIC, address_text text,
  created_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name,
    pp.owner_national_id, pp.status, pp.category_id, c.name AS category_name,
    CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL
      THEN ROUND((ST_Distance(pp.location, v_location) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    pp.business_address AS address_text, pp.created_at
  FROM provider_profiles pp
  LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED'
    AND (p_query IS NULL OR p_query = ''
         OR pp.business_name ILIKE '%' || p_query || '%'
         OR pp.business_address ILIKE '%' || p_query || '%')
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type)
    AND (p_category_id IS NULL OR pp.category_id = p_category_id)
    AND (v_location IS NULL OR pp.location IS NULL
         OR ST_DWithin(pp.location, v_location, p_radius_km * 1000))
  ORDER BY CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL
    THEN ST_Distance(pp.location, v_location) ELSE 999999999 END
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_delivery_zone(
  p_provider_id uuid, p_lat double precision, p_lng double precision
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  SELECT pp.location INTO v_location
  FROM provider_profiles pp WHERE pp.id = p_provider_id;
  IF v_location IS NULL THEN RETURN false; END IF;
  RETURN ST_DWithin(
    v_location,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
    10 * 1000); -- default 10 km service radius (no per-profile column on live)
END;
$$;

-- Same public shape (lat/lng doubles) the app already consumes — only the
-- source of the numbers changes.
CREATE OR REPLACE FUNCTION public.get_provider_public_location(p_provider_id uuid)
RETURNS TABLE (lat double precision, lng double precision, address_text text)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT ST_Y(pp.location::geometry), ST_X(pp.location::geometry),
         pp.business_address
  FROM provider_profiles pp
  WHERE pp.id = p_provider_id AND pp.status = 'APPROVED';
$$;

GRANT EXECUTE ON FUNCTION public.get_nearby_providers(double precision, double precision, NUMERIC, app_role, uuid, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_providers(text, app_role, uuid, double precision, double precision, NUMERIC, int, int) TO authenticated;
GRANT EXECUTE ON FUNCTION public.check_delivery_zone(uuid, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_provider_public_location(uuid) TO authenticated;

-- =========================================================
-- 3. Refresh PostgREST schema cache
-- =========================================================
NOTIFY pgrst, 'reload schema';
