-- =============================================================================
-- 20260927000068 — Product likes, a denormalised count, and a trending score
-- =============================================================================
-- Part 1 of the virality work: a user can like a product, the count is
-- maintained by a trigger so no list query ever counts rows, and trending is
-- computed server-side from CEO-tunable weights.
--
-- ── Why like_count is a column and not a subquery ──────────────────────────
--
-- The product grid is the hottest read in the app. A `select count(*)` per
-- card, or a correlated subquery in the list query, turns a 12-card page into
-- 12 extra round trips or one wide aggregate the planner cannot index. The
-- count is therefore maintained by trigger on the likes table, which is the
-- same trade every denormalised counter makes: writes get slightly more
-- expensive, reads get free, and the reads are the ones on the hot path.
--
-- The trigger is the ONLY writer. Nothing in the app is permitted to set
-- like_count directly, so the column cannot drift away from the rows.
--
-- ── Why trending is a view and not a stored column ─────────────────────────
--
-- The weights live in system_settings so the CEO can tune them. A stored
-- trending_score column would have to be recomputed for every product in the
-- catalogue every time a weight changed, and any drift between the stored
-- score and the current weights would be invisible. A view recomputes from the
-- current weights on read, so tuning a weight takes effect immediately and
-- there is nothing to fall out of sync.
--
-- The cost is that the score is an expression, so Postgres cannot use an index
-- to order by it. That is accepted deliberately: the trending feed is bounded
-- (LIMIT 20 on a filtered, active-listing set) and the alternative -- a stored
-- column plus a recompute job plus a staleness window -- is strictly more
-- machinery for a correctness problem. If the catalogue grows far enough for
-- this to matter, the migration to a maintained column is additive.
--
-- ── RLS shape ─────────────────────────────────────────────────────────────
-- Matches the house pattern used by the other per-user tables: a user may
-- insert and delete their OWN like, anyone signed in may read, and nobody may
-- update (a like has no state to update -- it is either there or not, so an
-- UPDATE policy would only ever be a way to rewrite someone else's row).
-- -----------------------------------------------------------------------------

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The likes table
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.product_likes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint product_likes_unique_per_user unique (user_id, product_id)
);

comment on table public.product_likes is
  'One row per (user, product). Like state only -- there is nothing to update, so there is no UPDATE policy.';

create index if not exists idx_product_likes_product
  on public.product_likes (product_id, created_at desc);
create index if not exists idx_product_likes_user
  on public.product_likes (user_id, created_at desc);

alter table public.product_likes enable row level security;

drop policy if exists product_likes_insert_own on public.product_likes;
create policy product_likes_insert_own on public.product_likes
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists product_likes_delete_own on public.product_likes;
create policy product_likes_delete_own on public.product_likes
  for delete to authenticated
  using (auth.uid() = user_id);

-- Read is open to any signed-in user because a like count is public
-- information by construction: it is displayed on the card to everyone.
drop policy if exists product_likes_read_authenticated on public.product_likes;
create policy product_likes_read_authenticated on public.product_likes
  for select to authenticated
  using (true);

grant select, insert, delete on public.product_likes to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The denormalised counter
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.products
  add column if not exists like_count integer not null default 0;

comment on column public.products.like_count is
  'Maintained by trg_product_likes_count. Never written by the app.';

create or replace function public.trg_product_likes_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.products
       set like_count = like_count + 1
     where id = new.product_id;
    return new;
  end if;

  update public.products
     set like_count = greatest(like_count - 1, 0)
   where id = old.product_id;
  return old;
end;
$$;

drop trigger if exists trg_product_likes_count on public.product_likes;
create trigger trg_product_likes_count
  after insert or delete on public.product_likes
  for each row execute function public.trg_product_likes_count();

-- Backfill from the rows that may predate this migration. Idempotent: running
-- it twice produces the same value, because it recomputes rather than adds.
update public.products p
   set like_count = coalesce(l.c, 0)
  from (select product_id, count(*)::int as c
          from public.product_likes
         group by product_id) l
 where l.product_id = p.id
   and p.like_count is distinct from l.c;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The settings the CEO tunes
--
-- Seeded through the same guard-lift the other money and points seeds use:
-- trg_system_settings_security refuses every write unless is_admin(), which is
-- auth.uid()-derived and therefore false on a migration connection.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings disable trigger %I', r.tgname);
  end loop;
end $$;

insert into public.system_settings (key, value, description) values
  ('trending_like_weight', '1'::jsonb,
   'Points added to a product''s trending score per like. Raise to favour likes, lower to favour sales.'),
  ('trending_order_weight', '3'::jsonb,
   'Points added to a product''s trending score per completed order. An order is a stronger signal than a like, so this starts higher than trending_like_weight.'),
  ('trending_half_life_days', '30'::jsonb,
   'How many days it takes for a product''s trending score to halve since its last signal. Lower means trending follows the news faster.'),
  ('trending_popular_threshold', '10'::jsonb,
   'Like count at or above which a product is marked Popular. Set to 0 to hide the mark everywhere.')
on conflict (key) do update
   set description = excluded.description
 where public.system_settings.description is distinct from excluded.description;

do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings enable trigger %I', r.tgname);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. The trending score
-- ─────────────────────────────────────────────────────────────────────────────

