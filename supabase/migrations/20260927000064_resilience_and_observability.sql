-- 20260927000064 — Resilience and observability
--
-- The client half of the resilience work (bootstrap, error boundaries,
-- retries) can only report what it catches, and a report needs somewhere to
-- land. This migration adds that, plus the two backend things the brief
-- asked for that can be verified from here: a statement_timeout for the
-- authenticated role, and indexes for the four hot read paths.
--
-- ─────────────────────────────────────────────────────────────────────────
-- 1. client_error_logs
-- ─────────────────────────────────────────────────────────────────────────
--
-- WHY A TABLE AND NOT A LOG FILE
-- The failure mode this exists to catch is "it only happens on my phone,
-- with a specific user, about ten minutes after they open the Orders tab".
-- Without a server-side sink that is unreportable, and the previous build
-- only wrote to the console, which is discarded on release.
--
-- RLS, in one line each:
--   * insert own rows only   — `user_id = auth.uid()`, so one user cannot
--                              write a log that looks like another's, and
--                              cannot forge a crash report to frame someone.
--   * read only as admin     — the CEO reads these; a normal user reading
--                              their own error text is a small information
--                              leak (it can contain screen context).
--   * no update, no delete   — the log is append-only evidence. An admin
--                              who can delete a crash report can hide a
--                              bug, which defeats the point of having it.
--
-- The app additionally rate-limits in ErrorLogger (a per-session cap plus
-- a dedupe window). That is a client-side courtesy, NOT a security control —
-- a hostile client ignores it. So the same bound is enforced here, in a
-- BEFORE INSERT trigger, where it cannot be bypassed. Both layers exist
-- deliberately: the trigger protects the database, the client cap protects
-- the user's battery.

create table if not exists public.client_error_logs (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references auth.users(id) on delete set null,
  -- Where it came from: flutter_error | platform_error | zone | startup |
  -- realtime | screen | rpc …
  error_source text not null,
  error_message text not null,
  -- Truncated client-side to 4000 chars; the column is text, not varchar,
  -- because the truncation is a courtesy and a hard varchar limit would
  -- turn a long stack into an insert failure — the one thing a logger
  -- must never do while trying to report a failure.
  stack_trace  text,
  error_context jsonb,
  is_fatal     boolean not null default false,
  -- Stable identity used for dedupe (source + first line of message).
  -- Indexed because the admin view groups by it to answer "how many
  -- distinct bugs are there" rather than "how many rows are there".
  fingerprint  text not null,
  created_at   timestamptz not null default now()
);

comment on table public.client_error_logs is
  'Client-reported crashes and handled failures. Append-only; see RLS below.';

-- Listing/recent view and dedupe grouping.
create index if not exists idx_client_error_logs_created
  on public.client_error_logs (created_at desc);
create index if not exists idx_client_error_logs_user
  on public.client_error_logs (user_id, created_at desc);
create index if not exists idx_client_error_logs_fingerprint
  on public.client_error_logs (fingerprint);

alter table public.client_error_logs enable row level security;

do $$ begin
  create policy client_error_logs_insert_own on public.client_error_logs
    for insert to authenticated
    with check (auth.uid() IS NOT NULL AND user_id = auth.uid());
exception when duplicate_object then null; end $$;

do $$ begin
  create policy client_error_logs_admin_read on public.client_error_logs
    for select to authenticated
    using (is_admin());
exception when duplicate_object then null; end $$;

-- Intentionally NO update and NO delete policy. Append-only.

grant insert on public.client_error_logs to authenticated;
grant select on public.client_error_logs to authenticated;

-- Server-side flood guard. A crash in a build() method fires once per
-- frame; at 60fps that is 216,000 rows a minute and it would take the
-- table — and the user — down. The cap is deliberately generous (200 rows
-- per hour per user) because the client's own cap is far lower; this
-- exists to stop a hostile or broken client, not to tune normal operation.
create or replace function public.trg_client_error_logs_flood_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recent integer;
begin
  select count(*) into v_recent
    from public.client_error_logs
   where user_id = new.user_id
     and created_at > now() - interval '1 hour';

  if v_recent >= 200 then
    -- Silently drop rather than raise. Raising would surface inside the
    -- ErrorLogger's own error path, where failures are already swallowed;
    -- the only visible effect of raising here would be a stack trace in a
    -- console nobody reads. The client is already rate-limited, so this
    -- branch is a backstop, not the normal path.
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_client_error_logs_flood on public.client_error_logs;
create trigger trg_client_error_logs_flood
  before insert on public.client_error_logs
  for each row execute function public.trg_client_error_logs_flood_guard();

