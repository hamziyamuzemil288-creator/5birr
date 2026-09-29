-- =============================================================================
-- 20260927000076 — make a like actually persist, and add a dislike
-- =============================================================================
--
-- WHY THIS EXISTS
-- ---------------
-- A like on a product card filled, then emptied again a moment later. Two
-- independent causes, both real, either one of which alone produces exactly
-- that symptom.
--
-- ── Cause 1: every like write was refused by the provider write gate ──────
--
-- Liking inserts into product_likes. trg_product_likes_count is an AFTER
-- INSERT OR DELETE trigger that maintains products.like_count, so the insert
-- issues an UPDATE against products. On products sits
-- trg_provider_product_write_gate -> enforce_provider_write_gate(), whose job
-- is to stop a client editing a listing that is not its own. It asks
--
--   SELECT user_id FROM provider_profiles WHERE id = NEW.provider_id
--   IF v_user_id IS DISTINCT FROM auth.uid() ...
--
-- The caller is a BUYER, so the provider's user_id is by definition not
-- auth.uid(), the IF is true, and the gate raises
-- PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED. That exception propagates
-- out of the trigger, out of the INSERT, out of toggle_product_like, and the
-- client's `catch (_)` rolls the heart back to empty. Nothing is written,
-- and the user is told nothing.
--
-- The gate was right about what it could see and wrong about what it was
-- looking at. It is a client-write guard, and the write it rejected was not a
-- client write: it was the database maintaining a denormalised counter on
-- somebody else's behalf.
--
-- The fix is the one discriminator a client cannot forge:
-- pg_trigger_depth(). A top-level client write to products runs this trigger
-- at depth 1. A write performed from inside another trigger — which is what
-- a counter trigger is — runs it at depth 2. There is no GUC to set and no
-- role to claim; the server counts the nesting itself.
--
-- This is not a blanket exemption. To reach depth 2 the client must already
-- be inside a trigger, and the values it then writes are the outer trigger's
-- values, not the client's. The only client-reachable outer trigger that
-- writes products is trg_product_likes_count, whose UPDATE is
-- `like_count = like_count ± 1`.
--
-- ── Cause 2: the client's like state was never read from the server ──────
--
-- ProductLikeService.isLiked() answered from an in-memory map, and
-- hydrate() — the only thing that was ever meant to fill that map from the
-- server — had no caller anywhere in lib/. So a user who had liked a product
-- in a previous session saw an empty heart, tapped it, and the server, which
-- did have their row, toggled it OFF. The authoritative `liked: false` came
-- back and the heart emptied. Same symptom, different cause, and fixing only
-- the database would have left it.
--
-- So the client is given a batched load (one round trip for a grid of
-- cards, not one per card) and the two screens that show a product ask for it.
--
-- ── Part 2: the dislike ───────────────────────────────────────────────────
--
-- DECISION: the same table, a `reaction` column, not a parallel
-- product_dislikes table. The reasons are concrete rather than aesthetic:
--
--   * The unique (user_id, product_id) constraint already gives "one
--     reaction per user per product" for free, which is exactly the
--     mutual-exclusion rule Part 2 asks to be enforced server-side. A second
--     table would have needed a cross-table trigger to enforce the same
--     thing, and a cross-table trigger is a place the two tables can drift.
--   * There is deliberately no UPDATE policy on product_likes (a reaction has
--     no state to update — it is either there or not). A change of reaction
--     is therefore DELETE + INSERT, which means the existing AFTER INSERT OR
--     DELETE counter trigger is already the right shape and only needs to read
--     which counter to move off OLD.reaction / NEW.reaction.
--   * One table means one set of RLS policies, one grant, one entry in the
--     client write surface, one set of indexes. A parallel table would have
--     doubled all six to carry one more enum value.
--
-- The cost is honest and worth stating: the table is now named
-- product_likes while also holding dislikes. It is not renamed here, because
-- product_likes is already pinned in client_write_surface_report() (migration
-- 70) and in test/client_write_surface_test.dart, and a rename would ripple
-- into both for no functional gain. The comment on the table records what it
-- now means.
--
-- ── Dislike counts are NOT public ─────────────────────────────────────────
--
-- DECISION: `products.dislike_count` exists and is maintained by the trigger,
-- but it is never exposed to the app, and there is no dislike number on any
-- card. The reasoning:
--
--   * Nothing consumes it. A like count has a consumer from day one — the
--     Popular flame at the CEO-set threshold — and a public dislike number has
--     no user-facing meaning to offer a buyer, who is deciding whether to buy
--     something, not whether to pile on something.
--   * On a marketplace with a thin buyer base per listing, one dislike is a
--     death mark. A count that reads "1" tells a buyer nothing true and a
--     provider something unforgiving.
--   * The value that IS worth having is its effect on ranking, which a buyer
--     benefits from silently. So the signal is used, just not displayed.
--
-- It therefore feeds trending, negatively and weakly, through
-- trending_dislike_weight in system_settings alongside the existing weights,
-- defaulting to 0.5. A default of 0 would have made the whole feature inert;
-- a large value would let one dislike outrank a sale. 0.5 against
-- trending_like_weight of 1 means ten dislikes offset five likes, and a
-- single completed order (weight 3) still outweighs six dislikes. The CEO can
-- set it to 0 to switch the effect off without a release, exactly as
-- trending_popular_threshold = 0 hides the Popular mark.
-- -----------------------------------------------------------------------------

