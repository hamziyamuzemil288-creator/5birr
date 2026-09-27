-- Ranks: a status ladder over the points the account already earns.
--
-- THE LADDER IS DATA, NOT DART
-- ----------------------------
-- The thresholds live in system_settings under `rank_tiers`, as a JSON array,
-- for one concrete reason: the generic admin settings editor added in
-- 20260927000059 writes system_settings keys, so putting the ladder there
-- means the CEO can retune it from the screen they already have, with no
-- migration and no app release. A dedicated table would have needed a
-- dedicated editor to reach the same place.
--
-- admin_update_setting() type-checks the value against validate_rank_tiers()
-- (added in 59) before it is stored, so the array cannot be saved in a shape
-- the readers below would choke on: not an object per tier, a missing
-- min_points, duplicate codes, or thresholds that do not ascend.
--
-- NOTHING IS GATED BY RANK. This is the trust/visibility surface only: a
-- badge, a colour, and a distance to the next rung. No feature in this app
-- reads rank to decide whether an action is allowed.
--
-- PRIVACY OF THE BADGE LOOKUP
-- ---------------------------
-- A badge has to appear next to OTHER people's names — a product listing, an
-- order, a review — and `user_points` is readable only by its owner and by an
-- admin. points_rank_for_subjects() is the read that makes that possible: it
-- resolves a set of ids server-side and returns the TIER, and deliberately not
-- the point total. The ladder is public; a stranger's exact balance is not.

-- ===========================================================================
-- 1. The default ladder
--
-- Bronze is the first rung, so an account below 100 points holds no rank yet
-- and its progress reads as a distance to Bronze — which is what makes
-- "240 / 1,000 to Silver" a real number from the very first trade.
-- ===========================================================================
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

INSERT INTO public.system_settings (key, value, description) VALUES
  ('rank_tiers',
   '[
      {"code": "BRONZE",   "name": "Bronze",   "min_points": 100,    "color": "#A9714B"},
      {"code": "SILVER",   "name": "Silver",   "min_points": 1000,   "color": "#7C8B99"},
      {"code": "GOLD",     "name": "Gold",     "min_points": 5000,   "color": "#B08A1E"},
      {"code": "PLATINUM", "name": "Platinum", "min_points": 20000,  "color": "#17786F"},
      {"code": "DIAMOND",  "name": "Diamond",  "min_points": 75000,  "color": "#1565C0"},
      {"code": "LEGEND",   "name": "Legend",   "min_points": 200000, "color": "#5E35B1"}
    ]'::jsonb,
   'Rank ladder: a JSON array of {"code","name","min_points","color"}. min_points must ascend. Codes must be unique')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;

