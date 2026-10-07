-- =============================================================================
-- 20261007000015 — the four connectivity findings, fixed at the source
-- =============================================================================
-- Four tests were red on the live suite. None of them was a deploy ordering
-- problem; each one is a defect in a migration the repo already carries. This
-- migration fixes the three that are demonstrably wrong in the repo, and
-- re-establishes the fourth's ownership, which is the only fragile half of it.
--
--  1. ride_requests is missing the scalar coordinate columns and requested_at
--     that create_ride_request has written since 20261006000005. Migration
--     20261007000011 added only `city` on the assumption that 20261006000005's
--     ALTER TABLE had run — but that migration is recorded as applied on the
--     live database while its ALTER never executed (the same class of problem
--     20261007000011's own header describes). Every insert into ride_requests
--     therefore fails with 42703, which is why no ride request ever reaches the
--     database, nothing can be claimed, and both GPS-rides tests fail.
--
--  2. assert_ride_request_write_matches_schema() reads create_ride_request's
--     INSERT column list and compares each name against information_schema —
--     but it trimmed each name with `trim(both from part)`, and PostgreSQL's
--     trim removes only spaces. The column list is written across several
--     indented lines, so every captured name still carried its leading newline
--     and indentation ("\n    pickup_location") and matched no column at all.
--     The assertion reported every column as missing even on a correct body.
--     Fixed by stripping all whitespace, not just spaces.
--
--  3. client_write_surface_report()'s expected list, restated in
--     20261007000013, dropped 'product_likes' and put the function's own name
--     in its place. product_likes is therefore reported as an unexpected
--     client-writable table, and assert_client_write_surface_is_closed() — whose
--     second half requires that bucket to be empty — returns false. Restored to
--     the intended 24 entries: the 23 from 20261007000010 plus banks.
--
--  4. like_probe_as_client() must be OWNED BY authenticated for its policies to
--     be evaluated (it is the only way a SECURITY DEFINER body can be a real
--     client). Ownership does not travel with CREATE OR REPLACE, so the
--     transfer is re-applied here — idempotent, and borrowed exactly as
--     20260927000079 does it, because Supabase does not grant authenticated
--     CREATE on public.
--
-- Deploy: needs a Supabase deploy (columns + three function bodies).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The columns create_ride_request writes
-- ---------------------------------------------------------------------------
-- Idempotent, so this is a no-op on any database where 20261006000005 did run.
alter table public.ride_requests
  add column if not exists pickup_lat double precision,
  add column if not exists pickup_lng double precision,
  add column if not exists destination_lat double precision,
  add column if not exists destination_lng double precision,
  add column if not exists requested_at timestamptz,
  add column if not exists city text;

-- Backfill the scalars from the geography halves that always existed, so the
-- timeout and any distance display behave identically for pre-existing rows.
update public.ride_requests r
   set pickup_lat      = coalesce(r.pickup_lat, st_y(r.pickup_location::geometry)),
       pickup_lng      = coalesce(r.pickup_lng, st_x(r.pickup_location::geometry)),
       destination_lat = coalesce(r.destination_lat, st_y(r.destination_location::geometry)),
       destination_lng = coalesce(r.destination_lng, st_x(r.destination_location::geometry)),
       requested_at    = coalesce(r.requested_at, r.created_at)
 where r.pickup_lat is null
    or r.pickup_lng is null
    or r.destination_lat is null
    or r.destination_lng is null
    or r.requested_at is null;

create index if not exists idx_ride_requests_status_requested_at
  on public.ride_requests (status, requested_at);

-- ---------------------------------------------------------------------------
-- 2. The assertion that reads that write (whitespace fix)
-- ---------------------------------------------------------------------------
create or replace function public.assert_ride_request_write_matches_schema()
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_src text;
  v_list text;
  v_col text;
  v_bad text[] := '{}'::text[];
begin
  select prosrc into v_src
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_ride_request';
  if v_src is null then
    raise exception 'create_ride_request is missing';
  end if;

  v_list := substring(v_src from
    '(?i)INSERT\s+INTO\s+(?:public\.)?ride_requests\s*\(([^)]*)\)');
  if v_list is null then
    raise exception 'create_ride_request no longer INSERTs into ride_requests';
  end if;

  -- Strip ALL whitespace, not just spaces: the column list is written across
  -- indented lines and trim(both from ...) left the newlines in place, so every
  -- name failed to match a column and a correct body reported as broken.
  for v_col in
    select regexp_replace(part, '[[:space:]]', '', 'g')
      from unnest(string_to_array(v_list, ',')) as part
  loop
    if v_col <> '' and not exists (
      select 1
        from information_schema.columns
       where table_schema = 'public'
         and table_name = 'ride_requests'
         and column_name = lower(v_col)
    ) then
      v_bad := v_bad || array[format(
        'create_ride_request writes ride_requests.%s, which the table does '
        'not have (42703 at first call; the rider sees "problem on our side")',
        lower(v_col))];
    end if;
  end loop;

  if v_src not ilike '%pickup_location%'
     or v_src not ilike '%destination_location%' then
    v_bad := v_bad || array[
      'create_ride_request does not fill pickup_location/destination_location '
      '(NOT NULL, no default) — the insert fails with 23502'];
  end if;

  if v_src not ilike '%requested_at%' then
    v_bad := v_bad || array[
      'create_ride_request does not stamp requested_at, so the 3-minute '
      'unclaimed timeout counts from nothing'];
  end if;

  if coalesce(array_length(v_bad, 1), 0) > 0 then
    raise exception 'the ride request write does not match the table: %',
      array_to_string(v_bad, '; ');
  end if;

  return true;
end;
$$;

grant execute on function public.assert_ride_request_write_matches_schema()
  to anon, authenticated;

comment on function public.assert_ride_request_write_matches_schema() is
  'Reads the live create_ride_request body and checks every column it writes '
  'exists on ride_requests, that the NOT NULL geography halves are filled, '
  'and that requested_at is stamped. Strips all whitespace from each captured '
  'name, so a multi-line INSERT is judged on its names rather than its '
  'indentation.';

-- ---------------------------------------------------------------------------
-- 3. The write-surface report's expected list
-- ---------------------------------------------------------------------------
-- 24 entries: the 23 from 20261007000010 (which correctly carries both
-- client_error_logs and product_likes) plus banks. The version in
-- 20261007000013 listed this function's own name instead of product_likes,
-- which left the one table the app writes directly under RLS in the
-- "unexpected" bucket.
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
  with expected(t) as (
    values
      ('admin_expenses'), ('admin_notification_broadcasts'), ('appeal_cases'),
      ('banks'), ('cart_items'), ('chat_logs'), ('client_error_logs'),
      ('product_likes'), ('favorites'), ('notifications'), ('order_messages'),
      ('payment_methods'), ('payment_proofs'), ('product_images'),
      ('products'), ('profiles'), ('provider_payment_methods'),
      ('provider_profiles'), ('reviews'), ('ride_ratings'),
      ('support_tickets'), ('user_documents'), ('vehicles'),
      ('wallet_recharge_requests')
  ),
  public_tables as (
    select t.table_name
    from information_schema.tables t
    where t.table_schema = 'public'
      and t.table_type = 'BASE TABLE'
  ),
  writable as (
    select pt.table_name
    from public_tables pt
    where has_table_privilege('authenticated', pt.table_name, 'INSERT')
      and exists (
        select 1 from pg_policies p
        where p.schemaname = 'public'
          and p.tablename = pt.table_name
          and p.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      )
  ),
  unguarded as (
    select w.table_name
    from writable w
    where not exists (
      select 1 from pg_policies p
      where p.schemaname = 'public'
        and p.tablename = w.table_name
        and p.cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        and lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  select 'expected', coalesce(array_agg(t order by t), '{}') from expected
  union all
  select 'unexpected', coalesce(array_agg(w.table_name order by w.table_name), '{}')
    from writable w
    where not exists (select 1 from expected e where e.t = w.table_name)
  union all
  select 'unguarded', coalesce(array_agg(table_name order by table_name), '{}')
    from unguarded;
$$;

comment on function public.client_write_surface_report() is
  'Compares the tables the app is expected to write against the ones it can. '
  'client_error_logs, product_likes and provider_payment_methods are expected: '
  'an app that is failing must be able to record why, a like is written '
  'directly under RLS by design, and a provider manages their own payment '
  'methods from their dashboard. banks is expected because the admin writes '
  'bank account numbers for payment processing.';

grant execute on function public.client_write_surface_report() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. The like probe, owned by authenticated
-- ---------------------------------------------------------------------------
create or replace function public.like_probe_as_client()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_forge uuid := '00000000-0000-4000-8000-0000000007a3';
  v_result jsonb;
  v_rows int;
  v_like int;
  v_dislike int;
begin
  if current_user <> 'authenticated' then
    raise exception 'the like probe is running as %, not as authenticated, so every RLS '
                    'step below would pass without a policy being evaluated',
      current_user;
  end if;

  if auth.uid() is distinct from v_user then
    raise exception 'the like probe reads auth.uid() as %, expected the fixture user %',
      auth.uid(), v_user;
  end if;

  if public.is_admin() then
    raise exception 'the like probe is unexpectedly an admin, so it could pass without '
                    'any policy being consulted';
  end if;

  v_result := public.set_product_reaction(v_prod, 'LIKE');
  if (v_result->>'liked')::boolean is not true then
    raise exception 'set_product_reaction LIKE did not report liked=true: %', v_result;
  end if;

  select count(*) into v_rows from public.product_likes
   where user_id = v_user and product_id = v_prod and reaction = 'LIKE';
  if v_rows <> 1 then
    raise exception 'the like did not persist: % row(s) in product_likes', v_rows;
  end if;

  select like_count, dislike_count into v_like, v_dislike
    from public.products where id = v_prod;
  if v_like <> 1 or v_dislike <> 0 then
    raise exception 'after LIKE the counters are like=% dislike=% , expected 1 and 0. '
                    'The denormalised counter is not moving.', v_like, v_dislike;
  end if;
  if (v_result->>'like_count')::int <> 1 then
    raise exception 'set_product_reaction returned like_count %, expected 1',
      v_result->>'like_count';
  end if;

  v_result := public.set_product_reaction(v_prod, 'DISLIKE');

  select count(*) into v_rows from public.product_likes
   where user_id = v_user and product_id = v_prod;
  if v_rows <> 1 then
    raise exception 'a user holds % reaction rows for one product; the like and the '
                    'dislike are not mutually exclusive', v_rows;
  end if;
  if not exists (select 1 from public.product_likes
                  where user_id = v_user and product_id = v_prod and reaction = 'DISLIKE') then
    raise exception 'the dislike did not replace the like';
  end if;

  select like_count, dislike_count into v_like, v_dislike
    from public.products where id = v_prod;
  if v_like <> 0 or v_dislike <> 1 then
    raise exception 'after DISLIKE the counters are like=% dislike=% , expected 0 and 1',
      v_like, v_dislike;
  end if;

  v_result := public.set_product_reaction(v_prod, 'NONE');
  if (v_result->>'liked')::boolean is not false
     or (v_result->>'disliked')::boolean is not false then
    raise exception 'set_product_reaction NONE still reports a reaction: %', v_result;
  end if;

  select count(*) into v_rows from public.product_likes
   where user_id = v_user and product_id = v_prod;
  if v_rows <> 0 then
    raise exception 'NONE left % reaction row(s) behind', v_rows;
  end if;

  select like_count, dislike_count into v_like, v_dislike
    from public.products where id = v_prod;
  if v_like <> 0 or v_dislike <> 0 then
    raise exception 'after NONE the counters are like=% dislike=% , expected 0 and 0',
      v_like, v_dislike;
  end if;

  begin
    insert into public.product_likes (user_id, product_id, reaction)
    values (v_other, v_forge, 'LIKE');
    raise exception 'a user was able to write a reaction row for somebody else';
  exception
    when others then
      if sqlerrm = 'a user was able to write a reaction row for somebody else' then
        raise;
      end if;
      null;
  end;

  select count(*) into v_rows from public.product_likes
   where user_id = v_other and product_id = v_prod;
  if v_rows <> 1 then
    raise exception 'the fixture row belonging to the other user is missing (% row(s)), '
                    'so the delete policy is not being exercised', v_rows;
  end if;

  v_rows := -1;
  begin
    delete from public.product_likes where user_id = v_other and product_id = v_prod;
    get diagnostics v_rows = row_count;
  exception when others then
    v_rows := 0;
  end;

  if v_rows <> 0 then
    raise exception 'a user deleted % reaction row(s) belonging to somebody else', v_rows;
  end if;

  perform public.set_product_reaction(v_prod, 'LIKE');

  v_rows := -1;
  begin
    delete from public.product_likes
     where user_id = v_user and product_id = v_prod;
    get diagnostics v_rows = row_count;
  exception when others then
    v_rows := 0;
  end;

  if v_rows <> 1 then
    raise exception 'a user could not delete their own reaction row (affected %), so the '
                    'delete policy is a blanket block', v_rows;
  end if;

  return true;
end;
$$;

comment on function public.like_probe_as_client() is
  'WRITE test helper: SECURITY DEFINER and OWNED BY authenticated, so current_user is a real client inside it and row-level security is genuinely evaluated. Never call this directly -- it assumes the fixtures exist. Asserts its own identity on entry and refuses to run otherwise.';

create or replace function public.assert_likes_persist_and_are_exclusive()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prov  uuid := '00000000-0000-4000-8000-0000000007a1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_forge uuid := '00000000-0000-4000-8000-0000000007a3';
  v_ok boolean;
begin
  begin
    insert into auth.users (id, email, email_confirmed_at)
    values (v_user,  'like-probe@example.invalid', now()),
           (v_other, 'like-probe-other@example.invalid', now())
    on conflict (id) do nothing;

    insert into public.profiles (id, full_name, status)
    values (v_user,  'Like Probe',       'PENDING_APPROVAL'),
           (v_other, 'Like Probe Other', 'PENDING_APPROVAL')
    on conflict (id) do nothing;

    execute 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    insert into public.provider_profiles (id, user_id, provider_type, business_name, status)
    values (v_prov, v_other, 'SERVICE_PROVIDER', 'Like Probe Provider', 'APPROVED')
    on conflict (id) do nothing;
    execute 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    insert into public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    values (v_prod, v_prov, 'Like Probe Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100),
           (v_forge, v_prov, 'Like Probe Product 2', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    on conflict (id) do nothing;

    insert into public.product_likes (user_id, product_id, reaction)
    values (v_other, v_prod, 'DISLIKE')
    on conflict (user_id, product_id) do nothing;

    update public.products set like_count = 0, dislike_count = 0 where id = v_prod;

    perform set_config('request.jwt.claim.sub', v_user::text, true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    v_ok := public.like_probe_as_client();
    if v_ok is not true then
      raise exception 'the client-side like probe returned %, expected true', v_ok;
    end if;

    raise exception '%', c_sentinel;

  exception
    when others then
      if sqlerrm = c_sentinel then
        return true;
      end if;
      raise;
  end;
end;
$$;

comment on function public.assert_likes_persist_and_are_exclusive() is
  'WRITE test: acts as a real non-admin buyer and requires a LIKE to persist with products.like_count incremented, a DISLIKE to replace it with both counters correct, NONE to remove it, and a reaction written for another user to be refused. Builds the fixtures as the schema owner, then steps aside while like_probe_as_client() runs as authenticated. Rolls back via a sentinel.';

grant execute on function public.assert_likes_persist_and_are_exclusive() to anon, authenticated;

-- Ownership does not travel with CREATE OR REPLACE, and it is the whole
-- mechanism: only when like_probe_as_client() is owned by authenticated is
-- current_user inside it a real client. Re-applied idempotently, borrowing
-- CREATE on public for the one statement because Supabase does not grant it.
do $$
declare
  v_caller name;
  v_borrowed_create boolean := false;
begin
  select pg_get_userbyid(p.proowner) into v_caller
    from pg_proc p
   where p.oid = 'public.assert_likes_persist_and_are_exclusive()'::regprocedure;

  if v_caller is null then
    raise exception 'cannot find the owner of assert_likes_persist_and_are_exclusive(), '
                    'so like_probe_as_client() cannot be made callable by it';
  end if;

  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise exception 'the authenticated role does not exist, so no function can be owned '
                    'by it and the like probe cannot run as a real client';
  end if;

  execute 'REVOKE ALL ON FUNCTION public.like_probe_as_client() FROM PUBLIC';
  execute format('GRANT EXECUTE ON FUNCTION public.like_probe_as_client() TO %I', v_caller);

  if not has_schema_privilege('authenticated', 'public', 'CREATE') then
    execute 'GRANT CREATE ON SCHEMA public TO authenticated';
    v_borrowed_create := true;
  end if;

  execute 'ALTER FUNCTION public.like_probe_as_client() OWNER TO authenticated';

  if v_borrowed_create then
    execute 'REVOKE CREATE ON SCHEMA public FROM authenticated';
  end if;
end;
$$;