-- ===========================================================================
-- 1. The provider write gate stops rejecting server-maintained counters
--
--    Restated in full (same name, same signature, same SECURITY DEFINER
--    posture). The only change is the added pg_trigger_depth() branch; the
--    service-role escape, the provider lookup and the exception are
--    byte-for-byte what 20260924000004 wrote.
--
--    CREATE OR REPLACE keeps the function's oid, so both triggers that
--    reference it stay attached and do not need recreating.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.enforce_provider_write_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  -- A denormalised counter being maintained by another trigger. The UPDATE
  -- on products here is products.like_count / dislike_count, issued by
  -- trg_product_likes_count, not by the client whose session is current. A
  -- top-level client write to products runs at depth 1 and is still judged on
  -- every line below.
  IF pg_trigger_depth() > 1 THEN
    RETURN NEW;
  END IF;

  -- Service-role verification/maintenance paths are trusted by role.
  IF auth.uid() IS NULL
     OR current_setting('request.jwt.claim.role', true) = 'service_role'
     OR public.is_admin() THEN
    RETURN NEW;
  END IF;

  SELECT user_id INTO v_user_id
  FROM public.provider_profiles
  WHERE id = NEW.provider_id;

  IF v_user_id IS DISTINCT FROM auth.uid() OR NOT public.provider_can_publish(NEW.provider_id) THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enforce_provider_write_gate() IS
  'Refuses a client write to a guarded table belonging to a provider that is not the caller''s, or to a provider that cannot publish. Exempts writes made from inside another trigger (pg_trigger_depth() > 1), which is how denormalised counters are maintained: trg_product_likes_count updates products.like_count on behalf of a user who is not the provider, and this gate used to refuse every like with PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED.';

-- ===========================================================================
-- 2. The reaction column, and the counter it moves
-- ===========================================================================

-- One row per (user, product) already, so a user cannot hold a like and a
-- dislike at once: there is nowhere for the second one to go. The CHECK is
-- what stops a third, meaningless value appearing.
alter table public.product_likes
  add column if not exists reaction text not null default 'LIKE';

alter table public.product_likes
  drop constraint if exists product_likes_reaction_check;
alter table public.product_likes
  add constraint product_likes_reaction_check
  check (reaction in ('LIKE','DISLIKE'));

comment on column public.product_likes.reaction is
  'LIKE or DISLIKE. The table is named for the feature that came first; it now holds both. Exclusive by construction: the unique (user_id, product_id) constraint means a user has at most one reaction per product, and set_product_reaction() deletes the opposite one rather than updating.';

comment on table public.product_likes is
  'One row per (user, product) carrying a LIKE or a DISLIKE. Reaction state only -- there is nothing to update, so there is no UPDATE policy and a change of reaction is a delete plus an insert.';

alter table public.products
  add column if not exists dislike_count integer not null default 0;

comment on column public.products.dislike_count is
  'Maintained by trg_product_likes_count. Never written by the app and deliberately NOT exposed to the client: it feeds the trending score through trending_dislike_weight and is shown nowhere.';

-- The counter. On INSERT it moves the counter named by NEW.reaction; on
-- DELETE, the one named by OLD.reaction. That is the whole change from
-- migration 68's version, which had a single counter to move.
CREATE OR REPLACE FUNCTION public.trg_product_likes_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
begin
  if tg_op = 'INSERT' then
    if new.reaction = 'DISLIKE' then
      update public.products
         set dislike_count = dislike_count + 1
       where id = new.product_id;
    else
      update public.products
         set like_count = like_count + 1
       where id = new.product_id;
    end if;
    return new;
  end if;

  if old.reaction = 'DISLIKE' then
    update public.products
       set dislike_count = greatest(dislike_count - 1, 0)
     where id = old.product_id;
  else
    update public.products
       set like_count = greatest(like_count - 1, 0)
     where id = old.product_id;
  end if;
  return old;
