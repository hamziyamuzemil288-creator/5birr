-- 5BIRR Resilience & Security Hardening
-- Migration 0024_resilience_hardening.sql
-- 1. Sanitize ILIKE patterns in search_providers to prevent wildcard abuse
-- 2. Add comments for rate-limiting guidance on Edge Functions

-- =========================================================
-- 1. FIX: Sanitize ILIKE wildcards in search_providers
-- The original function concatenated p_query directly into ILIKE
-- patterns, allowing % and _ wildcards to broaden search unexpectedly.
-- =========================================================

CREATE OR REPLACE FUNCTION search_providers(
  p_query text DEFAULT NULL,
  p_provider_type app_role DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_radius_km numeric DEFAULT NULL,
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0
)
RETURNS TABLE (
  id uuid,
  user_id uuid,
  provider_type app_role,
  business_name text,
  owner_national_id text,
  status account_status,
  category_id uuid,
  category_name text,
  distance_km numeric,
  address_text text,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_location geography(Point,4326);
  v_safe_query text;
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;

  -- Sanitize the query: escape ILIKE special characters (% and _)
  -- so user input is treated as literal text, not a wildcard pattern.
  IF p_query IS NOT NULL AND p_query != '' THEN
    v_safe_query := replace(replace(p_query, '%', '\%'), '_', '\_');
  ELSE
    v_safe_query := NULL;
  END IF;

  RETURN QUERY
  SELECT
    pp.id,
    pp.user_id,
    pp.provider_type,
    pp.business_name,
    pp.owner_national_id,
    pp.status,
    pp.category_id,
    c.name AS category_name,
    CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL
      THEN ROUND((ST_Distance(pp.location, v_location) / 1000.0)::numeric, 2)
      ELSE NULL
    END AS distance_km,
    pp.address_text,
    pp.created_at
  FROM provider_profiles pp
  LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED'
    AND (v_safe_query IS NULL
         OR pp.business_name ILIKE '%' || v_safe_query || '%'
         OR pp.address_text ILIKE '%' || v_safe_query || '%')
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type)
    AND (p_category_id IS NULL OR pp.category_id = p_category_id)
    AND (v_location IS NULL OR pp.location IS NULL
         OR ST_DWithin(pp.location, v_location, p_radius_km * 1000))
  ORDER BY
    CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL
      THEN ST_Distance(pp.location, v_location)
      ELSE 999999999 END
  LIMIT p_limit
  OFFSET p_offset;
END;
$$;

-- =========================================================
-- 2. EDGE FUNCTION RATE LIMITING RECOMMENDATION
-- Supabase Edge Functions do not have built-in rate limiting.
-- For production, implement one of:
--
-- Option A: Supabase Edge Function middleware (Deno KV-based)
--   Store request counts per user+function in Deno KV with a TTL.
--   Reject if count exceeds threshold within the window.
--
-- Option B: Supabase custom domain + Cloudflare/AWS WAF rate rules
--   Apply at the CDN level before requests reach Edge Functions.
--
-- Option C: Add a rate_limits table + trigger (database-level):
--
--   CREATE TABLE IF NOT EXISTS rate_limits (
--     id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
--     user_id uuid NOT NULL REFERENCES auth.users(id),
--     endpoint text NOT NULL,
--     window_start timestamptz NOT NULL DEFAULT now(),
--     request_count int NOT NULL DEFAULT 1,
--     UNIQUE (user_id, endpoint, window_start)
--   );
--
--   -- Helper function to check and increment rate
--   CREATE OR REPLACE FUNCTION check_rate_limit(
--     p_user_id uuid,
--     p_endpoint text,
--     p_max_requests int DEFAULT 10,
--     p_window_seconds int DEFAULT 60
--   ) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER AS $$
--   DECLARE
--     v_window timestamptz;
--   BEGIN
--     v_window := date_trunc('second', now()) - (p_window_seconds || ' seconds')::interval;
--     INSERT INTO rate_limits (user_id, endpoint, window_start, request_count)
--     VALUES (p_user_id, p_endpoint, date_trunc('second', now()), 1)
--     ON CONFLICT (user_id, endpoint, window_start)
--     DO UPDATE SET request_count = rate_limits.request_count + 1;
--
--     RETURN (
--       SELECT request_count <= p_max_requests
--       FROM rate_limits
--       WHERE user_id = p_user_id
--         AND endpoint = p_endpoint
--         AND window_start >= v_window
--     );
--   END;
--   $$;
-- =========================================================
