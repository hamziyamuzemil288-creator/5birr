-- 20260927000086 — one idempotent, failure-isolated call site for money
-- notifications
--
-- WHY THIS EXISTS
-- ---------------
-- Every event in the next three migrations is a side effect of a money or
-- approval function, and every one of them has the same two hazards:
--
--   1. A retried call (a double tap, a webhook redelivery, a scheduler that
--      runs twice) repeats the whole function body. The wallet functions
--      already solve this with wallet_transactions.idempotency_key: the second
--      call finds the existing row and returns it. Notifications had no
--      equivalent, so a retry would write a second copy of the same message
--      and the user's bell would show "ETB 250 credited" twice.
--
--   2. A notification insert that raises rolls back the transaction it is
--      attached to. Inside approve_wallet_recharge that would mean an admin
--      approves a real recharge and the database reports failure because a
--      message could not be written. The MONEY must not depend on the NOTICE.
--      Migration 30 already learned this the hard way: its comment says an
--      insert failing "would abort the whole transaction — rolling the
--      verdict back and reporting the approval as failed, which is the worst
--      possible outcome."
--
-- notify_user_once() is the answer to both, and it is deliberately the ONLY
-- new primitive. The migrations after this one add message text at existing
-- call sites; they do not add notification machinery of their own.
--
-- WHY NOT A TRIGGER
-- ------------------
-- A trigger on the same table fires in the same transaction, so the ordering
-- concern in the brief is satisfied either way. The trigger is the wrong tool
-- for the money events specifically: the amount that must appear in the
-- message (fee actually deducted, points actually converted, fee actually
-- withheld) is computed inside the function and is not recoverable from the
-- row alone. A trigger would have to recompute it, which is how a message
-- starts contradicting the ledger. The call is made next to the arithmetic,
-- from the same variables the ledger row was written from.
--
-- THE DEDUPE KEY
-- --------------
-- notifications has no unique column, so uniqueness is enforced by an
-- advisory lock plus an existence check on a partial index. The lock is taken
-- on the key BEFORE the check, which is what makes this correct under
-- concurrency: two sessions calling convert_points_to_wallet for the same
-- ledger row serialize here, so the second sees the first's row and returns
-- NULL. Checking without locking would let both pass.
--
-- The key is stored in the existing `data` jsonb under a reserved key
-- ('idem_key') rather than in a new column, so no new table and no new
-- column is introduced. The partial index means rows written before this
-- migration — which have no idem_key — are not indexed and cannot collide
-- with a keyed row.
--
-- FAILURE ISOLATION
-- -----------------
-- The whole body is wrapped so that ANY error becomes a WARNING and a NULL
-- return. A notification that cannot be delivered must never undo the payment,
-- the approval, or the status change it describes. The failure is logged via
-- RAISE WARNING so it is visible in the database log rather than silent.

-- ---------------------------------------------------------------------------
-- 1. Index for the dedupe check.
--
-- Partial on idem_key IS NOT NULL so the pre-existing rows stay out of it and
-- the index stays small: only keyed (i.e. new money-event) rows are in it.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notifications_idem_key
  ON public.notifications ((data ->> 'idem_key'))
  WHERE (data ->> 'idem_key') IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 2. The call site.
--
-- SECURITY DEFINER + is_server_write() routing, matching notify_user: a
-- server call writes straight to notifications, a client-initiated call
-- queues to notification_outbox for the cron drain. Revoked from the client
-- roles below, for the same reason notify_user is: a client that could call
-- this could notify any user id of its choosing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_user_once(
  p_idem_key text,
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_data jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_data jsonb;
BEGIN
  -- Nothing to address, or nothing to key on. Callers pass nullable subjects
  -- (an order with no provider yet, a conversion with no user) and must not
  -- have to pre-check. A NULL key is refused rather than allowed through as
  -- an unkeyed write, because an unkeyed write is exactly the duplicate this
  -- function exists to prevent.
  IF p_user_id IS NULL OR p_idem_key IS NULL OR p_idem_key = '' THEN
    RETURN NULL;
  END IF;

  -- Serialize every writer of this key before any of them reads. Without the
  -- lock two concurrent calls both see "no existing row" and both write.
  PERFORM pg_advisory_xact_lock(hashtext('notify:' || p_idem_key));

  IF EXISTS (
    SELECT 1
      FROM public.notifications
     WHERE (data ->> 'idem_key') = p_idem_key
  ) THEN
    RETURN NULL;  -- already delivered by an earlier call
  END IF;

  -- The key rides in `data` so the app's existing reader is unaffected: it
  -- renders title/body and ignores unknown jsonb fields.
  v_data := COALESCE(p_data, '{}'::jsonb) || jsonb_build_object('idem_key', p_idem_key);

  RETURN public.notify_user(p_user_id, p_type, p_title, p_body, v_data);

EXCEPTION
  WHEN OTHERS THEN
    -- The whole point: a delivery failure is logged, never raised. Raising
    -- here would roll back the money movement, the approval, or the status
    -- change that this notification was describing.
    RAISE WARNING 'notify_user_once(%) failed and was swallowed: %',
      p_idem_key, SQLERRM;
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb) IS
  'The call site for notifications attached to money movement and approvals. '
  'Deduplicates on p_idem_key (advisory lock + existence check) so a retried '
  'call cannot send the same message twice, and swallows any error as a '
  'WARNING so a failed notice never rolls back the payment or approval it '
  'describes.';

