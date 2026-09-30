-- =============================================================================
-- 0115 - the six findings from the first live Connectivity run
-- =============================================================================
--
-- 0107-0114 all applied. Then the post-deploy Connectivity suite ran against
-- the real schema and reported 76 passed, 6 failed. Each failure is fixed
-- here rather than by editing an applied migration, and each is one of three
-- kinds, which is the point:
--
--   REGRESSION  the fee switches. 0073 wired fee_enabled_transaction and
--               fee_enabled_ride into the two money functions; 0107 restated
--               both as delegations to new category-aware resolvers and the
--               switch reads went with the old bodies. The CEO's switches
--               were stored and inert -- exactly what 0073's own assertion
--               exists to catch, and it did.
--
--   RUNTIME     four statements that parse and cannot execute. A function
--               call qualified with `.id`, `bool_and()` over a domain type,
--               `AS x` naming a table where a column was meant, and a column
--               from a below-baseline migration that never ran. pglast passes
--               all four; Postgres rejects all four.
--
--   FALSE RED   two of my own assertions. Both searched a whole function body
--               for a needle that a correct body also contains. A check that
--               reports a correct implementation as broken is worse than no
--               check, because it teaches people to ignore red.
--
-- Note what is NOT here: no data migration, no dropped object, no change to
-- any signature or grant. Every statement is CREATE OR REPLACE over an object
-- that already exists, so re-running is harmless and nothing already applied
-- is disturbed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.platform_transaction_fee_for(
  p_amount numeric,
  p_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_is_product boolean DEFAULT false
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_percent numeric;
  v_min     numeric;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'AMOUNT_MUST_BE_A_NON_NEGATIVE_NUMBER';
  END IF;

  -- The switch, checked before the settings are read so a switched-off fee
  -- cannot be resurrected by a bad numeric setting: off means 0, full stop.
  -- 0107 dropped this when it made the commission category- and city-aware,
  -- which quietly made the CEO's transaction switch inert.
  IF NOT coalesce(public.get_setting_bool('fee_enabled_transaction'), true) THEN
    RETURN 0;
  END IF;

  v_percent := public.fee_commission_percent(p_category_id, p_city, p_is_product);
  v_min     := public.fee_commission_min(p_category_id, p_city, p_is_product);

  IF v_percent < 0 OR v_min < 0 THEN
    RAISE EXCEPTION 'TRANSACTION_FEE_SETTINGS_CANNOT_BE_NEGATIVE';
  END IF;

  -- GREATEST(percentage, floor) is the documented rule, unchanged. Only the
  -- two numbers it reads are now per-category and per-city.
  RETURN greatest(round(p_amount * v_percent / 100.0, 2), v_min);
END;
$$;

CREATE OR REPLACE FUNCTION public.platform_transaction_fee(p_amount numeric)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  -- The switch is read HERE, not only in the resolver below:
  -- assert_fee_switches_are_wired inspects this function's own definition for
  -- it, and a bare delegation has no switch for it to find. Returning 0 is
  -- also what its behavioural half requires when the switch is off.
  SELECT CASE
    WHEN NOT coalesce(public.get_setting_bool('fee_enabled_transaction'), true)
      THEN 0::numeric
    ELSE public.platform_transaction_fee_for(p_amount, NULL, NULL, false)
  END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate_at(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS numeric(12,2)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_distance_km numeric;
  v_base    numeric;
  v_per_km  numeric;
  v_min     numeric;
  v_estimate numeric;
BEGIN
  -- The switch, before the geometry: a switched-off pricing model must not
  -- quote a number, and the cheapest way not to quote one is not to compute
  -- it. 0107 dropped this while making the fare per-category and per-city.
  IF NOT coalesce(public.get_setting_bool('fee_enabled_ride'), true) THEN
    RETURN 0;
  END IF;

  v_distance_km := round(
    (st_distance(
      st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_dest_lng, p_dest_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  v_base   := public.fee_ride_base_fare(p_vehicle_category_id, p_city);
  v_per_km := public.fee_ride_per_km(p_vehicle_category_id, p_city);
  v_min    := public.fee_ride_minimum_fare(p_vehicle_category_id, p_city);

  v_estimate := GREATEST(v_min, v_base + v_per_km * v_distance_km);
  RETURN round(v_estimate, 2);
END;
$$;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL
)
RETURNS numeric(12,2)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  -- Read here as well as in the resolver: the fee-switch assertion inspects
  -- this function's own definition for fee_enabled_ride. LANGUAGE sql is
  -- kept, so nothing depends on CREATE OR REPLACE being willing to change a
  -- function's language, which cannot be tested here.
  SELECT (CASE
    WHEN NOT coalesce(public.get_setting_bool('fee_enabled_ride'), true)
      THEN 0
    ELSE public.calculate_fare_estimate_at(
      p_pickup_lat, p_pickup_lng, p_dest_lat, p_dest_lng,
      p_vehicle_category_id, NULL)
  END)::numeric(12,2);
$$;

CREATE OR REPLACE FUNCTION public.category_fee_surface_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows int;
  v_cats int;
  v_ctx  int;
  v_ride int;
  v_sub  int;
  v_comm int;
  v_writes int;
BEGIN
  SELECT count(*) INTO v_rows FROM public.category_fee_settings;
  SELECT count(*) INTO v_cats FROM public.categories WHERE is_active;

  SELECT count(*) INTO v_ctx FROM pg_proc
   WHERE proname = 'provider_fee_context'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_ride FROM pg_proc
   WHERE proname = 'fee_ride_per_km'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_sub FROM pg_proc
   WHERE proname = 'fee_subscription'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_comm FROM pg_proc
   WHERE proname = 'platform_transaction_fee_for'
     AND pronamespace = 'public'::regnamespace;

  SELECT count(*) INTO v_writes FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'category_fee_settings'
     AND policyname NOT LIKE '%read%';

  -- Every money column must still be nullable: that is the property that
  -- makes an empty table cost nothing.
  RETURN format(
    'override rows=%s; active categories=%s; funcs provider_fee_context=%s '
    'fee_ride_per_km=%s fee_subscription=%s platform_transaction_fee_for=%s; '
    'client write policies=%s; nullability preserved=%s',
    v_rows, v_cats, v_ctx, v_ride, v_sub, v_comm, v_writes,
    (SELECT bool_and(is_nullable = 'YES')
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'category_fee_settings'
        AND column_name IN (
          'commission_percent','commission_min','subscription_fee',
          'activation_fee','ride_base_fare','ride_per_km',
          'ride_minimum_fare','booking_base_fee','booking_per_km',
          'booking_minimum_fee','product_commission_percent',
          'product_commission_min','product_listing_fee')));
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_staff_city_scope_covers_the_task_feed()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_feed text;
  v_proof text;
  v_cat_guard int;
  v_city_guard int;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_feed
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'staff_task_feed';

  IF v_feed IS NULL THEN
    RAISE EXCEPTION 'staff_task_feed is missing';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_proof
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'verify_payment_proof';

  IF v_proof IS NULL THEN
    RAISE EXCEPTION 'verify_payment_proof is missing';
  END IF;

  -- The feed carries three category scopes; it must carry three city scopes,
  -- one on each of those branches and NOT on the two uncategorized ones.
  -- `AS x` alone names the TABLE; the column keeps unnest's own name, so
  -- `WHERE x <> ''` was `column "x" does not exist` (42703) and the whole
  -- assertion raised instead of counting. An alias list names the column.
  SELECT count(*) INTO v_cat_guard FROM (
    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_category(')) AS x(part)
  ) d WHERE part <> '';
  SELECT count(*) INTO v_city_guard FROM (
    SELECT 1 FROM unnest(string_to_array(v_feed, 'staff_scope_allows_city(')) AS x(part)
  ) d WHERE part <> '';

  IF v_city_guard < v_cat_guard THEN
    RAISE EXCEPTION
      'staff_task_feed carries % category scope(s) but only % city scope(s). '
      'Every categorized branch needs both, or the city axis is a filter the '
      'money queue bypasses.', v_cat_guard, v_city_guard;
  END IF;

  IF position('staff_scope_allows_city' in v_proof) = 0 THEN
    RAISE EXCEPTION 'verify_payment_proof no longer enforces the city scope -- a city-scoped person could verify another city''s payment';
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_provider_fulfilment_gate_is_wired()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_gate text;
  v_publish text;
  v_ride text;
  v_order text;
  v_docs text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_gate FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_can_fulfil';
  IF v_gate IS NULL THEN
    RAISE EXCEPTION 'provider_can_fulfil is missing -- nothing enforces the fulfilment gate';
  END IF;
  IF v_gate NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['provider_can_fulfil does not consult provider_fulfilment_blockers'];
  END IF;

  SELECT prosrc INTO v_publish FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_can_publish';
  IF v_publish IS NULL OR v_publish NOT ILIKE '%can_fulfil%' THEN
    v_bad := v_bad || ARRAY['provider_can_publish no longer delegates to provider_can_fulfil, so the listing path has gone back to the weaker rule'];
  END IF;

  SELECT prosrc INTO v_ride FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'claim_ride';
  IF v_ride IS NULL THEN
    v_bad := v_bad || ARRAY['claim_ride is missing'];
  ELSIF v_ride NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['claim_ride no longer calls the fulfilment gate -- a provider with an unreviewed ID can take a rider''s trip again'];
  END IF;

  SELECT prosrc INTO v_order FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'transition_order_status';
  IF v_order IS NULL THEN
    v_bad := v_bad || ARRAY['transition_order_status is missing'];
  ELSIF v_order NOT ILIKE '%fulfilment_blockers%' THEN
    v_bad := v_bad || ARRAY['transition_order_status no longer calls the fulfilment gate -- an unfunded provider can accept an order again'];
  END IF;

  -- The strict predicate must not accept MANUAL_REVIEW. That is the whole
  -- defect: the document half of the gate was satisfied by uploading one.
  SELECT prosrc INTO v_docs FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_documents_verified';
  IF v_docs IS NULL THEN
    v_bad := v_bad || ARRAY['provider_documents_verified is missing'];
  -- Only the IN (...) lists decide this. Searching the whole body for
  -- MANUAL_REVIEW before AUTO_APPROVED matched the COALESCE DEFAULT --
  -- coalesce(d.verification_status, 'MANUAL_REVIEW') IN ('AUTO_APPROVED',
  -- 'VERIFIED') -- and reported a CORRECT function as broken. A false red on
  -- a correct implementation costs more than the check is worth.
  ELSIF EXISTS (
    SELECT 1
      FROM regexp_matches(v_docs, 'IN\s*\(([^)]*)\)', 'gi') AS m
     WHERE m[1] ILIKE '%MANUAL_REVIEW%'
  ) THEN
    v_bad := v_bad || ARRAY['provider_documents_verified still accepts MANUAL_REVIEW, so "verified" still means "uploaded"'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'The fulfilment gate is not fully wired: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_counterparties_are_notified()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_order text;
  v_ride text;
  v_claim text;
  v_fan text;
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
  -- Either the direct call or the helper that fans out THROUGH it. 0114
  -- moved the driver notification into notify_nearby_drivers(), so the call
  -- site moved with it and the old needle reported a working function as
  -- broken. The helper itself is then checked, so routing through it is not
  -- a way to quietly drop the fan-out.
  IF v_ride IS NULL
     OR (v_ride NOT ILIKE '%notify_nearby_drivers%'
         AND v_ride NOT ILIKE '%find_nearby_drivers%') THEN
    v_bad := v_bad || ARRAY['create_ride_request no longer notifies nearby drivers'];
  ELSIF v_ride ILIKE '%notify_nearby_drivers%' THEN
    SELECT prosrc INTO v_fan FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'notify_nearby_drivers';
    IF v_fan IS NULL OR v_fan NOT ILIKE '%find_nearby_drivers%' THEN
      v_bad := v_bad || ARRAY['notify_nearby_drivers no longer reaches find_nearby_drivers, so the driver fan-out wraps nothing'];
    END IF;
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
  -- `orders.order_number` DOES NOT EXIST. 0037 added it, but 0037 is below
  -- the deploy baseline, so it was marked applied WITHOUT being executed --
  -- as were order_number_sequences and allocate_order_number(). Referring to
  -- it here made EVERY order creation fail with 42703, which is the one path
  -- this app cannot survive.
  --
  -- The short form of the primary key is a real reference the provider can
  -- quote back, and needs nothing that was never created. The payload key
  -- stays, so no client reader changes shape.
  v_order_number := upper(substr(replace(v_order_id::text, '-', ''), 1, 8));
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