end;
$$;

-- Backfill, recomputed rather than added, so running this twice is a no-op.
update public.products p
   set dislike_count = coalesce(
         (select count(*) from public.product_likes l
           where l.product_id = p.id and l.reaction = 'DISLIKE'), 0)
 where p.dislike_count <> coalesce(
         (select count(*) from public.product_likes l
           where l.product_id = p.id and l.reaction = 'DISLIKE'), 0);

-- ===========================================================================
-- 3. RLS
--
-- Unchanged, and restated in full so the shape is readable next to the code
-- that depends on it. product_likes is the house pattern for a per-user
-- table and a dislike is not a different kind of row, so it takes the same
-- three policies verbatim: a user manages only their own, anyone signed in may
-- read (the client hydrates its own reaction state through this), and nobody
-- may update.
-- ===========================================================================
alter table public.product_likes enable row level security;

drop policy if exists product_likes_insert_own on public.product_likes;
create policy product_likes_insert_own on public.product_likes
  for insert to authenticated
  with check (auth.uid() = user_id);

drop policy if exists product_likes_delete_own on public.product_likes;
create policy product_likes_delete_own on public.product_likes
  for delete to authenticated
  using (auth.uid() = user_id);

drop policy if exists product_likes_read_authenticated on public.product_likes;
create policy product_likes_read_authenticated on public.product_likes
  for select to authenticated
  using (true);

-- A LIKE and a DISLIKE are the same kind of statement, so the grant is too.
grant select, insert, delete on public.product_likes to authenticated;

