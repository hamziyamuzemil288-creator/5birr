-- 20261011000001 — the public reads stop showing photo-less listings, search
-- carries the listing's own type, and the trending rail ranks by this week
-- =============================================================================
--
-- WHY — three reports, one migration, because all three are the same two
-- functions plus the ranking read:
--
-- 1. A LISTING WITH NO PHOTO WAS ON EVERY PUBLIC SURFACE. `products` has no
--    image column: a listing's photos live in `product_images`, so "does this
--    listing have a photo?" is a question about a second table. Nothing asked
--    it. A listing whose provider had uploaded nothing therefore appeared in
--    category browse and in search as a card with a grey frame and a box icon
--    -- which reads as a BROKEN image, not as a listing that never had one.
--
--    Both public discovery reads now exclude those rows:
--    `visible_products_for_city` (the category screen) and `search_products`
--    (the search screen — SECURITY DEFINER, so no policy reaches it; the same
--    reason 20261006000008 had to restate the payment-account predicate into
--    it).
--
--    `products_public_read` deliberately does NOT carry this exclusion. That
--    policy also answers the provider's own public page, and that page HAS to
--    keep showing a text-only listing — it renders it as a card with the name,
--    the price and the BUY/BOOK action and no image box at all. Hiding the row
--    at the policy level would hide it from the one surface allowed to show it.
--    The home feed, the one discovery read the client makes directly, applies
--    the same rule in Dart (`Product.hasPhoto` / `Product.coverStoragePath`).
--
-- 2. `search_products` NOW RETURNS `listing_type`. The shared card's button
--    says BUY for a good and BOOK for a service or a room, and search was the
--    one listing surface whose read did not carry the column that decides
--    which — so a service found by searching read BUY, and only there. A return
--    type cannot be changed by CREATE OR REPLACE (PostgreSQL raises 42P13 while
--    analysing the statement, before it reads the new body), so the function is
--    DROPPED first and its GRANT re-issued.
--
-- 3. THE TRENDING RAIL RANKED BY CAREER TOTALS, so it never moved.
--    `ranked_providers` ordered by `completed_transactions` — all-time
--    completed orders plus completed rides, a number that moves by one and only
--    after months — with `created_at ASC` behind it. For every provider with no
--    completed work that collapses to "the oldest signup first": the same names
--    in the same order on every launch. It now orders by COMPLETED WORK IN THE
--    LAST 7 DAYS first, then career totals, then the same stable tiebreak, so
--    the rail follows the trade that is happening now. Same return shape, no
--    new column, no new function, so nothing else that reads it changes.
--
-- All three are READ-ONLY: no new table, no new policy, no write anywhere.
-- =============================================================================

SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- 1. Category browse: no photo, no listing
-- ---------------------------------------------------------------------------

create or replace function public.visible_products_for_city(
  p_city text,
  p_category_id uuid default null
)
returns setof public.products
language sql
stable
as $$
  select p.*
  from public.products p
  where p.is_active
    -- An EMPTY (or NULL) city is "all cities", not "the city named ''". Every
    -- existing caller passes a real city, so this only widens the call that
    -- asks for the combined view.
    and (coalesce(btrim(p_city), '') = '' or p.city is null or p.city = p_city)
    and (
      p_category_id is null
      or p.category_id = p_category_id
      or p.category_id in (
        select c.id from public.categories c where c.parent_id = p_category_id
      )
    )
    -- A listing with no photo is a text-only listing, and a browse grid has
    -- nowhere to put one: the card would be an empty frame. It stays reachable
    -- on its own provider's page, which reads `products` directly and so is not
    -- touched by this predicate.
    and exists (
      select 1 from public.product_images pi where pi.product_id = p.id
    )
  order by p.sales_count desc nulls last, p.created_at desc
  limit 100;
$$;