-- ─────────────────────────────────────────────────────────────────────────
-- 2. statement_timeout for the authenticated role
-- ─────────────────────────────────────────────────────────────────────────
--
-- WHY NOT SET IT GLOBALLY
-- `alter role postgres` / `alter role service_role` would cap migrations
-- and Edge Functions too, and a long analytics query is legitimate. The
-- authenticated role is different: it is the app, and every query it runs
-- is on a phone with a spinner behind it. A query that has not finished in
-- 15 seconds is not one a user is still waiting for — they have left.
--
-- 15s rather than something tighter because the slowest real path is the
-- city-scoped product feed with a popularity sort, and cutting that off
-- would trade a slow screen for a wrong one.
--
-- Scoped with a guard so re-running this migration does not stack applies.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'alter role authenticated set statement_timeout = 15000';
  end if;
end $$;

-- ─────────────────────────────────────────────────────────────────────────
-- 3. Indexes for the four hot read paths
-- ─────────────────────────────────────────────────────────────────────────
--
-- Every index below corresponds to a query the app issues on every visit
-- to a primary screen, and every one of them is a filter + sort composite.
-- The existing indexes are all single-column, which Postgres can use for
-- the filter and then has to sort separately — on a table that grows with
-- orders, "sort separately" is the difference between 5ms and a timeout.
--
-- Listed with the exact query each one serves, so a future change to the
-- query without a matching index change is visible.

-- Home feed: active products in a city, ranked by popularity then recency.
--   select * from products where is_active
--    and (city = $1 or city is null)
--    order by sales_count desc nulls last, created_at desc limit 20
-- The partial predicate (`where is_active`) keeps the index small: inactive
-- listings are never shown and never need to be in the index at all.
create index if not exists idx_products_active_popular
  on public.products (sales_count desc nulls last, created_at desc)
  where is_active;

-- Orders list: one user's orders, newest first.
--   select * from orders where user_id = $1 order by created_at desc limit 50
-- Existing idx_orders_user covers the filter alone; this one is ordered so
-- the LIMIT can be satisfied by an index scan instead of a top-N sort.
create index if not exists idx_orders_user_recent
  on public.orders (user_id, created_at desc);

-- Provider order list — same shape, other side of the marketplace.
--   select * from orders where provider_id = $1 order by created_at desc
create index if not exists idx_orders_provider_recent
  on public.orders (provider_id, created_at desc);

-- Notifications: a user's inbox, newest first.
--   select * from notifications where user_id = $1 order by created_at desc
create index if not exists idx_notifications_user_recent
  on public.notifications (user_id, created_at desc);

-- Driver open-request feed, filtered by the column the client actually
-- watches. `status` is not the primary key, which is exactly why this feed
-- needed REPLICA IDENTITY FULL (migration 61) — the same fact makes the
-- partial index here worthwhile.
--
-- The value list must match the enum exactly, or the whole migration fails
-- with `invalid input value for enum ride_status` and nothing applies at
-- all. These are the five statuses ride_service.dart treats as "not
-- finished": a ride is dropped from the index the moment it reaches
-- COMPLETED or CANCELLED, which is what keeps the driver's polling feed
-- short.
create index if not exists idx_ride_requests_open_by_status
  on public.ride_requests (status, created_at desc)
  where status in ('REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING', 'ARRIVED', 'TRIP_STARTED');

-- ─────────────────────────────────────────────────────────────────────────
-- 4. assert_resilience_is_wired()
-- ─────────────────────────────────────────────────────────────────────────
--
-- The Dart side has an ErrorLogger and the bootstrap; this checks the half
-- that can silently not exist — that the table is there, that the policies
-- say what the client assumes, and that the indexes the hot paths need were
-- actually created. A migration that creates a table and a policy with a
-- typo fails open: the app logs into a void and nobody finds out.
create or replace function public.assert_resilience_is_wired()
returns boolean
language plpgsql
as $$
declare
  v_missing text[] := '{}';
