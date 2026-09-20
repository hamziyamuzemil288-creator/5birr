-- 0037_category_order_numbers.sql
--
-- Category-coded, human-readable order numbers:
--   Vehicle / transport → Vh00001, Vh00002, …
--   Hotels (accommodation) → Ht00001, …
--   Food → Fd00001, …
--   Retail products → Pr00001, …
--   Services → Sv00001, …
--   Everything else → Ot00001, …
--
-- Design:
--  * `order_number_sequences` holds one counter per category group. The
--    number is allocated inside create_order_secure() with the counter row
--    locked FOR UPDATE, so two simultaneous orders in the same category can
--    never receive the same number.
--  * The order number is derived server-side from the products' marketplace
--    sector (or the provider's business sector for single-item lookups) —
--    the client never sends it and cannot influence it.
--  * The order-created notification to the provider (ORDER_RECEIVED) now
--    leads with the human-readable number. insert_notification() is the
--    existing server-side helper (SECURITY DEFINER) used by the wallet
--    functions, so the notify trigger's client-insert restriction holds.

-- ---------------------------------------------------------------------
-- 1. Counter table (service-role only; numbers are server-allocated)
-- ---------------------------------------------------------------------
create table if not exists order_number_sequences (
  category_group text primary key,
  last_number bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table order_number_sequences enable row level security;

-- No policies: only the service role (Edge Functions) touches this table.
revoke all on order_number_sequences from anon, authenticated, public;
grant select, update on order_number_sequences to service_role;

-- ---------------------------------------------------------------------
-- 2. Prefix mapping
-- ---------------------------------------------------------------------
create or replace function order_category_prefix(p_sector text)
returns text
language sql
immutable
as $$
  select case p_sector
    when 'TRANSPORT' then 'Vh'
    when 'ACCOMMODATION' then 'Ht'
    when 'FOOD' then 'Fd'
    when 'RETAIL' then 'Pr'
    when 'SERVICES' then 'Sv'
    else 'Ot'
  end;
$$;

-- ---------------------------------------------------------------------
-- 3. Server-side allocation (service-role only)
--    Locks the counter row FOR UPDATE → race-condition safe.
-- ---------------------------------------------------------------------
create or replace function allocate_order_number(p_sector text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text;
  v_next bigint;
begin
  if pg_catalog.current_setting('role', true) != 'service_role' then
    raise exception 'ORDER_NUMBERS_ARE_SERVER_ALLOCATED';
  end if;

  v_prefix := order_category_prefix(p_sector);

  insert into order_number_sequences (category_group, last_number)
  values (v_prefix, 1)
  on conflict (category_group) do update
    set last_number = order_number_sequences.last_number + 1,
        updated_at = now()
  where order_number_sequences.category_group = v_prefix
  returning last_number into v_next;

  return v_prefix || lpad(v_next::text, 5, '0');
end;
$$;

revoke execute on function allocate_order_number(text)
  from public, anon, authenticated;
grant execute on function allocate_order_number(text) to service_role;

-- ---------------------------------------------------------------------
-- 4. Insert notification helper (mirrors the wallet functions' helper;
--    create-if-missing so this migration is order-independent)
-- ---------------------------------------------------------------------
create or replace function insert_notification(
  p_user_id uuid,
  p_type notification_type,
  p_title text,
  p_body text,
  p_data jsonb default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into notifications (user_id, type, title, body, data)
  values (p_user_id, p_type, p_title, p_body, p_data)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 5. create_order_secure — allocate + store the order number
--    (Same signature and return shape as before; orders JSON now carries
--    order_number. All prior behaviour is unchanged.)
-- ---------------------------------------------------------------------
create or replace function create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_sector text;
  v_order_number text;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;

  -- Derive the category group from the ordered products' marketplace
  -- sector; fall back to the provider's business category sector.
  select c.marketplace_sector
    into v_sector
    from products p
    join categories c on c.id = p.category_id
   where p.id = (p_items->0->>'product_id')::uuid
   limit 1;

  if v_sector is null then
    select c.marketplace_sector
      into v_sector
      from provider_profiles pp
      join categories c on c.id = pp.category_id
     where pp.id = p_provider_id
     limit 1;
  end if;

  v_order_number := allocate_order_number(coalesce(v_sector, 'OTHER'));

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, order_number, created_at
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount,
    coalesce(p_currency, 'ETB'), true, v_order_number, now()
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(), v_order_id, (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::int, (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note);

  -- Notify the provider with the human-readable order number.
  perform insert_notification(
    (select user_id from provider_profiles where id = p_provider_id),
    'ORDER_RECEIVED',
    'New order received',
    'Order ' || v_order_number || ' has been placed.',
    jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number)
  );

  return (select to_jsonb(o) from orders o where o.id = v_order_id);
end;
$$;

revoke execute on function create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  from public, anon, authenticated;
grant execute on function create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  to service_role;
