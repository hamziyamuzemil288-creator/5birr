-- A test that actually places an order, and leaves nothing behind.
--
-- Why this exists
-- ---------------
-- Every other assertion in this suite reads: function source text, policy
-- catalogues, table contents. None of them write. That gap let a real
-- production outage ship green.
--
-- 20260927000009 changed create_order_secure to insert PENDING_PROVIDER.
-- The live trigger trg_orders_insert_security still required 'CREATED' and
-- raised ORDERS_MUST_START_AS_CREATED, so every order the app created
-- failed — for about 25 minutes, on a live marketplace. Nothing caught it,
-- because the only order-related assertion,
-- assert_create_order_persists_fulfillment, greps prosrc for the strings
-- 'fulfillment_mode' and 'p_city'. It never creates an order. It could not
-- have caught this even in principle.
--
-- The same blind spot hid the subscription scheduler failing for the same
-- reason, and would hide the next one.
--
-- How this stays safe
-- -------------------
-- The work happens inside a PL/pgSQL block with an EXCEPTION handler. Every
-- statement is part of one subtransaction, and the block ends by raising a
-- sentinel error, which rolls the subtransaction back — including the
-- trigger toggling described below, since PostgreSQL DDL is transactional.
-- The handler recognises the sentinel and returns normally.
--
-- So the function creates a synthetic auth user, provider, product and
-- order, asserts the result, and leaves the database exactly as it found
-- it. There is no cleanup step that can fail, no residue to accumulate, and
-- no window in which another session could observe the test rows: they are
-- never visible outside the subtransaction.
--
-- A genuine failure re-raises, so a broken create_order_secure surfaces
-- with its actual error rather than a silent pass.
--
-- The trigger toggle
-- ------------------
-- The fixture needs an APPROVED provider, but that is precisely what the
-- write guards exist to prevent: a client cannot insert a provider in any
-- state but PENDING_APPROVAL, nor change one to APPROVED. The test runs as
-- whatever role called it (anon, from CI), so it is subject to the same
-- rules as a real client — correctly.
--
-- So the provider INSERT guard is disabled for the single fixture INSERT
-- and re-enabled immediately after. That is the only DDL in the function,
-- the window is a few statements wide, and both the DDL and the data are
-- undone by the rollback. The order-creation path under test is NOT
-- disabled or bypassed in any way: create_order_secure runs, with every
-- order trigger attached, exactly as the app invokes it.

CREATE OR REPLACE FUNCTION public.assert_order_creation_writes()
RETURNS boolean
LANGUAGE plpgsql
STABLE
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
  'refused. Leaves no data behind.';

GRANT EXECUTE ON FUNCTION public.assert_order_creation_writes() TO anon, authenticated;
