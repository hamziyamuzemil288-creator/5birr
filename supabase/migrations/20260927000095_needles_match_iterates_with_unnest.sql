-- 20260927000095 — the needle table iterated zero times
--
-- THE FAILURE
-- -----------
-- Migration 94 replaced the refused FOREACH with a subscripted loop and the
-- 42804 went away — the function now runs. It then returned:
--
--   FAIL: no needle was checked at all, so this assertion is reporting
--   success without having looked at anything
--
-- The loop body never executed once. `FOR v_i IN 1 ..
-- COALESCE(array_length(v_cases, 1), 0)` evaluated to an empty range.
--
-- Worth being precise about what is and is not known. v_cases was declared
-- text[][] with a nine-row ARRAY, and array_length on that should be 9. This
-- environment has no database access, so the reason the range came out empty
-- could not be observed, only that the effect was. Guessing at it in a comment
-- would be worse than saying so.
--
-- WHAT CHANGES
-- ------------
-- The 2-D array is removed entirely rather than merely re-looped, because the
-- second dimension is the thing that has now failed twice in three attempts:
-- once as a FOREACH loop variable (42804) and once as an array_length bound.
--
-- The needles and their targets are two flat text[] arrays, walked together by
-- Postgres's multi-argument unnest:
--
--   FOR v_needle, v_target_fn IN SELECT * FROM unnest(v_needles, v_targets)
--
-- Two 1-D arrays of text, equal length, unnest in parallel by position. There
-- is no second dimension to index, no bound arithmetic, and no array-typed
-- loop variable, so all three of the things that went wrong are gone rather
-- than worked around.
--
-- The comparison, the messages and the counter are unchanged. The counter is
-- the part worth keeping: it is what turned "this loop silently did nothing"
-- into a red build instead of a green one, and it stays.
--
-- THE GENERAL RULE, RECORDED BECAUSE IT APPLIES TO EVERY ASSERTION HERE
-- ---------------------------------------------------------------------
-- A check that examines nothing and returns success is indistinguishable, in
-- CI, from a check that examined everything and found nothing wrong. The only
-- thing that separates them is an explicit "did I actually look at anything"
-- counter. assert_source_needles_match() has one. assert_approval_welcome_-
-- covers_all_paths(), assert_order_and_ride_receipts_are_sent() and
-- assert_points_conversion_notifies() return a string describing what they
-- checked, which serves the same purpose — and that is the standard the next
-- assertion should meet.

CREATE OR REPLACE FUNCTION public.assert_source_needles_match()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Parallel 1-D arrays rather than one 2-D table. Equal length; walked
  -- together by unnest's multi-argument form.
  v_needles text[] := ARRAY[
    'points-convert:''||v_ledger_id',
    'order-payment-verified:',
    'order-payment-received:',
    'ride-completed:',
    'ride-completed-driver:',
    'provider-approved:',
    'user-approved:',
    'notification_outbox',
    'pg_advisory_xact_lock'
  ];
  v_targets text[] := ARRAY[
    'convert_points_to_wallet',
    'fn_notify_order_status_change',
    'fn_notify_order_status_change',
    'fn_notify_ride_status_change',
    'fn_notify_ride_status_change',
    'approve_provider',
    'approve_user',
    'notify_user_once',
    'notify_user_once'
  ];
  v_needle text;
  v_target_fn text;
  v_src text;
  v_bad text := '';
  v_checked int := 0;
BEGIN
  IF array_length(v_needles, 1) IS DISTINCT FROM array_length(v_targets, 1) THEN
    RETURN 'FAIL: the needle and target lists are different lengths ('
           || coalesce(array_length(v_needles, 1)::text, 'null') || ' vs '
           || coalesce(array_length(v_targets, 1)::text, 'null')
           || '), so needles would be checked against the wrong functions';
  END IF;

  FOR v_needle, v_target_fn IN
    SELECT * FROM unnest(v_needles, v_targets)
  LOOP
    SELECT regexp_replace(lower(pg_proc.prosrc), '[[:space:]]+', ' ', 'g')
      INTO v_src
      FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
     WHERE pg_namespace.nspname = 'public'
       AND pg_proc.proname = v_target_fn;

    IF v_src IS NULL THEN
      v_bad := v_bad || v_target_fn || ' does not exist; ';
      CONTINUE;
    END IF;

    v_checked := v_checked + 1;

    -- Spaces removed from both sides, mirroring what the assertions do, so the
    -- author's line breaks cannot decide the outcome.
    IF position(replace(v_needle, ' ', '') IN replace(v_src, ' ', '')) = 0 THEN
      v_bad := v_bad || v_needle || ' not found in ' || v_target_fn || '; ';
    END IF;
  END LOOP;

  IF v_checked = 0 THEN
    RETURN 'FAIL: no needle was checked at all, so this assertion is reporting '
           || 'success without having looked at anything';
  END IF;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad
           || '. A source-matching assertion whose needle does not occur in '
           || 'its target reports defects that do not exist and passes when '
           || 'it should fail. Two of these shipped and were caught only by a '
           || 'live run.';
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
  'inspect. Two parallel 1-D arrays walked by unnest(a, b): a 2-D table cost '
  'two deploy cycles (FOREACH refuses an array-typed loop variable, 42804; an '
  'array_length subscript bound evaluated to an empty range). The v_checked '
  'counter exists so that examining everything can never be reported as '
  'examining nothing and finding nothing wrong.';

notify pgrst, 'reload schema';
