-- Regression test for search_products proximity scoping.
-- Run against a database built from the real deploy lineage.
-- Prints "PASS <name> ..." / "FAIL <name> ..." lines.

-- A thin wrapper so every call names the 14-argument overload explicitly:
-- a 12-arg variant also exists, and partial named-argument calls are
-- ambiguous between the two.
CREATE OR REPLACE FUNCTION pg_temp.sp(
  q text, lat float8, lng float8, radius numeric, sortby text,
  lim int, city text, global boolean
) RETURNS TABLE(name text, distance_km numeric) LANGUAGE sql AS $$
  SELECT s.name, s.distance_km
  FROM public.search_products(
    p_query := q, p_category_id := NULL::uuid, p_sector := NULL::text,
    p_lat := lat, p_lng := lng, p_radius_km := radius,
    p_min_price := NULL::numeric, p_max_price := NULL::numeric,
    p_min_rating := NULL::numeric, p_sort_by := sortby,
    p_limit := lim, p_offset := 0, p_city := city,
    p_include_global := global) s;
$$;

-- ── Fixtures ───────────────────────────────────────────────────────────────
-- search_vector is a plain tsvector column in the deployed schema, not a
-- generated one, so each fixture populates it the way a real listing would.
DO $$
DECLARE
  v_uid uuid;
  v_pid uuid;
BEGIN
  DELETE FROM public.products WHERE name LIKE 'geo-test-%';
  DELETE FROM public.provider_profiles WHERE business_name = 'Geo Test Provider';
  DELETE FROM public.profiles WHERE full_name = 'Geo Test Owner';
  DELETE FROM auth.users WHERE email = 'geo-test-owner@test.local';

  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password,
                          email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                          created_at, updated_at)
  VALUES ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
          'authenticated', 'authenticated', 'geo-test-owner@test.local',
          'x', now(), '{}'::jsonb, NULL, now(), now())
  RETURNING id INTO v_uid;

  -- provider_profiles must start PENDING_APPROVAL (signup-chain guard) and
  -- carry a provider_type (the profile trigger assigns a role from it).
  INSERT INTO public.provider_profiles (user_id, business_name, status, provider_type)
  VALUES (v_uid, 'Geo Test Provider', 'PENDING_APPROVAL', 'VEHICLE_PROVIDER')
  RETURNING id INTO v_pid;
  UPDATE public.provider_profiles SET status = 'APPROVED' WHERE id = v_pid;

  -- Nearby, in-city, located ~0.4 km from the query point, so a 1 km radius
  -- genuinely includes it (Addis Ababa)
  INSERT INTO public.products (provider_id, name, price, city, location, search_vector)
  VALUES (v_pid, 'geo-test-near', 100, 'Addis Ababa',
          ST_SetSRID(ST_MakePoint(38.702, 9.002), 4326)::geography,
          to_tsvector('simple', 'geo-test-near'));
  -- Same city, no coordinates recorded
  INSERT INTO public.products (provider_id, name, price, city, location, search_vector)
  VALUES (v_pid, 'geo-test-near-noloc', 100, 'Addis Ababa', NULL,
          to_tsvector('simple', 'geo-test-near-noloc'));
  -- Located but in another country (Nairobi ~ -1.29 36.81)
  INSERT INTO public.products (provider_id, name, price, city, location, search_vector)
  VALUES (v_pid, 'geo-test-far', 100, 'Nairobi',
          ST_SetSRID(ST_MakePoint(36.81, -1.29), 4326)::geography,
          to_tsvector('simple', 'geo-test-far'));
  -- No city, no coordinates: a "global" listing
  INSERT INTO public.products (provider_id, name, price, city, location, search_vector)
  VALUES (v_pid, 'geo-test-global', 100, NULL, NULL,
          to_tsvector('simple', 'geo-test-global'));
END $$;

