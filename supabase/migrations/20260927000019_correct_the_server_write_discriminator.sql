-- Correct the "is this the server?" discriminator used by every client-write guard.
--
-- What went wrong
-- ----------------
-- 20260927000015/16/17 scoped the client-write guards to clients with:
--
--   IF session_user IN ('postgres', 'service_role', 'supabase_admin') THEN
--     RETURN new;
--   END IF;
--
-- That reads correctly but does not work. PostgREST connects to Postgres as the
-- `authenticator` role and then issues SET ROLE for each request. session_user
-- is fixed at connection time and is NOT changed by SET ROLE -- only
-- current_user is. So for every request through the Data API:
--
--   session_user   = authenticator     (always, for anon/authenticated/service_role)
--   current_user   = anon | authenticated | service_role
--
-- Neither session_user nor current_user can identify a service-role call.
-- current_user is worse than useless inside these triggers: they are SECURITY
-- DEFINER, so current_user is the function owner (postgres) for every caller,
-- which is why migration 0030's
--
--   IF current_user IN ('postgres','service_role') THEN RETURN new; END IF;
--
-- made prevent_wallet_direct_balance_edit a no-op -- it exempted every caller,
-- clients included. That guard has been inert in production ever since.
--
-- The session_user form fails in the opposite direction: it exempts pg_cron
-- (which really does connect as postgres) but NOT the edge functions, so
-- subscription-process and the rest were still refused.
--
-- The discriminator that does work
-- --------------------------------
-- Two signals, and they cover the two genuinely different server paths:
--
--   pg_cron (direct connection)     session_user = 'postgres'
--   edge function via service_role  current_setting('role') = 'service_role'
--   a client (anon/authenticated)   session_user = 'authenticator',
--                                   current_setting('role') = 'anon'|'authenticated'
--
-- current_setting('role') is safe against spoofing: changing it means SET ROLE
-- service_role, which requires the caller to already be a member of that role,
-- and `authenticated` is not.
--
-- One helper, so the seven guards cannot drift apart again -- the original bug
-- was that 00015/16/17 each rewrote the same check by hand and 00017 had to go
-- back and extend 00016's assertion to catch up.
--
-- Every client-facing check is preserved verbatim. Only the "is this the
-- server?" question changes.

-- ---------------------------------------------------------------------------
-- The shared discriminator.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_server_write()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT session_user IN ('postgres', 'supabase_admin')
      OR coalesce(pg_catalog.current_setting('role', true), 'none') = 'service_role';
$$;

COMMENT ON FUNCTION public.is_server_write() IS
  'True when the current statement was initiated by the server (pg_cron as '
  'postgres, or an Edge Function calling as service_role) rather than by a '
  'client. session_user cannot be used on its own: PostgREST connects as '
  'authenticator and SET ROLE never changes it, so a service-role call still '
  'reports authenticator. current_user cannot be used at all inside a '
  'SECURITY DEFINER trigger, where it is always the function owner.';

-- ---------------------------------------------------------------------------
-- The seven guards, all re-scoped to the helper.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
  END IF;

  IF new.provider_type IS DISTINCT FROM old.provider_type THEN
    RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
  END IF;

  IF new.subscription_start_date IS DISTINCT FROM old.subscription_start_date THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED';
  END IF;

  IF old.owner_national_id IS NOT NULL
     AND new.owner_national_id IS DISTINCT FROM old.owner_national_id THEN
    RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
  END IF;

  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_order_insert_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
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
  IF public.is_server_write() THEN
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
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_subscription_self_modification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED';
  END IF;

  IF new.next_due_date IS DISTINCT FROM old.next_due_date THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_CANNOT_BE_SELF_MODIFIED';
  END IF;

  RETURN new;
END;
$$;

