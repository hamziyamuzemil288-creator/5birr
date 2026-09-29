-- 20260927000085 — a gated buyer may open the payment step after confirmation
--
-- THE GAP
-- -------
-- Migration 74 built the availability gate and the Dart screen reads it
-- correctly: the buyer sees "Waiting for provider to confirm availability"
-- while the order is PENDING_PROVIDER, the provider gets a "Confirm
-- Availability" button, and the payment details card appears once the order
-- is ACCEPTED. What was missing is the LAST step of that chain.
--
-- The buyer could only reach the screenshot upload from PAYMENT_PENDING, and
-- the only actor the state machine allows to move ACCEPTED -> PAYMENT_PENDING
-- is the provider or an admin. So on a gated order the provider had to press
-- "Request Payment" on their own screen before the buyer was given a way to
-- pay — a second round trip for a decision the provider had already made by
-- confirming availability. In practice the provider never presses it, the
-- order sits at ACCEPTED forever, and the buyer is shown payment details with
-- no button to act on them. That is the reported "the screenshot page does
-- not appear after the availability confirmation".
--
-- THE FIX
-- -------
-- One clause, and only for gated orders:
--
--   ACCEPTED -> PAYMENT_PENDING is now also legal for the order's OWNER,
--   and only when orders.requires_availability_confirmation is true.
--
-- Why that is the right shape rather than a new status or a new role:
--
--   * It is scoped to the order owner. A buyer can open the payment step on
--     their OWN order and on nothing else. It grants no reach over another
--     person's order, and it moves no money.
--   * It is scoped to gated orders. Every un-gated order keeps the existing
--     provider-only rule byte for byte, so nothing that works today changes
--     behaviour. The flag is NOT NULL DEFAULT false, so the population of
--     affected orders is exactly the listings a provider has opted in.
--   * The provider's own path is untouched. A provider may still press
--     "Request Payment" and still may accept straight from PENDING_PROVIDER.
--   * The escrow guarantee is untouched. This clause only opens the step
--     where a proof can be ATTACHED. release_order_contact() still refuses
--     below APPROVED, the phone number still does not appear, and
--     transition_order_status() still refuses APPROVED without a VERIFIED
--     proof. Confirming availability was never supposed to reveal contact;
--     it was only ever supposed to unlock the payment details.
--
-- The buyer's client already has a two-step submit (open the step, then
-- attach the proof and hand it to an admin), and it is written to be
-- retry-safe: it re-reads the status first and skips the hop when the order
-- is already PAYMENT_PENDING.
--
-- Every other statement of transition_order_status() is preserved exactly,
-- including the 20260927000073 fee-on-STARTED behaviour and the
-- PAYMENT_PROOF_REQUIRED gate on APPROVED. It is restated in full because a
-- migration file that has already run will not run again.

