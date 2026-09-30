-- =============================================================================
-- 0116 - the task-feed assertion can count again
-- =============================================================================
--
-- 0115 fixed the MIRE of this count and introduced a worse one. The original
-- was:
--
--     SELECT count(*) INTO v_cat_guard FROM (
--       SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x
--     ) d WHERE x <> '';
--
-- `AS x` names the TABLE; the column keeps unnest's own name, so `WHERE x` was
-- `column "x" does not exist` (42703). 0115 answered that by naming the column
-- with an alias list -- `AS x(part)` -- while LEAVING THE SUBQUERY WRAPPED.
-- The subquery projects the CONSTANT `1`, not `part`, so the derived table `d`
-- has exactly one column and it is called `1`. `WHERE part <> ''` was then
-- `column "part" does not exist` (42703) as well.
--
-- The wrapper was never needed. `unnest(...)` in FROM is already a table
-- expression; filtering it directly is the whole query, and the alias then
-- names the one column it produces:
--
--     SELECT count(*) INTO v_cat_guard
--       FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS part
--      WHERE part <> '';
--
-- Both statements parse either way, which is why two rounds of local gates and
-- a whole-file parse let this through and only the live run found it: a
-- reference to a column no subquery projects is a SEMANTIC error, invisible to
-- every parser this repo runs.
--
-- Note this migration is small on purpose. 0115 is applied and must not be
-- edited; the only thing wrong with it is these two statements, so the only
-- thing restated here is the one function that contains them.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.assert_staff_city_scope_covers_the_task_feed()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_feed text;
  v_proof text;
  v_cat_guard int;
  v_city_guard int;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_feed
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'staff_task_feed';

  IF v_feed IS NULL THEN
    RAISE EXCEPTION 'staff_task_feed is missing';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_proof
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'verify_payment_proof';

  IF v_proof IS NULL THEN
    RAISE EXCEPTION 'verify_payment_proof is missing';
  END IF;

  -- The feed carries three category scopes; it must carry three city scopes,
  -- one on each of those branches and NOT on the two uncategorized ones.
  --
  -- Counted by filtering the array directly. An earlier version wrapped this
  -- in `FROM (SELECT 1 FROM unnest(...)) d` and then filtered on a column of
  -- the derived table -- but that subquery projects the constant 1, so the
  -- derived table has no such column and the assertion raised 42703 instead
  -- of counting. `unnest` in FROM is already a table expression; it needs no
  -- wrapper, and the alias names the single column it produces.
  SELECT count(*) INTO v_cat_guard
    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS part
   WHERE part <> '';

  SELECT count(*) INTO v_city_guard
    FROM unnest(string_to_array(v_feed, 'staff_scope_allows_city(')) AS part
   WHERE part <> '';

  IF v_city_guard < v_cat_guard THEN
    RAISE EXCEPTION
      'staff_task_feed carries % category scope(s) but only % city scope(s). '
      'Every categorized branch needs both, or the city axis is a filter the '
      'money queue bypasses.', v_cat_guard, v_city_guard;
  END IF;

  IF position('staff_scope_allows_city' in v_proof) = 0 THEN
    RAISE EXCEPTION 'verify_payment_proof no longer enforces the city scope -- a city-scoped person could verify another city''s payment';
  END IF;

  RETURN true;
END;
$$;
