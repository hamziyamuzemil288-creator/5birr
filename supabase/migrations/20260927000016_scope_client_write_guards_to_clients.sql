-- Scope the client-write guards to clients.
--
-- Same defect as 20260927000015, in the remaining guards. Each of these
-- triggers gates on `is_admin()`, which is `auth.uid()` — NULL for anything
-- the server initiates — so each rejects the server's own writes.
--
-- The order INSERT guard is the urgent one.
--
-- trg_orders_insert_security -> prevent_order_insert_privilege_escalation:
--
--   IF NOT is_admin() THEN
--     IF new.status != 'CREATED' THEN
--       RAISE EXCEPTION 'ORDERS_MUST_START_AS_CREATED';
--     IF new.user_id != auth.uid() THEN
--       RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER';
--
-- create_order_secure() inserts on behalf of a real user but runs as the
-- function owner, so auth.uid() is NULL. That made the second check
-- harmless by accident — `new.user_id != NULL` is NULL, and `IF NULL` does
-- not run its branch. The FIRST check is not so lucky: it compares two
-- non-null values, so it evaluates honestly.
--
-- That check encoded the old convention that orders begin life as CREATED,
-- which 20260927000009 changed to PENDING_PROVIDER. With both in place the
-- guard rejects every order the app creates:
--
--   ERROR: ORDERS_MUST_START_AS_CREATED
--
-- so this is a fix for a regression of our own making, not a new feature.
-- The guard is kept rather than dropped, because "no client INSERT policy"
-- and "the database refuses a client insert anyway" are different defences
-- and both are worth having.
--
-- trg_orders_security -> prevent_order_self_privilege_escalation has the
-- same shape: it raises on any client status change, which is correct, but
-- is expressed in a way that also catches the server. It is restated here
-- for the same reason and with the same client-only scope.
--
-- trg_notifications_security -> prevent_notification_injection already
-- special-cases service_role, but via `current_setting('role')`, and so it
-- still rejects pg_cron. charge_due_subscriptions() calls insert_notification()
-- on the overdue path, outside any exception block, so that raise aborts
-- the whole daily run — the same failure as the suspension one. Moving the
-- exemption to session_user covers both the edge function and the cron job.
--
-- The discriminator is session_user, not current_user: inside a SECURITY
-- DEFINER trigger current_user is always the owner, so a guard written
-- against it would exempt every caller and disable itself.

CREATE OR REPLACE FUNCTION public.prevent_order_insert_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF session_user IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN new;
  END IF;

  -- A client may only start an order in the state the app actually uses.
  -- CREATED is no longer a starting state (20260927000009), so requiring it
  -- here would reject legitimate orders as well as forged ones.
  IF new.status IS DISTINCT FROM 'PENDING_PROVIDER' THEN
    RAISE EXCEPTION 'ORDERS_MUST_START_AS_PENDING_PROVIDER';
  END IF;

  IF new.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER';
  END IF;

  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_order_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF session_user IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'ORDER_STATUS_CHANGE_REQUIRES_SERVER_FUNCTION';
  END IF;

  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_notification_injection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF session_user IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN new;
  END IF;

  RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
END;
$$;

COMMENT ON FUNCTION public.prevent_order_insert_privilege_escalation() IS
  'Refuses a client-inserted order that does not start in PENDING_PROVIDER '
  'or is not for the caller. Server inserts (create_order_secure over '
  'service_role) are exempt via session_user.';

COMMENT ON FUNCTION public.prevent_notification_injection() IS
  'Notifications are written only by the server. Exempts service_role edge '
  'functions and the pg_cron subscription job, which both write '
  'legitimately and were previously rejected.';

-- ── Guard against regressing ─────────────────────────────────────────────
-- All three must be client-scoped, and the order INSERT guard must still
-- refuse a client. Checked on the session_user exemption plus the presence
-- of each raise, so a guard that was emptied rather than scoped fails too.
CREATE OR REPLACE FUNCTION public.assert_client_guards_are_server_safe()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_missing text;
BEGIN
  FOREACH v_missing IN ARRAY ARRAY[
    'prevent_order_insert_privilege_escalation',
    'prevent_order_self_privilege_escalation',
    'prevent_notification_injection'
  ] LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_missing;

    IF v_flat IS NULL THEN
      RETURN false;
    END IF;

    -- Must exempt the server...
    IF position('session_user' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('service_role' in v_flat) = 0 THEN
      RETURN false;
    END IF;

    -- ...and must still refuse a client. A guard that merely returned new
    -- unconditionally would pass the check above, so the raise is required.
    IF position('raise exception' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_client_guards_are_server_safe() IS
  'True when the order and notification write guards exempt server roles via '
  'session_user while still refusing client writes.';

GRANT EXECUTE ON FUNCTION public.assert_client_guards_are_server_safe() TO authenticated;
