-- ============================================================
-- Migration 20260922000005_ride_status_transitions.sql
-- Phase 2 fix (connection audit, 2026-09-21): rides could never complete.
-- ============================================================
-- DIAGNOSIS (code trace): the driver app (driver_trip_screen.dart) and the
-- ride-transition edge function drive and authorize the chain
--   CLAIMED -> DRIVER_ARRIVING -> ARRIVED -> TRIP_STARTED -> COMPLETED
-- but transition_ride_status() (0022_complete_schema.sql, matching the live
-- 0021 snapshot) only has CASE branches for REQUESTED / CLAIMED /
-- DRIVER_ARRIVING / STARTED and raises UNEXPECTED_RIDE_STATUS_% otherwise.
-- Any ride therefore freezes at DRIVER_ARRIVING: "ARRIVED" and
-- "TRIP_STARTED" taps fail, COMPLETED is unreachable, and the ride
-- transaction fee (deduct_transaction_fee on COMPLETED) is never charged —
-- the same "money never reaches the ledger" symptom as the orphaned
-- subscription scheduler.
--
-- FIX: restate transition_ride_status() (same name, same signature, same
-- SECURITY DEFINER posture) with explicit whitelisted transitions covering
-- the full live status chain, plus a back-compat STARTED branch for any
-- legacy in-flight rows. The fee-on-COMPLETED behavior is preserved
-- verbatim. No table, column, enum, or policy changes.
-- ============================================================

create or replace function public.transition_ride_status(
  p_ride_id uuid,
  p_new_status ride_status,
  p_actor uuid
)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride ride_requests;
  v_old ride_status;
  v_actor_is_admin boolean := false;
  v_actor_is_claiming_provider boolean := false;
begin
  select * into v_ride from ride_requests where id = p_ride_id for update;
  if v_ride.id is null then
    raise exception 'RIDE_NOT_FOUND';
  end if;
  v_old := v_ride.status;
  if v_old in ('CANCELLED', 'COMPLETED') then
    raise exception 'RIDE_ALREADY_TERMINAL';
  end if;

  select exists (select 1 from user_roles where user_id = p_actor and role = 'ADMIN')
    into v_actor_is_admin;
  if v_ride.claimed_by_provider_id is not null then
    select exists (
      select 1 from provider_profiles
       where id = v_ride.claimed_by_provider_id and user_id = p_actor
    ) into v_actor_is_claiming_provider;
  end if;

  case v_old
    when 'REQUESTED' then
      if p_new_status != 'CANCELLED' then
        raise exception 'ONLY_CANCELLATION_ALLOWED_FROM_REQUESTED_USE_CLAIM_RIDE';
      end if;
      if v_ride.user_id != p_actor and not v_actor_is_admin then
        raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL_BEFORE_CLAIM';
      end if;

    when 'CLAIMED' then
      if p_new_status = 'CANCELLED' then
        if v_ride.user_id != p_actor and not v_actor_is_admin then
          raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL_CLAIMED_RIDE';
        end if;
      elsif p_new_status != 'DRIVER_ARRIVING' then
        raise exception 'INVALID_TRANSITION_%_TO_%', v_old, p_new_status;
      elsif not v_actor_is_claiming_provider and not v_actor_is_admin then
        raise exception 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_PROGRESS_RIDE';
      end if;

    when 'DRIVER_ARRIVING' then
      if p_new_status = 'CANCELLED' then
        if v_ride.user_id != p_actor and not v_actor_is_admin then
          raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL';
        end if;
      elsif p_new_status != 'ARRIVED' then
        raise exception 'INVALID_TRANSITION_%_TO_%', v_old, p_new_status;
      elsif not v_actor_is_claiming_provider and not v_actor_is_admin then
        raise exception 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_PROGRESS_RIDE';
      end if;

    when 'ARRIVED' then
      if p_new_status = 'CANCELLED' then
        if v_ride.user_id != p_actor and not v_actor_is_admin then
          raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL';
        end if;
      elsif p_new_status != 'TRIP_STARTED' then
        raise exception 'INVALID_TRANSITION_%_TO_%', v_old, p_new_status;
      elsif not v_actor_is_claiming_provider and not v_actor_is_admin then
        raise exception 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_PROGRESS_RIDE';
      end if;

    when 'TRIP_STARTED' then
      if p_new_status in ('COMPLETED') then
        if not v_actor_is_claiming_provider and not v_actor_is_admin then
          raise exception 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_COMPLETE_RIDE';
        end if;
      elsif p_new_status = 'CANCELLED' then
        if v_ride.user_id != p_actor and not v_actor_is_admin then
          raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL';
        end if;
      else
        raise exception 'INVALID_TRANSITION_%_TO_%', v_old, p_new_status;
      end if;

    -- Back-compat: rides created before the ARRIVED/TRIP_STARTED statuses
    -- existed may still sit in the legacy STARTED state.
    when 'STARTED' then
      if p_new_status in ('COMPLETED') then
        if not v_actor_is_claiming_provider and not v_actor_is_admin then
          raise exception 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_COMPLETE_RIDE';
        end if;
      elsif p_new_status = 'CANCELLED' then
        if v_ride.user_id != p_actor and not v_actor_is_admin then
          raise exception 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL';
        end if;
      else
        raise exception 'INVALID_TRANSITION_%_TO_%', v_old, p_new_status;
      end if;

    else
      raise exception 'UNEXPECTED_RIDE_STATUS_%', v_old;
  end case;

  update ride_requests
     set status = p_new_status, updated_at = now()
   where id = p_ride_id
   returning * into v_ride;

  insert into ride_status_history (ride_request_id, from_status, to_status, changed_by)
  values (p_ride_id, v_old, p_new_status, p_actor);

  -- Unchanged money behavior: the ride fee is charged exactly once, on
  -- completion, idempotent by 'ride:<id>'.
  if p_new_status = 'COMPLETED' then
    perform deduct_transaction_fee(
      v_ride.claimed_by_provider_id,
      null,
      p_ride_id,
      coalesce(v_ride.fare_estimate, 0),
      'ride:' || p_ride_id::text
    );
  end if;

  return v_ride;
end;
$$;
