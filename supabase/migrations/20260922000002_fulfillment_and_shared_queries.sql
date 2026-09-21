-- ============================================================
-- Migration 20260922000002_fulfillment_and_shared_queries.sql
-- Phase 4: selection/fulfillment flow + shared ranked queries
-- ============================================================
-- STRICTLY ADDITIVE:
--   - Two new nullable columns on orders (fulfillment_mode,
--     delivery_address) with a backfill; no existing column changes.
--   - create_order_secure is restated with THREE NEW OPTIONAL parameters
--     appended (p_fulfillment_mode / p_delivery_address / p_city).
--     Existing callers are unaffected: the Edge Function passes named
--     arguments, and appended optional params are backward-compatible.
--   - New SQL function visible_products_for_city: ONE shared ranked
--     products query for the dashboard feed and category pages
--     (p_category_id NULL = all categories).
-- ============================================================

-- 1. Fulfillment columns on orders
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'orders'
                   AND column_name = 'fulfillment_mode') THEN
    ALTER TABLE public.orders ADD COLUMN fulfillment_mode text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'orders'
                   AND column_name = 'delivery_address') THEN
    ALTER TABLE public.orders ADD COLUMN delivery_address text;
  END IF;
END $$;

-- Backfill: existing orders were all delivered.
UPDATE public.orders SET fulfillment_mode = 'DELIVERY' WHERE fulfillment_mode IS NULL;

-- Guard against typos going forward (NULL allowed for safety).
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'orders_fulfillment_mode_check') THEN
    ALTER TABLE public.orders ADD CONSTRAINT orders_fulfillment_mode_check
      CHECK (fulfillment_mode IS NULL OR fulfillment_mode IN ('DELIVERY','SELF_PICKUP'));
  END IF;
END $$;

-- ============================================================
-- 2. create_order_secure — restated from 0040 with appended optional
--    params (p_fulfillment_mode / p_delivery_address / p_city).
--    Original logic, statuses, and grants unchanged.
-- ============================================================
create or replace function public.create_order_secure(
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
    gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount,
    coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
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
  values (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note);

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  to service_role;
-- Legacy 6-arg signature stays executable by service_role (Edge Function).
revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  to service_role;

-- ============================================================
-- 3. Shared ranked products query (Phase 4.6): the dashboard mixed feed
--    and every category page call THIS function (p_category_id NULL =
--    all categories). Ranked by sales_count then newest, scoped to the
--    active city; city-less products stay visible everywhere.
-- ============================================================
create or replace function public.visible_products_for_city(
  p_city text,
  p_category_id uuid default null
)
returns setof public.products
language sql
stable
as $$
  select p.*
  from public.products p
  where p.is_active
    and (p.city is null or p.city = p_city)
    and (
      p_category_id is null
      or p.category_id = p_category_id
      or p.category_id in (
        select c.id from public.categories c where c.parent_id = p_category_id
      )
    )
  order by p.sales_count desc nulls last, p.created_at desc
  limit 100;
$$;

grant execute on function public.visible_products_for_city(text, uuid) to authenticated;

-- ============================================================
-- 4. Whiteboard category tree — ADDITIVE seed of missing leaves.
--    Existing categories/rows untouched (ON CONFLICT DO NOTHING).
--    Shop: Cloth shops, Supermarkets, Wholesalers, Electric material,
--          Construction material (Retailers = the retail parent itself).
--    Service: Pensions (lodging), Beauty Salons.
--    Ride/Delivery: Heavy Trucks (Sino/Isuzu/FSR/Howo), Motorbikes,
--          Bajaj (layered on the existing ride-claim/transition flow).
-- ============================================================
insert into public.categories (parent_id, name, sector, slug, sort_order)
select p.id, v.name, v.sector, v.slug, v.sort_order
from (values
  ('retail', 'Cloth Shops', 'SERVICE', 'cloth-shops', 20),
  ('retail', 'Supermarkets', 'SERVICE', 'supermarkets', 21),
  ('retail', 'Wholesalers', 'SERVICE', 'wholesalers', 22),
  ('retail', 'Electric Material Shops', 'SERVICE', 'electric-materials', 23),
  ('retail', 'Construction Material Shops', 'SERVICE', 'construction-materials', 24),
  ('hotels-lodging', 'Pensions', 'SERVICE', 'pensions', 10),
  ('beauty', 'Beauty Salons', 'SERVICE', 'beauty-salons', 10),
  ('truck', 'Heavy Trucks (Sino/Isuzu/FSR/Howo)', 'VEHICLE', 'heavy-trucks', 1),
  ('motorcycle-bajaj', 'Motorbikes', 'VEHICLE', 'motorbikes', 1),
  ('motorcycle-bajaj', 'Bajaj', 'VEHICLE', 'bajaj', 2)
) as v(parent_slug, name, sector, slug, sort_order)
join public.categories p on p.slug = v.parent_slug
on conflict (slug) do nothing;
