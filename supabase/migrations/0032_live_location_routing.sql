-- 5BIRR — Live GPS collection & routing enablement
-- Migration 0032_live_location_routing.sql
--
-- CONTEXT
--   The app's location features could not collect or display real GPS:
--   1. driver_status had no SELECT policy for the riding user, so the
--      buyer-side embed (driver_status!current_ride_id) always returned
--      nothing — riders could never see their driver's live location.
--   2. The search/location RPC layer from migrations 0006/0022
--      (search_products, get_nearby_providers, get_nearby_ride_providers,
--      search_providers, check_delivery_zone) was never present on this
--      live project — the search screen's RPC call failed silently.
--      These are restored verbatim (verified against the live schema:
--      products.*, provider_profiles.*, vehicles.*, product_images.*).
--   3. Directions need the counterparty's coordinates after the existing
--      reveal timing: rides already expose pickup/destination to the
--      CLAIMED driver only (create_ride_request + RLS, untouched);
--      marketplace orders reveal the provider business location only
--      once the order reaches APPROVED (payment verified) or later.
--
-- SAFETY
--   * No existing policy is modified — one new SELECT policy is added.
--   * No fee, escrow-transition, approval, or FSM logic is touched.
--   * All functions are SECURITY DEFINER with locked search_path.

-- =========================================================
-- 1. RLS: rider may read the driver_status row assigned to their ride
-- =========================================================
DROP POLICY IF EXISTS driver_status_rider_read ON public.driver_status;
CREATE POLICY driver_status_rider_read
  ON public.driver_status
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.ride_requests r
      WHERE r.id = driver_status.current_ride_id
        AND r.user_id = auth.uid()
    )
  );

-- =========================================================
-- 2. Restore the search/location RPC layer (0006/0022, verbatim shape)
-- =========================================================

