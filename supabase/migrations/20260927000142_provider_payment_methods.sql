-- Provider self-service payment methods
-- Provider personal payment methods (name, payee name, account number, buyer note)
-- are per-provider: each provider owns their own rows, and buyers see them to
-- confirm payment and upload proof. This table keeps methods scoped to the
-- owning provider so one provider's details can never be read or mutated by
-- another.

create table if not exists provider_payment_methods (
  id uuid primary key default uuid_generate_v4(),
  provider_id uuid not null references provider_profiles(id) on delete cascade,
  name text not null,
  account_name text,
  account_number text,
  instructions text,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_provider_payment_methods_provider
  on provider_payment_methods(provider_id);

create index if not exists idx_provider_payment_methods_active
  on provider_payment_methods(provider_id) where is_active = true;

-- Provider personal methods are private to the owner; admins (support) can read
-- them for dispute/reconciliation purposes.
create policy provider_payment_methods_owner on provider_payment_methods
  for all
  using (owns_provider_profile(provider_id));

create policy provider_payment_methods_admin_read on provider_payment_methods
  for select
  using (is_admin());

create or replace function public.set_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

DO $func$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname = 'trg_provider_payment_methods_updated'
      AND tgrelid = 'provider_payment_methods'::regclass
  ) THEN
    CREATE TRIGGER trg_provider_payment_methods_updated
    BEFORE UPDATE ON provider_payment_methods
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
  END IF;
END
$func$;
