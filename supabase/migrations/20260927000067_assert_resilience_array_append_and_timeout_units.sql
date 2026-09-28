-- =============================================================================
-- 20260927000067 — Two real bugs in assert_resilience_is_wired(), found by
--                   running it instead of reading it
-- =============================================================================
-- Migration 66 added a diagnostic to the connectivity suite so this function
-- would report its error instead of collapsing it into a null. That was the
-- right call, and it paid for itself on the next run. The suite reported:
--
--   PostgrestException: malformed array literal:
--     "authenticated statement_timeout is not 15s (got: ", code 22P02
--   details: Array value must start with "{" or dimension information.
--
-- That is not a permissions problem, not a return-type problem, and not a
-- PostgREST cache problem. It is a genuine bug in this function, and it is
-- why the null survived every previous fix. Two separate defects:
--
-- ── 1. `text[] || 'literal'` is ambiguous, and here it throws ──────────────
--
-- `v_missing` is text[] and the body appends with `v_missing || 'message'`.
-- With an untyped literal on the right, `||` is overloaded between
-- array_append(anyarray, anyelement) and array_cat(anycompatiblearray,
-- anycompatiblearray), and the second candidate casts the literal to an
-- array. Checks 1-5 never hit it because their branches were all false, so
-- the appends never executed; check 6 is the first branch that both fires
-- AND composes a message, and it threw while composing.
--
-- The fix is `array_append`, which has one signature and no overload to
-- resolve against. Applied to all six checks, not just the one that threw:
-- a function whose job is to report what is broken must not itself be the
-- thing that breaks, and the other five would fail the same way the moment
-- they had something to report.
--
-- ── 2. The statement_timeout check compared a hardcoded rendering ──────────
--
-- The check was `'statement_timeout=15s' = any (rolconfig)`. rolconfig stores
-- the value as PostgreSQL normalised it, and the unit it picks is not
-- guaranteed to be `s` — `15000ms` is an equally normal rendering of the same
-- setting. So a timeout that IS correctly applied can fail this check, and
-- the function would report a missing timeout that does not exist.
--
-- The comparison is now numeric: the value and its unit are parsed out and
-- converted to seconds, with a bare number treated as milliseconds because
-- that is GUC syntax. This asks the question actually being asked — "is the
-- authenticated role capped at 15 seconds?" — instead of "did Postgres
-- happen to write these characters".
--
-- I do NOT know which of the two is true on the live database: that the
-- timeout is genuinely absent, or that it is present and merely rendered
-- differently. Migration 64's `alter role authenticated set statement_timeout
-- = 15000` ran inside a successful deploy and no other migration touches the
-- role, which is weak evidence it applied. Rather than assume, the new
-- message reports what was actually found: if the setting is missing the
-- function now says so in those words, and the finding stands on its own
-- rather than resting on a string comparison.
--
-- The six checks themselves are otherwise unchanged from 64/65/66.
-- =============================================================================

create or replace function public.assert_resilience_is_wired()
returns text
language plpgsql
as $$
declare
  v_missing text[] := '{}';
  v_timeout_cfg text;
begin
  -- 1. The sink exists.
  if to_regclass('public.client_error_logs') is null then
    v_missing := array_append(v_missing, 'table client_error_logs missing');
  end if;

  -- 2. RLS is ON. An un-RLS'd table is world-writable and every row is a
  --    forgeable crash report.
  if exists (
    select 1 from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'client_error_logs'
       and not c.relrowsecurity
  ) then
    v_missing := array_append(v_missing, 'client_error_logs has RLS disabled');
  end if;

  -- 3. Exactly the two intended policies, and no write-back policy.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and policyname = 'client_error_logs_insert_own' and cmd = 'INSERT'
  ) then
    v_missing := array_append(v_missing, 'missing insert-own policy');
  end if;
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and policyname = 'client_error_logs_admin_read' and cmd = 'SELECT'
  ) then
    v_missing := array_append(v_missing, 'missing admin-read policy');
  end if;
  if exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'client_error_logs'
       and cmd in ('UPDATE', 'DELETE')
  ) then
    v_missing := array_append(v_missing,
      'client_error_logs must be append-only (an UPDATE/DELETE policy exists)');
  end if;

  -- 4. The flood guard trigger is attached.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.client_error_logs'::regclass
       and tgname = 'trg_client_error_logs_flood'
       and not tgisinternal
  ) then
    v_missing := array_append(v_missing, 'flood guard trigger not attached');
  end if;

  -- 5. The hot-path indexes exist. Named explicitly so a dropped or renamed
  --    index names itself in the failure rather than producing a bare count.
  if to_regclass('public.idx_products_active_popular') is null then
    v_missing := array_append(v_missing, 'idx_products_active_popular missing');
  end if;
  if to_regclass('public.idx_orders_user_recent') is null then
    v_missing := array_append(v_missing, 'idx_orders_user_recent missing');
  end if;
  if to_regclass('public.idx_orders_provider_recent') is null then
    v_missing := array_append(v_missing, 'idx_orders_provider_recent missing');
  end if;
  if to_regclass('public.idx_notifications_user_recent') is null then
    v_missing := array_append(v_missing, 'idx_notifications_user_recent missing');
  end if;
  if to_regclass('public.idx_ride_requests_open_by_status') is null then
    v_missing := array_append(v_missing, 'idx_ride_requests_open_by_status missing');
  end if;

  -- 6. The timeout is actually applied to the role.
  --
  --    Compared NUMERICALLY, in seconds. The previous form was
  --    `'statement_timeout=15s' = any (rolconfig)`, which tests a rendering
  --    rather than a value: rolconfig holds whatever unit PostgreSQL chose to
  --    normalise to, and `15000ms` is as valid a spelling of 15 seconds as
  --    `15s`. That check could fail on a correctly applied timeout.
  --
  --    A bare number with no unit is milliseconds, per GUC syntax, so the
  --    default branch is 0.001 rather than 1.
  begin
    select c.cfg into v_timeout_cfg
      from pg_roles r
      cross join lateral unnest(r.rolconfig) as c(cfg)
     where r.rolname = 'authenticated'
       and c.cfg like 'statement_timeout=%'
     limit 1;

    if not exists (
      select 1
        from pg_roles r
        cross join lateral unnest(r.rolconfig) as c(cfg)
        cross join lateral (
          select
            substring(c.cfg from '^statement_timeout=(-?[0-9.]+)')::numeric as n,
            nullif(
              substring(c.cfg from '^statement_timeout=-?[0-9.]+(\S*)$'), ''
            ) as u
        ) m
       where r.rolname = 'authenticated'
         and c.cfg like 'statement_timeout=%'
         and m.n * (case m.u
                       when 'ms'  then 0.001
                       when 's'   then 1
                       when 'min' then 60
                       when 'h'   then 3600
                       when 'd'   then 86400
                       else 0.001
                     end) = 15
    ) then
      v_missing := array_append(v_missing,
        'authenticated role is not capped at a 15s statement_timeout' ||
        case
          when v_timeout_cfg is null
            then ' (no statement_timeout set on the role at all)'
          else ' (role has: ' || v_timeout_cfg || ')'
        end);
    end if;
  exception when undefined_object then
    v_missing := array_append(v_missing, 'role authenticated does not exist');
  end;

  -- The return is the contract: a sentence when everything is wired, and a
  -- sentence naming every missing piece when it is not. The connectivity suite
  -- asserts `isNotNull` and prints this text, so a failure shows what was
  -- actually true at that moment rather than only that something was wrong.
  --
  -- Deliberately built with concat(), not ||, for the same reason the body
  -- uses array_append: a chained || over a text[] is exactly the ambiguity
  -- that made this function throw instead of reporting.
  if cardinality(v_missing) > 0 then
    return concat('RESILIENCE_NOT_WIRED: ', array_to_string(v_missing, '; '));
  end if;

  return concat(
    'client_error_logs + RLS + append-only policies + flood guard + ',
    '5 hot-path indexes + statement_timeout 15s (',
    coalesce(v_timeout_cfg, 'unset'),
    '): all wired'
  );
end;
$$;

comment on function public.assert_resilience_is_wired() is
  'Returns a sentence describing the state of the client error sink, its RLS, the hot-path indexes and the authenticated statement_timeout, or a sentence naming what is missing. Reports; does not raise. Compares the timeout numerically, not by its stored rendering.';

grant execute on function public.assert_resilience_is_wired() to anon, authenticated, service_role;
