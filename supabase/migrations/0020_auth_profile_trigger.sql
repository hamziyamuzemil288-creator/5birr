-- 5BIRR — Auto-profile + role on auth signup
-- Migration 0020_auth_profile_trigger.sql
--
-- ROOT CAUSE FIX: Without this trigger, newly signed-up users have no
-- row in user_roles.  The client cannot insert one (RLS admin-only), so
-- the Flutter redirect saw an empty roles list and either looped back
-- to /login or defaulted to the wrong dashboard.
--
-- This SECURITY DEFINER trigger bypasses RLS to insert the USER role
-- and a default profile row whenever a new auth user is created.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 1. Create a default profile (skip if the client already inserted one)
  insert into public.profiles (id, full_name, phone, email, status)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', 'New User'),
    new.phone,
    new.email,
    'PENDING_APPROVAL'::account_status
  )
  on conflict (id) do nothing;

  -- 2. Assign the USER role (skip if already present)
  insert into public.user_roles (user_id, role)
  values (new.id, 'USER'::app_role)
  on conflict (user_id, role) do nothing;

  return new;
end;
$$;

-- Attach the trigger
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();