begin
  -- 1. The sink exists.
  if to_regclass('public.client_error_logs') is null then
    v_missing := v_missing || 'table client_error_logs missing';
  end if;

  -- 2. RLS is ON. An un-RLS'd table is world-writable and every row is a
  --    forgeable crash report.
  if exists (
    select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'client_error_logs'
       and not c.relrowsecurity
  ) then
    v_missing := v_missing || 'client_error_logs has RLS disabled';
  end if;

  -- 3. Exactly the two intended policies, and no write-back policy.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and policyname = 'client_error_logs_insert_own' and cmd = 'INSERT'
  ) then
    v_missing := v_missing || 'missing insert-own policy';
  end if;
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and policyname = 'client_error_logs_admin_read' and cmd = 'SELECT'
  ) then
    v_missing := v_missing || 'missing admin-read policy';
  end if;
  if exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and cmd in ('UPDATE', 'DELETE')
  ) then
    v_missing := v_missing ||
      'client_error_logs must be append-only (an UPDATE/DELETE policy exists)';
  end if;

  -- 4. The flood guard trigger is attached.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.client_error_logs'::regclass
       and tgname = 'trg_client_error_logs_flood'
       and not tgisinternal
  ) then
    v_missing := v_missing || 'flood guard trigger not attached';
  end if;

  -- 5. The hot-path indexes exist. Named explicitly so a dropped or renamed
  --    index names itself in the failure rather than producing a bare count.
  if to_regclass('public.idx_products_active_popular') is null then
    v_missing := v_missing || 'idx_products_active_popular missing';
  end if;
  if to_regclass('public.idx_orders_user_recent') is null then
    v_missing := v_missing || 'idx_orders_user_recent missing';
  end if;
  if to_regclass('public.idx_orders_provider_recent') is null then
    v_missing := v_missing || 'idx_orders_provider_recent missing';
  end if;
  if to_regclass('public.idx_notifications_user_recent') is null then
    v_missing := v_missing || 'idx_notifications_user_recent missing';
  end if;
  if to_regclass('public.idx_ride_requests_open_by_status') is null then
    v_missing := v_missing || 'idx_ride_requests_open_by_status missing';
  end if;

  -- 6. The timeout is actually applied to the role.
  --
  --    Checked with array containment, NOT equality. `rolconfig` is the
  --    role's entire set of per-role GUCs, so a strict `= array[...]` would
  --    start failing the moment any other migration sets anything on this
  --    role — turning a real regression into an unrelated red build that
  --    nobody trusts. Containment asks the question actually being asked:
  --    "is statement_timeout 15s on this role?"
  begin
    if not exists (
      select 1 from pg_roles
       where rolname = 'authenticated'
         and 'statement_timeout=15s' = any (rolconfig)
    ) then
      v_missing := v_missing ||
        'authenticated statement_timeout is not 15s (got: ' ||
        coalesce((select array_to_string(rolconfig, ',')
                    from pg_roles where rolname = 'authenticated'), 'NULL') || ')';
    end if;
  exception when undefined_object then
    v_missing := v_missing || 'role authenticated does not exist';
  end;

  if cardinality(v_missing) > 0 then
    raise exception 'RESILIENCE_NOT_WIRED: %', array_to_string(v_missing, '; ')
      using errcode = 'P0001';
  end if;

  return true;
end;
$$;

comment on function public.assert_resilience_is_wired() is
  'Fails loudly if the client error sink, its RLS, or a hot-path index is missing.';

grant execute on function public.assert_resilience_is_wired() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────
-- 5. Keep the write-surface report honest
-- ─────────────────────────────────────────────────────────────────────────
--
-- `client_write_surface_report()` (migration 42) carries a hardcoded list of
-- the tables the app is EXPECTED to write directly, and
-- `test/client_write_surface_test.dart` reads the same list from the Dart
-- side. The test fails if the two disagree, which is the whole point — so
-- adding a genuine client write means updating BOTH, and this is the SQL
-- half of that.
--
-- client_error_logs genuinely belongs in the list: ErrorLogger inserts
-- straight into it with no SECURITY DEFINER wrapper, because the entire
-- purpose is that an app which is failing can still record why. It is
-- guarded — RLS forces user_id = auth.uid() and only INSERT is granted — so
-- it does not appear in the report's "unguarded" list.
create or replace function public.client_write_surface_report()
returns table (
  kind text,
  tables text[]
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  WITH expected(t) AS (
    VALUES
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('cart_items'), ('chat_logs'), ('client_error_logs'), ('favorites'),
      ('notifications'),
      ('order_messages'), ('payment_methods'), ('payment_proofs'),
      ('product_images'), ('products'), ('profiles'), ('provider_profiles'),
      ('reviews'), ('ride_ratings'), ('support_tickets'), ('user_documents'),
      ('vehicles'), ('wallet_recharge_requests')
  ),
  writable AS (
    SELECT DISTINCT tablename
    FROM pg_policies
    WHERE schemaname = 'public'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND has_table_privilege('authenticated', format('public.%I', tablename), 'INSERT')
  ),
  unguarded AS (
    SELECT w.tablename
    FROM writable w
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = w.tablename
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  SELECT 'expected',    COALESCE(array_agg(t ORDER BY t), '{}') FROM expected
  UNION ALL
  SELECT 'unexpected', COALESCE(array_agg(w.tablename ORDER BY w.tablename), '{}')
    FROM writable w WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.t = w.tablename)
  UNION ALL
  SELECT 'unguarded',   COALESCE(array_agg(tablename ORDER BY tablename), '{}') FROM unguarded;
$$;

comment on function public.client_write_surface_report() is
  'Compares the tables the app is expected to write against the ones it can. client_error_logs is expected: an app that is failing must be able to record why.';

-- Re-granted explicitly even though CREATE OR REPLACE preserves the grants
-- from migration 42. A future refactor of this file that turns the statement
-- into DROP + CREATE would otherwise silently take EXECUTE away from the
-- connectivity suite, and the failure would read as "the report is empty"
-- rather than "you forgot the grant".
grant execute on function public.client_write_surface_report() to anon, authenticated;
