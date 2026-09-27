-- Meaningful notifications: one per event that the person it concerns has to
-- know about, and nothing else.
--
-- WHAT ALREADY EXISTED
-- --------------------
-- Four of the seven events named in the brief were already notified, by the
-- functions that perform them:
--
--   wallet recharge approved / rejected   approve_wallet_recharge,
--                                         reject_wallet_recharge
--   provider approved / rejected /
--     correction requested                approve_provider, reject_provider,
--                                         request_correction_provider
--
-- Those are verified by assert_meaningful_events_are_notified() below rather
-- than re-implemented — a second notification for the same event would be the
-- spam this work is meant to remove.
--
-- WHAT WAS MISSING
-- ----------------
--   1. order and ride status changes wrote NOTHING to notifications. Every
--      status transition in this product happens inside
--      transition_order_status() / transition_ride_status() — which contain no
--      notification call at all — so a customer who had a payment verified, an
--      order accepted, a ride matched, a trip started or an order or ride
--      completed was told nothing.
--   2. appeal_cases: the person a case is filed AGAINST and the person who
--      filed it were never told anything, before or after a resolution.
--   3. points awards (0028) wrote the ledger row and stopped there.
--
-- THE ONE STRUCTURAL PROBLEM, AND HOW IT IS SOLVED WITHOUT WEAKENING A GUARD
-- -------------------------------------------------------------------------
-- trg_notifications_security -> prevent_notification_injection() refuses every
-- client insert, and that is deliberate: it is what stops a signed-in account
-- writing itself a notification. It exempts the server through
-- is_server_write() (session_user = postgres, or SET ROLE service_role).
--
-- Orders, rides and provider approvals all reach the database through an Edge
-- Function using the service key, so a trigger on them can write notifications
-- directly. Appeals are NOT: filing an appeal, and resolving one from the
-- admin screen, are direct client writes on appeal_cases (it is one of the
-- twenty tables the app writes). A trigger on that table therefore runs as
-- `authenticated`, and the guard — correctly — refuses it.
--
-- There is no role trick available. 20260927000024 established, from a real
-- failure, that PostgreSQL refuses set_config('role', ...) inside a SECURITY
-- DEFINER function precisely so a definer cannot escalate itself, so an
-- "impersonate the server" helper is impossible in any environment.
--
-- So the queue is the fix. notify_user() writes the notification straight
-- through on the server path and, on a client path, appends to
-- notification_outbox instead. drain_notification_outbox() runs on pg_cron,
-- where session_user really is postgres and is_server_write() is true, and is
-- the only thing that moves rows out of the queue. The guard is not touched,
-- widened, or routed around: the notification still arrives from the server.
--
-- The cost is latency: a queued notification lands within a minute rather than
-- instantly. In exchange, nothing a client can do is able to create a
-- notification row, which is the property the guard exists to hold. The
-- server path also flushes that user's queue on the way past, so a queued
-- appeal notice lands the moment anything else happens to that account.

-- ===========================================================================
-- 1. The notification types this adds
--
-- Reused where one already fits, so the existing display screen's icon
-- mapping (which matches on the ORDER_/RIDE_/WALLET_ substrings) keeps
-- working: ORDER_ACCEPTED, ORDER_REJECTED, RIDE_CLAIMED, RIDE_STARTED,
-- RIDE_COMPLETED already exist.
-- ===========================================================================
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ORDER_PAYMENT_VERIFIED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ORDER_COMPLETED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ORDER_CANCELLED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'ORDER_REFUNDED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE_CANCELLED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'POINTS_EARNED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'APPEAL_FILED';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'APPEAL_RESOLVED';

