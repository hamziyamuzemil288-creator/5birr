-- Task 8 part 2: trigger-resolution test for 20260924000001_referral_signup_trigger.sql.
-- Requires the mock schema from referral_migration_test.sql (run that first).
-- Applies the trigger migration against a FRESH clone of the schema, then
-- simulates handle_new_user() for three signups:
--   • no referral code      → all referral columns NULL (self-registered)
--   • valid code            → staff id + name stored (sales-registered)
--   • unknown code          → raw code kept, staff columns NULL ("Other")
-- Run after referral_migration_test.sql:
--   sudo -u postgres psql -d referral_test -f /tmp/referral_trigger_test.sql

\set ON_ERROR_STOP on

-- Fresh trigger migration (idempotent re-emit is fine).
\ir /tmp/20260924000001_referral_signup_trigger.sql

-- OTP gate helper needs a stubbed pass (the trigger calls it); the mock DB
-- has no email_otp_codes table, so provide the minimal surface.
create schema if not exists public;  -- already exists
create table if not exists public.email_otp_codes (
  id uuid primary key default uuid_generate_v4(),
  email text,
  code_hash text,
  consumed boolean default false,
  attempts int default 0,
  max_attempts int default 5,
  expires_at timestamptz default now() + interval '10 minutes',
  created_at timestamptz default now()
);

create or replace function public.otp_verified_recently(p_email text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.email_otp_codes
    where email = lower(btrim(p_email))
      and consumed = true
      and attempts > 0
      and attempts <= 2
      and created_at > now() - interval '24 hours'
  );
$$;

-- Re-emit AFTER the stub so the trigger binds to it.
\ir /tmp/20260924000001_referral_signup_trigger.sql

-- Drop the trigger from 0005-era re-emits is not needed: create trigger here.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- Make the trigger's auth-user inserts pass the OTP gate: seed verified OTPs
-- for the three test emails.
insert into public.email_otp_codes (email, code_hash, consumed, attempts)
values
  ('self2@example.com',    'x', true, 1),
  ('salesreg2@example.com','x', true, 1),
  ('other2@example.com',   'x', true, 1);

create or replace function run_trigger_tests() returns void language plpgsql as $$
declare
  v_pass int := 0; v_fail int := 0;
  v_id uuid;
  v_row record;
begin
  perform set_config('role', 'postgres', true);

  -- S1: signup WITHOUT a referral code → self-registered (all NULL)
  insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-0000-0000-00000000d001', 'self2@example.com',
          jsonb_build_object('full_name', 'New Self', 'provider_type', 'VEHICLE_PROVIDER', 'business_name', 'Self2 Biz'))
  returning id into v_id;
  select referral_code, referred_by_staff_id, referred_by_name into v_row
    from public.provider_profiles where user_id = v_id;
  if v_row.referral_code is null and v_row.referred_by_staff_id is null and v_row.referred_by_name is null then
    v_pass := v_pass + 1; raise notice 'ok   S1 no code → self-registered (NULLs)';
  else v_fail := v_fail + 1; raise notice 'FAIL S1 code=% staff=% name=%', v_row.referral_code, v_row.referred_by_staff_id, v_row.referred_by_name; end if;

  -- S2: signup WITH a valid code → staff id + name resolved
  insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-0000-0000-00000000d002', 'salesreg2@example.com',
          jsonb_build_object('full_name', 'New Sales', 'provider_type', 'SERVICE_PROVIDER', 'business_name', 'Sales2 Biz', 'referral_code', 'sale-muktar-01'))
  returning id into v_id;
  select referral_code, referred_by_staff_id, referred_by_name into v_row
    from public.provider_profiles where user_id = v_id;
  if v_row.referral_code = 'SALE-MUKTAR-01'
     and v_row.referred_by_staff_id = '00000000-0000-0000-0000-00000000f001'
     and v_row.referred_by_name = 'Muktar Sales' then
    v_pass := v_pass + 1; raise notice 'ok   S2 valid code → staff resolved (case-insensitive)';
  else v_fail := v_fail + 1; raise notice 'FAIL S2 code=% staff=% name=%', v_row.referral_code, v_row.referred_by_staff_id, v_row.referred_by_name; end if;

  -- S3: signup with an UNKNOWN code → raw kept, staff NULL ("Other")
  insert into auth.users (id, email, raw_user_meta_data)
  values ('00000000-0000-0000-0000-00000000d003', 'other2@example.com',
          jsonb_build_object('full_name', 'New Other', 'provider_type', 'VEHICLE_PROVIDER', 'business_name', 'Other2 Biz', 'referral_code', 'GHOST-99'))
  returning id into v_id;
  select referral_code, referred_by_staff_id, referred_by_name into v_row
    from public.provider_profiles where user_id = v_id;
  if v_row.referral_code = 'GHOST-99' and v_row.referred_by_staff_id is null and v_row.referred_by_name is null then
    v_pass := v_pass + 1; raise notice 'ok   S3 unknown code → raw kept, staff NULL';
  else v_fail := v_fail + 1; raise notice 'FAIL S3 code=% staff=%', v_row.referral_code, v_row.referred_by_staff_id; end if;

  -- S4: history channel for the three new rows matches the spec
  if (select count(*) from public.admin_registration_history(p_channel => 'SALES')
      where display_name in ('Sales2 Biz')) = 1
     and (select count(*) from public.admin_registration_history(p_channel => 'OTHER')
      where display_name in ('Other2 Biz')) = 1
     and (select count(*) from public.admin_registration_history(p_channel => 'SELF')
      where display_name in ('Self2 Biz')) = 1 then
    v_pass := v_pass + 1; raise notice 'ok   S4 history channels correct for all three';
  else v_fail := v_fail + 1; raise notice 'FAIL S4 history channel split'; end if;

  raise notice 'RESULT: % passed, % failed', v_pass, v_fail;
  if v_fail > 0 then raise exception 'TRIGGER TESTS FAILED'; end if;
end $$;

select run_trigger_tests();
