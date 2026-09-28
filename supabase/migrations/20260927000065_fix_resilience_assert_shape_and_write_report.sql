-- =============================================================================
-- 20260927000065 — Fix two defects migration 64 introduced
-- =============================================================================
-- Migration 64 applied cleanly once the ride_status literals were corrected,
-- and then two of its own additions turned out to be wrong. Both were caught
-- by Connectivity CI against the live database, which is the only place they
-- could be caught: neither is wrong in a way that reading the file reveals.
--
-- 1. client_write_surface_report() raised `relation "public.job" does not
--    exist` (SQLSTATE 42P01) and the write-surface check stopped reporting at
--    all. The rewrite replaced an existence-guarded enumeration of public
--    tables with a bare scan of pg_policies, then called
--    has_table_privilege() on every row it found. That call resolves its
--    second argument as a relation name, so any policy row naming a relation
--    that does not resolve makes the whole report throw.
--
--    The original shape is restored wholesale from migration 43, which asked
--    the question in the safe order: list the relations that exist, then ask
--    which of those a client may write. The only intended difference is one
--    more name in the expected list. Nothing else about the report changes,
--    because nothing else about it was broken.
--
--    On the mechanism, stated precisely because the distinction matters: the
--    defect is provable — the rewrite fed has_table_privilege() names taken
--    from pg_policies rather than from a list of relations known to exist,
--    and has_table_privilege() resolves a text argument as a relation name
--    and raises 42P01 when it does not resolve. What is NOT established is
--    where a policy row naming "job" came from: no migration creates such a
--    relation, and policies cannot outlive the table they are attached to, so
--    the row is evidence of schema that the migration history does not
--    describe. That does not need to be resolved to fix this, because the
--    existence-guarded form cannot throw regardless of what the catalog
--    holds. But the same unexplained catalog state is worth a look, and
--    build/guard_restore_check.py exists because the settings guard turned
--    out to have a second, differently-named copy.
--
-- 2. assert_resilience_is_wired() returned boolean. The connectivity suite
--    reads every assert_* function through rpcText(), which returns
--    `result is String ? result : null` — a boolean comes back as null, and
--    the suite reported "Expected: not null, Actual: <null>", which reads
--    like the function is missing rather than like it returned the wrong
--    type. The established convention here (assert_live_map_is_wired, 61) is
--    RETURNS text: the caller gets a sentence naming what it measured, and
--    the CI log carries the evidence. This converts to that shape.
--
--    Converting the return type is not something CREATE OR REPLACE can do, so
--    the function is dropped and recreated. It is a read-only assertion with
--    no callers outside the connectivity suite, so nothing depends on the old
--    signature between the drop and the create, and both statements are in
--    this transaction.
--
-- Deliberately not done here: no RLS change, no policy change, no new index,
-- no settings write. Both fixes are confined to two functions' bodies, and the
-- first is largely a revert.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Restore the existence-guarded write-surface report
-- -----------------------------------------------------------------------------
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
  public_tables AS (
    -- The existence guard, restored. has_table_privilege() resolves a text
    -- argument as a relation name and raises 42P01 when it does not resolve,
    -- so every name handed to it below must come from a relation that is
    -- known to exist. Enumerating pg_policies instead does not guarantee
    -- that, which is how this function ended up throwing on a relation named
    -- "job" that no migration creates.
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
  ),
  writable AS (
    SELECT pt.table_name
    FROM public_tables pt
    WHERE has_table_privilege('authenticated', pt.table_name, 'INSERT')
      AND EXISTS (
        SELECT 1 FROM pg_policies p
        WHERE p.schemaname = 'public'
          AND p.tablename = pt.table_name
          AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      )
  ),
  unguarded AS (
    SELECT w.table_name
    FROM writable w
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = w.table_name
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))
            ~ '(is_admin|is_ceo|is_super_admin)\(\)'
    )
  )
  SELECT 'expected', COALESCE(array_agg(t ORDER BY t), '{}') FROM expected
  UNION ALL
  SELECT 'unexpected', COALESCE(array_agg(w.table_name ORDER BY w.table_name), '{}')
    FROM writable w
    WHERE NOT EXISTS (SELECT 1 FROM expected e WHERE e.t = w.table_name)
  UNION ALL
  SELECT 'unguarded', COALESCE(array_agg(table_name ORDER BY table_name), '{}')
    FROM unguarded;
$$;

comment on function public.client_write_surface_report() is
  'Compares the tables the app is expected to write against the ones it can. client_error_logs is expected: an app that is failing must be able to record why.';

grant execute on function public.client_write_surface_report() to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. assert_resilience_is_wired() returns text, like every other assert_*
-- -----------------------------------------------------------------------------
drop function if exists public.assert_resilience_is_wired();

create function public.assert_resilience_is_wired()
returns text
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

  -- The return is the contract: non-null when everything is wired, and a
  -- sentence naming every missing piece when it is not. The connectivity
  -- suite asserts `isNotNull` and prints this text, so a failure shows what
  -- was actually true at that moment rather than only that something was
  -- wrong. This is the same shape as assert_live_map_is_wired() from 61, and
  -- deliberately not a RAISE: an assert that throws is reported by the
  -- database as an opaque error, and a broken RPC is indistinguishable from a
  -- genuine finding. Saying what is missing is the whole value.
  if cardinality(v_missing) > 0 then
    return 'RESILIENCE_NOT_WIRED: ' || array_to_string(v_missing, '; ');
  end if;

  return 'client_error_logs + RLS + append-only policies + flood guard + '
         || '5 hot-path indexes + statement_timeout 15s: all wired';
end;
$$;

comment on function public.assert_resilience_is_wired() is
  'Returns a sentence describing the state of the client error sink, its RLS, the hot-path indexes and the authenticated statement_timeout, or null-valued text naming what is missing. Reports; does not raise.';

grant execute on function public.assert_resilience_is_wired() to authenticated, service_role;