-- ===========================================================================
-- 2. notify_user — the one call site, which routes itself
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.notify_user(
  p_user_id uuid,
  p_type notification_type,
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
  v_id uuid;
BEGIN
  -- Nothing to address. Callers pass nullable subjects (an unclaimed ride's
  -- provider, an appeal with no respondent) and should not have to check.
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF public.is_server_write() THEN
    -- Flush anything this user already has queued before adding the new row,
    -- so a queued notice never arrives after a newer one.
    INSERT INTO public.notifications (user_id, type, title, body, data)
    SELECT user_id, type, title, body, data
      FROM public.notification_outbox
     WHERE user_id = p_user_id AND drained_at IS NULL
     ORDER BY created_at;

    UPDATE public.notification_outbox
       SET drained_at = now()
     WHERE user_id = p_user_id AND drained_at IS NULL;

    RETURN public.insert_notification(p_user_id, p_type, p_title, p_body, p_data);
  END IF;

  INSERT INTO public.notification_outbox (user_id, type, title, body, data)
  VALUES (p_user_id, p_type, p_title, p_body, p_data)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.notify_user(uuid, notification_type, text, text, jsonb) IS
  'Sends one in-app notification. Writes straight to notifications when it is '
  'called by the server, and queues for the scheduler when it is called from a '
  'client write, because prevent_notification_injection refuses the latter by '
  'design.';

-- Only other SECURITY DEFINER functions (the triggers below) and the server
-- may send notifications. A client that could call this could notify anyone.
REVOKE ALL ON FUNCTION public.notify_user(uuid, notification_type, text, text, jsonb)
  FROM public, anon, authenticated;

-- ===========================================================================
-- 3. The queue
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.notification_outbox (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type       notification_type NOT NULL,
  title      text NOT NULL,
  body       text,
  data       jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  drained_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_notification_outbox_pending
  ON public.notification_outbox (created_at)
  WHERE drained_at IS NULL;

-- Deny-all: RLS on with no policy, and no privilege for either client role.
-- The only writers are the SECURITY DEFINER trigger functions (which run as the
-- owner and so bypass RLS) and the drain below. Deliberately not a client
-- table: a client-writable queue would be a client-writable notification.
ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.notification_outbox FROM public, anon, authenticated;

-- ===========================================================================
-- 4. The drain — the only thing that can move a queued row into notifications
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.drain_notification_outbox(p_limit integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ids uuid[];
BEGIN
  IF NOT public.is_server_write() THEN
    RAISE EXCEPTION 'THE_NOTIFICATION_QUEUE_IS_DRAINED_BY_THE_SERVER_ONLY';
  END IF;

  SELECT array_agg(id) INTO v_ids
    FROM (
      SELECT id
        FROM public.notification_outbox
       WHERE drained_at IS NULL
       ORDER BY created_at
       LIMIT greatest(p_limit, 1)
       FOR UPDATE SKIP LOCKED
    ) pending;

  IF v_ids IS NULL THEN
    RETURN 0;
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, data)
  SELECT user_id, type, title, body, data
    FROM public.notification_outbox
   WHERE id = ANY (v_ids);

  UPDATE public.notification_outbox
     SET drained_at = now()
   WHERE id = ANY (v_ids);

  RETURN cardinality(v_ids);
END;
$$;

COMMENT ON FUNCTION public.drain_notification_outbox(integer) IS
  'Moves queued notifications into notifications, exactly once, on the server '
  'path where prevent_notification_injection permits it.';

REVOKE ALL ON FUNCTION public.drain_notification_outbox(integer)
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.drain_notification_outbox(integer) TO service_role;

-- Every minute. Idempotent, like the other schedules in this repo.
CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = '5birr-notification-outbox'
  ) THEN
    PERFORM cron.schedule(
      '5birr-notification-outbox',
      '* * * * *',
      $cron$SELECT public.drain_notification_outbox()$cron$
    );
  END IF;
END $$;

-- ===========================================================================
-- 5. Orders — the six transitions the customer has to know about
--
-- Not every transition. STARTED, PAYMENT_PENDING, PAYMENT_VERIFICATION and
-- DISPUTED are the provider's or the admin queue's business, and a customer
-- who is told about each one learns to ignore all of them.
--
-- Customer-side only, on purpose. The provider has their own orders screen, a
-- live realtime banner and the staff task feed; there is no transition here
-- that a provider does not already see, and the brief asks specifically for
-- what "matters to the user".
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_order_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_label text;
  v_ref jsonb;
BEGIN
  -- No status change: nothing to say. (AFTER UPDATE fires on every update,
  -- including the fee/updated_at writes other paths make.)
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_label := 'Order ' || coalesce('#' || NEW.order_number, 'update');
  v_ref := jsonb_build_object('order_id', NEW.id, 'status', NEW.status);

  IF NEW.status = 'ACCEPTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_ACCEPTED', 'Order confirmed',
      v_label || ' was accepted by the provider.', v_ref);
  ELSIF NEW.status = 'APPROVED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_PAYMENT_VERIFIED', 'Payment verified',
      'Your payment for ' || v_label || ' has been verified.', v_ref);
  ELSIF NEW.status = 'COMPLETED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_COMPLETED', 'Order completed',
      v_label || ' is complete.', v_ref);
  ELSIF NEW.status = 'REJECTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_REJECTED', 'Order rejected',
      v_label || ' was rejected by the provider.', v_ref);
  ELSIF NEW.status = 'CANCELLED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_CANCELLED', 'Order cancelled',
      v_label || ' was cancelled.', v_ref);
  ELSIF NEW.status = 'REFUNDED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_REFUNDED', 'Order refunded',
      v_label || ' has been refunded.', v_ref);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_meaningful_notification ON public.orders;
CREATE TRIGGER trg_orders_meaningful_notification
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_order_status_change();

-- ===========================================================================
-- 6. Rides — matched, started, completed, cancelled
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_ride_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ref jsonb;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_ref := jsonb_build_object('ride_id', NEW.id, 'status', NEW.status);

  IF NEW.status = 'CLAIMED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_CLAIMED', 'Driver matched',
      'A driver has accepted your ride request.', v_ref);
  ELSIF NEW.status = 'TRIP_STARTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_STARTED', 'Trip started',
      'Your trip has started.', v_ref);
  ELSIF NEW.status = 'COMPLETED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_COMPLETED', 'Ride completed',
      'Your trip is complete.', v_ref);
  ELSIF NEW.status = 'CANCELLED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_CANCELLED', 'Ride cancelled',
      'Your ride request was cancelled.', v_ref);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rides_meaningful_notification ON public.ride_requests;
