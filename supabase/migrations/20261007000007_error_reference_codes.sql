-- =============================================================================
-- 20261007000007_error_reference_codes.sql
--
-- ITEM K: a friendly error that says "Something went wrong" is only half a fix.
-- The user needs something to quote and support needs something to look up, and
-- until now `client_error_logs` had no short handle — the only identifiers were
-- a uuid nobody reads aloud and a fingerprint that is a debug artefact.
--
-- This adds `reference_code`: a short, human-readable string of the form
-- `AL-3F9C21` that the app prints next to the sentence ("… (Ref AL-3F9C21)")
-- and writes on the same row. Support searches the column, finds the exact
-- report, and sees the trace, the source and the sanitised context. The code is
-- generated client-side so it exists even when the INSERT itself is what
-- failed, and it is deliberately NOT unique: a retried report may carry the
-- same code, and a lookup returning two rows for one incident is correct.
--
-- Nothing here changes who may read the table. The admin surfaces already read
-- `client_error_logs`; this only makes a row findable by the string a user can
-- actually say out loud.
-- =============================================================================

alter table public.client_error_logs
  add column if not exists reference_code text;

comment on column public.client_error_logs.reference_code is
  'The short code the user was shown (e.g. AL-3F9C21), so support can find '
  'this exact report from the sentence on the screen. Not unique: a retried '
  'report may repeat its code, and two rows for one incident is correct.';

-- Support searches by the code, and the admin list sorts by recency, so the
-- two access patterns get one index each. Partial on NOT NULL, because the
-- rows written before this migration have no code.
create index if not exists idx_client_error_logs_reference_code
  on public.client_error_logs (reference_code)
  where reference_code is not null;

-- -----------------------------------------------------------------------------
-- The assertion: the column the client writes must exist, or every report is
-- silently rejected and the admin panel goes quietly empty.
-- -----------------------------------------------------------------------------
create or replace function public.assert_error_logs_carry_a_reference()
returns boolean
-- `LANGUAGE plpgsql` is upper-cased on purpose: the harness's body extractor
-- recognises the clause case-sensitively, so a lowercase `language plpgsql`
-- makes it report "found 0 plpgsql bodies" and skip the file entirely. The SQL
-- is identical either way; this only makes the file actually get checked.
LANGUAGE plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'client_error_logs'
       and column_name = 'reference_code'
  ) then
    raise exception
      'ERROR_LOGS_HAVE_NO_REFERENCE: client_error_logs.reference_code is '
      'missing, so a user-visible reference cannot be resolved to a row';
  end if;

  -- The table must still be admin-readable: a code nobody can look up is
  -- decoration.
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename = 'client_error_logs'
  ) then
    raise exception
      'ERROR_LOGS_ARE_NOT_READABLE: client_error_logs has no policy, so the '
      'admin panel cannot read the reference a user was shown';
  end if;

  return true;
end;
$$;

comment on function public.assert_error_logs_carry_a_reference() is
  'Fails when client_error_logs has no reference_code column or no policy, '
  'either of which makes the reference code shown to a user useless.';

revoke all on function public.assert_error_logs_carry_a_reference() from public, anon;
grant execute on function public.assert_error_logs_carry_a_reference()
  to authenticated, service_role;