-- Restores the protection 0030 disabled. The trigger is BEFORE UPDATE, so a
-- client that somehow got UPDATE on a wallet row would otherwise be able to
-- set its own balance. RLS (wallets_admin_all USING is_admin()) is the primary
-- barrier and still holds; this is the defence in depth behind it.
CREATE OR REPLACE FUNCTION public.prevent_wallet_direct_balance_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF new.balance IS DISTINCT FROM old.balance THEN
    RAISE EXCEPTION 'BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION';
  END IF;

  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_wallet_txn_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF old.status = 'COMPLETED' THEN
    RAISE EXCEPTION 'COMPLETED_TRANSACTIONS_CANNOT_BE_MODIFIED';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_wallet_direct_balance_edit() IS
  'Stops a client setting a wallet balance directly. Inert since 0030, which '
  'tested current_user inside a SECURITY DEFINER trigger and so exempted every '
  'caller including clients.';

COMMENT ON FUNCTION public.prevent_wallet_txn_mutation() IS
  'Stops a client editing a COMPLETED ledger row. Exempts the server, which '
  'is what writes those rows in the first place.';

-- ---------------------------------------------------------------------------
-- Assertions.
--
-- assert_server_write_discriminator is the important one: it is behavioural,
-- not a source grep. It evaluates is_server_write() in the caller's own
-- context, which for this suite is a PostgREST call as anon, and requires the
-- answer to be FALSE. A discriminator that returned true for clients -- the
-- 0030 bug -- fails here immediately, whatever its source text says.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_server_write_discriminator()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- This function is reached over the Data API by the test client, so the
  -- only question that matters is whether that client is classified as a
  -- server write. It must not be.
  IF public.is_server_write() THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_server_write_discriminator() IS
  'Behavioural check that is_server_write() is false for the client calling '
  'it. Catches the 0030 failure mode (every caller classified as the server) '
  'without relying on a source-text match.';

GRANT EXECUTE ON FUNCTION public.assert_server_write_discriminator() TO anon, authenticated;

-- All seven guards must route through the helper and must still refuse a
-- client. Checking for the helper rather than for session_user/current_user
-- means a future edit cannot quietly reintroduce either broken form.
CREATE OR REPLACE FUNCTION public.assert_client_guards_are_server_safe()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'prevent_provider_self_privilege_escalation',
    'prevent_order_insert_privilege_escalation',
    'prevent_order_self_privilege_escalation',
    'prevent_notification_injection',
    'prevent_subscription_self_modification',
    'prevent_wallet_direct_balance_edit',
    'prevent_wallet_txn_mutation'
  ] LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_flat IS NULL THEN
      RETURN false;
    END IF;

    -- Must route through the shared discriminator...
    IF position('is_server_write' in v_flat) = 0 THEN
      RETURN false;
    END IF;

    -- ...and must still refuse a client. A guard that merely RETURN NEW
    -- unconditionally would pass the check above, so the raise is required.
    IF position('raise exception' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_client_guards_are_server_safe() IS
  'True when all seven client-write guards exempt server writes via '
  'is_server_write() while still refusing client writes.';

GRANT EXECUTE ON FUNCTION public.assert_client_guards_are_server_safe() TO authenticated;

-- The provider guard has its own assertion (00015); retarget it at the helper.
CREATE OR REPLACE FUNCTION public.assert_provider_status_guard_is_client_scoped()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'prevent_provider_self_privilege_escalation';

  IF v_flat IS NULL THEN
    RETURN false;
  END IF;

  IF position('is_server_write' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- The client branch must still exist and still refuse, checked on the raise
  -- rather than just the comparison.
  IF position(
       'if new.status is distinct from old.status then raise exception ''status_cannot_be_self_modified'''
       in v_flat
     ) = 0 THEN
    RETURN false;
  END IF;

  RETURN position('provider_type' in v_flat) > 0
     AND position('subscription_start_date' in v_flat) > 0
     AND position('owner_national_id' in v_flat) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_status_guard_is_client_scoped() IS
  'True when the provider_profiles status guard exempts server writes via '
  'is_server_write() while still refusing client status changes.';
