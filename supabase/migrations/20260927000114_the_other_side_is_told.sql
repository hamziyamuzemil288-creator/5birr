-- 0114: tell the other side.
--
-- WHAT THIS FIXES
--
-- A notification is the only thing that makes a marketplace reactive, and
-- three of the most important events in this product fired silently:
--
--   event                          told                        not told
--   -----------------------------  --------------------------  --------------------
--   a buyer places an order        the buyer (by definition)  the PROVIDER
--   a rider requests a ride        the rider                  any nearby DRIVER
--   a driver claims that ride      --                         the RIDER
--
-- All three worked. That is what made them survive: a provider who was never
-- told an order arrived found out by opening the orders screen, a driver who
-- was never told a ride was nearby found out by the same polling, and a rider
-- whose ride had been claimed found out by looking at the map. Nothing errors,
-- nothing logs, and the product simply feels dead to the two people on the
-- other side of the transaction.
--
-- ORDER_RECEIVED and RIDE_CLAIMED have been members of the notification_type
-- enum since 0001. Nothing has ever written them. Fifteen of the enum's
-- twenty-nine values are in that position, which is the clearest evidence in
-- the repository that the enum was designed from the data model rather than
-- from the flows.
--
-- WHY THE NOTIFICATIONS CANNOT BE ALLOWED TO BREAK THE FLOW
--
-- Every insert below is wrapped so that a failure to notify cannot roll back
-- the order, the ride, or the claim. A notification is a courtesy to the other
-- party; the transaction is the work. Making the notification load-bearing
-- would mean a full notifications table takes down every purchase in the
-- city, which is a strictly worse failure than the one being fixed.
-- notify_user_once()'s own contract (20260927000086) is the same principle:
-- swallow the error, never propagate it out of the money movement.

SET search_path = public, pg_temp;

-- -----------------------------------------------------------------------------
-- 0. Two helpers, so the restated bodies stay small and verifiable
-- -----------------------------------------------------------------------------
--
-- The failure contract is "a notification must never take down the thing it
-- was describing", and that is expressed with a function-level EXCEPTION
-- clause -- the same shape notify_user_once() uses in 20260927000086, for the
-- same reason: a delivery failure is logged, never raised.
--
-- The alternative, a nested `BEGIN ... EXCEPTION ... END` around each insert
-- inside the restated functions, is correct SQL and unreadable at four call
-- sites, and it nests a plpgsql block deep enough that the body-syntax gate
-- can no longer see inside it. Two helpers keep the swallowing in one place
-- and keep the diff of each restated body to a single line.

