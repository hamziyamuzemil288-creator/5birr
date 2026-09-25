-- 0049 — backfill products.location from the owning provider's business GPS.
--
-- WHY
-- ---
-- 20260925140000_search_geo_scope.sql is deployed and correct: it honours
-- p_radius_km and gates city-less listings behind p_include_global. Probing
-- the live function showed it doing nothing, and the reason is data, not code:
--
--   select sample row -> distance_km = null   (p.lat/p.lng supplied)
--   p_radius_km 0.5 -> 4 rows ; p_radius_km 500 -> 4 rows
--
-- In the 0044 body, distance_km is computed only when BOTH the searcher's
-- position and the row's p.location are set, and the proximity predicate is
--
--   AND (v_location IS NULL OR p.location IS NULL
--        OR ST_DWithin(p.location, v_location, v_radius * 1000))
--
-- `p.location IS NULL` short-circuits the clause, so the radius is never
-- consulted and every location-less listing is returned regardless of how far
-- away it is. That is indistinguishable from an ignored radius, and it is why
-- the fix looked like it had not shipped.
--
-- The listings have no location because provider_product_form_screen.dart
-- writes it conditionally:
--
--   if (locationValue != null) 'location': locationValue,
--
-- where the value falls back to the provider's business-profile
-- location_lat/lng. Any product created by a provider whose profile had no
-- GPS was stored with location = NULL and has stayed that way.
--
-- WHAT THIS DOES
-- --------------
-- Copies the provider's business GPS onto their products. This is the same
-- value the form would have written had the profile had a location, so it
-- introduces no new information — it only stops the existing information from
-- being dropped.
--
-- Products whose provider still has no GPS are deliberately left NULL. They
-- remain reachable through search; the client now ranks them last rather than
-- as peers of nearby hits, and 0049's companion client change stops
-- p_include_global from admitting every city-less row once a position is
-- known. Faking coordinates for those would be worse than admitting we do
-- not know where the listing is.
--
-- The point expression matches what the Flutter client writes
-- ('SRID=4326;POINT(lng lat)') and what the search function builds, so
-- distances are computed consistently across all three.

DO $$
DECLARE
  v_updated int;
BEGIN
  UPDATE public.products p
     SET location = ST_SetSRID(
           ST_MakePoint(pp.location_lng, pp.location_lat), 4326)::geography
    FROM public.provider_profiles pp
   WHERE p.provider_id = pp.id
     AND p.location IS NULL
     AND pp.location_lat IS NOT NULL
     AND pp.location_lng IS NOT NULL;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE NOTICE 'backfilled % product(s) with the provider business location', v_updated;
END $$;

-- Proximity filtering now has data to work with, so index the column it
-- filters on. Partial: location-less rows are excluded from both the index
-- and the ST_DWithin test, so indexing them would be dead weight.
CREATE INDEX IF NOT EXISTS idx_products_location
  ON public.products (location)
  WHERE location IS NOT NULL;