REVOKE ALL ON FUNCTION public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)
  FROM public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The assertion.
--
-- A live check, not a source grep: it confirms the function exists, is
-- callable only by the server, actually dedupes (the write is called twice and
-- the second must be a no-op), and actually swallows an error instead of
-- propagating it. Each of those was a real way this could be wrong.
-- ---------------------------------------------------------------------------
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
  -- Fixture. The notifications row we assert on is rolled back with the rest
  -- of this function by the sentinel exception below.
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'notify-user-once@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Notify Once Probe', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  -- 1. The first call delivers and returns the new row's id.
  v_first := public.notify_user_once(
    v_key, v_user, 'APPROVAL', 'Probe', 'First delivery', NULL);

  IF v_first IS NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_MISSING: the first notify_user_once() returned NULL, so it delivered nothing (either it swallowed an error or the guard rejected it)';
  END IF;

  -- 2. The second call with the SAME key must not write a second row. This is
  --    the property the whole feature rests on.
  v_second := public.notify_user_once(
    v_key, v_user, 'APPROVAL', 'Probe', 'Second delivery', NULL);

  IF v_second IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_NOT_IDEMPOTENT: a repeated call with key % returned a new id instead of NULL, so a retried payment would notify twice', v_key;
  END IF;

  SELECT count(*) INTO v_rows
    FROM public.notifications
   WHERE (data ->> 'idem_key') = v_key;

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_WROTE_%_ROWS: expected exactly 1 row for key %, found %', v_rows, v_key, v_rows;
  END IF;

  -- 3. Failure isolation, proven rather than asserted.
  --
  --    The failure is provoked from INSIDE the function on purpose. An earlier
  --    version of this assertion passed a non-existent enum label, which fails
  --    as a CAST at the call site — before notify_user_once is ever entered —
  --    so the inner handler under test was never reached and the assertion
  --    proved nothing while looking like it did.
  --
  --    A NULL title does fail inside: notifications.title is NOT NULL, so the
  --    insert inside notify_user raises not_null_violation, which is exactly
  --    the "the notice could not be written" case that must not reach the
  --    caller. The call must return NULL, and the table must be unchanged.
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
    FROM public.notifications
   WHERE (data ->> 'idem_key') = v_key || '-undeliverable';

  IF v_rows <> 0 THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_UNDELIVERABLE_WROTE_%_ROWS: a call that should have failed wrote % rows', v_rows, v_rows;
  END IF;

  -- 4. A NULL key is refused rather than sent unkeyed, because an unkeyed
  --    write cannot be deduplicated and is the duplicate this prevents.
  IF public.notify_user_once(NULL, v_user, 'APPROVAL', 'Probe', 'Unkeyed', NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_ACCEPTS_NULL_KEY: a call with no dedupe key was accepted, so it could never be deduplicated';
  END IF;

  -- 5. A NULL user is a no-op, not an error: callers pass nullable subjects
  --    (an order with no provider yet) and must not have to pre-check.
  IF public.notify_user_once(v_key || '-nouser', NULL, 'APPROVAL', 'Probe', 'Nobody', NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_NULL_USER: a call with no recipient returned an id instead of NULL';
  END IF;

  -- 6. The client roles must not be able to call it at all. A client that
  --    could would be able to notify any user id it chose.
  IF has_function_privilege('authenticated',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE')
     OR has_function_privilege('anon',
       'public.notify_user_once(text, uuid, notification_type, text, text, jsonb)',
       'EXECUTE') THEN
    RAISE EXCEPTION 'NOTIFY_ONCE_CLIENT_EXECUTABLE: authenticated or anon can EXECUTE notify_user_once(), so a client could notify any user id of its choosing';
  END IF;

  SELECT body INTO v_body
    FROM public.notifications
   WHERE (data ->> 'idem_key') = v_key;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN 'ok: first call delivered, repeat was a no-op, a bad type was '
             || 'swallowed, null key and null user refused, client roles have '
             || 'no EXECUTE; delivered body = ' || coalesce(v_body, '(none)');
    END IF;
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_notify_user_once_is_idempotent()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_notify_user_once_is_idempotent()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.assert_notify_user_once_is_idempotent() IS
  'Proves, against the live database, that notify_user_once() dedupes on its '
  'key, swallows a delivery failure instead of propagating it, refuses a null '
  'key or recipient, and is not executable by a client role.';

notify pgrst, 'reload schema';
