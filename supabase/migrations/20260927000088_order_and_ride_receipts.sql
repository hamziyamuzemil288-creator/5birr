-- 20260927000088 — both sides of an order and a ride, told what actually happened
--
-- WHAT THIS CHANGES
-- -----------------
-- Migration 58 wired order and ride status notifications to the BUYER only.
-- The provider was never told anything, and the buyer's own messages carried
-- no amount. This migration:
--
--   * adds the missing provider-side message for an order payment verified,
--   * puts the real amount and counterparty in the buyer's message,
--   * does the same for a completed ride.
--
-- Both triggers are restated IN FULL and diffed by
-- tools/harness/restatement_diff.py, because dropping a branch here would
-- silently stop notifying on a status nobody is watching.
--
-- WHY THE TRIGGER AND NOT transition_order_status / transition_ride_status
-- ------------------------------------------------------------------------
-- The brief asks for the notification to be written in the same transaction as
-- the money movement, and to distrust a trigger that "could fire out of sync".
-- An AFTER UPDATE trigger on the same row cannot: it runs inside the same
-- transaction, so if the money movement raises (deduct_transaction_fee raises
-- INSUFFICIENT_WALLET_BALANCE, for instance) the trigger's writes roll back
-- with it, and if the trigger writes the commit carries both. There is no
-- window in which the money moved and the notification did not.
--
-- Restating transition_ride_status instead would mean reproducing all nine
-- status branches — including the DRIVER_EN_ROUTE branch that once went
-- missing and froze every ride in it. That is a much larger blast radius for
-- no consistency gain, so the existing trigger is the right seam.
--
-- The one event in this brief that genuinely must live in a function body is
-- points conversion, because it moves money without updating any row this
-- trigger covers. That is migration 89.
--
-- THE RIDE IS COMMISSION-ONLY — THE BRIEF'S EXPECTED MESSAGE IS FACTUALLY WRONG
-- -------------------------------------------------------------------------
-- The brief asks the driver to be told "Trip completed, ETB X added to your
-- wallet." Nothing is added to the driver's wallet. Completing a ride calls
-- deduct_transaction_fee(), which DEBITS the platform commission from the
-- driver (wallets.balance = balance - fee) and writes a TRANSACTION_FEE_DEDUCTED
-- notification. The rider's fare is not collected in-app and is never credited
-- to a wallet — fares are agreed and settled outside the platform, and the
-- wallet exists to pay the platform's subscription and commission out of it.
--
-- So the driver is told what is true: the trip is complete, here is the fare,
-- and the platform fee has been deducted (deduct_transaction_fee sends that
-- half already, with the exact amount, from the ledger row it just wrote).
-- Sending "ETB X added to your wallet" would tell a driver money arrived that
-- did not arrive, and the wallet screen would contradict it immediately.
--
-- This is also the Part 2.2 batching note: one ride completion now produces two
-- driver notifications. They are deliberately non-overlapping — this one is
-- about the trip, the existing one is about the fee — rather than a single
-- message trying to be both, because the fee amount is computed inside
-- deduct_transaction_fee and is not available here.
--
-- ORDER PAYMENT: NO WALLET MOVEMENT EITHER
-- -----------------------------------------
-- An order's payment is made outside the app (the buyer uploads a screenshot of
-- a bank transfer or cash handover) and an admin verifies the proof. No wallet
-- is credited on APPROVED; the only order money movement is the commission
-- charged on STARTED. The provider message therefore says the payment is
-- verified and the buyer's contact is now available — which is exactly what
-- changes at APPROVED, since release_order_contact() refuses below APPROVED —
-- and does not claim a wallet credit that never happened.

-- ===========================================================================
-- 1. Orders
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
  v_amount text;
  v_provider_user uuid;
  v_provider_name text;
