-- 0040_unit_pricing_and_payment_method_dedupe.sql
--
-- Two changes (2026-09-20):
--
-- 1. UNIT-BASED PRICING (providers can list by kg / liter)
--    products gains price_per_unit + unit. Existing full listings keep
--    their fixed price (price_per_unit = 0, unit = NULL) so nothing
--    changes for rows that already exist.
--
-- 2. PAYMENT METHOD DUPLICATES
--    The recharge screen rendered Telebirr twice because
--    payment_methods has no name uniqueness and the admin Payment
--    Methods screen can insert a second active 'Telebirr' row (first
--    seen live as a second, near-empty card on Recharge Wallet).
--    Deactivate duplicates (keep the oldest per name) and add a trigger
--    guard so two ACTIVE methods can never share a name again.

-- =========================================================
-- 1) UNIT PRICING
-- =========================================================

alter table public.products
  add column if not exists price_per_unit numeric(12,2) not null default 0;

-- 'KG' | 'LTR' | NULL (NULL = fixed-price listing, price_per_unit ignored)
alter table public.products
  add column if not exists unit text;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'products_unit_check'
  ) then
    alter table public.products
      add constraint products_unit_check
      check (unit is null or unit in ('KG', 'LTR'));
  end if;
end $$;

comment on column public.products.price_per_unit is
  'Price per unit for unit-priced listings (KG/LTR). 0 for fixed-price listings.';
comment on column public.products.unit is
  'Unit for unit-priced listings: KG or LTR. NULL = fixed-price listing.';

-- Cart lines must hold decimal amounts for unit-priced items (0.5 kg …).
alter table public.cart_items alter column quantity type numeric(10,3);

-- Order lines too: unit-priced items are ordered in fractional amounts.
-- `subtotal` is a STORED generated column over (quantity * unit_price), so it
-- must be dropped before the type change and recreated after (Postgres
-- does not rewrite generated-column dependencies automatically).
alter table public.order_items drop column if exists subtotal;
alter table public.order_items alter column quantity type numeric(10,3);
alter table public.order_items
  add column subtotal numeric(12,2)
  generated always as (quantity * unit_price) stored;

-- =========================================================
-- 2) PAYMENT METHOD NAME DUPLICATES
-- =========================================================

-- Deactivate all but the oldest row per (case-insensitive) name.
-- Deactivate, not delete: historical wallet_recharge_requests keep their
-- payment_method_id FK, and the data stays visible in Admin → Payment Methods.
with ranked as (
  select id,
         row_number() over (
           partition by lower(name)
           order by created_at asc, id asc
         ) as rn
  from public.payment_methods
)
update public.payment_methods pm
set is_active = false, updated_at = now()
from ranked r
where pm.id = r.id and r.rn > 1 and pm.is_active;

-- Guard: only one ACTIVE method per (case-insensitive) name.
create or replace function public.enforce_unique_active_payment_method()
returns trigger
language plpgsql
as $$
begin
  if new.is_active and exists (
    select 1 from public.payment_methods
    where lower(name) = lower(new.name)
      and is_active
      and id <> new.id
  ) then
    raise exception 'DUPLICATE_PAYMENT_METHOD: an active payment method named "%" already exists', new.name;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_payment_methods_unique_name on public.payment_methods;
create trigger trg_payment_methods_unique_name
  before insert or update of name, is_active on public.payment_methods
  for each row execute function public.enforce_unique_active_payment_method();

-- =========================================================
-- 3) create_order_secure: accept fractional quantities
--    (was (v_item->>'quantity')::int — unit-priced 0.5 kg orders failed)
-- =========================================================
create or replace function public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,          -- [{ product_id, quantity, unit_price }]
  p_total_amount numeric,
  p_currency text,
  p_note text default null
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

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount,
    coalesce(p_currency, 'ETB'), true, now()
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
  values (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note);

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  to service_role;