-- ===========================================================================
-- 4. The write path
--
-- set_product_reaction() replaces toggle_product_like() as the function the
-- client calls, and the difference is the reason the optimistic toggle can be
-- made correct. toggle_product_like() flips whatever is there: a client whose
-- local state was stale, or which retried a request it had not seen the answer
-- to, flipped the row the wrong way and had no way to express "I want LIKE,
-- not whatever this currently is". A setter says what it wants. It is also
-- idempotent, so a resend is harmless and out-of-order arrivals cannot invert
-- the user's most recent intent.
--
-- SECURITY INVOKER, as the original was: RLS does the ownership check, so
-- there is no second copy of "is this mine" here that could disagree with the
-- policies.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.set_product_reaction(
  p_product_id uuid,
  p_reaction text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_reaction text := upper(coalesce(p_reaction, 'NONE'));
  v_like_count integer;
  v_dislike_count integer;
BEGIN
  if v_user is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;

  if v_reaction not in ('LIKE','DISLIKE','NONE') then
    raise exception 'INVALID_REACTION' using errcode = '22023';
  end if;

  if not exists (select 1 from public.products where id = p_product_id) then
    raise exception 'PRODUCT_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Delete first, unconditionally. For NONE that is the whole operation; for
  -- LIKE or DISLIKE it is what makes the two mutually exclusive server-side
  -- rather than merely in the UI, because the surviving row is the one the
  -- unique (user_id, product_id) constraint allows to exist.
  delete from public.product_likes
   where user_id = v_user and product_id = p_product_id;

  if v_reaction <> 'NONE' then
    insert into public.product_likes (user_id, product_id, reaction)
    values (v_user, p_product_id, v_reaction);
  end if;

  -- Read the counters back rather than computing them here. The trigger
  -- already updated them inside this transaction, so these are the same
  -- numbers the next list query will show.
  select like_count, dislike_count into v_like_count, v_dislike_count
    from public.products
   where id = p_product_id;

  return jsonb_build_object(
    'product_id', p_product_id,
    'reaction', case when v_reaction = 'NONE' then null else v_reaction end,
    'liked', v_reaction = 'LIKE',
    'disliked', v_reaction = 'DISLIKE',
    'like_count', v_like_count,
    'dislike_count', v_dislike_count
  );
end;
$$;

comment on function public.set_product_reaction(uuid, text) is
  'Sets the caller''s reaction on a product to LIKE, DISLIKE or NONE, and returns the resulting state and both authoritative counters. A setter rather than a toggle, so it is idempotent and a stale client cannot flip the wrong way. Mutual exclusion is enforced here, not only in the UI: the opposite row is deleted before the new one is inserted, and the unique (user_id, product_id) constraint means only one can exist.';

grant execute on function public.set_product_reaction(uuid, text) to authenticated;

-- The old entry point is kept so nothing that already calls it breaks, and is
-- restated on top of the setter so the two can never disagree about what a
-- reaction is. A toggle is still a toggle; it just is no longer what the
-- client uses.
CREATE OR REPLACE FUNCTION public.toggle_product_like(p_product_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_liked boolean;
BEGIN
  if v_user is null then
    raise exception 'NOT_SIGNED_IN' using errcode = '42501';
  end if;

  select (reaction = 'LIKE') into v_liked
    from public.product_likes
   where user_id = v_user and product_id = p_product_id;

  return public.set_product_reaction(p_product_id, case when v_liked then 'NONE' else 'LIKE' end);
end;
$$;

-- ===========================================================================
-- 5. Trending
--
-- trending_dislike_weight joins the three that exist. CREATE OR REPLACE
-- cannot change a function's return type, so the old one is dropped first;
-- nothing depends on it at the catalog level (a view body does not register a
-- dependency on the functions inside it), which is why the drop is safe.
-- ===========================================================================
-- Seeded through the same guard-lift the other money and points seeds use:
-- trg_system_settings_security refuses every write unless is_admin(), which is
-- auth.uid()-derived and therefore false on a migration connection. Without
-- this the deploy fails with the guard's own exception.
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
  ('trending_dislike_weight', '0.5'::jsonb,
   'Points subtracted from a product''s trending score per dislike. Set to 0 to ignore dislikes in ranking entirely. Dislike counts are never shown to buyers; this is the only place they are used.')
on conflict (key) do update
  set description = excluded.description
 where public.system_settings.description is distinct from excluded.description;

-- Restore the guards immediately, before anything else in this file writes.
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

drop function if exists public.trending_settings();

CREATE OR REPLACE FUNCTION public.trending_settings()
RETURNS TABLE (
  like_weight numeric,
  dislike_weight numeric,
  order_weight numeric,
  half_life_days numeric,
  popular_threshold integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  select
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_like_weight'), 1),
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_dislike_weight'), 0.5),
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_order_weight'), 3),
    coalesce((select (value #>> '{}')::numeric from public.system_settings
               where key = 'trending_half_life_days'), 30),
    coalesce((select (value #>> '{}')::integer from public.system_settings
               where key = 'trending_popular_threshold'), 10);
$$;

comment on function public.trending_settings() IS
  'The CEO-tunable trending weights, each with its documented default so a deleted key degrades to a sane score rather than to NULL. dislike_weight is 0.5: ten dislikes offset five likes, and one completed order still outweighs six.';

grant execute on function public.trending_settings() to anon, authenticated, service_role;

-- The view. Recreated rather than replaced, so disliked_by_me can sit next to
-- liked_by_me instead of being appended after computed_at; CREATE OR REPLACE
-- VIEW may only add columns at the end, and the ordering matters to anyone
-- reading the definition.
drop view if exists public.product_trending;

CREATE OR REPLACE VIEW public.product_trending
WITH (security_invoker = true)
AS
with cfg as (select * from public.trending_settings()),
signals as (
  -- One pass over product_likes for both reactions. Split into two subqueries
  -- this would read the table twice for no benefit, and the table grows.
  select product_id,
         count(*) filter (where reaction = 'LIKE')::int as like_total,
         count(*) filter (where reaction = 'DISLIKE')::int as dislike_total,
         max(created_at) as last_reacted
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
  select product_id, reaction
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
  exists (select 1 from mine m
           where m.product_id = p.id and m.reaction = 'LIKE')
    as liked_by_me,
  exists (select 1 from mine m
           where m.product_id = p.id and m.reaction = 'DISLIKE')
    as disliked_by_me,
  (p.like_count >= cfg.popular_threshold and cfg.popular_threshold > 0)
    as is_popular,
  greatest(
    cfg.like_weight * p.like_count
      - cfg.dislike_weight * p.dislike_count
      + cfg.order_weight * coalesce(s.completed_orders, 0),
    0
  ) * public.trending_decay(
      extract(epoch from (now() - greatest(
        p.created_at,
        coalesce(sg.last_reacted, p.created_at),
        coalesce(s.last_sold, p.created_at)
      ))) / 86400.0,
      cfg.half_life_days
    ) as trending_score,
  now() as computed_at
from public.products p
cross join cfg
left join signals sg on sg.product_id = p.id
left join sales s on s.product_id = p.id
where p.is_active
  and p.listing_status = 'ACTIVE';

comment on view public.product_trending is
  'Server-side trending score from CEO-tunable weights in system_settings, with a half-life decay from the most recent signal, and a small negative weight on dislikes. Recomputed on read so tuning a weight takes effect immediately. Carries dislike_count nowhere on purpose: the score uses it, no surface displays it.';

-- PostgREST caches view definitions as well as function signatures.
NOTIFY pgrst, 'reload schema';

-- ===========================================================================
-- 6. The write test
--
-- This is a WRITE assertion on purpose, and it is the one that would have
-- caught cause 1. Every like-related check that existed before this was a
-- source-text grep over pg_proc.prosrc: the trigger was there, the function
-- was there, the policies were there, and all of it looked correct while
-- every single like in the app was being refused.
--
-- It acts as a real non-admin user, through the real function, with every
-- real trigger attached, and requires:
--
--   1. a LIKE persists, with products.like_count incremented;
--   2. a DISLIKE replaces the LIKE, with both counters correct -- the
--      mutual-exclusion rule, proved rather than asserted;
--   3. NONE removes the row and returns both counters to their start;
--   4. a reaction written for somebody ELSE is refused, so the RLS is proven
--      to bite in the same breath.
--
-- Rolls back through the usual sentinel, on fixed fixture ids, so nothing
-- accumulates.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_likes_persist_and_are_exclusive()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prov  uuid := '00000000-0000-4000-8000-0000000007a1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_result jsonb;
  v_rows int;
  v_like int;
  v_dislike int;
BEGIN
  BEGIN
    -- Fixtures first, BEFORE the JWT claims are set. Once we are acting as a
    -- buyer, the provider write gate refuses to let us create a product --
    -- which is the guard working, and exactly why these come first.
    INSERT INTO auth.users (id, email, email_confirmed_at)
    VALUES (v_user,  'like-probe@example.invalid', now()),
           (v_other, 'like-probe-other@example.invalid', now())
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user,  'Like Probe',      'PENDING_APPROVAL'),
           (v_other, 'Like Probe Other', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    -- An APPROVED provider, which no client could create. The guard is off for
    -- this one row, inside the subtransaction about to be rolled back.
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES (v_prov, v_other, 'SERVICE_PROVIDER', 'Like Probe Provider', 'APPROVED')
    ON CONFLICT (id) DO NOTHING;
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    INSERT INTO public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    VALUES (v_prod, v_prov, 'Like Probe Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    ON CONFLICT (id) DO NOTHING;

    -- Start from a known count. A previous rolled-back run leaves nothing, but
    -- ON CONFLICT DO NOTHING means a fixture row may already exist, and the
    -- assertions below are about deltas.
    UPDATE public.products SET like_count = 0, dislike_count = 0 WHERE id = v_prod;

    -- Act as a plain signed-in buyer, who is not the provider and not an admin.
    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    IF public.is_admin() THEN
      RAISE EXCEPTION 'the like probe is unexpectedly an admin, so this test cannot prove anything';
    END IF;

    -- ── 1. A like persists ──
    v_result := public.set_product_reaction(v_prod, 'LIKE');
    IF (v_result->>'liked')::boolean IS NOT TRUE THEN
      RAISE EXCEPTION 'set_product_reaction LIKE did not report liked=true: %', v_result;
    END IF;

    SELECT count(*) INTO v_rows FROM public.product_likes
     WHERE user_id = v_user AND product_id = v_prod AND reaction = 'LIKE';
    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'the like did not persist: % row(s) in product_likes', v_rows;
    END IF;

    SELECT like_count, dislike_count INTO v_like, v_dislike
      FROM public.products WHERE id = v_prod;
    IF v_like <> 1 OR v_dislike <> 0 THEN
      RAISE EXCEPTION 'after LIKE the counters are like=% dislike=% , expected 1 and 0. '
                      'This is the regression: the counter UPDATE on products is being '
                      'refused by enforce_provider_write_gate.', v_like, v_dislike;
    END IF;
    IF (v_result->>'like_count')::int <> 1 THEN
      RAISE EXCEPTION 'set_product_reaction returned like_count %, expected 1', v_result->>'like_count';
    END IF;

    -- ── 2. A dislike replaces the like, and only one row can exist ──
    v_result := public.set_product_reaction(v_prod, 'DISLIKE');

    SELECT count(*) INTO v_rows FROM public.product_likes
     WHERE user_id = v_user AND product_id = v_prod;
    IF v_rows <> 1 THEN
      RAISE EXCEPTION 'a user holds % reaction rows for one product; the like and the '
                      'dislike are not mutually exclusive', v_rows;
    END IF;
    IF NOT EXISTS (select 1 from public.product_likes
                    where user_id = v_user and product_id = v_prod and reaction = 'DISLIKE') THEN
      RAISE EXCEPTION 'the dislike did not replace the like';
    END IF;

    SELECT like_count, dislike_count INTO v_like, v_dislike
      FROM public.products WHERE id = v_prod;
    IF v_like <> 0 OR v_dislike <> 1 THEN
      RAISE EXCEPTION 'after DISLIKE the counters are like=% dislike=% , expected 0 and 1', v_like, v_dislike;
    END IF;

    -- ── 3. NONE removes it and gives both counters back ──
    v_result := public.set_product_reaction(v_prod, 'NONE');
    IF (v_result->>'liked')::boolean IS NOT FALSE
       OR (v_result->>'disliked')::boolean IS NOT FALSE THEN
      RAISE EXCEPTION 'set_product_reaction NONE still reports a reaction: %', v_result;
    END IF;

    SELECT count(*) INTO v_rows FROM public.product_likes
     WHERE user_id = v_user AND product_id = v_prod;
    IF v_rows <> 0 THEN
      RAISE EXCEPTION 'NONE left % reaction row(s) behind', v_rows;
    END IF;

    SELECT like_count, dislike_count INTO v_like, v_dislike
      FROM public.products WHERE id = v_prod;
    IF v_like <> 0 OR v_dislike <> 0 THEN
      RAISE EXCEPTION 'after NONE the counters are like=% dislike=% , expected 0 and 0', v_like, v_dislike;
    END IF;

    -- ── 4. The RLS bites: somebody else's reaction is refused ──
    -- Without this the "you may only manage your own row" half of the policy
    -- would be untested, and a like feature that let a user write rows for
    -- other users would be a vote-forging primitive.
    BEGIN
      INSERT INTO public.product_likes (user_id, product_id, reaction)
      VALUES (v_other, v_prod, 'LIKE');
      RAISE EXCEPTION 'a user was able to write a reaction row for somebody else';
    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM = 'a user was able to write a reaction row for somebody else' THEN
          RAISE;
        END IF;
        NULL;  -- any other error is the refusal we wanted
    END;

    RAISE EXCEPTION '%', c_sentinel;

  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = c_sentinel THEN
        RETURN true;
      END IF;
      RAISE;
  END;
END;
$$;

COMMENT ON FUNCTION public.assert_likes_persist_and_are_exclusive() IS
  'WRITE test: acts as a real non-admin buyer and requires a LIKE to persist with products.like_count incremented, a DISLIKE to replace it with both counters correct, NONE to remove it, and a reaction written for another user to be refused. Every previous like-related check was a pg_proc.prosrc grep, which is how a database where every like in the app was being refused by enforce_provider_write_gate looked entirely correct. Rolls back via a sentinel; fixture ids are fixed and inert.';

GRANT EXECUTE ON FUNCTION public.assert_likes_persist_and_are_exclusive() TO anon, authenticated;

-- The gate fix is load-bearing, so it is pinned independently of the write
-- test, which needs products to exist. A prosrc check is the right tool HERE
-- because the property is "this branch is present", and the behavioural half
-- is covered by the assertion above.
CREATE OR REPLACE FUNCTION public.assert_provider_write_gate_allows_counter_updates()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
BEGIN
  SELECT p.prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'enforce_provider_write_gate'
   LIMIT 1;

  v_src := regexp_replace(lower(coalesce(v_src, '')), E'\\s+', ' ', 'g');

  IF position('pg_trigger_depth() > 1' in v_src) = 0 THEN
    RETURN false;
  END IF;

  -- The exemption must not be a blanket pass: the provider check it sits
  -- above has to still be there, or the gate would have been opened rather
  -- than scoped.
  IF position('provider_not_activated_or_documents_required' in v_src) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_write_gate_allows_counter_updates() IS
  'True when enforce_provider_write_gate exempts writes made from inside another trigger (pg_trigger_depth() > 1) AND still refuses the write it was written to refuse. The behavioural half is assert_likes_persist_and_are_exclusive().';

GRANT EXECUTE ON FUNCTION public.assert_provider_write_gate_allows_counter_updates() TO anon, authenticated;