grant execute on function public.visible_products_for_city(text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Search: the same exclusion, plus the listing's own type
-- ---------------------------------------------------------------------------
-- DROP before CREATE: the RETURNS TABLE below gains `listing_type`, and
-- PostgreSQL refuses a changed return type on CREATE OR REPLACE (42P13), which
-- would abort the whole deploy at this file. Dropping the one signature also
-- drops its GRANT, which is re-issued immediately after.

-- The argument list is spelled the way pg_dump spells it (float8/int4/bool),
-- which is the same signature PostgreSQL resolves: `double precision` written
-- out in full inside a DROP is also valid SQL, but the harness that guards
-- against 42P13 reads the types back out of this line and only recognises the
-- canonical spelling.
DROP FUNCTION IF EXISTS public.search_products(
  text, uuid, text, float8, float8, numeric, numeric,
  numeric, numeric, text, int4, int4, text, bool);

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
  listing_type listing_type,
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
    p.listing_type,
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
    -- Item 6: an account-less provider's listings are hidden from buyers,
    -- exactly like the products_public_read policy (this function runs as
    -- its owner, so the policy alone cannot reach it).
    AND EXISTS (
      SELECT 1 FROM public.provider_payment_methods m
       WHERE m.provider_id = p.provider_id AND m.is_active = true)
    -- A listing with no photo never appears in a search result: the result is
    -- a card, and a card with no photo is an empty frame. The listing is not
    -- gone — its own provider's page still shows it, as a text-only card.
    AND EXISTS (
      SELECT 1 FROM public.product_images pi
       WHERE pi.product_id = p.id)
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR EXISTS (
      SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price)
    AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
    -- Phase 1: city scope. NULL param = no filter (old behavior).
    AND (p_city IS NULL OR p.city IS NULL OR p.city = p_city)
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

COMMENT ON FUNCTION public.search_products(text, uuid, text, double precision, double precision, numeric, numeric, numeric, numeric, text, int, int, text, boolean) IS
  'Public listing search. Since 20261011000001 it also returns the listing''s '
  'own `listing_type` (the shared card says BUY for a good and BOOK for a '
  'service or a room) and it excludes listings with no photo in '
  '`product_images` — a photo-less listing belongs on its provider''s own page, '
  'never in a result grid.';

-- ---------------------------------------------------------------------------
-- 3. Trending: this week's completed work first, then career totals
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ranked_providers(
  p_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  business_name text,
  photo_storage_path text,
  city text,
  provider_type app_role,
  category_id uuid,
  category_name text,
  price_range text,
  completed_transactions bigint,
  rank_position bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_limit integer := GREATEST(COALESCE(p_limit, 20), 1);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  -- The trending window. A week: long enough that a provider with real trade
  -- keeps a place on the rail, short enough that the rail is about now rather
  -- than about the sum of all time.
  v_window interval := interval '7 days';
BEGIN
  RETURN QUERY
  SELECT
    v.id,
    v.business_name,
    v.photo_storage_path,
    v.city,
    v.provider_type,
    v.category_id,
    v.category_name,
    v.price_range,
    v.completed_transactions,
    v.rank_position
  FROM (
    SELECT
      pp.id,
      pp.business_name,
      pp.photo_storage_path,
      pp.city,
      pp.provider_type,
      pp.category_id,
      c.name AS category_name,
      pp.price_range,
      s.completed_transactions,
      row_number() OVER (
        ORDER BY (
          (SELECT count(*) FROM public.orders o
            WHERE o.provider_id = pp.id
              AND o.status = 'COMPLETED'::order_status
              AND o.updated_at >= now() - v_window)
          + (SELECT count(*) FROM public.ride_requests r
              WHERE r.claimed_by_provider_id = pp.id
                AND r.status = 'COMPLETED'::ride_status
                AND r.updated_at >= now() - v_window)
        ) DESC,
        s.completed_transactions DESC,
                 pp.created_at ASC,
                 pp.id ASC
      ) AS rank_position
    FROM public.provider_profiles pp
    LEFT JOIN public.categories c ON c.id = pp.category_id
    JOIN public.provider_transaction_stats() s ON s.provider_id = pp.id
    WHERE pp.status = 'APPROVED'::account_status
      AND (p_category_id IS NULL OR pp.category_id = p_category_id)
      AND (
        p_city IS NULL
        OR btrim(p_city) = ''
        OR pp.city = p_city
        OR pp.city IS NULL
      )
  ) v
  ORDER BY v.rank_position
  LIMIT v_limit OFFSET v_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ranked_providers(uuid, text, integer, integer)
  TO anon, authenticated;

COMMENT ON FUNCTION public.ranked_providers(uuid, text, integer, integer) IS
  'Approved providers from the most to the least transacted. Since '
  '20261011000001 the first key is completed work in the last 7 days (orders '
  'and rides), so the rail reflects the trade happening now; career totals are '
  'the second key and created_at/id the stable tiebreak.';

-- ---------------------------------------------------------------------------
-- 4. The deploy proves its own three claims
-- ---------------------------------------------------------------------------
-- A read that silently loses its predicate still parses, still returns rows and
-- still looks right — which is how each of these three was reported in the
-- first place. So the three bodies are re-read by name at deploy time: if any
-- of them no longer carries its predicate, this file fails loudly here instead
-- of shipping the same bug a third time.

DO $$
DECLARE
  v_visible text;
  v_search text;
  v_ranked text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_visible
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'visible_products_for_city';
  IF v_visible IS NULL OR v_visible NOT ILIKE '%product_images%' THEN
    v_bad := v_bad || ARRAY[
      'visible_products_for_city no longer excludes photo-less listings'];
  END IF;

  SELECT prosrc INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'search_products';
  IF v_search IS NULL OR v_search NOT ILIKE '%product_images%' THEN
    v_bad := v_bad || ARRAY[
      'search_products no longer excludes photo-less listings'];
  END IF;
  IF v_search IS NULL OR v_search NOT ILIKE '%p.listing_type%' THEN
    v_bad := v_bad || ARRAY[
      'search_products no longer projects listing_type — every service it '
      'returns would read BUY'];
  END IF;

  SELECT prosrc INTO v_ranked
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'ranked_providers';
  IF v_ranked IS NULL OR v_ranked NOT ILIKE '%v_window%' THEN
    v_bad := v_bad || ARRAY[
      'ranked_providers is back to ranking by career totals only — the rail '
      'would be the same names in the same order forever'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the public reads are not wired: %',
      array_to_string(v_bad, '; ');
  END IF;
END $$;

notify pgrst, 'reload schema';
