-- Make the order write assertion VOLATILE so it can run at all.
--
-- 20260927000018 declared assert_order_creation_writes STABLE. Postgres
-- refuses to execute INSERT inside a STABLE function, so the very first
-- fixture write failed and the test reported:
--
--   PostgrestException: INSERT is not allowed in a non-volatile function
--   code: 0A000
--
-- The test has been failing for that reason alone and has never once
-- exercised order creation. It was supposed to be the check that would have
-- caught the 25-minute ORDERS_MUST_START_AS_CREATED outage; instead it has
-- been reporting a PostgreSQL error code.
--
-- The body is re-emitted verbatim. Only the volatility changes: plpgsql
-- defaults to VOLATILE, which is what a function that writes and is rolled
-- back has to be. A write test is by definition not read-only, so STABLE was
-- never the right annotation -- and the failure was silent about intent,
-- because a wrong annotation reads the same as a genuine assertion failure
-- from the outside.
--
-- The sibling wallet assertion added in 20260927000021 was declared VOLATILE
-- from the start for the same reason; this migration exists only because
-- 00018 has already been applied and CREATE OR REPLACE is the way to correct
-- a live definition.

CREATE OR REPLACE FUNCTION public.assert_order_creation_writes()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000c0de';
  v_prov  uuid := '00000000-0000-4000-8000-0000000000c1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000000c2';
  v_order jsonb;
  v_row   record;
  v_count int;
BEGIN
  BEGIN
    -- A synthetic auth user, because provider_profiles.user_id references
    -- auth.users. Fixed ids, so this can never accumulate.
    INSERT INTO auth.users (id, email, email_confirmed_at)
    VALUES (v_user, 'write-test@example.invalid', now())
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user, 'Write Test', 'APPROVED')
    ON CONFLICT (id) DO NOTHING;

    -- Fixture only: an APPROVED provider, which no client could create.
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES (v_prov, v_user, 'SERVICE_PROVIDER', 'Write Test Provider', 'APPROVED')
    ON CONFLICT (id) DO NOTHING;
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    INSERT INTO public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    VALUES (v_prod, v_prov, 'Write Test Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    ON CONFLICT (id) DO NOTHING;

    -- The real path the app uses, through the real function, with every
    -- real trigger attached.
    v_order := public.create_order_secure(
      p_user_id          => v_user,
      p_provider_id      => v_prov,
      p_items            => jsonb_build_array(
                             jsonb_build_object('product_id', v_prod,
                                                'quantity', 2, 'unit_price', 10.00)),
      p_total_amount     => 20.00,
      p_currency         => 'ETB',
      p_note             => 'write-verification',
      p_fulfillment_mode => 'DELIVERY',
      p_delivery_address => 'Write Test Address',
      p_city             => 'Addis Ababa'
    );

    IF v_order IS NULL THEN
      RAISE EXCEPTION 'create_order_secure returned null';
    END IF;

    -- The order must be on disk and in the state the app relies on. A
    -- different status is exactly the regression that caused the outage:
    -- the provider queue and the accept button are both built around
    -- PENDING_PROVIDER.
    SELECT o.status, o.total_amount INTO v_row
    FROM public.orders o WHERE o.id = (v_order->>'id')::uuid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'create_order_secure did not persist an order row';
    END IF;

    IF v_row.status <> 'PENDING_PROVIDER' THEN
      RAISE EXCEPTION 'order created in status %, expected PENDING_PROVIDER',
        v_row.status;
    END IF;

    IF v_row.total_amount <> 20.00 THEN
      RAISE EXCEPTION 'order total is %, expected 20.00', v_row.total_amount;
    END IF;

    -- Order items too, or the detail screen and fulfilment see an empty
    -- order even though the order row exists.
    SELECT count(*) INTO v_count
    FROM public.order_items WHERE order_id = (v_order->>'id')::uuid;

    IF v_count <> 1 THEN
      RAISE EXCEPTION 'order has % items, expected 1', v_count;
    END IF;

    -- A provider who is not APPROVED must be refused — proven by attempting
    -- the write, not by reading the function body. A PENDING_APPROVAL
    -- provider is enough: the guard is "status <> APPROVED", and this
    -- provider was created that way by the app's real signup path.
    INSERT INTO public.provider_profiles (id, user_id, provider_type, business_name, status)
    VALUES ('00000000-0000-4000-8000-0000000000c3', v_user, 'SERVICE_PROVIDER',
            'Write Test Pending', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    BEGIN
      PERFORM public.create_order_secure(
        p_user_id          => v_user,
        p_provider_id      => '00000000-0000-4000-8000-0000000000c3',
        p_items            => jsonb_build_array(
                               jsonb_build_object('product_id', v_prod,
                                                  'quantity', 1, 'unit_price', 10.00)),
        p_total_amount     => 10.00,
        p_currency         => 'ETB',
        p_fulfillment_mode => 'DELIVERY',
        p_delivery_address => 'Write Test Address'
      );
      RAISE EXCEPTION 'a non-approved provider was allowed to take an order';
    EXCEPTION
      -- Reaching the RAISE above means the guard did not fire. Anything
      -- else here is the refusal we wanted.
      WHEN OTHERS THEN
        IF SQLERRM = 'a non-approved provider was allowed to take an order' THEN
          RAISE;
        END IF;
        NULL;
    END;

    -- Undo everything this function did, atomically.
    RAISE EXCEPTION '%', c_sentinel;

  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = c_sentinel THEN
        -- Rollback already happened as the subtransaction unwound.
        RETURN true;
      END IF;
      -- A real failure: surface it so CI fails with the actual reason.
      RAISE;
  END;
END;
$$;

COMMENT ON FUNCTION public.assert_order_creation_writes() IS
  'Places a real order through create_order_secure inside a subtransaction '
  'that is always rolled back, asserting the order persists in '
  'PENDING_PROVIDER with its items, and that a non-approved provider is '
  'refused. VOLATILE, not STABLE: a function that writes cannot be STABLE. '
  'Leaves no data behind.';

GRANT EXECUTE ON FUNCTION public.assert_order_creation_writes() TO anon, authenticated;
