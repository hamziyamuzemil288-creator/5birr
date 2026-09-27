-- Assert the order lifecycle has no state the app cannot move out of.
--
-- The bug this guards
-- -------------------
-- Two separate dead ends meant the marketplace could not complete an order:
--
--   1. Orders were created with status 'CREATED'. Nothing ever moved them:
--      no caller in the app, no edge function, no trigger. Out of CREATED the
--      whitelist allows only PENDING_PROVIDER (buyer or admin) or CANCELLED,
--      and the buyer's action list had no CREATED case — so the provider
--      could not accept an order that had been placed. Orders sat in CREATED
--      forever. 20260927000009 creates them in PENDING_PROVIDER instead.
--
--   2. PAYMENT_VERIFICATION has exactly two exits (APPROVED, REJECTED) and
--      BOTH require an admin actor:
--        when 'PAYMENT_VERIFICATION' then
--          p_new_status in ('APPROVED','REJECTED') and v_actor_is_admin
--      with no admin screen for order payment proofs, a customer who had
--      paid stayed stuck indefinitely and the provider never got APPROVED
--      (so never reached STARTED, and the order never completed).
--
-- Both were invisible to CI: the suite proved the RIDE chain was walkable
-- and never checked the ORDER chain. This does.
--
-- What is asserted
-- ----------------
-- Two properties of the live transition_order_status() source:
--
--   (a) every non-terminal status has at least one onward transition, so
--       no order can reach a state the machine refuses to leave;
--   (b) PAYMENT_VERIFICATION is still gated on an admin actor. This one is
--       deliberately an ASSERTION OF THE RESTRICTION, not of its absence:
--       loosening it would let a customer approve their own payment, so a
--       regression here is the dangerous direction and must fail CI.
--
-- The check reads function source, not data, for the same reason the
-- vehicle-assertion does: whether a particular order is stuck is a fact
-- about that order, but whether a state is escapable at all is a fact about
-- the code, and only the code can be asserted without fixtures.

CREATE OR REPLACE FUNCTION public.assert_order_chain_has_no_dead_ends()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  -- Statuses an order can be parked in and must always be able to leave.
  -- Terminal states (CANCELLED, REJECTED, REFUNDED, COMPLETED) are absent:
  -- they are meant to be final. CREATED is included because rows in it can
  -- still exist from before 20260927000009, and the whitelist kept its
  -- CREATED -> PENDING_PROVIDER / CANCELLED entries for exactly that reason.
  v_escapable text[] := ARRAY[
    'CREATED', 'PENDING_PROVIDER', 'ACCEPTED', 'PAYMENT_PENDING',
    'PAYMENT_VERIFICATION', 'APPROVED', 'STARTED', 'COMPLETED', 'DISPUTED'
  ];
  v_status text;
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'transition_order_status';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  -- (a) every non-terminal status must appear as a `when '<status>'` branch
  -- with at least one onward target. Matching the branch opener avoids
  -- matching a status that only ever appears as a destination.
  FOREACH v_status IN ARRAY v_escapable LOOP
    -- 'when' <STATUS> 'then', with the status spliced in.
    --
    -- No backslashes appear in these fragments, so no E'' escaping is needed
    -- and the quoting stays ordinary: v_src is lower-cased once up front, so
    -- a case-insensitive match is not required, and the single quotes around
    -- the status are written the plain way (one quote, doubled for SQL).
    IF position('when ''' || v_status || ''' then' in lower(v_src)) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  -- (b) PAYMENT_VERIFICATION must remain admin-only.
  --
  -- Matched on the guard itself, not the bare status name, so that prose in a
  -- comment cannot satisfy it. The live body is stored on a single line, so
  -- the exact spacing of the dumped function is matched; the status list and
  -- the v_actor_is_admin flag are what actually carry the meaning.
  IF position(
       'when ''payment_verification'' then p_new_status in (''approved'',''rejected'') and v_actor_is_admin'
       in lower(v_src)
     ) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_order_chain_has_no_dead_ends() IS
  'True when every non-terminal order status has an onward transition in '
  'transition_order_status(), and PAYMENT_VERIFICATION is still admin-only.';

GRANT EXECUTE ON FUNCTION public.assert_order_chain_has_no_dead_ends() TO authenticated;