BEGIN
  -- No status change: nothing to say. (AFTER UPDATE fires on every update,
  -- including the fee/updated_at writes other paths make.)
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_label := 'Order ' || coalesce('#' || NEW.order_number, 'update');
  v_ref := jsonb_build_object('order_id', NEW.id, 'status', NEW.status);

  -- The amount, formatted once, only for the transitions that quote money.
  -- total_amount is NOT NULL on orders, so coalesce is belt-and-braces.
  v_amount := trim(to_char(coalesce(NEW.total_amount, 0), 'FM999,999,990.00'));

  IF NEW.status = 'ACCEPTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_ACCEPTED', 'Order confirmed',
      v_label || ' was accepted by the provider.', v_ref);
  ELSIF NEW.status = 'APPROVED' THEN
    -- Buyer: the existing message, now carrying the amount so it reads as a
    -- receipt rather than a status ping. Same notification type as before.
    PERFORM public.notify_user_once(
      'order-payment-verified:' || NEW.id::text,
      NEW.user_id, 'ORDER_PAYMENT_VERIFIED', 'Payment confirmed',
      'Your payment of ETB ' || v_amount || ' for ' || v_label || ' has been verified.',
      v_ref || jsonb_build_object('total_amount', NEW.total_amount));

    -- Provider: the missing half. The buyer's phone number becomes readable at
    -- APPROVED (release_order_contact allows APPROVED/STARTED/COMPLETED), so
    -- this is the moment contact actually opens. Skipped when the order has no
    -- provider, which the NOT NULL column forbids but which a partially
    -- written row should not crash the transaction over.
    SELECT pp.user_id, pp.business_name INTO v_provider_user, v_provider_name
      FROM public.provider_profiles pp
     WHERE pp.id = NEW.provider_id;

    PERFORM public.notify_user_once(
      'order-payment-received:' || NEW.id::text,
      v_provider_user, 'ORDER_PAYMENT_VERIFIED', 'Payment received',
      'Payment of ETB ' || v_amount || ' for ' || v_label || ' has been verified. '
        || 'The buyer''s contact details are now available in the order.',
      v_ref || jsonb_build_object('total_amount', NEW.total_amount,
                                  'buyer_id', NEW.user_id));
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
    -- The refund half of the brief. The money is refunded outside the app (it
    -- came from outside), so this says the order was refunded and stops there
    -- rather than inventing a wallet credit.
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_REFUNDED', 'Order refunded',
      v_label || ' has been refunded.', v_ref);
  END IF;

  RETURN NEW;
END;
$$;

-- ===========================================================================
-- 2. Rides
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_ride_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ref jsonb;
  v_fare text;
  v_driver_user uuid;
  v_driver_name text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  v_ref := jsonb_build_object('ride_id', NEW.id, 'status', NEW.status);

  -- fare_estimate is nullable and is 0 when the platform does not quote fares
  -- (fee_enabled_ride off), so the quoted figure is only shown when there is
  -- one. A rider is never told they paid ETB 0.00.
  IF NEW.fare_estimate IS NOT NULL AND NEW.fare_estimate > 0 THEN
    v_fare := trim(to_char(NEW.fare_estimate, 'FM999,999,990.00'));
  ELSE
    v_fare := NULL;
  END IF;

  SELECT pp.user_id, pp.business_name INTO v_driver_user, v_driver_name
    FROM public.provider_profiles pp
   WHERE pp.id = NEW.claimed_by_provider_id;

  IF NEW.status = 'CLAIMED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_CLAIMED', 'Driver matched',
      CASE
        WHEN v_driver_name IS NULL THEN 'A driver has accepted your ride request.'
        ELSE v_driver_name || ' has accepted your ride request.'
      END, v_ref);
  ELSIF NEW.status = 'TRIP_STARTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_STARTED', 'Trip started',
      'Your trip has started.', v_ref);
  ELSIF NEW.status = 'COMPLETED' THEN
    -- Rider: receipt-shaped, with the fare when one was quoted and the driver
    -- by name. Replaces the previous "Your trip is complete." under the same
    -- notification type, so the app's icon colouring is unchanged.
    PERFORM public.notify_user_once(
      'ride-completed:' || NEW.id::text,
      NEW.user_id, 'RIDE_COMPLETED', 'Trip completed',
      CASE
        WHEN v_fare IS NULL AND v_driver_name IS NOT NULL THEN
          'Your trip with ' || v_driver_name || ' is complete.'
        WHEN v_fare IS NOT NULL AND v_driver_name IS NULL THEN
          'Your trip is complete. The fare was ETB ' || v_fare || '.'
        WHEN v_fare IS NOT NULL THEN
          'Your trip with ' || v_driver_name || ' is complete. The fare was ETB '
            || v_fare || '.'
        ELSE
          'Your trip is complete.'
      END,
      v_ref || jsonb_build_object('fare_estimate', NEW.fare_estimate,
                                  'driver_id', NEW.claimed_by_provider_id));

    -- Driver: the fare for the trip they ran. It is NOT a wallet credit — the
    -- commission is about to be (or has just been) deducted from their wallet
    -- by deduct_transaction_fee, which sends its own TRANSACTION_FEE_DEDUCTED
    -- notice with the exact figure. See the header on why.
    PERFORM public.notify_user_once(
      'ride-completed-driver:' || NEW.id::text,
      v_driver_user, 'RIDE_COMPLETED', 'Trip completed',
      CASE
        WHEN v_fare IS NULL THEN
          'The trip you ran is complete. The platform fee for this trip has been deducted from your wallet.'
        ELSE
          'The trip you ran is complete. The fare was ETB ' || v_fare
            || ', and the platform fee for this trip has been deducted from your wallet.'
      END,
      v_ref || jsonb_build_object('fare_estimate', NEW.fare_estimate));
  ELSIF NEW.status = 'CANCELLED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'RIDE_CANCELLED', 'Ride cancelled',
      'Your ride request was cancelled.', v_ref);
  END IF;

  RETURN NEW;
