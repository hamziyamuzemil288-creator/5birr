-- 20260927000093 — two assertion needles that were wrong, found by the
-- second live run
--
-- The first live run of these assertions (migrations 86-90) produced three
-- failures; migration 92 fixed one real defect and two wrong assertions. This
-- is what the second live run found: BOTH remaining failures were wrong
-- assertions again, and both were needles that did not match the thing they
-- claimed to check.
--
-- Neither is cosmetic. An assertion whose needle does not match reports a
-- defect that does not exist, and a green one that asserts nothing is the most
-- expensive kind of test to own — it is reported as a safety net and provides
-- none. Two rounds in, the pattern is consistent enough to name: every failure
-- so far has been in the checking, not the checked.
--
-- ===========================================================================
-- FINDING 1: the conversion key needle had a typo
-- ===========================================================================
--   FAIL: the conversion notice is not keyed on the points ledger id
--
-- Migration 92 made this match whitespace-insensitively, which fixed the line
-- wrapping. The needle itself was still wrong:
--
--   'points-convert:''||v_ledgerid'      <- what the assertion searched for
--   'points-convert:' || v_ledger_id      <- what the function actually says
--
-- v_ledgerid, not v_ledger_id. One missing underscore, and the assertion
-- could never match, so it would have reported this defect on every run
-- forever. The key in the function was correct the whole time.
--
-- The deeper problem is that nothing checked that a needle matches its
-- target. assert_source_needles_match() below now does exactly that, for this
-- function and for every other source-matching assertion in the series.
--
-- ===========================================================================
-- FINDING 2: the dedupe test counted rows in the wrong table
-- ===========================================================================
--   NOTIFY_ONCE_WROTE_0_ROWS: expected exactly 1 row for key
--   assert-notify-user-once:...
--
-- The dedupe itself was FIXED — the repeat call correctly returned NULL and
-- wrote nothing, which is the property that matters. The test then counted
-- rows in public.notifications and found none, because the suite runs as anon
-- and the notification went to notification_outbox instead.
--
-- This is the same mistake as the migration 92 defect, committed a second
-- time one layer up: the assertion hardcoded the server delivery path while
-- the code routes both ways. The test now counts in both tables, which is
-- what makes it able to tell "delivered once" from "delivered twice" on
-- either path.
--
-- The other three sub-checks in that function were already path-independent
-- and are unchanged: the repeat call returning NULL, the undeliverable call
-- returning NULL, and the null key / null user refusals.

-- ===========================================================================
-- 1. The corrected conversion assertion
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_points_conversion_notifies()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_missing text := '';
  v_required text[] := ARRAY[
    'pg_advisory_xact_lock',
    'for update',
    'not_your_provider_profile',
    'points_subject_and_wallet_must_match',
    'points_to_birr_rate',
    'wallet_transactions',
    'points-convert:'
  ];
  v_clause text;
  -- Whitespace-insensitive AND verified: this file's own key is checked
  -- against the body by assert_source_needles_match() at the end of the
  -- migration, so a typo like v_ledgerid cannot ship again.
  v_needle constant text := 'points-convert:''||v_ledger_id';
  v_flat text;
