-- 0039_support_tickets_and_terms.sql
--
-- Two related additions (requested 2026-09-20):
--
-- 1. SUPPORT TICKETS from the in-app help chat (Behaviors 2/3/4)
--    support_tickets (0001) had only subject/status. The help chat now
--    collects a structured "other party is not responding" report:
--    provider name / reference / city, the reporter's own phone, the order
--    number (Aliob category-coded number, e.g. Vh00012) and a free-text
--    description. `source` distinguishes the help-chat flow from other
--    ticket origins. Admin resolution notes + timestamps power the
--    10-hour no-response fallback shown to the reporter in chat.
--
-- 2. TERMS / PRIVACY AGREEMENT on profiles (Behavior 5)
--    Every registration flow requires an explicit checkbox before account
--    creation. The signed-in user records their own acceptance
--    (timestamp + policy version) via an UPDATE restricted by RLS to
--    their own row. Columns are nullable: existing accounts predate
--    versioned consent.
--
-- No destructive statements; nothing existing is weakened.

-- ============================================================================
-- 1. Support tickets: structured escalation details
-- ============================================================================
alter table public.support_tickets
  add column if not exists reporter_phone text,
  add column if not exists provider_name text,
  add column if not exists provider_reference text,
  add column if not exists provider_city text,
  add column if not exists order_number text,
  add column if not exists description text,
  add column if not exists source text not null default 'OTHER',
  add column if not exists resolved_at timestamptz,
  add column if not exists resolution_note text,
  add column if not exists fallback_notified_at timestamptz;

comment on column public.support_tickets.fallback_notified_at is
  'Set when the help chat has already shown the reporter the 10-hour no-response fallback contacts (phone + email), so the notice fires at most once per ticket.';

comment on column public.support_tickets.source is
  'Where the ticket came from: HELP_CHAT (in-app assistant escalation), OTHER (email/phone/manual entry).';

comment on column public.support_tickets.provider_reference is
  'Provider name, ID or phone as reported by the user — free text so partial info is still captured.';

create index if not exists idx_support_tickets_status
  on public.support_tickets (status, created_at);
create index if not exists idx_support_tickets_user
  on public.support_tickets (user_id, created_at);

-- ============================================================================
-- 2. Terms & privacy agreement (versioned consent on the profile)
-- ============================================================================
alter table public.profiles
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists terms_version text;

comment on column public.profiles.terms_accepted_at is
  'When the user accepted the current Terms & Privacy Policy (null: pre-versioning account).';
comment on column public.profiles.terms_version is
  'Version string of the accepted policy, e.g. "2026-09-20".';

-- The signed-in user records their own acceptance right after signup.
-- Owner-scoped UPDATE already exists (profiles_update_own, 0002); this
-- function just makes the write explicit and auditable.
create or replace function public.accept_terms(p_version text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_version is null or length(trim(p_version)) = 0 then
    raise exception 'TERMS_VERSION_REQUIRED';
  end if;
  update profiles
     set terms_accepted_at = now(),
         terms_version = left(trim(p_version), 32),
         updated_at = now()
   where id = auth.uid();
  if not found then
    raise exception 'PROFILE_NOT_FOUND';
  end if;

  insert into audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (auth.uid(), 'TERMS_ACCEPTED', 'profiles', auth.uid(),
          jsonb_build_object('version', left(trim(p_version), 32)));
end;
$$;

revoke execute on function public.accept_terms(text) from public, anon;
grant execute on function public.accept_terms(text) to authenticated;

notify pgrst, 'reload schema';