CREATE OR REPLACE FUNCTION public.transition_order_status(
  p_order_id uuid,
  p_new_status order_status,
  p_actor uuid,
  p_note text DEFAULT null
)
RETURNS orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order orders;
  v_old order_status;
  v_valid boolean := false;
  v_actor_is_provider boolean := false;
  v_actor_is_admin boolean := false;
  -- Resolved once, used by exactly one branch below. Kept as its own
  -- variable so the reason the buyer may open the payment step is legible in
  -- the source rather than buried in a boolean expression.
  v_buyer_may_open_payment boolean := false;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  v_old := v_order.status;

  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN')
    INTO v_actor_is_admin;
  SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_order.provider_id AND user_id = p_actor)
    INTO v_actor_is_provider;

  -- The whole of this migration. Gated order + the buyer who placed it.
  -- False for an un-gated order, for the provider, and for an admin, so
  -- every other branch of the whitelist below behaves exactly as it did.
  v_buyer_may_open_payment :=
    v_order.requires_availability_confirmation
    AND v_order.user_id = p_actor
    AND NOT v_actor_is_admin;

  v_valid := case v_old
    when 'CREATED' then
      p_new_status in ('PENDING_PROVIDER','CANCELLED')
      AND (v_order.user_id = p_actor OR v_actor_is_admin)

    when 'PENDING_PROVIDER' then
      (p_new_status in ('ACCEPTED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    -- THE CHANGED LINE. `OR v_buyer_may_open_payment` is the only addition;
    -- the provider/admin rule and the buyer-may-cancel rule are unchanged.
    when 'ACCEPTED' then
      (p_new_status = 'PAYMENT_PENDING'
        AND (v_actor_is_provider OR v_actor_is_admin OR v_buyer_may_open_payment))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'PAYMENT_PENDING' then
      (p_new_status = 'PAYMENT_VERIFICATION' AND v_order.user_id = p_actor)
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    when 'PAYMENT_VERIFICATION' then
      p_new_status in ('APPROVED','REJECTED') AND v_actor_is_admin

    when 'APPROVED' then
      (p_new_status = 'STARTED' AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'STARTED' then
      (p_new_status = 'COMPLETED' AND (v_actor_is_provider OR v_actor_is_admin))
      OR (p_new_status in ('DISPUTED','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin))

    when 'COMPLETED' then
      (p_new_status in ('DISPUTED','REFUNDED') AND (v_order.user_id = p_actor OR v_actor_is_admin))
      OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)

    when 'DISPUTED' then
      p_new_status in ('REFUNDED','COMPLETED') AND v_actor_is_admin

    else false
  end;

  IF NOT v_valid THEN
    RAISE EXCEPTION 'INVALID_TRANSITION_%_TO_%_FOR_ACTOR', v_old, p_new_status;
  END IF;

  -- Unchanged: contact and fulfilment stay behind a VERIFIED proof.
  IF p_new_status = 'APPROVED' AND v_order.requires_payment_proof THEN
    IF NOT exists (
      SELECT 1 FROM payment_proofs
       WHERE order_id = p_order_id AND verification_status = 'VERIFIED'
    ) THEN
      RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED';
    END IF;
  END IF;

  UPDATE orders SET status = p_new_status, updated_at = now()
   WHERE id = p_order_id
   RETURNING * INTO v_order;

  INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, note)
  VALUES (p_order_id, v_old, p_new_status, p_actor, p_note);

  -- Unchanged (migration 73): the transaction fee moves at STARTED.
  IF p_new_status = 'STARTED' THEN
    PERFORM deduct_transaction_fee(
      v_order.provider_id, p_order_id, null, v_order.total_amount,
      'order:' || p_order_id::text
    );
  END IF;

  RETURN v_order;
END;
$$;

COMMENT ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text) IS
  'The order lifecycle whitelist. Unchanged from 0022c except one clause: on '
  'an order whose requires_availability_confirmation snapshot is true, the '
  'BUYER may move ACCEPTED -> PAYMENT_PENDING. That opens the step where a '
  'payment proof is attached; it reveals nothing, moves no money, and leaves '
  'release_order_contact() refusing below APPROVED.';

GRANT EXECUTE ON FUNCTION public.transition_order_status(uuid, order_status, uuid, text)
  TO authenticated, service_role;

-- ===========================================================================
-- The assertion.
--
-- Source-level, because the live check that would be better — actually
-- calling the function as the buyer — needs a real order in each of the two
-- states, and Connectivity CI has neither. What is asserted here is the
-- property that decays silently: the clause exists, it is gated on the
-- snapshot, and it is scoped to the owner. A future refactor of the
-- whitelist that drops it, widens it to un-gated orders, or widens it past
-- the order's own buyer fails here instead of in a support ticket.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_gated_buyer_payment_request_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_has_clause boolean;
  v_gated_on_snapshot boolean;
  v_scoped_to_owner boolean;
BEGIN
  SELECT regexp_replace(lower(coalesce(pg_get_functiondef(
           'public.transition_order_status(uuid, order_status, uuid, text)'::regprocedure
         ), '')), '\s+', ' ', 'g')
    INTO v_src;

  IF v_src = '' THEN
    RAISE EXCEPTION
      'GATED_PAYMENT_REQUEST_REGRESSION: transition_order_status() is missing, so the availability gate has no last step and a confirmed order can never be paid';
  END IF;

  v_has_clause := position('v_buyer_may_open_payment' in v_src) > 0;
  IF NOT v_has_clause THEN
    RAISE EXCEPTION
      'GATED_PAYMENT_REQUEST_REGRESSION: transition_order_status() no longer lets a buyer open the payment step on a gated order. The provider must press "Request Payment" on their own screen before the buyer can pay, so a confirmed order sits at ACCEPTED with payment details on screen and no way to act on them';
  END IF;

  -- The clause must be gated on the order-level snapshot, not unconditional.
  -- Unconditional would let every buyer of every un-gated order skip the
  -- provider, which is a behaviour change to orders that work today.
  v_gated_on_snapshot := position(
    'v_order.requires_availability_confirmation and v_order.user_id = p_actor'
    in v_src
  ) > 0;
  IF NOT v_gated_on_snapshot THEN
    RAISE EXCEPTION
      'GATED_PAYMENT_REQUEST_REGRESSION: the buyer payment-step clause is not gated on orders.requires_availability_confirmation AND orders.user_id = p_actor. It must be both — otherwise it changes behaviour for un-gated orders, or lets a buyer act on somebody else''s order';
  END IF;

  -- And it must be reachable: the ACCEPTED branch has to consult it.
  v_scoped_to_owner := position('or v_buyer_may_open_payment' in v_src) > 0;
  IF NOT v_scoped_to_owner THEN
    RAISE EXCEPTION
      'GATED_PAYMENT_REQUEST_REGRESSION: the ACCEPTED -> PAYMENT_PENDING branch does not consult v_buyer_may_open_payment, so the clause is computed and then ignored';
  END IF;

  -- The escrow guarantee this migration must not have weakened.
  IF position('payment_proof_required' in v_src) = 0 THEN
    RAISE EXCEPTION
      'GATED_PAYMENT_REQUEST_REGRESSION: transition_order_status() no longer refuses APPROVED without a VERIFIED payment proof. Opening the payment step to the buyer must not open the escrow with it';
  END IF;

  RETURN 'gated buyer payment request OK: on a gated order the buyer may move '
         || 'ACCEPTED -> PAYMENT_PENDING, scoped to their own order; APPROVED '
         || 'still requires a VERIFIED proof';
END;
$$;

COMMENT ON FUNCTION public.assert_gated_buyer_payment_request_is_wired() IS
  'True when a buyer can open the payment step on a gated order they placed, '
  'scoped to that order and to the availability snapshot, and when APPROVED '
  'still requires a VERIFIED payment proof. Source-level; never raises on '
  'success.';

GRANT EXECUTE ON FUNCTION public.assert_gated_buyer_payment_request_is_wired()
  TO anon, authenticated, service_role;

notify pgrst, 'reload schema';