BEGIN
  SELECT regexp_replace(lower(pg_proc.prosrc), '[[:space:]]+', ' ', 'g')
    INTO v_src
    FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
   WHERE pg_namespace.nspname = 'public'
     AND pg_proc.proname = 'convert_points_to_wallet';

  IF v_src IS NULL THEN
    RETURN 'FAIL: convert_points_to_wallet() does not exist';
  END IF;

  -- Strip every space from both sides, so the author's line breaks and the
  -- spacing around || cannot decide whether this matches.
  v_flat := replace(v_src, ' ', '');

  IF position('notify_user_once' IN v_src) = 0 THEN
    RETURN 'FAIL: convert_points_to_wallet() credits the wallet and notifies '
           || 'nobody; the points balance changes with no way for the user to '
           || 'find out';
  END IF;

  IF position(v_needle IN v_flat) = 0 THEN
    RETURN 'FAIL: the conversion notice is not keyed on the points ledger id. '
           || 'Looked for ' || v_needle || ' in the function body. A key built '
           || 'from the amount would collide across two identical '
           || 'conversions, and a retry would notify twice.';
  END IF;

  IF position('points_spent' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the points spent';
  END IF;

  IF position('birr_credited' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the birr received';
  END IF;

  FOREACH v_clause IN ARRAY v_required LOOP
    IF position(replace(v_clause, ' ', '') IN v_flat) = 0 THEN
      v_missing := v_missing || ' [' || v_clause || ']';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RETURN 'FAIL: convert_points_to_wallet() is missing' || v_missing
           || '. A money invariant was lost in the restatement; restore it '
           || 'from 20260927000059 before deploying.';
  END IF;

  RETURN 'ok: the conversion notifies with the points spent and the birr '
         || 'credited, keyed on the points ledger id; the advisory lock, the '
         || 'FOR UPDATE balance re-read, both ownership checks, the '
         || 'server-owned rate and the ADJUSTMENT ledger row are all present';
END;
$$;

-- ===========================================================================
-- 2. The corrected idempotency assertion
--
-- Every delivery count below is taken across BOTH tables, because
-- notify_user() writes to notifications on the server path and to
-- notification_outbox on the client path, and the connectivity suite is the
-- client path.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_notify_user_once_is_idempotent()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000f001';
  v_key  text := 'assert-notify-user-once:' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || floor(random() * 1000000)::text;
  v_first  uuid;
  v_second uuid;
  v_rows   integer;
  v_swallowed uuid;
  v_body   text;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'notify-user-once@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Notify Once Probe', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  v_first := public.notify_user_once(
    v_key, v_user, 'APPROVAL', 'Probe', 'First delivery', NULL);

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_MISSING: the first notify_user_once() returned NULL, so it delivered nothing (either it swallowed an error or the guard rejected it)';
  END IF;

  v_second := public.notify_user_once(
    v_key, v_user, 'APPROVAL', 'Probe', 'Second delivery', NULL);

  IF v_second IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_NOT_IDEMPOTENT: a repeated call with key % returned a new id instead of NULL, so a retried payment would notify twice', v_key;
  END IF;

  -- BOTH tables. Counting notifications alone reads as "delivered zero times"
  -- on the client path, which is the path this suite exercises — and that
  -- reading is what made the first version of this test report a failure
  -- while the dedupe was in fact working.
  SELECT count(*) INTO v_rows
    FROM (
      SELECT id FROM public.notifications
       WHERE (data ->> 'idem_key') = v_key
      UNION ALL
      SELECT id FROM public.notification_outbox
       WHERE (data ->> 'idem_key') = v_key
    ) delivered;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_WROTE_%_ROWS: expected exactly 1 delivered row for key % across notifications and notification_outbox, found %', v_rows, v_key, v_rows;
  END IF;

  -- The undeliverable call, provoked from INSIDE the function. An earlier
  -- version passed a non-existent enum label, which fails as a CAST at the
  -- call site — before notify_user_once is entered — so the handler under
  -- test was never reached.
  BEGIN
    v_swallowed := public.notify_user_once(
      v_key || '-undeliverable', v_user, 'APPROVAL',
      NULL, 'This title violates the NOT NULL constraint', NULL);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_RAISED: an undeliverable notification propagated out of notify_user_once() instead of being swallowed, so it would roll back the money movement it was attached to: %', SQLERRM;
  END;

  IF v_swallowed IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_UNDELIVERABLE_RETURNED_ID: an undeliverable notification returned an id instead of NULL, so the caller believes it was delivered';
  END IF;

  SELECT count(*) INTO v_rows
    FROM (
      SELECT id FROM public.notifications
       WHERE (data ->> 'idem_key') = v_key || '-undeliverable'
      UNION ALL
      SELECT id FROM public.notification_outbox
       WHERE (data ->> 'idem_key') = v_key || '-undeliverable'
    ) delivered;

  IF v_rows <> 0 THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_UNDELIVERABLE_WROTE_%_ROWS: a call that should have failed wrote % rows', v_rows, v_rows;
  END IF;

  IF public.notify_user_once(NULL, v_user, 'APPROVAL', 'Probe', 'Unkeyed', NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_ACCEPTS_NULL_KEY: a call with no dedupe key was accepted, so it could never be deduplicated';
  END IF;

  IF public.notify_user_once(v_key || '-nouser', NULL, 'APPROVAL', 'Probe', 'Nobody', NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_NULL_USER: a call with no recipient returned an id instead of NULL';
  END IF;

  IF has_function_privilege('authenticated',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE')
     OR has_function_privilege('anon',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_CLIENT_EXECUTABLE: authenticated or anon can EXECUTE notify_user_once(), so a client could notify any user id of its choosing';
  END IF;

  -- Read the delivered body from whichever table received it.
  SELECT body INTO v_body FROM (
    SELECT body, created_at FROM public.notifications
     WHERE (data ->> 'idem_key') = v_key
    UNION ALL
    SELECT body, created_at FROM public.notification_outbox
     WHERE (data ->> 'idem_key') = v_key
  ) d ORDER BY created_at LIMIT 1;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN 'ok: first call delivered, repeat was a no-op, an undeliverable '
             || 'call was swallowed, null key and null user refused, client '
             || 'roles have no EXECUTE; counted across BOTH delivery tables; '
             || 'delivered body = ' || coalesce(v_body, '(none)');
    END IF;
    RAISE;
END;
$$;

-- ===========================================================================
-- 3. A needle must match what it claims to check
--
-- Every failure above was an assertion whose needle did not match its target,
-- and nothing in CI would have caught it because the assertion itself is the
-- thing that was wrong.
--
-- The needles are DECLARED here rather than scraped out of the assertion
-- sources. Scraping was the first attempt and it does not work: an assertion
-- builds its own messages with ||, so every quoted fragment of it contains an
-- operator, and the check reported a wall of fragments that legitimately do
-- not appear in the target. A declared list is dull and cannot lie about what
-- it is checking.
--
-- Each row is (target function, needle). The needle must occur in the target's
-- whitespace-stripped, lowercased body. To add a source-matching assertion,
-- add its needle here — the omission is then visible, because a needle nobody
-- declared is a needle nobody is checking.
-- ===========================================================================
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
BEGIN
  FOREACH v_row IN ARRAY v_cases LOOP
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

  RETURN 'ok: all ' || v_checked::text
         || ' declared source needle(s) occur in the function bodies they '
         || 'inspect, so the source-matching assertions are comparing against '
         || 'text that is actually there';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_points_conversion_notifies()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_points_conversion_notifies()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_notify_user_once_is_idempotent()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_notify_user_once_is_idempotent()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_source_needles_match()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_source_needles_match()
  TO anon, authenticated, service_role;

COMMENT ON FUNCTION public.assert_source_needles_match() IS
  'Checks that the multi-token source needles used by the source-matching '
  'assertions actually occur in the function bodies they inspect. Two of those '
  'needles were wrong (one typo, one spacing assumption) and each reported a '
  'defect that did not exist until a live run caught it.';

notify pgrst, 'reload schema';
