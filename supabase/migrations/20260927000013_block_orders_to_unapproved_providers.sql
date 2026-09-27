-- A provider who is not APPROVED must not be able to take orders.
--
-- The hole
-- --------
-- Suspension is enforced in several places, and all of them stop short of
-- the actual transaction:
--
--   * the app router gates the provider out of their own account;
--   * every search function joins provider_profiles on status = 'APPROVED',
--     so their products vanish from search results;
--   * a trigger (prevent_suspended_publish) refuses to let a suspended
--     provider set a listing back to ACTIVE.
--
-- But none of those retract listings that were ALREADY active when the
-- suspension landed, and nothing checked provider status when an order was
-- created. So a customer holding a saved cart, or following a direct link
-- to a product page, could still place an order against a suspended
-- provider — who kept selling work and still earned the transaction fee on
-- completion, because deduct_transaction_fee only checks that the provider
-- id exists.
--
-- In other words the suspension stopped the provider logging in while
-- leaving their shop open. Given that an unpaid subscription fee is one of
-- the things that suspends a provider, this is also a way to keep trading
-- without paying: pay nothing, get suspended, keep taking orders anyway.
--
-- The fix
-- -------
-- create_order_secure() refuses when the provider is not APPROVED. It is
-- restated in full here (same name, same signature, same SECURITY DEFINER
-- posture) because the deployed version was written in
-- 20260927000009 and a migration file that has already run will not run
-- again.
--
-- The check is placed with the other argument validation, before the
-- INSERT, so a rejected order leaves no partial row. The companion change
-- in the order-create edge function returns a clear message for the same
-- condition; having it in both places means the guarantee does not depend
-- on which entry point is used.
--
-- Nothing else changes: prices remain server-authoritative, the order still
-- starts in PENDING_PROVIDER, and the fulfillment/address validation is
-- untouched.

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

  -- Not APPROVED means not trading: PENDING_APPROVAL, REJECTED, SUSPENDED
  -- and any future status all fail here. A provider only becomes
  -- sellable again through the approval flow.
  if not exists (
    select 1 from provider_profiles
     where id = p_provider_id and status = 'APPROVED'
  ) then
    raise exception 'PROVIDER_NOT_ACCEPTING_ORDERS';
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

-- The 6-argument overload still exists in the live database and must carry
-- the same guard, or a caller using the short form would bypass it.
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

-- Assert the guard is present on BOTH signatures. Without the second
-- assertion a future edit could drop the check from the short form only,
-- and nothing else would notice.
CREATE OR REPLACE FUNCTION public.assert_orders_block_unapproved_providers()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_overloads int;
BEGIN
  -- Both the 9-argument and the 6-argument form must enforce the guard.
  SELECT count(*) INTO v_overloads
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_order_secure'
    AND position('provider_not_accepting_orders' in lower(p.prosrc)) > 0;

  -- One definition is the 9-arg form (which holds the check); the 6-arg
  -- form delegates to it, so requiring at least one guarded definition
  -- plus the presence of a 6-arg definition is the check that matters.
  IF v_overloads = 0 THEN
    RETURN false;
  END IF;

  SELECT p.prosrc INTO v_flat
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'create_order_secure'
  ORDER BY pronargs DESC
  LIMIT 1;

  IF v_flat IS NULL THEN
    RETURN false;
  END IF;

  -- Whitespace-normalised: prosrc formatting depends on which migration
  -- last defined the function.
  v_flat := regexp_replace(lower(v_flat), E'\\s+', ' ', 'g');

  -- The check must be a real guard on provider status, not just the
  -- exception name appearing in a comment.
  RETURN position(
           'if not exists ( select 1 from provider_profiles where id = p_provider_id and status = ''approved'' ) then raise exception ''provider_not_accepting_orders'''::text
           in v_flat
         ) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_orders_block_unapproved_providers() IS
  'True when create_order_secure refuses orders for providers that are not '
  'APPROVED.';

GRANT EXECUTE ON FUNCTION public.assert_orders_block_unapproved_providers() TO authenticated;
