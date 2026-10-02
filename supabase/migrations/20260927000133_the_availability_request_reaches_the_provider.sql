-- 20260927000133 — the availability request actually reaches the provider
--
-- WHY THE ORDER LIFECYCLE NEVER STARTED
-- ------------------------------------
-- `fn_notify_order_status_change()` is the AFTER UPDATE trigger on `orders`.
-- Migration 0088 restated it with this line:
--
--   v_label := 'Order ' || coalesce('#' || NEW.order_number, 'update');
--
-- `orders.order_number` DOES NOT EXIST. 0037 created
-- `order_number_sequences` and `allocate_order_number()` and never altered
-- `orders`; no CREATE TABLE in this repository declares the column and no
-- ALTER TABLE adds it. Migration 0115 found the identical bug in
-- `create_order_secure()`, hit it as a live 42703 on every single order
-- creation, and wrote the finding into its own header:
--
--   "Referring to it here made EVERY order creation fail with 42703, which is
--    the one path this app cannot survive."
--
-- It fixed the INSERT path. It did not fix the UPDATE path, because the
-- trigger only fires on UPDATE and order creation is an INSERT -- so the bug
-- sat there for every order ever placed.
--
-- A plpgsql record field is resolved at RUN time, not at CREATE FUNCTION
-- time, so nothing in review could see it. Proven, not argued:
--
--   ERROR:  record "new" has no field "order_number"
--   CONTEXT:  PL/pgSQL assignment "v_label := 'Order ' || coalesce(..."
--
-- The trigger raises, the UPDATE rolls back, and the order stays at
-- PENDING_PROVIDER forever. That is the whole of the availability chain:
--
--   PENDING_PROVIDER --provider: Confirm Availability--> ACCEPTED
--   ACCEPTED          --buyer: open the payment step--> PAYMENT_PENDING
--   PAYMENT_PENDING   --buyer: attach the proof------> PAYMENT_VERIFICATION
--   PAYMENT_VERIFICATION --admin: verify the proof----> APPROVED
--
-- Every arrow is an UPDATE on `orders`. Not one of them can fire. The buyer
-- waits at "Waiting for the provider to confirm availability" on an order no
-- provider is able to move, which is the report this migration answers.
--
-- THE LABEL IS NOT COSMETIC
-- -------------------------
-- The replacement is the same short reference `create_order_secure` settled on
-- in 0115 -- the first eight characters of the id, uppercased -- so the order
-- a provider reads in the notification is the same order number they read on
-- the order screen and can quote back. Inventing a second convention here
-- would put two different identifiers for one order in front of two people.
--
-- WHAT ELSE WAS MISSING ON THE PROVIDER SIDE
-- ------------------------------------------
-- Even with the trigger repaired, the provider is told about three of the five
-- events that need them:
--
--   event                       provider told?
--   --------------------------  ------------------------------------------------
--   order placed                yes  ORDER_RECEIVED (0114)
--   availability confirmed      no   the buyer is told, the actor is not
--   proof submitted for review  no   -- the order is now BLOCKED on an admin
--   payment verified            yes  ORDER_PAYMENT_VERIFIED (0088)
--   proof rejected              no
--
-- The third row is the one that stalls a transaction: the buyer has paid and
-- handed over a screenshot, the order sits at PAYMENT_VERIFICATION, and the
-- provider has no idea their money is in flight until they happen to poll the
-- orders screen. Both are added below, keyed through notify_user_once() so a
-- repeated UPDATE of the same row cannot produce a second ping.
--
-- Everything 0088 established is preserved line for line: the buyer receipts
-- with their amounts, the provider's "Payment received" notice that names the
-- moment contact opens, and the cancelled/refunded wording.

-- ===========================================================================
-- 0. Two notification types the provider half of this needs
-- ===========================================================================
-- `notification_type` has been a design artefact since 0001: several members
-- were declared and then never written by anything. These two are written
-- below, and they are added here, ABOVE the restatement, for the reason 0010
-- did the same for the ride statuses: a plpgsql body is syntax-checked at
-- CREATE and its literals are resolved at first CALL, so the value has to
-- exist before anything can execute it.
ALTER TYPE public.notification_type
  ADD VALUE IF NOT EXISTS 'PAYMENT_PROOF_SUBMITTED';
ALTER TYPE public.notification_type
  ADD VALUE IF NOT EXISTS 'PAYMENT_PROOF_REJECTED';

-- ===========================================================================
-- 1. The trigger, repaired
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
  v_short_ref text;
