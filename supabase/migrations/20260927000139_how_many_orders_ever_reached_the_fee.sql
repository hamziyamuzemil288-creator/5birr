-- 20260927000139 — how many orders ever reached the fee
--
-- THE PROBLEM WITH THE INSTRUMENT WE HAD
-- --------------------------------------
-- assert_recent_started_orders_have_fees() (20260922000007) is:
--
--   select not exists (
--     select 1 from orders o
--      where o.status in ('STARTED','COMPLETED')
--        and o.updated_at > now() - interval '7 days'
--        and not exists (<the fee row for that order>));
--
-- If NO order has reached STARTED or COMPLETED in the window, the inner
-- `not exists` is trivially satisfied and the function returns TRUE. The
-- Connectivity CI check built on it — "recent started/completed orders charged
-- their transaction fee" — therefore goes GREEN while proving nothing, on
-- exactly the deployment where the order fee has never fired at all.
--
-- That is not hypothetical here. The order fee is deducted in exactly one
-- place, `transition_order_status` on APPROVED -> STARTED, and the only actor
-- the state machine lets make that move is the order's provider (or an admin).
-- No provider screen in lib/ calls `order-transition` — only the two admin
-- screens and the buyer's order-detail screen do — so no order can reach
-- STARTED, so the assertion has nothing to check and passes. Green, and silent.
--
-- This is the third time in this repository that a check has been confidently
-- green because its subject did not exist: `storage.buckets` under RLS read
-- zero rows and made every NOT EXISTS vacuous (fixed in 0136), and
-- assert_private_buckets_are_owner_scoped read `qual` for an INSERT policy
-- that has no USING clause (fixed in 00048). The lesson is the same each time:
-- an assertion over a possibly-empty set must SAY how many rows it looked at.
--
-- WHAT THIS ADDS
-- --------------
-- A read-only report that prints the counts, including the one that matters:
-- how many orders have reached STARTED in the last 7 days. A zero there is not
-- a failure of the ledger — it is the shape of the missing provider actor, and
-- it is now visible in the CI log instead of hidden behind a vacuous true.
--
-- It DELIBERATELY does not fail on the zero. Failing would turn Connectivity CI
-- red for a flow that has never worked, on every deploy, before the fix lands —
-- a red build that says "the order flow is broken" is correct but is a decision
-- for the person who owns the flow, not something an instrument should do on
-- its own. It fails only on the thing that IS unambiguously wrong: an order
-- that reached STARTED and has no fee row.
--
-- Given the provider actor, this report becomes the evidence that the fee
-- fires, with no change to the report itself.
--
-- Read-only: no writes, no fixtures, callable by anon (it returns counts, not
-- order contents).

CREATE OR REPLACE FUNCTION public.order_lifecycle_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_total integer := 0;
  v_created integer := 0;
  v_pending integer := 0;
  v_accepted integer := 0;
  v_paying integer := 0;
  v_approved integer := 0;
  v_started_window integer := 0;
  v_unfeeed integer := 0;
  v_note text;
BEGIN
  SELECT count(*) INTO v_total FROM public.orders;
  SELECT count(*) INTO v_created FROM public.orders WHERE status = 'CREATED';
  SELECT count(*) INTO v_pending
    FROM public.orders WHERE status = 'PENDING_PROVIDER';
  SELECT count(*) INTO v_accepted
    FROM public.orders WHERE status = 'ACCEPTED';
  SELECT count(*) INTO v_paying
    FROM public.orders
   WHERE status IN ('PAYMENT_PENDING', 'PAYMENT_VERIFICATION');
  SELECT count(*) INTO v_approved
    FROM public.orders WHERE status = 'APPROVED';

  -- Orders that actually reached the point where the fee is charged.
  SELECT count(*) INTO v_started_window
    FROM public.orders o
   WHERE o.status IN ('STARTED', 'COMPLETED')
     and o.updated_at > now() - interval '7 days';

  -- The only unambiguous failure: an order that DID start and has no fee row.
  SELECT count(*) INTO v_unfeeed
    FROM public.orders o
   WHERE o.status IN ('STARTED', 'COMPLETED')
     and o.updated_at > now() - interval '7 days'
     and not exists (
       SELECT 1 FROM public.wallet_transactions t
        WHERE t.idempotency_key = 'order:' || o.id::text
          and t.transaction_type = 'TRANSACTION_FEE');

  IF v_unfeeed > 0 THEN
    RETURN format(
      'FAIL: %s order(s) reached STARTED/COMPLETED in the last 7 days without '
      || 'a TRANSACTION_FEE ledger row, so the shelf fee was charged to nobody',
      v_unfeeed);
  END IF;

  -- Say plainly what a zero means, so the next reader does not read it as
  -- "verified fine" the way the boolean did.
  v_note := CASE
    WHEN v_started_window > 0 THEN
      format('%s order(s) reached STARTED/COMPLETED in 7 days and every one '
             || 'carries its fee row', v_started_window)
    ELSE
      'NO order has reached STARTED/COMPLETED in 7 days, so no order fee has '
      || 'ever fired on this deployment. That is the signature of the missing '
      || 'provider actor (PENDING_PROVIDER -> ACCEPTED -> ... -> STARTED), not '
      || 'proof that the fee works. The fee is charged only inside '
      || 'transition_order_status on APPROVED -> STARTED, and only the '
      || 'provider or an admin may make that move'
  END;

  RETURN format(
    'ok: %s order(s) total -- %s CREATED, %s PENDING_PROVIDER (waiting for a '
    || 'provider availability decision), %s ACCEPTED, %s at the payment step, '
    || '%s APPROVED, and %s reached the fee point. %s',
    v_total, v_created, v_pending, v_accepted, v_paying, v_approved,
    v_started_window, v_note);
END;
$$;

COMMENT ON FUNCTION public.order_lifecycle_report() IS
  'Prints the live order funnel and states plainly what a zero at the '
  'STARTED step means. Exists because '
  'assert_recent_started_orders_have_fees() returns TRUE over an empty set, so '
  'the Connectivity CI check built on it went green on a deployment where the '
  'order fee had never fired at all. Fails only on an order that DID start '
  'without a fee row.';

REVOKE ALL ON FUNCTION public.order_lifecycle_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.order_lifecycle_report()
  TO anon, authenticated, service_role;
