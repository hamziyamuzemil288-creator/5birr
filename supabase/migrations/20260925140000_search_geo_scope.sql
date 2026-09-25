-- 0042 — search_products: make the proximity filter actually apply, and make
-- p_include_global mean something.
--
-- Two defects shipped together in 20260922000003_search_city_scope.sql, and
-- together they produced "search returns places in other countries":
--
--   1. NULL RADIUS ERASED EVERY LOCATED LISTING. The radius clause was
--         (v_location IS NULL OR p.location IS NULL
--              OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
--      and p_radius_km has DEFAULT NULL. The client sent p_lat/p_lng but never
--      a radius, so the third operand became ST_DWithin(..., NULL) -> NULL, the
--      whole OR chain became NULL, and every product that HAD a location was
--      filtered out. The only rows that could survive were the location-less
--      ones — verified directly:
--        dwithin_null_radius | row_passes_filter
--                           (null) |           (null)
--      The failure was location-DEPENDENT, which is why it looked like a GPS
--      bug: with permission denied, `v_location IS NULL` short-circuits and
--      everything is returned; with a fix, only the unlocatable rows come back.
--
--   2. p_include_global WAS DECLARED AND NEVER READ. It appears in the
--      signature and nowhere in the body, so the client's `p_include_global:
--      true` was a no-op. Combined with the city clause
--      (p_city IS NULL OR p.city IS NULL OR p.city = p_city), city-less
--      listings always passed no matter where they were.
--
-- Fix, deliberately minimal:
--   * v_radius := COALESCE(p_radius_km, 50) — a NULL radius can never reach
--     ST_DWithin again. 50 km is the default proximity window for a city-scale
--     marketplace and is overridden whenever a caller passes its own radius.
--   * p_include_global now gates the city-less rows. TRUE (the default, so
--     existing callers are unchanged) keeps them as a fallback tail; FALSE
--     makes the catalogue strictly local.
--   * Unlocatable rows keep surviving the radius test (there is no distance to
--     judge them by) but the existing 'distance' sort already pushes them last
--     via 999999999, so nearby located stock always leads.
--
-- Signature, return type, and grants are unchanged, so every existing caller
-- and the PostgREST schema cache stay valid.

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
  p_offset int DEFAULT 0,
  p_city text DEFAULT NULL,
  p_include_global boolean DEFAULT true
)
RETURNS TABLE (
  id uuid, name text, description text, price NUMERIC, currency text,
  rating NUMERIC, review_count int, sales_count int, category_id uuid,
  provider_id uuid, provider_name text, distance_km NUMERIC,
  is_available boolean, image_path text, rank_score NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE
  v_location geography(Point,4326);
  v_radius NUMERIC;
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;
  -- Never let a NULL radius reach ST_DWithin (see header item 1).
  v_radius := COALESCE(p_radius_km, 50);

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
    -- Proximity: a NULL radius can no longer wipe out located listings.
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, v_radius * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price)
    AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
    -- City scope. NULL param = no filter (old behavior). City-less listings
    -- are admitted only when the caller opts into global results.
    AND (p_city IS NULL
         OR p.city = p_city
         OR (p.city IS NULL AND COALESCE(p_include_global, true)))
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

GRANT EXECUTE ON FUNCTION public.search_products(text, uuid, text, double precision, double precision, numeric, numeric, numeric, numeric, text, int, int, text, boolean)
  TO authenticated, anon;