BEGIN
  -- No status change: nothing to say. (AFTER UPDATE fires on every update,
  -- including the fee/updated_at writes other paths make.)
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- The column 0088 quoted was never created. Same short reference
  -- `create_order_secure` uses, so one order has one name everywhere.
  v_short_ref := upper(substr(replace(NEW.id::text, '-', ''), 1, 8));
  v_label := 'Order ' || coalesce('#' || v_short_ref, 'update');
  v_ref := jsonb_build_object('order_id', NEW.id, 'status', NEW.status);

  -- The amount, formatted once, only for the transitions that quote money.
  -- total_amount is NOT NULL on orders, so coalesce is belt-and-braces.
  v_amount := trim(to_char(coalesce(NEW.total_amount, 0), 'FM999,999,990.00'));

  IF NEW.status = 'ACCEPTED' THEN
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_ACCEPTED', 'Order confirmed',
      v_label || ' was accepted by the provider.', v_ref);
  ELSIF NEW.status = 'PAYMENT_VERIFICATION' THEN
    -- The buyer's proof is in and an administrator now owns the next step.
    -- Before this the provider learned nothing, and an order waiting on a
    -- payment review looks identical to one that was simply forgotten.
    --
    -- notify_user_once() because this is an AFTER UPDATE trigger: any retry of
    -- the transition would otherwise re-notify, and a provider who is sent
    -- "still waiting" twice starts ignoring the first one.
    SELECT pp.user_id, pp.business_name INTO v_provider_user, v_provider_name
      FROM public.provider_profiles pp
     WHERE pp.id = NEW.provider_id;

    PERFORM public.notify_user_once(
      'order-proof-submitted:' || NEW.id::text,
      v_provider_user, 'PAYMENT_PROOF_SUBMITTED', 'Payment proof submitted',
      'The buyer submitted a payment proof of ETB ' || v_amount || ' for '
        || v_label || '. It is waiting for an administrator to verify it.',
      v_ref || jsonb_build_object('total_amount', NEW.total_amount,
                                  'buyer_id', NEW.user_id));
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
    -- Buyer, unchanged: from PENDING_PROVIDER this is the provider declining
    -- availability, which is what the sentence has always meant.
    PERFORM public.notify_user(
      NEW.user_id, 'ORDER_REJECTED', 'Order rejected',
      v_label || ' was rejected by the provider.', v_ref);

    -- But a rejection that follows PAYMENT_VERIFICATION is an administrator
    -- refusing the PROOF, not the provider refusing the job, and the provider
    -- is the one who has to chase it. The buyer's sentence above is not
    -- changed -- it is the same refusal either way -- while the provider gets
    -- the half that explains why their order just went backwards.
    IF OLD.status = 'PAYMENT_VERIFICATION' THEN
      SELECT pp.user_id, pp.business_name INTO v_provider_user, v_provider_name
        FROM public.provider_profiles pp
       WHERE pp.id = NEW.provider_id;

      PERFORM public.notify_user_once(
        'order-proof-rejected:' || NEW.id::text,
        v_provider_user, 'PAYMENT_PROOF_REJECTED', 'Payment proof rejected',
        'An administrator rejected the payment proof of ETB ' || v_amount
          || ' for ' || v_label || '. The order is back with the buyer.',
        v_ref || jsonb_build_object('total_amount', NEW.total_amount,
                                    'buyer_id', NEW.user_id));
    END IF;
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
-- 2. Say what the request actually is
-- ===========================================================================
-- 0114's message is "A customer placed an order for 2 items. Open it to
-- confirm." That is right for a shelf and wrong for a booking: on a gated
-- listing the provider is not being asked to confirm an order, they are being
-- asked whether they have the item, the room or the slot. It is the only
-- signal that lets them triage, and the whole flow is gated on their answer.
--
-- `v_needs_availability` is already computed above the INSERT -- it is what
-- decides the snapshot on the order row -- so this reads it rather than
-- re-deriving it.
--
-- Restated in full, because a migration file that has already run will not run
-- again. Every other statement is 0115's byte for byte.
CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null,
  p_fulfillment_mode text default 'DELIVERY',
  p_delivery_address text default null,
  p_city text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_needs_availability boolean := false;
  v_order_number text;
  v_item_count int;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;
  if p_fulfillment_mode is null or p_fulfillment_mode not in ('DELIVERY','SELF_PICKUP') then
    p_fulfillment_mode := 'DELIVERY';
  end if;
  if p_fulfillment_mode = 'DELIVERY' and coalesce(trim(p_delivery_address), '') = '' then
    raise exception 'DELIVERY_REQUIRES_ADDRESS';
  end if;

  if not exists (
    select 1 from provider_profiles
     where id = p_provider_id and status = 'APPROVED'
  ) then
    raise exception 'PROVIDER_NOT_ACCEPTING_ORDERS';
  end if;

  select exists (
    select 1
      from (select distinct on (e->>'product_id') e->>'product_id' as product_id
              from jsonb_array_elements(p_items) e) d
      join products pr on pr.id = d.product_id::uuid
     where pr.requires_availability_confirmation
  ) into v_needs_availability;

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at, fulfillment_mode,
    delivery_address, city, requires_availability_confirmation
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'PENDING_PROVIDER',
    p_total_amount, coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
    nullif(trim(p_delivery_address), ''),
    coalesce(
      nullif(trim(p_city), ''),
      (select pp.city from provider_profiles pp where pp.id = p_provider_id),
      default_city()
    ),
    coalesce(v_needs_availability, false)
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(),
      v_order_id,
      (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::numeric,
      (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'PENDING_PROVIDER', p_user_id, p_note);

  -- `orders.order_number` DOES NOT EXIST. 0037 added it, but 0037 is below
  -- the deploy baseline, so it was marked applied WITHOUT being executed --
  -- as were order_number_sequences and allocate_order_number(). The short form
  -- of the primary key is a real reference the provider can quote back, and
  -- needs nothing that was never created. The payload key stays, so no client
  -- reader changes shape.
  v_order_number := upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
  select count(*) into v_item_count from order_items oi where oi.order_id = v_order_id;

  perform public.notify_best_effort(
    (select pp.user_id from provider_profiles pp where pp.id = p_provider_id),
    'ORDER_RECEIVED',
    case when v_needs_availability
         then 'Availability request ' || coalesce(v_order_number, '')
         else 'New order ' || coalesce(v_order_number, '')
    end,
    case when v_needs_availability then
      case when v_item_count = 1
           then 'A customer is asking whether you have 1 item available. '
                || 'Open it to confirm or decline.'
           else 'A customer is asking whether you have ' || v_item_count
                || ' items available. Open it to confirm or decline.'
      end
      else
        case when v_item_count = 1
             then 'A customer placed an order for 1 item. Open it to confirm.'
             else 'A customer placed an order for ' || v_item_count
                  || ' items. Open it to confirm.'
        end
    end,
    jsonb_build_object(
      'order_id', v_order_id,
      'order_number', v_order_number,
      -- The client reads this to decide where the tap lands and what the row
      -- says, so it travels with the notification rather than being guessed
      -- from the message text.
      'requires_availability_confirmation', coalesce(v_needs_availability, false))
  );

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

-- ===========================================================================
-- 3. The assertion
-- ===========================================================================
-- Reads the LIVE catalog, because the defect this migration repairs was
-- invisible to every source-level check in this repository: a plpgsql record
-- field is resolved at run time, so no amount of reading the file finds it.
-- Only the database can answer "does this trigger reference a column the table
-- does not have".
--
-- So the check is the database's own: for every `NEW.<col>` / `OLD.<col>` the
-- installed trigger functions read, is `<col>` a column of the table the
-- trigger is on. That is a question about the live catalog, and it is the
-- question that would have caught 0088 on the day it was written.
--
-- The pattern matches `NEW.col` the way a trigger body actually writes it. The
-- first attempt anchored on a leading dot -- `\.NEW\.` -- which matches
-- nothing at all, and a check that reports "0 references" is worse than no
-- check because it is green.
CREATE OR REPLACE FUNCTION public.assert_no_trigger_reads_a_missing_column()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  r record;
  v_missing text := '';
  v_checked integer := 0;
  v_col text;
BEGIN
  FOR r IN
    SELECT p.proname AS fn, t.relname AS tbl, n.nspname AS sch,
           (SELECT string_agg(DISTINCT x.col, ', ')
              FROM (
                SELECT (regexp_matches(
                          pg_get_functiondef(p.oid),
                          '(^|[^a-z0-9_])(new|old)\.([a-z_][a-z0-9_]*)',
                          'gi'))[3] AS col
               ) x) AS cols
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_trigger tg ON tg.tgfoid = p.oid
      JOIN pg_class t ON t.oid = tg.tgrelid
      JOIN pg_namespace tn ON tn.oid = t.relnamespace
     WHERE p.pronamespace = 'public'::regnamespace
       AND NOT tg.tgisinternal
       AND tn.nspname = 'public'
       AND t.relkind = 'r'
  LOOP
    CONTINUE WHEN r.cols IS NULL;

    FOREACH v_col IN ARRAY string_to_array(r.cols, ', ')
    LOOP
      v_checked := v_checked + 1;
      IF NOT EXISTS (
           SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema = r.sch
              AND c.table_name = r.tbl
              AND c.column_name = v_col) THEN
        v_missing := v_missing || format('%s reads %s.%s; ', r.fn, r.tbl, v_col);
      END IF;
    END LOOP;
  END LOOP;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'a row trigger reads a column its table does not have: %s. Plpgsql resolves a record field at RUN time, so this deploys cleanly and then raises 42703 on every row it touches -- the statement is rolled back and nothing about that row ever changes.', v_missing;
  END IF;

  RETURN format(
    'ok: %s trigger column reference(s) all resolve to real columns', v_checked);
END;
$$;

REVOKE ALL ON FUNCTION public.assert_no_trigger_reads_a_missing_column()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_no_trigger_reads_a_missing_column()
  TO anon, authenticated, service_role;

NOTIFY pgrt, 'reload schema';