-- 20260927000138 — the online status was computed for every provider and read
-- by nobody
--
-- THE REPORT
-- ----------
-- "Show the provider's last seen status on their public profile." The status
-- was already being computed. What was missing was both halves of the last
-- mile, and this migration and the Dart change that ships with it are those
-- two halves.
--
-- HALF ONE: no screen ever read it
-- --------------------------------
-- lib/core/services/provider_presence_service.dart has existed with a
-- heartbeat (started from auth_provider on sign-in), a reader
-- (`ProviderPresence.fetchStatus`) and a human formatter
-- (`ProviderPresence.labelFor` -> "Online" / "Last seen 3 hours ago"). Grep
-- for its call sites and the only hits outside the service are the two
-- heartbeat start/stop lines in auth_provider.dart. `fetchStatus` and
-- `labelFor` were never called from any screen, so every provider's activity
-- was recorded, stored, aged out and never shown to anyone. The public
-- provider profile (user_provider_detail_screen.dart) now renders it.
--
-- HALF TWO: nothing guaranteed the surface exists ON THE LIVE DATABASE
-- ------------------------------------------------------------------
-- The column and both functions live in 0038_activation_fee_and_wallet_guards.
-- 0038 is BELOW this repository's deploy baseline: deploy-supabase.yml marks
-- every staged migration whose numeric version is < 20260919000000 as applied
-- WITHOUT executing it, and says so in its own comment —
--
--   "the loop marks EVERY staged file whose numeric version is
--    < 20260919000000 ... Those 8 migrations would be recorded as applied
--    WITHOUT ever executing. Their effects are already in the live DB (pasted
--    via SQL editor), so this is correct in practice"
--
-- "Correct in practice" is an assumption about a manual paste, and this file
-- is the one place that can turn it into a guarantee. This is the same shape
-- as 0096/0097, which re-created the provider-gallery and vehicle-images
-- buckets for exactly this reason after 0012/0017 turned out never to have
-- run: a feature whose only definition is in an unexecuted migration is a
-- feature that is absent wherever that migration was not executed. If 0038 DID
-- run, every statement here is a no-op and nothing changes.
--
-- What it would look like if it had not run and nothing restated it: the
-- heartbeat's `_touch()` swallows its error (`onError: (_) {}`), the reader's
-- caller catches too, and the profile simply renders no indicator — a silent
-- absence, which is the failure mode this repository keeps paying for.
--
-- NO BEHAVIOUR CHANGE
-- -------------------
-- The two bodies are the 0038 bodies. The only edits are `pg_temp` added to
-- search_path (the house rule for SECURITY DEFINER here) and
-- get_provider_online_status written as a plpgsql body rather than an SQL one,
-- which is a language choice and not a rule change — it returns the same two
-- columns for the same row. The grants are restated exactly as 0038 set them:
-- the HEARTBEAT is caller-scoped (own rows only) and the READER is deliberately
-- NOT granted to anon, because a provider's activity window is not something an
-- anonymous visitor is owed. A signed-out viewer sees no indicator; that is the
-- existing security decision and it is preserved.

-- ===========================================================================
-- 1. The column
-- ===========================================================================
alter table public.provider_profiles
  add column if not exists last_active_at timestamptz;

-- ===========================================================================
-- 2. The heartbeat (caller-owned rows only)
-- ===========================================================================
create or replace function public.touch_provider_activity()
returns void
LANGUAGE plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update provider_profiles
     set last_active_at = now()
   where user_id = auth.uid()
     and (last_active_at is null or last_active_at < now() - interval '45 seconds');
end;
$$;

revoke execute on function public.touch_provider_activity()
  from public, anon;
grant execute on function public.touch_provider_activity() to authenticated;

-- ===========================================================================
-- 3. The reader (one provider, approved only)
-- ===========================================================================
create or replace function public.get_provider_online_status(p_provider_id uuid)
returns table (online boolean, last_seen timestamptz)
LANGUAGE plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  return query
    select
      pp.last_active_at is not null
        and pp.last_active_at > now() - interval '3 minutes' as online,
      pp.last_active_at as last_seen
    from provider_profiles pp
    where pp.id = p_provider_id and pp.status = 'APPROVED';
end;
$$;

revoke execute on function public.get_provider_online_status(uuid)
  from public, anon;
grant execute on function public.get_provider_online_status(uuid) to authenticated;

-- ===========================================================================
-- 4. The instrument
-- ===========================================================================
-- Reads the catalog rather than trusting this file: the column, both
-- functions, and the one grant without which the provider page's indicator can
-- never load for the audience it has. Callable by anon (it is a report, it
-- returns no provider data), so the connectivity suite can assert it without
-- credentials that can read anyone's presence.

create or replace function public.provider_presence_report()
returns text
LANGUAGE plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_missing text := '';
  v_col boolean := false;
  v_grants integer := 0;
begin
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'provider_profiles'
       and column_name = 'last_active_at') into v_col;
  if not v_col then
    v_missing := v_missing || 'provider_profiles.last_active_at is missing; ';
  end if;

  if to_regprocedure('public.touch_provider_activity()') is null then
    v_missing := v_missing || 'touch_provider_activity() is missing; ';
  end if;
  if to_regprocedure('public.get_provider_online_status(uuid)') is null then
    v_missing := v_missing
      || 'get_provider_online_status(uuid) is missing; ';
  end if;

  select count(*) into v_grants
    from information_schema.routine_privileges
   where routine_schema = 'public'
     and routine_name = 'get_provider_online_status'
     and grantee = 'authenticated'
     and privilege_type = 'EXECUTE';
  if v_grants = 0 then
    v_missing := v_missing
      || 'get_provider_online_status(uuid) is not executable by authenticated, '
      || 'so the profile indicator can never load; ';
  end if;

  if v_missing <> '' then
    return 'FAIL: ' || v_missing;
  end if;

  return 'ok: provider presence is complete -- last_active_at, the heartbeat '
         || 'touch_provider_activity(), the reader get_provider_online_status() '
         || 'and its authenticated grant';
end;
$$;

comment on function public.provider_presence_report() is
  'Reports whether the whole provider-presence surface exists on THIS database '
  '(column, heartbeat, reader, and the grant that lets a signed-in viewer read '
  'it). Exists because that surface is defined only in 0038, which the deploy '
  'pipeline marks applied without executing, so "it is in a migration" is not '
  'the same as "it is on the database".';

revoke all on function public.provider_presence_report() from public;
grant execute on function public.provider_presence_report()
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
