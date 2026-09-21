-- ============================================================
-- Migration 20260922000007_integration_assertions.sql
-- Phase 3: read-only assertions the CI integration suite calls.
-- ============================================================
-- The Dart integration suite (tools/integration_test/connectivity_test.dart)
-- runs against the LIVE Supabase project with read-only credentials and
-- writes NO app data. Each function below returns a boolean verifying that
-- a "write" connection actually produced its "read" counterpart. The
-- assertions look back over the last 7 days so legacy data predating a fix
-- never turns CI red.
--
-- Additive only: SELECT-only logic, no table or policy changes.
-- ============================================================

-- Every wallet's balance must equal the sum of its COMPLETED ledger rows.
create or replace function public.assert_income_ledger_consistent()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1
      from wallets w
     where coalesce((
       select sum(t.net_amount) from wallet_transactions t
        where t.wallet_id = w.id and t.status = 'COMPLETED'
     ), 0) <> w.balance
  );
$$;

-- Money: every COMPLETED ride (last 7 days) must have its fee ledger row
-- (COMPLETED or FAILED-empty-wallet), idempotency_key = 'ride:<id>'.
create or replace function public.assert_recent_completed_rides_have_fees()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from ride_requests r
     where r.status = 'COMPLETED'
       and r.updated_at > now() - interval '7 days'
       and not exists (
         select 1 from wallet_transactions t
          where t.idempotency_key = 'ride:' || r.id::text
            and t.transaction_type = 'TRANSACTION_FEE'
       )
  );
$$;

-- Money: every STARTED/COMPLETED order (last 7 days) must have its fee row,
-- idempotency_key = 'order:<id>'.
create or replace function public.assert_recent_started_orders_have_fees()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from orders o
     where o.status in ('STARTED', 'COMPLETED')
       and o.updated_at > now() - interval '7 days'
       and not exists (
         select 1 from wallet_transactions t
          where t.idempotency_key = 'order:' || o.id::text
            and t.transaction_type = 'TRANSACTION_FEE'
       )
  );
$$;

-- Money: every APPROVED recharge (last 7 days) must have credited the
-- wallet through a RECHARGE ledger row, idempotency_key = 'recharge:<id>'.
create or replace function public.assert_recent_approved_recharges_credited()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select not exists (
    select 1 from wallet_recharge_requests q
     where q.status = 'APPROVED'
       and q.updated_at > now() - interval '7 days'
       and not exists (
         select 1 from wallet_transactions t
          where t.idempotency_key = 'recharge:' || q.id::text
            and t.transaction_type = 'RECHARGE'
       )
  );
$$;

-- Structural assertions (schema/function introspection) run server-side
-- because pg_proc / information_schema are NOT exposed through PostgREST;
-- the Dart suite sees them as plain booleans.

-- The city column the whole city-scoping path depends on.
create or replace function public.assert_profiles_have_city()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'profiles'
       and column_name = 'city'
  );
$$;

create or replace function public.assert_ride_transition_covers_chain()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'transition_ride_status' limit 1;
  return v_src like '%when ''ARRIVED''%'
     and v_src like '%when ''TRIP_STARTED''%';
end;
$$;

create or replace function public.assert_staff_performance_uses_claimed_by()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'staff_performance' limit 1;
  return v_src is not null
     and position('r.provider_id' in v_src) = 0
     and position('claimed_by_provider_id' in v_src) > 0;
end;
$$;

create or replace function public.assert_create_order_persists_fulfillment()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_src text;
begin
  select prosrc into v_src from pg_proc
   where proname = 'create_order_secure' limit 1;
  return v_src is not null
     and position('fulfillment_mode' in v_src) > 0
     and position('p_city' in v_src) > 0;
end;
$$;

-- cron.job lives outside the API schema; expose the wiring check as a boolean.
create or replace function public.assert_subscription_scheduler_scheduled()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from cron.job
     where command like '%charge_due_subscriptions%'
  ) and exists (
    select 1 from cron.job
     where command like '%reconcile_income_and_log%'
  );
$$;

revoke execute on function
  public.assert_income_ledger_consistent(),
  public.assert_recent_completed_rides_have_fees(),
  public.assert_recent_started_orders_have_fees(),
  public.assert_recent_approved_recharges_credited(),
  public.assert_profiles_have_city(),
  public.assert_ride_transition_covers_chain(),
  public.assert_staff_performance_uses_claimed_by(),
  public.assert_create_order_persists_fulfillment(),
  public.assert_subscription_scheduler_scheduled()
  from public, anon, authenticated;
-- The CI safety net authenticates with the anon key (read-only booleans, no
-- data access), so anon gets execute: the suite must run on every push
-- without a service key or user session.
grant execute on function
  public.assert_income_ledger_consistent(),
  public.assert_recent_completed_rides_have_fees(),
  public.assert_recent_started_orders_have_fees(),
  public.assert_recent_approved_recharges_credited(),
  public.assert_profiles_have_city(),
  public.assert_ride_transition_covers_chain(),
  public.assert_staff_performance_uses_claimed_by(),
  public.assert_create_order_persists_fulfillment(),
  public.assert_subscription_scheduler_scheduled()
  to anon, authenticated, service_role;
