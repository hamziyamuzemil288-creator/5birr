-- Give transition_ride_status a branch for DRIVER_EN_ROUTE, and assert the
-- ride chain has no dead ends.
--
-- The gap
-- -------
-- ride_status is a nine-value enum:
--
--   REQUESTED, CLAIMED, DRIVER_ARRIVING, DRIVER_EN_ROUTE, ARRIVED,
--   TRIP_STARTED, STARTED, COMPLETED, CANCELLED
--
-- but the transition function (restated in 20260922000005 to fix rides
-- freezing at DRIVER_ARRIVING) has a CASE branch for every one of them
-- EXCEPT DRIVER_EN_ROUTE. A ride in that status falls through to
--
--   raise exception 'UNEXPECTED_RIDE_STATUS_%', v_old;
--
-- and is frozen permanently: the rider cannot cancel it, the driver cannot
-- advance or complete it, and the transaction fee is never charged because
-- only COMPLETED charges it.
--
-- It is latent rather than live — nothing in the app currently sets
-- DRIVER_EN_ROUTE. It is fixed anyway because the enum value is real, the
-- rider's active-ride screen already lists it among the statuses it renders
-- (user_active_ride_screen.dart), and a status that exists in the enum but
-- not in the state machine is a trap for whoever wires it up next. Adding
-- the branch costs nothing and removes the possibility.
--
-- The semantics mirror DRIVER_ARRIVING exactly, which is what
-- DRIVER_EN_ROUTE means: the driver is on the way to the pickup, so the next
-- step is ARRIVED. Rider or admin may cancel; only the claiming provider or
-- an admin may advance.
--
-- The assertion below is the check that would have caught this. The existing
-- assert_ride_transition_covers_chain only verifies that ARRIVED and
-- TRIP_STARTED are handled at all, not that every status has a branch.

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

    -- ADDED: DRIVER_EN_ROUTE is a live enum value that had no branch, so a
    -- ride in it raised UNEXPECTED_RIDE_STATUS_% on every transition and
    -- could neither be advanced nor cancelled. Same semantics as
    -- DRIVER_ARRIVING: the driver is travelling to the pickup.
    when 'DRIVER_EN_ROUTE' then
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

-- Backfill: a ride already sitting in DRIVER_EN_ROUTE is frozen, and nothing
-- can move it. There is no way to know whether the driver was actually
-- en route, so the conservative repair is to treat it as the state it is
-- equivalent to and let the driver confirm arrival from there. Rides that
-- are already terminal are left alone.
UPDATE public.ride_requests
   SET status = 'DRIVER_ARRIVING', updated_at = now()
 WHERE status = 'DRIVER_EN_ROUTE';

-- ── The assertion that would have caught this ────────────────────────────
-- Every non-terminal ride status must have a branch, and an unhandled status
-- must still fail loudly rather than silently doing nothing.
--
-- The status list is hard-coded rather than read from pg_enum on purpose:
-- reading the enum would make this assertion silently accept a newly added
-- value with no matching branch, which is exactly the regression worth
-- catching. A new status must be added here deliberately, by whoever also
-- adds its branch.
CREATE OR REPLACE FUNCTION public.assert_ride_chain_has_no_dead_ends()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_status text;
  v_escapable text[] := ARRAY[
    'REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING', 'DRIVER_EN_ROUTE',
    'ARRIVED', 'TRIP_STARTED', 'STARTED'
  ];
BEGIN
  SELECT p.prosrc INTO v_src
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'transition_ride_status';

  IF v_src IS NULL THEN
    RETURN false;
  END IF;

  FOREACH v_status IN ARRAY v_escapable LOOP
    IF position('when ''' || v_status || ''' then' in lower(v_src)) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  IF position('unexpected_ride_status' in lower(v_src)) = 0 THEN
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_ride_chain_has_no_dead_ends() IS
  'True when transition_ride_status() has a branch for every non-terminal '
  'ride status and still rejects unknown ones loudly.';

GRANT EXECUTE ON FUNCTION public.assert_ride_chain_has_no_dead_ends() TO authenticated;