CREATE OR REPLACE FUNCTION public.notify_best_effort(
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_data jsonb DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Nothing to address: callers legitimately do not know the counterparty
  -- yet, and must not have to pre-check.
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN public.insert_notification(p_user_id, p_type, p_title, p_body, p_data);

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'notify_best_effort(%) failed and was swallowed: %',
      p_type, SQLERRM;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_best_effort(
  uuid, public.notification_type, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_best_effort(
  uuid, public.notification_type, text, text, jsonb)
  TO authenticated, service_role;

-- The driver fan-out, isolated so that neither its cost nor its failure can
-- reach the rider's ride request.
--
-- The LIMIT is a correctness requirement rather than an optimisation: a busy
-- city at peak time would otherwise write one row per driver in the country
-- for a single request, which is a denial of service against our own
-- notifications table.
CREATE OR REPLACE FUNCTION public.notify_nearby_drivers(
  p_ride_id uuid,
  p_pickup_text text,
  p_lat double precision,
  p_lng double precision,
  p_vehicle_category_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_driver record;
  v_sent integer := 0;
BEGIN
  FOR v_driver IN
    SELECT d.provider_id
      FROM public.find_nearby_drivers(
             p_lat, p_lng, 10, p_vehicle_category_id
           ) d
      JOIN public.provider_profiles pp ON pp.id = d.provider_id
     WHERE pp.status = 'APPROVED'
       AND pp.provider_type = 'VEHICLE_PROVIDER'
     ORDER BY d.distance_km
     LIMIT 12
  LOOP
    PERFORM public.notify_best_effort(
      (SELECT pp2.user_id FROM public.provider_profiles pp2
        WHERE pp2.id = v_driver.provider_id),
      'RIDE_REQUEST',
      'Ride nearby',
      'A rider near ' || coalesce(p_pickup_text, 'you')
          || ' is looking for a driver.',
      jsonb_build_object('ride_request_id', p_ride_id)
    );
    v_sent := v_sent + 1;
  END LOOP;

  RETURN v_sent;

EXCEPTION
  WHEN OTHERS THEN
    RAISE WARNING 'notify_nearby_drivers(%) failed and was swallowed: %',
      p_ride_id, SQLERRM;
    RETURN v_sent;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_nearby_drivers(
  uuid, text, double precision, double precision, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_nearby_drivers(
  uuid, text, double precision, double precision, uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 1. A new order reaches the provider
-- -----------------------------------------------------------------------------
--
-- Restated verbatim from 20260927000074_availability_confirmation_gate.sql
-- apart from the appended notification. The order number is included in both
-- the title and the data, because a provider reading "You have a new order"
-- has to open the app to find out which one, and the number is what they quote
-- on the phone.

CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null,
  p_fulfillment_mode text default 'DELIVERY',
  p_delivery_address text default null,
  p_city text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_needs_availability boolean := false;
  v_order_number text;
  v_item_count int;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;
  if p_fulfillment_mode is null or p_fulfillment_mode not in ('DELIVERY','SELF_PICKUP') then
    p_fulfillment_mode := 'DELIVERY';
  end if;
  if p_fulfillment_mode = 'DELIVERY' and coalesce(trim(p_delivery_address), '') = '' then
    raise exception 'DELIVERY_REQUIRES_ADDRESS';
  end if;

  if not exists (
    select 1 from provider_profiles
     where id = p_provider_id and status = 'APPROVED'
  ) then
    raise exception 'PROVIDER_NOT_ACCEPTING_ORDERS';
  end if;

  select exists (
    select 1
      from (select distinct on (e->>'product_id') e->>'product_id' as product_id
              from jsonb_array_elements(p_items) e) d
      join products pr on pr.id = d.product_id::uuid
     where pr.requires_availability_confirmation
  ) into v_needs_availability;

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at, fulfillment_mode,
    delivery_address, city, requires_availability_confirmation
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'PENDING_PROVIDER',
    p_total_amount, coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
    nullif(trim(p_delivery_address), ''),
    coalesce(
      nullif(trim(p_city), ''),
      (select pp.city from provider_profiles pp where pp.id = p_provider_id),
      default_city()
    ),
    coalesce(v_needs_availability, false)
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(),
      v_order_id,
      (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::numeric,
      (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'PENDING_PROVIDER', p_user_id, p_note);

  -- NEW. The provider is the counterparty on this order and was the only
  -- participant not told about it. notify_best_effort swallows a delivery
  -- failure, so this can never roll back the customer's order.
  select o.order_number into v_order_number from orders o where o.id = v_order_id;
  select count(*) into v_item_count from order_items oi where oi.order_id = v_order_id;

  perform public.notify_best_effort(
    (select pp.user_id from provider_profiles pp where pp.id = p_provider_id),
    'ORDER_RECEIVED',
    'New order ' || coalesce(v_order_number, ''),
    case when v_item_count = 1
         then 'A customer placed an order for 1 item. Open it to confirm.'
         else 'A customer placed an order for ' || v_item_count
              || ' items. Open it to confirm.'
    end,
    jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number)
  );

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

REVOKE ALL ON FUNCTION public.create_order_secure(
  uuid, uuid, jsonb, numeric, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_order_secure(
  uuid, uuid, jsonb, numeric, text, text, text, text, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. A new ride reaches nearby drivers
-- -----------------------------------------------------------------------------
--
-- Restated verbatim from 20260927000107 apart from the driver fan-out.
--
-- Bounded to the nearest 12 drivers within 10km of the pickup, matched on the
-- requested vehicle category. A cap is not an optimisation, it is a
-- correctness requirement: a busy city at peak time would otherwise write one
-- row per driver in the country for a single request, which is a denial of
-- service against our own notifications table.
--
-- Only drivers who could actually take this ride are told: an APPROVED
-- provider_type = 'VEHICLE_PROVIDER' with an available vehicle in the
-- category. find_nearby_drivers() already applies the vehicle join; the
-- profile filter is applied here so a suspended driver's notification does
-- not tell them to turn up for work they may not accept.

CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text default null,
  p_destination_text text default null,
  p_vehicle_category_id uuid default null
)
RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride ride_requests;
  v_city text;
BEGIN
  IF p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER';
  END IF;

  SELECT city INTO v_city FROM public.profiles WHERE id = p_user_id;

  INSERT INTO ride_requests (
    user_id, pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text, vehicle_category_id,
    fare_estimate, status, requested_at
  ) VALUES (
    p_user_id, p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
    p_pickup_text, p_destination_text, p_vehicle_category_id,
    public.calculate_fare_estimate_at(
      p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
      p_vehicle_category_id, v_city),
    'REQUESTED', now()
  ) RETURNING * INTO v_ride;

  -- The rider, as before.
  PERFORM insert_notification(
    p_user_id, 'RIDE_REQUEST', 'Ride requested',
    'Looking for a driver near ' || coalesce(p_pickup_text, 'your location'),
    jsonb_build_object('ride_request_id', v_ride.id));

  -- NEW. The drivers. Without this the only way to learn that work exists is
  -- to have the open-rides screen open at the moment it appears.
  perform public.notify_nearby_drivers(
    v_ride.id, p_pickup_text, p_pickup_lat, p_pickup_lng, p_vehicle_category_id);

  RETURN v_ride;
END;
$$;

REVOKE ALL ON FUNCTION public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_ride_request(
  uuid, double precision, double precision, double precision, double precision,
  text, text, uuid) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. A claimed ride reaches the rider
-- -----------------------------------------------------------------------------
--
-- Restated verbatim from 0113 apart from the rider notification. Same
-- reasoning as the two above: the rider is entitled to know their trip has a
-- driver before they open the map.

CREATE OR REPLACE FUNCTION public.claim_ride(
  p_ride_id uuid,
  p_provider_id uuid,
  p_vehicle_id uuid
)
RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_ride ride_requests;
  v_blockers text[];
  v_driver_name text;
BEGIN
  IF NOT exists (SELECT 1 FROM vehicles
                  WHERE id = p_vehicle_id
                    AND provider_id = p_provider_id
                    AND is_available = true) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE';
  END IF;

  IF NOT exists (SELECT 1 FROM provider_profiles
                  WHERE id = p_provider_id
                    AND provider_type = 'VEHICLE_PROVIDER'
                    AND status = 'APPROVED') THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ELIGIBLE';
  END IF;

  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %', array_to_string(v_blockers, ',');
  END IF;

  UPDATE ride_requests
     SET status = 'CLAIMED',
         claimed_by_provider_id = p_provider_id,
         claimed_vehicle_id = p_vehicle_id,
         claimed_at = now(),
         updated_at = now()
   WHERE id = p_ride_id
     AND status = 'REQUESTED'
  RETURNING * INTO v_ride;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'RIDE_ALREADY_TAKEN';
  END IF;

  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by)
  VALUES (p_ride_id, 'REQUESTED', 'CLAIMED', auth.uid());

  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'RIDE_CLAIMED', 'ride_requests', p_ride_id,
          jsonb_build_object('provider_id', p_provider_id, 'vehicle_id', p_vehicle_id));

  -- NEW. The rider. notify_best_effort swallows a delivery failure: the ride
  -- is already CLAIMED, and rolling that back because a row could not be
  -- written would hand the trip back to the pool while the driver has set off.
  select coalesce(pp.business_name, 'A driver') into v_driver_name
    from public.provider_profiles pp where pp.id = p_provider_id;

  perform public.notify_best_effort(
    v_ride.user_id,
    'RIDE_CLAIMED',
    'Your ride has a driver',
    v_driver_name || ' is on the way to your pickup point.',
    jsonb_build_object('ride_request_id', p_ride_id, 'provider_id', p_provider_id)
  );

  RETURN v_ride;
END;
$$;

REVOKE ALL ON FUNCTION public.claim_ride(uuid, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_ride(uuid, uuid, uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Assertion
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_counterparties_are_notified()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_order text;
  v_ride text;
  v_claim text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_order FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_order_secure'
     AND pg_get_function_identity_arguments(p.oid) LIKE '%fulfillment_mode%';
  IF v_order IS NULL OR v_order NOT ILIKE '%ORDER_RECEIVED%' THEN
    v_bad := v_bad || ARRAY['create_order_secure no longer tells the provider an order arrived'];
  END IF;

  SELECT prosrc INTO v_ride FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_ride_request';
  IF v_ride IS NULL OR v_ride NOT ILIKE '%find_nearby_drivers%' THEN
    v_bad := v_bad || ARRAY['create_ride_request no longer notifies nearby drivers'];
  END IF;

  SELECT prosrc INTO v_claim FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'claim_ride';
  IF v_claim IS NULL OR v_claim NOT ILIKE '%RIDE_CLAIMED%' THEN
    v_bad := v_bad || ARRAY['claim_ride no longer tells the rider they have a driver'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'A counterparty is no longer notified: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_counterparties_are_notified()
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_counterparties_are_notified()
  TO anon, authenticated, service_role;
