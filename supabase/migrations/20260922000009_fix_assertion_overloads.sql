-- ============================================================
-- Migration 20260922000009_fix_assertion_overloads.sql
-- Phase 3 safety-net fix: make the pg_proc-introspection assertions
-- deterministic on the live DB.
--
-- DIAGNOSIS (Connectivity CI run 35646692111, first post-deploy run):
-- 8/9 assertions passed. assert_create_order_persists_fulfillment
-- returned false even though the live chain is correct
-- (order-create -> create_order_secure 9-arg overload with
-- fulfillment_mode/p_city). Cause: the live DB legitimately holds
-- TWO overloads of create_order_secure (new 9-arg + legacy 6-arg),
-- and the assertion's `select prosrc ... limit 1` had no ORDER BY,
-- so it could read the legacy body and false-fail. Same pattern
-- existed for transition_ride_status and staff_performance.
--
-- FIX: rewrite the three assertions to check "at least one overload
-- of the function contains the required tokens" via EXISTS — no
-- ordering, no arbitrary pick. Read-only, SECURITY DEFINER booleans,
-- same names/signatures. Idempotent CREATE OR REPLACE; grants restated.
--
-- The app-side connection itself is verified working; this fixes only
-- the checker. No table, column, RLS or edge-function change.
-- ============================================================

-- (a) ride chain: live transition_ride_status covers the ARRIVED/TRIP_STARTED chain
create or replace function public.assert_ride_transition_covers_chain()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  select exists (
    select 1 from pg_proc
     where proname = 'transition_ride_status'
       and position('DRIVER_ARRIVING' in prosrc) > 0
       and position('ARRIVED' in prosrc) > 0
       and position('TRIP_STARTED' in prosrc) > 0
       and position('COMPLETED' in prosrc) > 0
  ) into v_ok;
  return coalesce(v_ok, false);
end;
$$;

-- (b) staff attribution: staff_performance counts rides via claimed_by_provider_id
create or replace function public.assert_staff_performance_uses_claimed_by()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  select exists (
    select 1 from pg_proc
     where proname = 'staff_performance'
       and position('claimed_by_provider_id' in prosrc) > 0
  ) into v_ok;
  return coalesce(v_ok, false);
end;
$$;

-- (c) order routing: create_order_secure persists fulfillment + city
create or replace function public.assert_create_order_persists_fulfillment()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  select exists (
    select 1 from pg_proc
     where proname = 'create_order_secure'
       and position('fulfillment_mode' in prosrc) > 0
       and position('p_city' in prosrc) > 0
  ) into v_ok;
  return coalesce(v_ok, false);
end;
$$;

-- Grants restated exactly as in 20260922000007: read-only booleans,
-- callable by anon (CI) and authenticated, revoked from public.
grant execute on function
  public.assert_ride_transition_covers_chain(),
  public.assert_staff_performance_uses_claimed_by(),
  public.assert_create_order_persists_fulfillment()
  to anon, authenticated, service_role;
revoke execute on function
  public.assert_ride_transition_covers_chain(),
  public.assert_staff_performance_uses_claimed_by(),
  public.assert_create_order_persists_fulfillment()
  from public;