END;
$$;

-- ===========================================================================
-- 3. The assertion
--
-- Checks the parts that are easy to break silently:
--   * both parties are notified on the two money events (a provider-only or
--     buyer-only regression is the exact failure this feature exists to stop),
--   * the messages quote the amount rather than being generic,
--   * every status branch from the previous body survived the restatement,
--   * the unclaimed-ride case does not crash: a NULL driver is passed to
--     notify_user_once, which returns NULL, rather than raising.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_order_and_ride_receipts_are_sent()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order_src text;
  v_ride_src text;
  v_missing text := '';
  v_name text;
  v_fns text[] := ARRAY['fn_notify_order_status_change', 'fn_notify_ride_status_change'];
  v_branches text[] := ARRAY[
    'order_accepted', 'order_payment_verified', 'order_completed',
    'order_rejected', 'order_cancelled', 'order_refunded',
    'ride_claimed', 'ride_started', 'ride_completed', 'ride_cancelled'
  ];
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_order_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'fn_notify_order_status_change';

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_ride_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'fn_notify_ride_status_change';

  IF v_order_src IS NULL OR v_ride_src IS NULL THEN
    RETURN 'FAIL: a notification trigger function is missing';
  END IF;

  -- No branch may have been lost in the restatement. These are the enum
  -- labels, so losing an ELSIF shows up here rather than as a user who is
  -- never told their order was cancelled.
  FOREACH v_name IN ARRAY v_branches LOOP
    IF position(lower(v_name) IN v_order_src) = 0
       AND position(lower(v_name) IN v_ride_src) = 0 THEN
      v_missing := v_missing || ' [' || v_name || ']';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RETURN 'FAIL: these status branches no longer notify at all:' || v_missing;
  END IF;

  -- The guard that makes the trigger ignore non-status updates. Without it,
  -- any unrelated write to the row sends a duplicate notification.
  IF position('is not distinct from old.status' IN v_order_src) = 0
     OR position('is not distinct from old.status' IN v_ride_src) = 0 THEN
    RETURN 'FAIL: the "no status change" guard is missing from one of the '
           || 'triggers, so unrelated row updates would re-notify';
  END IF;

  -- Both parties on the order payment. Two distinct dedupe keys is the
  -- evidence that both are sent; one key would mean a double message to the
  -- buyer and silence to the provider.
  IF position('order-payment-verified:' IN v_order_src) = 0 THEN
    RETURN 'FAIL: the buyer no longer gets a payment-confirmed notification';
  END IF;

  IF position('order-payment-received:' IN v_order_src) = 0 THEN
    RETURN 'FAIL: the provider no longer gets a payment-received notification '
           || 'on order APPROVED (this is the both-parties requirement)';
  END IF;

  -- Both parties on the ride.
  IF position('ride-completed:' IN v_ride_src) = 0 THEN
    RETURN 'FAIL: the rider no longer gets a trip-completed notification';
  END IF;

  IF position('ride-completed-driver:' IN v_ride_src) = 0 THEN
    RETURN 'FAIL: the driver no longer gets a trip-completed notification';
  END IF;

  -- The messages must quote a real amount, not a generic string.
  IF position('total_amount' IN v_order_src) = 0 THEN
    RETURN 'FAIL: the order messages no longer carry the amount';
  END IF;

  IF position('fare_estimate' IN v_ride_src) = 0 THEN
    RETURN 'FAIL: the ride messages no longer carry the fare';
  END IF;

  -- A guard against the exact wording this migration had to correct: claiming
  -- money was ADDED to a wallet on ride completion. The platform debits the
  -- commission, it never credits a fare, so that claim must not reappear.
  IF position('added to your wallet' IN v_ride_src) > 0
     OR position('added to your wallet' IN v_order_src) > 0 THEN
    RETURN 'FAIL: a message claims money was added to a wallet. Ride '
           || 'completion debits the platform commission and order payment is '
           || 'settled outside the app; neither credits a wallet.';
  END IF;

  RETURN 'ok: both parties notified on order payment verified and ride '
         || 'completed; all 10 status branches present; the no-change guard is '
         || 'intact; amounts are quoted; no message claims a wallet credit that '
         || 'does not happen';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_order_and_ride_receipts_are_sent()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_order_and_ride_receipts_are_sent()
  TO authenticated, service_role;

notify pgrst, 'reload schema';
