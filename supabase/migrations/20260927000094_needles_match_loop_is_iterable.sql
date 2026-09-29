-- 20260927000094 — assert_source_needles_match() could not run at all
--
-- THE FAILURE
-- -----------
--   PostgrestException: FOREACH loop variable must not be of an array type
--   (code 42804)
--
-- Migration 93 declared the source needles and added
-- assert_source_needles_match() to check them. The migration applied cleanly
-- and every other assertion passed — this one raised the moment it was called.
--
-- The bug is one line. plpgsql's FOREACH iterates a single-dimension array and
-- explicitly refuses an array-typed loop variable, and the loop variable here
-- was itself text[] because each row of v_cases is a (needle, target) pair:
--
--   v_cases text[][] := ARRAY[ ARRAY['needle','fn'], ... ];
--   FOREACH v_row IN ARRAY v_cases LOOP     -- v_row is text[]: refused
--
-- A subscripted FOR loop handles a multi-dimensional array, and is what this
-- wanted all along.
--
-- WHY A DEPLOY DID NOT CATCH IT
-- -----------------------------
-- Worth recording, because it is the same shape as everything else in this
-- series: the check was wrong, and nothing else could have noticed.
--
--   * `db push` succeeded. CREATE FUNCTION does not parse or plan a plpgsql
--     body, so a body that cannot run is created happily. Only calling it
--     raises. Every migration in this series that "applied successfully" has
--     still needed a live call to prove anything.
--   * assert_every_assertion_is_reachable() passed it, correctly: the function
--     exists and anon may execute it. Reachability is not correctness, and
--     conflating the two is how a broken assertion gets reported as a working
--     safety net.
--   * The static harness could not see it either — it reads the .sql, and the
--     text of a wrong FOREACH is indistinguishable from the text of a right
--     one without a plpgsql parser.
--
-- So the only thing that found it was Connectivity CI calling it. That is the
-- safety net doing the one job nothing else can.
--
-- WHAT IS FIXED
-- -------------
-- Only the loop. The declared needle list, the whitespace-stripped comparison
-- and the failure message are unchanged, because the function was never
-- correct-but-unrun: it was simply never run.

CREATE OR REPLACE FUNCTION public.assert_source_needles_match()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- needle, target function it must occur in
  v_cases text[][] := ARRAY[
    -- The typo that shipped: v_ledgerid for v_ledger_id.
    ARRAY['points-convert:''||v_ledger_id', 'convert_points_to_wallet'],
    ARRAY['order-payment-verified:',         'fn_notify_order_status_change'],
    ARRAY['order-payment-received:',         'fn_notify_order_status_change'],
    ARRAY['ride-completed:',                 'fn_notify_ride_status_change'],
    ARRAY['ride-completed-driver:',          'fn_notify_ride_status_change'],
    ARRAY['provider-approved:',              'approve_provider'],
    ARRAY['user-approved:',                  'approve_user'],
    ARRAY['notification_outbox',             'notify_user_once'],
    ARRAY['pg_advisory_xact_lock',           'notify_user_once']
  ];
  v_row text[];
  v_target text;
  v_bad text := '';
  v_checked int := 0;
  v_i int;
BEGIN
  -- A subscripted FOR over a 2-D array. FOREACH cannot be used here: its loop
  -- variable may not itself be an array (42804), and each row of v_cases is a
  -- (needle, target) pair.
  FOR v_i IN 1 .. COALESCE(array_length(v_cases, 1), 0) LOOP
    v_row := v_cases[v_i];

    SELECT regexp_replace(lower(pg_proc.prosrc), '[[:space:]]+', ' ', 'g')
      INTO v_target
      FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
     WHERE pg_namespace.nspname = 'public'
       AND pg_proc.proname = v_row[2];

    IF v_target IS NULL THEN
      v_bad := v_bad || v_row[2] || ' does not exist; ';
      CONTINUE;
    END IF;

    v_checked := v_checked + 1;

    -- Spaces removed from both sides, mirroring what the assertions do, so the
    -- author's line breaks cannot decide the outcome.
    IF position(replace(v_row[1], ' ', '') IN replace(v_target, ' ', '')) = 0 THEN
      v_bad := v_bad || v_row[1] || ' not found in ' || v_row[2] || '; ';
    END IF;
  END LOOP;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad
           || '. A source-matching assertion whose needle does not occur in '
           || 'its target reports defects that do not exist and passes when '
           || 'it should fail. Two of these shipped and were caught only by a '
           || 'live run.';
  END IF;

  IF v_checked = 0 THEN
    RETURN 'FAIL: no needle was checked at all, so this assertion is reporting '
           || 'success without having looked at anything';
  END IF;

  RETURN 'ok: all ' || v_checked::text
         || ' declared source needle(s) occur in the function bodies they '
         || 'inspect, so the source-matching assertions are comparing against '
         || 'text that is actually there';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_source_needles_match()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_source_needles_match()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_source_needles_match() IS
  'Checks that the declared source needles occur in the function bodies they '
  'inspect. Iterates the 2-D needle table with a subscripted FOR: plpgsql '
  'FOREACH refuses an array-typed loop variable (42804), which is why the '
  'first version of this function deployed cleanly and raised on every call.';

notify pgrst, 'reload schema';
