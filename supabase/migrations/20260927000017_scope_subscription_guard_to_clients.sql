-- Scope the subscriptions guard to clients.
--
-- The gap
-- ------
-- 20260927000015 and 20260927000016 applied the session_user fix to the
-- provider_profiles, orders and notification guards. They missed this one,
-- and it sits directly on the revenue path.
--
-- trg_subscriptions_security -> prevent_subscription_self_modification:
--
--   IF NOT is_admin() THEN
--     IF new.status != old.status THEN
--       RAISE EXCEPTION 'SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED';
--     IF new.next_due_date != old.next_due_date THEN
--       RAISE EXCEPTION 'SUBSCRIPTION_DATES_CANNOT_BE_SELF_MODIFIED';
--
-- is_admin() is auth.uid(), which is NULL for the pg_cron job, so the guard
-- rejects the scheduler's own writes. Three of them, all in
-- charge_due_subscriptions():
--
--   update subscriptions set status = 'GRACE'      -- not exception-wrapped
--   update subscriptions set status = 'SUSPENDED'  -- not exception-wrapped
--   deduct_subscription_fee() -> status = 'ACTIVE' and next_due_date += 1 mo
--
-- The first two sit in the insufficient-balance branch with no
-- BEGIN/EXCEPTION around them, so the raise aborts the entire function —
-- the first provider with a low balance ends the daily run, and every
-- provider after them is skipped: not charged, not moved to GRACE, not
-- notified. The third is inside the exception block, so it is swallowed:
-- v_deferred is incremented and the provider is silently left alone.
--
-- Net effect on the live database: the monthly fee is not collected from
-- anyone whose balance needs a grace window, nobody is moved to GRACE, and
-- nobody is ever suspended for non-payment. The subscription scheduler was
-- wired up in 20260922000004 and has been failing silently ever since.
--
-- The fix
-- ------
-- Same shape as 20260927000015/16: exempt the server roles, discriminated on
-- session_user so the guard cannot be bypassed by a client, and keep every
-- client-facing check intact. A provider still cannot move their own
-- subscription status or shift their own billing date — the check that
-- matters, since next_due_date controls when they are charged.
--
-- assert_client_guards_are_server_safe is extended to cover this function,
-- so the four guards cannot drift apart again.

CREATE OR REPLACE FUNCTION public.prevent_subscription_self_modification()
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
    RAISE EXCEPTION 'SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED';
  END IF;

  IF new.next_due_date IS DISTINCT FROM old.next_due_date THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_CANNOT_BE_SELF_MODIFIED';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_subscription_self_modification() IS
  'Stops a client editing its own subscription status or billing date. '
  'Exempts the server (pg_cron as postgres, edge functions as service_role), '
  'which is what charge_due_subscriptions() needs in order to charge, grace '
  'and suspend at all.';

-- Fold subscriptions into the existing guard assertion so all four are
-- covered by one test.
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
    'prevent_order_insert_privilege_escalation',
    'prevent_order_self_privilege_escalation',
    'prevent_notification_injection',
    'prevent_subscription_self_modification'
  ] LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

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
