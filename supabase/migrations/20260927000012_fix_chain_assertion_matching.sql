-- Fix the two chain assertions: they were matching against a shape of the
-- function source that does not exist in the live database.
--
-- What was wrong
-- --------------
-- Both assertions read `pg_proc.prosrc` and searched it with `position(... in
-- lower(v_src))`. Two mistakes, both of which made the assertion return
-- false against a perfectly correct database:
--
--   1. The needle was built from the UPPERCASE status name while the haystack
--      had been lower-cased, so it searched for `when 'CREATED' then` inside
--      `when 'created' then` and never matched. The assertion was therefore
--      guaranteed to fail for every status, every run.
--
--   2. The PAYMENT_VERIFICATION guard was matched as one contiguous string
--      spanning `then p_new_status in (...)`. That only holds in the
--      whitespace-flattened form the function has in some dumps. Where the
--      function is stored the way the migration wrote it — with the guard on
--      its own line — the newline sits exactly where the needle expects a
--      space, and the check failed.
--
-- So the live DB was right and the test was wrong. The order chain really is
-- complete; this migration only repairs how it is inspected.
--
-- The fix
-- -------
-- Collapse all whitespace runs to a single space and lower-case BOTH sides
-- before comparing. That makes the check independent of indentation, line
-- breaks, and whether the function was last applied from a flattened
-- statement or a formatted one — all of which are formatting, not behaviour.
--
-- The substance of both assertions is unchanged: every non-terminal order
-- status must have a `when <status> then` branch, PAYMENT_VERIFICATION must
-- still be gated on v_actor_is_admin, every non-terminal ride status must
-- have a branch, and an unknown ride status must still fail loudly.

CREATE OR REPLACE FUNCTION public.assert_order_chain_has_no_dead_ends()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  -- Source with all whitespace runs collapsed to one space, lower-cased.
  -- prosrc is the function body verbatim, so its formatting depends on which
  -- migration last defined the function; comparing normalized text is the
  -- only way to assert on it reliably.
  v_flat text;
  v_status text;
  v_escapable text[] := ARRAY[
    'CREATED', 'PENDING_PROVIDER', 'ACCEPTED', 'PAYMENT_PENDING',
    'PAYMENT_VERIFICATION', 'APPROVED', 'STARTED', 'COMPLETED', 'DISPUTED'
  ];
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'transition_order_status';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  v_flat := regexp_replace(lower(v_src), E'\\s+', ' ', 'g');

  FOREACH v_status IN ARRAY v_escapable LOOP
    IF position('when ''' || lower(v_status) || ''' then' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  -- The guard stays admin-only. Loosening it would let a customer approve
  -- their own payment, so that direction must fail CI.
  IF position(
       'when ''payment_verification'' then p_new_status in (''approved'',''rejected'') and v_actor_is_admin'
       in v_flat
     ) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_ride_chain_has_no_dead_ends()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_flat text;
  v_status text;
  v_escapable text[] := ARRAY[
    'REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING', 'DRIVER_EN_ROUTE',
    'ARRIVED', 'TRIP_STARTED', 'STARTED'
  ];
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'transition_ride_status';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  v_flat := regexp_replace(lower(v_src), E'\\s+', ' ', 'g');

  FOREACH v_status IN ARRAY v_escapable LOOP
    IF position('when ''' || lower(v_status) || ''' then' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  -- An unhandled status must still raise rather than silently do nothing.
  IF position('unexpected_ride_status' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;
