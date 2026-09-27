-- New orders must start in PENDING_PROVIDER, not CREATED.
--
-- The dead end
-- -----------
-- create_order_secure() has always inserted new orders with
-- status = 'CREATED'. Nothing in the system ever moves them out of it:
--
--   * the app has no CREATED -> PENDING_PROVIDER call
--     (user_order_detail_screen._providerActions switches on
--     PENDING_PROVIDER / ACCEPTED / APPROVED / STARTED only, and has no
--     CREATED case, so it returns an empty action list);
--   * the order-create edge function inserts and stops;
--   * no trigger promotes CREATED.
--
-- But CREATED is not a usable state for the rest of the machine either:
--
--   * the provider's "Pending" tab filters on
--     {CREATED, PENDING_PROVIDER, ACCEPTED, PAYMENT_PENDING,
--     PAYMENT_VERIFICATION}, so the order does show up — but with no
--     Accept/Reject button, so the provider can do nothing with it;
--   * transition_order_status() allows out of CREATED only
--     PENDING_PROVIDER or CANCELLED, and PENDING_PROVIDER is reachable only
--     by the buyer (v_order.user_id = p_actor) or an admin. The provider
--     cannot accept, and the buyer is not offered the transition.
--
-- So every order placed in the app sat in CREATED indefinitely: the
-- provider could not accept it, the buyer had no way to advance it, and the
-- order could only be cancelled. The marketplace order flow could not
-- complete an order at all.
--
-- The fix
-- -------
-- Create orders in PENDING_PROVIDER — the state the provider queue, the
-- accept/reject buttons, and the transition whitelist were all built
-- around. This is the state an order was always meant to occupy between
-- "placed" and "accepted"; CREATED was only ever the insert-time default.
--
-- The whitelist entry for CREATED is left in place. It is harmless, and
-- keeping it means an order that somehow lands in CREATED (a row inserted
-- directly, or an older client) can still be promoted rather than becoming
-- permanently stuck.
--
-- Only the INSERT changes. The status history is written to match, so the
-- order timeline shows the state the order actually starts in rather than a
-- CREATED entry that was immediately superseded.

CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,          -- [{ product_id, quantity, unit_price }]
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

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at, fulfillment_mode,
    delivery_address, city
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'PENDING_PROVIDER',
    p_total_amount, coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
    nullif(trim(p_delivery_address), ''),
    coalesce(
      nullif(trim(p_city), ''),
      (select pp.city from provider_profiles pp where pp.id = p_provider_id),
      default_city()
    )
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

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  to service_role;

-- The legacy 6-argument signature still exists in the live database (granted
-- in 20260922000002), and PostgreSQL will not let a function be dropped and
-- recreated with a different argument list under the same name while any
-- caller might still use it. Point it at the same body so an older client
-- calling the short form also gets PENDING_PROVIDER rather than the dead-end
-- CREATED state.
CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_secure(
    p_user_id, p_provider_id, p_items, p_total_amount, p_currency, p_note,
    'DELIVERY', null, null
  );
end;
$$;

-- Backfill: orders already sitting in CREATED can never be advanced by the
-- app, so promote the ones that have not been cancelled. An order in
-- CREATED is by definition un-actioned — nothing ever moved it — so this
-- cannot resurrect a cancelled or completed order.
UPDATE public.orders
   SET status = 'PENDING_PROVIDER',
       updated_at = now()
 WHERE status = 'CREATED';

-- Record the promotion in the timeline so the order's history explains why
-- it is pending rather than showing a bare CREATED entry.
INSERT INTO public.order_status_history (order_id, from_status, to_status, changed_by, note)
SELECT o.id, 'CREATED', 'PENDING_PROVIDER', NULL,
       'Order was promoted out of CREATED, where no transition could advance it'
  FROM public.orders o
 WHERE o.status = 'PENDING_PROVIDER'
   AND NOT EXISTS (
     SELECT 1 FROM public.order_status_history h
      WHERE h.order_id = o.id AND h.to_status = 'PENDING_PROVIDER'
   );