-- Half-life decay, as a pure function so it can be used in a view and, later,
-- in a generated column if the catalogue outgrows recomputing on read.
--
--   score * 0.5 ^ (age_days / half_life_days)
--
-- which is the textbook exponential half-life form. Written with power()
-- rather than a repeated halving loop so it is a single expression the
-- planner can evaluate once per row.
create or replace function public.trending_decay(
  age_days numeric,
  half_life_days numeric
)
returns numeric
language sql
immutable
as $$
  select case
    when half_life_days is null or half_life_days <= 0 then 0::numeric
    when age_days is null or age_days <= 0 then 1::numeric
    else power(0.5, age_days / half_life_days)
  end;
$$;

-- Reads the four settings, with the documented defaults if a row is missing,
-- so a deleted setting key degrades to a sane score rather than to NULL.
create or replace function public.trending_settings()
returns table (like_weight numeric, order_weight numeric, half_life_days numeric, popular_threshold integer)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_like_weight'), 1),
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_order_weight'), 3),
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_half_life_days'), 30),
    coalesce((select (value #>> '{}')::integer from public.system_settings
               where key = 'trending_popular_threshold'), 10);
$$;

grant execute on function public.trending_settings() to anon, authenticated, service_role;

-- The trending feed. One row per active product, scored from the current
-- weights, carrying the like state of the calling user so the client does not
-- need a second query to render filled vs outline hearts.
--
-- `last_signal_at` is the most recent of three things: the product being
-- created, someone liking it, and an order completing. Decaying from the most
-- recent signal rather than from the product's age is the difference between
-- "trending" and "newest" -- an old product that suddenly sells must be able
-- to climb back.
create or replace view public.product_trending
with (security_invoker = true)
as
with cfg as (select * from public.trending_settings()),
likes as (
  select product_id, count(*)::int as like_total, max(created_at) as last_liked
    from public.product_likes
   group by product_id
),
sales as (
  select oi.product_id,
         count(*)::int as completed_orders,
         max(o.created_at) as last_sold
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
   where o.status = 'COMPLETED'
     and oi.product_id is not null
   group by oi.product_id
),
mine as (
  select product_id
    from public.product_likes
   where user_id = auth.uid()
)
select
  p.id                as product_id,
  p.name,
  p.price,
  p.currency,
  p.provider_id,
  p.like_count,
  coalesce(s.completed_orders, 0) as completed_orders,
  (p.like_count > 0 and exists (select 1 from mine m where m.product_id = p.id))
    as liked_by_me,
  (p.like_count >= cfg.popular_threshold and cfg.popular_threshold > 0)
    as is_popular,
  greatest(
    cfg.like_weight * p.like_count
      + cfg.order_weight * coalesce(s.completed_orders, 0),
    0
  ) * public.trending_decay(
      extract(epoch from (now() - greatest(
        p.created_at,
        coalesce(l.last_liked, p.created_at),
        coalesce(s.last_sold, p.created_at)
      ))) / 86400.0,
      cfg.half_life_days
    ) as trending_score,
  now() as computed_at
from public.products p
cross join cfg
left join likes l on l.product_id = p.id
left join sales s on s.product_id = p.id
where p.is_active
  and p.listing_status = 'ACTIVE';

comment on view public.product_trending is
  'Server-side trending score from CEO-tunable weights in system_settings, with a half-life decay from the most recent signal. Recomputed on read so tuning a weight takes effect immediately.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. The toggle
--
-- One round trip, one atomic decision, returns the state the UI should show.
-- SECURITY INVOKER on purpose: RLS does the ownership check, so there is no
-- second copy of "is this mine" in this function that could disagree with the
-- policies.
--
-- The client applies the change optimistically and rolls back on failure, so
-- this is the authority, not the preview.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.toggle_product_like(p_product_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_liked boolean;
  v_count integer;
begin
  if v_user is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if exists (
    select 1 from public.product_likes
     where user_id = v_user and product_id = p_product_id
  ) then
    delete from public.product_likes
     where user_id = v_user and product_id = p_product_id;
    v_liked := false;
  else
    insert into public.product_likes (user_id, product_id)
    values (v_user, p_product_id);
    v_liked := true;
  end if;

  -- Read the counter back rather than computing it here. The trigger already
  -- updated it inside this transaction, so this is the same number the next
  -- list query will show -- no chance of the two disagreeing.
  select like_count into v_count
    from public.products
   where id = p_product_id;

  return jsonb_build_object(
    'product_id', p_product_id,
    'liked', v_liked,
    'like_count', v_count
  );
end;
$$;

comment on function public.toggle_product_like(uuid) is
  'Atomically adds or removes the caller''s like and returns the resulting liked flag and authoritative like_count. Rolls back on RLS violation; the client treats any error as "no change" and restores its optimistic value.';

grant execute on function public.toggle_product_like(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Hot-path index
--
-- The trending feed filters on the same active/listing_status pair the
-- existing product feed already uses, and orders by an expression. The index
-- that pays here is the one that narrows the candidate set before the scoring
-- runs, not one on the score itself.
-- ─────────────────────────────────────────────────────────────────────────────
create index if not exists idx_products_active_created
  on public.products (created_at desc)
  where is_active and listing_status = 'ACTIVE';

create index if not exists idx_order_items_product
  on public.order_items (product_id)
  where product_id is not null;