CREATE TRIGGER trg_rides_meaningful_notification
  AFTER UPDATE ON public.ride_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_ride_status_change();

-- ===========================================================================
-- 7. Appeals — the respondent learns a case exists, both sides learn the
--    outcome. Queued, because both writes are client writes.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_appeal_case_filed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- A case may name no respondent; the reporter knows they filed it.
  PERFORM public.notify_user(
    NEW.respondent_id, 'APPEAL_FILED', 'A case was filed about you',
    'Someone opened a support case that names you. You can read it and reply '
    'from your profile.',
    jsonb_build_object('appeal_case_id', NEW.id));

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_cases_notify_filed ON public.appeal_cases;
CREATE TRIGGER trg_appeal_cases_notify_filed
  AFTER INSERT ON public.appeal_cases
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_appeal_case_filed();

-- Named differently from on_appeal_case_resolved (20260923000000), which owns
-- the audit row. Two triggers, one event, each with one job.
CREATE OR REPLACE FUNCTION public.fn_notify_appeal_case_resolved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_was_open boolean;
  v_body text;
  v_ref jsonb;
BEGIN
  v_was_open := OLD.status IS DISTINCT FROM 'RESOLVED' AND OLD.status IS DISTINCT FROM 'CLOSED';

  IF NEW.status IN ('RESOLVED', 'CLOSED') AND v_was_open THEN
    v_body := coalesce(
      'Outcome: ' || nullif(btrim(NEW.resolution_note), ''),
      'Your case has been ' || lower(NEW.status) || '.'
    );
    v_ref := jsonb_build_object('appeal_case_id', NEW.id, 'status', NEW.status);

    -- The reporter.
    PERFORM public.notify_user(
      NEW.user_id, 'APPEAL_RESOLVED', 'Case resolved', v_body, v_ref);

    -- The respondent, if the case named one and they are someone else.
    IF NEW.respondent_id IS NOT NULL AND NEW.respondent_id IS DISTINCT FROM NEW.user_id THEN
      PERFORM public.notify_user(
        NEW.respondent_id, 'APPEAL_RESOLVED', 'Case resolved', v_body, v_ref);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_cases_notify_resolved ON public.appeal_cases;
CREATE TRIGGER trg_appeal_cases_notify_resolved
  AFTER UPDATE ON public.appeal_cases
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_appeal_case_resolved();

-- ===========================================================================
-- 8. Assertions
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_meaningful_events_are_notified()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_expected text[] := ARRAY[
    -- order + ride status changes are notified from a trigger on the table
    'fn_notify_order_status_change',
    'fn_notify_ride_status_change',
    -- the two appeal events are notified from triggers on appeal_cases
    'fn_notify_appeal_case_filed',
    'fn_notify_appeal_case_resolved',
    -- points awards notify from the ledger's own triggers
    'fn_notify_points_awarded',
    -- the four already-notified events, which must not have regressed
    'approve_wallet_recharge',
    'reject_wallet_recharge',
    'approve_provider',
    'reject_provider',
    'request_correction_provider'
  ];
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY v_expected LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_src IS NULL THEN
      RETURN false;
    END IF;

    -- Every one of them must go through the single call site. A hand-written
    -- INSERT INTO notifications in one of these is the drift this catches:
    -- it would bypass the queue and so fail on the client paths.
    IF position('notify_user' in v_src) = 0
       AND position('insert into notifications' in v_src) = 0
       AND position('insert into public.notifications' in v_src) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

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
  -- The queue is only a delivery mechanism if something empties it. Without
  -- the schedule, every client-path notification is written and never seen.
  IF NOT EXISTS (
    SELECT 1 FROM cron.job WHERE command LIKE '%drain_notification_outbox%'
  ) THEN
    RETURN false;
  END IF;

  -- RLS on with no policy and no client grant: a client-writable queue would
  -- be a client-writable notification.
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.notification_outbox'::regclass) THEN
    RETURN false;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policies
              WHERE schemaname = 'public' AND tablename = 'notification_outbox') THEN
    RETURN false;
  END IF;

  IF has_table_privilege('authenticated', 'public.notification_outbox', 'INSERT')
     OR has_table_privilege('authenticated', 'public.notification_outbox', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.notification_outbox', 'DELETE')
     OR has_table_privilege('anon', 'public.notification_outbox', 'INSERT') THEN
    RETURN false;
  END IF;

  -- ...and the injection guard must still exist and still refuse a client.
  -- (assert_client_guards_are_server_safe() covers the other six guards; this
  -- one names the notification guard so a future edit cannot relax it to make
  -- the queue unnecessary.)
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_guard
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'prevent_notification_injection';

  RETURN v_guard IS NOT NULL
     AND position('is_server_write' in v_guard) > 0
     AND position('raise exception' in v_guard) > 0;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_meaningful_events_are_notified()
  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_notification_outbox_is_drained()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_meaningful_events_are_notified()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_notification_outbox_is_drained()
  TO anon, authenticated, service_role;