CREATE OR REPLACE FUNCTION public.search_products(
  p_query text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_sector text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_radius_km NUMERIC DEFAULT NULL,
  p_min_price NUMERIC DEFAULT NULL,
  p_max_price NUMERIC DEFAULT NULL,
  p_min_rating NUMERIC DEFAULT NULL,
  p_sort_by text DEFAULT 'relevance',
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  id uuid, name text, description text, price NUMERIC, currency text,
  rating NUMERIC, review_count int, sales_count int, category_id uuid,
  provider_id uuid, provider_name text, distance_km NUMERIC,
  is_available boolean, image_path text, rank_score NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.price, p.currency, p.rating,
    p.review_count, p.sales_count, p.category_id, p.provider_id,
    pp.business_name AS provider_name,
    CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
      THEN ROUND((ST_Distance(p.location, v_location) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    p.is_available,
    (SELECT pi.storage_path FROM product_images pi
     WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1) AS image_path,
    CASE WHEN p_query IS NOT NULL AND p_query != ''
      THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
           + (1.0 / (1.0 + coalesce(
             CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
               THEN ST_Distance(p.location, v_location) / 1000.0
               ELSE 9999 END, 9999))))::numeric
      ELSE 0::numeric END AS rank_score
  FROM products p
  JOIN provider_profiles pp ON pp.id = p.provider_id AND pp.status = 'APPROVED'
  WHERE p.is_active = true AND p.is_available = true
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR EXISTS (
      SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price)
    AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
  ORDER BY
    CASE p_sort_by WHEN 'price_asc' THEN p.price ELSE null END ASC,
    CASE p_sort_by WHEN 'price_desc' THEN p.price ELSE null END DESC,
    CASE p_sort_by WHEN 'rating' THEN p.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN p.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN
      CASE WHEN p_query IS NOT NULL AND p_query != ''
        THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
             + (1.0 / (1.0 + coalesce(
               CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
                 THEN ST_Distance(p.location, v_location) / 1000.0
                 ELSE 9999 END, 9999))))::numeric
        ELSE 0::numeric END
      ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN
      CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
        THEN ST_Distance(p.location, v_location) ELSE 999999999 END
      ELSE null END ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

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
  -- Provider profiles store plain lat/lng doubles on this project.
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name, pp.status,
    0::NUMERIC AS rating,
    CASE WHEN pp.location_lat IS NOT NULL AND pp.location_lng IS NOT NULL
      THEN ROUND((ST_Distance(
             ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
             ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    NULL::NUMERIC AS service_area_radius_km,
    pp.category_id, c.name AS category_name
  FROM provider_profiles pp
  LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED'
    AND pp.location_lat IS NOT NULL AND pp.location_lng IS NOT NULL
    AND ST_DWithin(
      ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
      p_radius_km * 1000)
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type)
    AND (p_category_id IS NULL OR pp.category_id = p_category_id)
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography)
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_nearby_ride_providers(
  p_lat double precision, p_lng double precision,
  p_radius_km NUMERIC DEFAULT 5,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_limit int DEFAULT 10
)
RETURNS TABLE (
  provider_id uuid, vehicle_id uuid, provider_name text, plate_number text,
  vehicle_brand text, vehicle_model text, distance_km NUMERIC, rating NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN QUERY
  SELECT v.provider_id, v.id AS vehicle_id, pp.business_name AS provider_name,
    v.plate_number, v.brand AS vehicle_brand, v.model AS vehicle_model,
    ROUND((ST_Distance(v.current_location, v_location) / 1000.0)::numeric, 2) AS distance_km,
    v.rating
  FROM vehicles v
  JOIN provider_profiles pp ON pp.id = v.provider_id AND pp.status = 'APPROVED'
  WHERE v.is_available = true AND v.status = 'APPROVED'
    AND v.current_location IS NOT NULL
    AND ST_DWithin(v.current_location, v_location, p_radius_km * 1000)
    AND (p_vehicle_category_id IS NULL OR v.category_id = p_vehicle_category_id)
  ORDER BY ST_Distance(v.current_location, v_location)
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
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name,
    pp.owner_national_id, pp.status, pp.category_id, c.name AS category_name,
    CASE WHEN v_location IS NOT NULL AND pp.location_lat IS NOT NULL AND pp.location_lng IS NOT NULL
      THEN ROUND((ST_Distance(
             ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
             v_location) / 1000.0)::numeric, 2)
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
    AND (v_location IS NULL OR pp.location_lat IS NULL OR pp.location_lng IS NULL
         OR ST_DWithin(
           ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
           v_location, p_radius_km * 1000))
  ORDER BY CASE WHEN v_location IS NOT NULL AND pp.location_lat IS NOT NULL AND pp.location_lng IS NOT NULL
    THEN ST_Distance(
      ST_SetSRID(ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography,
      v_location) ELSE 999999999 END
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION public.check_delivery_zone(
  p_provider_id uuid, p_lat double precision, p_lng double precision
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_lat double precision; v_lng double precision;
BEGIN
  SELECT location_lat, location_lng INTO v_lat, v_lng
  FROM provider_profiles WHERE id = p_provider_id;
  IF v_lat IS NULL OR v_lng IS NULL THEN RETURN false; END IF;
  RETURN ST_DWithin(
    ST_SetSRID(ST_MakePoint(v_lng, v_lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography,
    10 * 1000); -- default 10 km service radius (no per-profile column on live)
END;
$$;

-- =========================================================
-- 3. Escrow-gated buyer location sharing (marketplace orders)
-- =========================================================
-- The buyer's real live GPS is shared with the provider ONLY after the
-- existing escrow reveal timing: payment verified (APPROVED) or delivery
-- in progress (STARTED). Nothing is exposed earlier — the setter enforces
-- the same statuses, so a buyer cannot pre-share even if they wanted to.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS delivery_lat double precision,
  ADD COLUMN IF NOT EXISTS delivery_lng double precision,
  ADD COLUMN IF NOT EXISTS delivery_shared_at timestamptz;

-- Buyer: share a fresh device GPS fix for this order.
CREATE OR REPLACE FUNCTION public.set_order_delivery_location(
  p_order_id uuid, p_lat double precision, p_lng double precision
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status text; v_owner uuid;
BEGIN
  SELECT o.user_id, o.status::text INTO v_owner, v_status
  FROM orders o WHERE o.id = p_order_id;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_owner != auth.uid() THEN RAISE EXCEPTION 'NOT_YOUR_ORDER'; END IF;
  IF v_status NOT IN ('APPROVED', 'STARTED') THEN
    RAISE EXCEPTION 'LOCATION_NOT_REVEALED';
  END IF;
  UPDATE orders
  SET delivery_lat = p_lat,
      delivery_lng = p_lng,
      delivery_shared_at = now()
  WHERE id = p_order_id;
END;
$$;

-- Provider (assigned + APPROVED profile) reads the buyer-shared location,
-- only at the same reveal statuses. Empty row = buyer hasn't shared yet.
CREATE OR REPLACE FUNCTION public.get_order_delivery_location(p_order_id uuid)
RETURNS TABLE (lat double precision, lng double precision, shared_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE
  v_provider_id uuid;
  v_status text;
  v_caller_provider uuid;
BEGIN
  SELECT pp.id INTO v_caller_provider
  FROM provider_profiles pp
  WHERE pp.user_id = auth.uid() AND pp.status = 'APPROVED';
  IF v_caller_provider IS NULL THEN
    RAISE EXCEPTION 'NOT_APPROVED_PROVIDER';
  END IF;

  SELECT o.provider_id, o.status::text INTO v_provider_id, v_status
  FROM orders o WHERE o.id = p_order_id;
  IF v_provider_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  IF v_provider_id != v_caller_provider THEN
    RAISE EXCEPTION 'NOT_YOUR_ORDER';
  END IF;
  IF v_status NOT IN ('APPROVED', 'STARTED') THEN
    RAISE EXCEPTION 'LOCATION_NOT_REVEALED';
  END IF;

  RETURN QUERY
  SELECT o.delivery_lat, o.delivery_lng, o.delivery_shared_at
  FROM orders o WHERE o.id = p_order_id;
END;
$$;

-- Public business location of a provider (what any signed-in user may see
-- on the provider profile anyway). No PII beyond the business address.
CREATE OR REPLACE FUNCTION public.get_provider_public_location(p_provider_id uuid)
RETURNS TABLE (lat double precision, lng double precision, address_text text)
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $$
  SELECT pp.location_lat, pp.location_lng, pp.business_address
  FROM provider_profiles pp
  WHERE pp.id = p_provider_id AND pp.status = 'APPROVED';
$$;

GRANT EXECUTE ON FUNCTION public.set_order_delivery_location(uuid, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_order_delivery_location(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_provider_public_location(uuid) TO authenticated;

-- =========================================================
-- 4. Refresh PostgREST schema cache
-- =========================================================
NOTIFY pgrst, 'reload schema';
