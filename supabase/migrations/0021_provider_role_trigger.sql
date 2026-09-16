-- 5BIRR — Auto-assign provider role + approval request on provider_profiles insert
-- Migration 0021_provider_role_trigger.sql
--
-- ROOT CAUSE FIX: signUpAsProvider() inserts into provider_profiles but
-- the client cannot insert into user_roles (RLS admin-only).  Without this
-- trigger the provider only has the USER role, so _getDashboardPath() sends
-- them to /user instead of /vehicle or /provider.

create or replace function public.handle_new_provider_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1. Assign the provider role (skip if already present)
  insert into public.user_roles (user_id, role)
  values (
    new.user_id,
    new.provider_type::app_role   -- 'VEHICLE_PROVIDER' or 'SERVICE_PROVIDER'
  )
  on conflict (user_id, role) do nothing;

  -- 2. Create the approval request (skip if one already exists for this provider)
  insert into public.approval_requests (subject_type, subject_id, status)
  values ('PROVIDER', new.id, 'PENDING_APPROVAL'::account_status)
  on conflict do nothing;

  return new;
end;
$$;

-- Attach the trigger
create trigger trg_provider_profiles_auto_setup
  after insert on provider_profiles
  for each row
  execute function public.handle_new_provider_profile();
