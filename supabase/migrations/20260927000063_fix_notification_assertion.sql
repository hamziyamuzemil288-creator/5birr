-- 20260927000063_fix_notification_assertion.sql
--
-- Fixes a false alarm in the connectivity suite, and makes the next real one
-- self-diagnosing.
--
-- WHAT WAS HAPPENING: `assert_meaningful_events_are_notified()` (58) has been
-- returning false on the live database since it was written. Its test in
-- tools/integration_test/connectivity_test.dart reported only
--
--     Expected: true
--       Actual: <false>
--
-- with no indication of which of the ten functions it walks had failed, so the
-- red pipeline looked like a broken notification feature. It is not: the
-- assertion is checking for one of three literal spellings —
-- `notify_user`, `insert into notifications`, `insert into public.notifications`
-- — and `approve_wallet_recharge()` sends its notification through
-- `insert_notification(...)`, the older admin-path helper it was refactored
-- onto in 20260927000020. The notification is delivered; the pattern list was
-- incomplete. Nothing about the notification feature was ever broken.
--
-- WHY THE HELPER IS LEGITIMATE HERE, rather than something to "fix": the
-- injection guard `prevent_notification_injection()` exempts verified admins
-- on purpose — its own comment records that dropping the `is_admin()` case
-- broke `admin_cash_recharge` and `admin_wallet_adjustment`, which write their
-- audit notification from inside the RPC while being called from the app with
-- the admin's own JWT. `approve_wallet_recharge` / `reject_wallet_recharge` are
-- the same shape of function. A direct insert from an admin-reachable RPC is
-- therefore allowed by design; what the guard forbids is an *ordinary* client
-- writing itself a notification, and that is untouched here.
--
-- WHAT CHANGED: both assertions now name the failing function and the value
-- they saw. An assertion that answers "false" and nothing else costs a CI
-- cycle and an afternoon of guessing — this one cost exactly that.
--
-- Also: the outbox assertion no longer returns a bare false for five different
-- reasons; each condition has its own message.
--
-- Safety: replaces two assertion functions only. No policy, table, trigger or
-- business logic is touched, and both keep their names, signatures, return
-- types and grants.

-- =========================================================
-- 1. Every meaningful event still notifies
-- =========================================================
CREATE OR REPLACE FUNCTION public.assert_meaningful_events_are_notified()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_expected text[] := ARRAY[
    -- order + ride status changes, notified from a trigger on the table
    'fn_notify_order_status_change',
    'fn_notify_ride_status_change',
    -- the two appeal events, from triggers on appeal_cases
    'fn_notify_appeal_case_filed',
    'fn_notify_appeal_case_resolved',
    -- points awards, from the ledger's own trigger
    'fn_notify_points_awarded',
    -- the events that were already notified before 58, which must not regress
    'approve_wallet_recharge',
    'reject_wallet_recharge',
    'approve_provider',
    'reject_provider',
    'request_correction_provider'
  ];
  v_name text;
  v_src text;
  v_via_queue boolean;
  v_via_insert boolean;
  v_via_helper boolean;
BEGIN
  FOREACH v_name IN ARRAY v_expected LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_src IS NULL THEN
      RAISE EXCEPTION
        'NOTIFICATION_REGRESSION: public.%() does not exist, so the event it carried notifies nobody',
        v_name;
    END IF;

    -- Three legitimate delivery routes:
    --   notify_user()            — the queue-aware path, preferred
    --   insert into notifications — a direct insert (server path, or an
    --                               admin-gated RPC the guard lets through)
    --   insert_notification(      — the older helper the wallet functions use
    v_via_queue := position('notify_user' in v_src) > 0;
    v_via_insert := position('insert into notifications' in v_src) > 0
                 OR position('insert into public.notifications' in v_src) > 0;
    v_via_helper := position('insert_notification(' in v_src) > 0;

    IF NOT (v_via_queue OR v_via_insert OR v_via_helper) THEN
      RAISE EXCEPTION
        'NOTIFICATION_REGRESSION: public.%() contains none of notify_user(), '
        'insert_notification() or a direct insert into notifications, so the '
        'event it handles notifies nobody',
        v_name;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_meaningful_events_are_notified() FROM public;
GRANT EXECUTE ON FUNCTION public.assert_meaningful_events_are_notified() TO anon, authenticated, service_role;

-- =========================================================
-- 2. The queue is still a delivery mechanism, not a graveyard
-- =========================================================
CREATE OR REPLACE FUNCTION public.assert_notification_outbox_is_drained()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_guard text;
BEGIN
  -- The queue only delivers if something empties it. Without the schedule,
  -- every client-path notification is written and never seen.
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE command LIKE '%drain_notification_outbox%'
  ) THEN
    RAISE EXCEPTION
      'NOTIFICATION_OUTBOX: no cron.job runs drain_notification_outbox(), so '
      'every notification written from a client path is queued and never delivered';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = 'public.notification_outbox'::regclass) THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX: public.notification_outbox does not exist';
  END IF;

  -- RLS on with no policy and no client grant: a client-writable queue would
  -- be a client-writable notification.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.notification_outbox'::regclass) THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX: row level security is off on notification_outbox';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'notification_outbox') THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX: notification_outbox has an RLS policy, which means a client can reach it';
  END IF;

  IF has_table_privilege('authenticated', 'public.notification_outbox', 'INSERT')
     OR has_table_privilege('authenticated', 'public.notification_outbox', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.notification_outbox', 'DELETE')
     OR has_table_privilege('anon', 'public.notification_outbox', 'INSERT') THEN
    RAISE EXCEPTION 'NOTIFICATION_OUTBOX: notification_outbox is writable by a client role';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_guard
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'prevent_notification_injection';

  IF v_guard IS NULL THEN
    RAISE EXCEPTION 'NOTIFICATION_GUARD: prevent_notification_injection() is missing';
  END IF;
  IF position('is_server_write' in v_guard) = 0 THEN
    RAISE EXCEPTION
      'NOTIFICATION_GUARD: prevent_notification_injection() no longer consults '
      'is_server_write(), so it can no longer tell a server write from a client one';
  END IF;
  IF position('raise exception' in v_guard) = 0 THEN
    RAISE EXCEPTION 'NOTIFICATION_GUARD: prevent_notification_injection() no longer raises, so it blocks nothing';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_notification_outbox_is_drained() FROM public;
GRANT EXECUTE ON FUNCTION public.assert_notification_outbox_is_drained() TO anon, authenticated, service_role;