-- ── A: the client's actual call shape (lat/lng, NO radius, distance sort) ─
-- Regression: a NULL radius made ST_DWithin return NULL, dropping every located
-- listing, so only the location-less rows survived.
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', 9.0, 38.7, NULL, 'distance', 50, 'Addis Ababa', true);
  IF 'geo-test-near' = ANY(r) THEN
    RAISE NOTICE 'PASS A_near_listing_survives_without_radius — %', r;
  ELSE
    RAISE NOTICE 'FAIL A_near_listing_survives_without_radius — %', r;
  END IF;
  IF 'geo-test-far' <> ALL(r) THEN
    RAISE NOTICE 'PASS A_far_country_excluded — %', r;
  ELSE
    RAISE NOTICE 'FAIL A_far_country_excluded — %', r;
  END IF;
  -- Unlocatable rows may still appear (no distance to judge them by), but the
  -- server's own distance sort must lead with the located nearby item.
  IF (SELECT name FROM pg_temp.sp('geo', 9.0, 38.7, NULL, 'distance', 50,
                                 'Addis Ababa', true) LIMIT 1) = 'geo-test-near' THEN
    RAISE NOTICE 'PASS A_nearby_ranks_first';
  ELSE
    RAISE NOTICE 'FAIL A_nearby_ranks_first';
  END IF;
END $$;

-- ── B: p_include_global := false drops city-less listings ────────────────
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', 9.0, 38.7, NULL, 'distance', 50, 'Addis Ababa', false);
  IF 'geo-test-global' <> ALL(r) AND 'geo-test-near' = ANY(r) THEN
    RAISE NOTICE 'PASS B_include_global_false_is_strictly_local — %', r;
  ELSE
    RAISE NOTICE 'FAIL B_include_global_false_is_strictly_local — %', r;
  END IF;
END $$;

-- ── C: no position at all — unchanged legacy behavior (everything shows) ──
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', NULL, NULL, NULL, 'relevance', 50, NULL, true);
  IF r @> ARRAY['geo-test-near','geo-test-far','geo-test-global'] THEN
    RAISE NOTICE 'PASS C_no_position_returns_everything — %', r;
  ELSE
    RAISE NOTICE 'FAIL C_no_position_returns_everything — %', r;
  END IF;
END $$;

-- ── D: an explicit tight radius is honored, with no city given ────────────
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', 9.0, 38.7, 1, 'distance', 50, NULL, true);
  IF 'geo-test-near' = ANY(r) AND 'geo-test-far' <> ALL(r) THEN
    RAISE NOTICE 'PASS D_explicit_radius_honored — %', r;
  ELSE
    RAISE NOTICE 'FAIL D_explicit_radius_honored — %', r;
  END IF;
END $$;

-- ── E: a wide explicit radius lets the far listing back in ────────────────
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', 9.0, 38.7, 10000, 'distance', 50, NULL, true);
  IF 'geo-test-far' = ANY(r) THEN
    RAISE NOTICE 'PASS E_wide_radius_includes_far — %', r;
  ELSE
    RAISE NOTICE 'FAIL E_wide_radius_includes_far — %', r;
  END IF;
END $$;

-- ── F: a city filter with no position still scopes to that city ───────────
DO $$
DECLARE r text[];
BEGIN
  SELECT array_agg(name ORDER BY name) INTO r
    FROM pg_temp.sp('geo', NULL, NULL, NULL, 'relevance', 50, 'Addis Ababa', false);
  IF r @> ARRAY['geo-test-near'] AND 'geo-test-far' <> ALL(r)
     AND 'geo-test-global' <> ALL(r) THEN
    RAISE NOTICE 'PASS F_city_scope_without_gps — %', r;
  ELSE
    RAISE NOTICE 'FAIL F_city_scope_without_gps — %', r;
  END IF;
END $$;

-- ── cleanup ───────────────────────────────────────────────────────────────
DELETE FROM public.products WHERE name LIKE 'geo-test-%';
DELETE FROM public.provider_profiles WHERE business_name = 'Geo Test Provider';
DELETE FROM public.profiles WHERE full_name = 'Geo Test Owner';
DELETE FROM auth.users WHERE email = 'geo-test-owner@test.local';