-- ===========================================================================
-- 2. Reading the ladder
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.points_rank_tiers()
RETURNS TABLE(
  code text,
  name text,
  min_points integer,
  color text,
  sort_order integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    tier ->> 'code'                        AS code,
    tier ->> 'name'                        AS name,
    (tier ->> 'min_points')::integer       AS min_points,
    coalesce(nullif(tier ->> 'color', ''), '#8A8A8A') AS color,
    (row_number() OVER (ORDER BY (tier ->> 'min_points')::integer))::integer AS sort_order
  FROM public.system_settings s,
       jsonb_array_elements(s.value) AS tier
  WHERE s.key = 'rank_tiers';
$$;

COMMENT ON FUNCTION public.points_rank_tiers() IS
  'The rank ladder, parsed from the rank_tiers setting. The client renders '
  'badges and progress from this rather than from thresholds compiled into '
  'the app.';

-- NULL below the lowest rung: an account with no rank yet is not Bronze.
CREATE OR REPLACE FUNCTION public.points_rank_code(p_points integer)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT (
    SELECT tier ->> 'code'
      FROM public.system_settings s,
           jsonb_array_elements(s.value) AS tier
     WHERE s.key = 'rank_tiers'
       AND (tier ->> 'min_points')::integer <= greatest(coalesce(p_points, 0), 0)
     ORDER BY (tier ->> 'min_points')::integer DESC
     LIMIT 1
  );
$$;

-- ===========================================================================
-- 3. Tier for a set of people, for badges next to their names
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.points_rank_for_subjects(
  p_user_ids uuid[] DEFAULT '{}'::uuid[],
  p_provider_ids uuid[] DEFAULT '{}'::uuid[]
)
RETURNS TABLE(
  subject_type text,
  subject_id uuid,
  rank_code text,
  rank_name text,
  rank_color text,
  rank_min_points integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH subjects AS (
    SELECT 'USER'::text AS subject_type, u AS subject_id
      FROM unnest(coalesce(p_user_ids, '{}'::uuid[])) AS u
    UNION ALL
    SELECT 'PROVIDER'::text, p
      FROM unnest(coalesce(p_provider_ids, '{}'::uuid[])) AS p
  ),
  scored AS (
    SELECT s.subject_type,
           s.subject_id,
           coalesce(up.points, 0) AS points
      FROM subjects s
      LEFT JOIN public.user_points up
        ON up.subject_type = s.subject_type
       AND up.subject_id = s.subject_id
  )
  SELECT sc.subject_type,
         sc.subject_id,
         tier.rank_code,
         tier.rank_name,
         tier.rank_color,
         tier.rank_min_points
    FROM scored sc
    LEFT JOIN LATERAL (
      SELECT
        t ->> 'code'                     AS rank_code,
        t ->> 'name'                     AS rank_name,
        coalesce(nullif(t ->> 'color', ''), '#8A8A8A') AS rank_color,
        (t ->> 'min_points')::integer    AS rank_min_points
      FROM public.system_settings s,
           jsonb_array_elements(s.value) AS t
      WHERE s.key = 'rank_tiers'
        AND (t ->> 'min_points')::integer <= sc.points
      ORDER BY (t ->> 'min_points')::integer DESC
      LIMIT 1
    ) tier ON true;
$$;

COMMENT ON FUNCTION public.points_rank_for_subjects(uuid[], uuid[]) IS
  'Rank tier for a set of users and provider profiles, for badges next to a '
  'name. Returns the tier only, never the point total: the ladder is public, '
  'a stranger''s balance is not.';

REVOKE ALL ON FUNCTION public.points_rank_tiers() FROM public, anon;
REVOKE ALL ON FUNCTION public.points_rank_code(integer) FROM public, anon;
REVOKE ALL ON FUNCTION public.points_rank_for_subjects(uuid[], uuid[]) FROM public, anon;

GRANT EXECUTE ON FUNCTION public.points_rank_tiers() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.points_rank_code(integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.points_rank_for_subjects(uuid[], uuid[])
  TO authenticated, service_role;

-- ===========================================================================
-- 4. Assertion
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_rank_ladder_is_consistent()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_value jsonb;
  v_first_min integer;
  v_first_code text;
  v_tier_count integer;
BEGIN
  SELECT value INTO v_value FROM public.system_settings WHERE key = 'rank_tiers';
  IF v_value IS NULL THEN
    RETURN false;
  END IF;

  -- Same validator the settings editor runs, so a value that saved is a value
  -- that reads.
  IF public.validate_rank_tiers(v_value) IS NOT NULL THEN
    RETURN false;
  END IF;

  SELECT count(*) INTO v_tier_count FROM public.points_rank_tiers();
  IF v_tier_count < 2 OR v_tier_count <> jsonb_array_length(v_value) THEN
    RETURN false;
  END IF;

  SELECT code, min_points INTO v_first_code, v_first_min
    FROM public.points_rank_tiers() ORDER BY sort_order LIMIT 1;

  IF v_first_min <= 0 THEN
    RETURN false;
  END IF;

  -- The boundary must behave: at the threshold the rank is the rung, one
  -- point below it there is no rank. A ladder that badges a zero-point
  -- account invalidates the whole progress display.
  IF public.points_rank_code(v_first_min) IS DISTINCT FROM v_first_code THEN
    RETURN false;
  END IF;

  IF public.points_rank_code(v_first_min - 1) IS NOT NULL THEN
    RETURN false;
  END IF;

  -- The top rung must be reachable as a rank rather than only as a threshold.
  IF public.points_rank_code(
       (SELECT max(min_points) FROM public.points_rank_tiers())
     ) IS NULL THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_rank_ladder_is_consistent()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_rank_ladder_is_consistent()
  TO anon, authenticated, service_role;
