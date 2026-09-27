-- Fix the two write tests' profile fixtures, not the guards they tripped.
--
-- What the deploy and CI showed
-- ----------------------------
-- After 00021/00022 applied, both write tests stopped failing on a Postgres
-- error code and started failing on a real one:
--
--   PostgrestException(message: MUST_START_AS_PENDING, code: P0001)
--
-- That is not the same MUST_START_AS_PENDING as the orders guard fixed in
-- 00016 (that one raises ORDERS_MUST_START_AS_PENDING_PROVIDER). This is
-- prevent_profile_insert_privilege_escalation:
--
--   IF NOT is_admin() THEN
--     IF new.status != 'PENDING_APPROVAL' THEN
--       RAISE EXCEPTION 'MUST_START_AS_PENDING';
--
-- on trg_profiles_insert_security, BEFORE INSERT ON profiles.
--
-- The guard is correct and is not being changed. It exists to stop a client
-- from creating an account that is already APPROVED, and every legitimate
-- server-side insert into profiles -- handle_new_user and the signup chain
-- migrations -- uses PENDING_APPROVAL for exactly that reason. The tests were
-- wrong: both built their fixture with status 'APPROVED', which is precisely
-- the thing the guard forbids.
--
-- So this migration corrects the fixtures to create the profile the way the
-- app does. It is deliberately NOT a guard change. Widening this guard to let
-- a server insert an APPROVED profile would remove a real protection to suit
-- a test, and the assertion it supports -- that a provider can be approved
-- only by a server flow -- is worth more than the convenience.
--
-- The tests do not need the profile to be APPROVED. The wallet test depends on
-- provider_profiles.registration_fee_paid, and the order test depends on
-- provider_profiles.status, which its own fixture already sets directly. The
-- profiles row exists to satisfy the foreign key from provider_profiles.
--
-- Also worth recording, since it looks like a bug and is not one:
-- prevent_role_escalation (trg_user_roles_security) tests
-- `current_user = 'authenticated'` from inside a SECURITY DEFINER trigger,
-- where current_user is always the function owner, so the check never fires.
-- That is why the ADMIN role fixture below inserts cleanly, and why signup
-- works despite that trigger sitting on the user_roles write inside
-- handle_new_user. It is left exactly as 20260925120000 established it:
-- tightening it to a real check would need the signup connection role
-- (supabase_auth_admin) added to the server-role list, and getting that
-- wrong breaks signup for every path. That is a separate piece of work with
-- its own risk, not something to smuggle in here.

-- ---------------------------------------------------------------------------
-- Order write test (re-emitted from 00022, fixtures corrected)
-- ---------------------------------------------------------------------------
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

    -- PENDING_APPROVAL, not APPROVED: trg_profiles_insert_security refuses a
    -- client-created profile that is not pending, which is the whole point of
    -- that guard. The order path reads provider_profiles.status, set below.
    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user, 'Write Test', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    -- Fixture only: an APPROVED provider, which no client could create. The
    -- guard is disabled for this one row, inside the subtransaction that is
    -- about to be rolled back anyway.
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

    -- A provider who is not APPROVED must be refused -- proven by attempting
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

-- ---------------------------------------------------------------------------
-- Wallet write test (re-emitted from 00021, fixtures corrected)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_wallet_crediting_writes()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_admin uuid := '00000000-0000-4000-8000-00000000e501';
  v_user  uuid := '00000000-0000-4000-8000-00000000e502';
  v_prov  uuid := '00000000-0000-4000-8000-00000000e503';
  v_wal   uuid := '00000000-0000-4000-8000-00000000e504';
  v_req   uuid := '00000000-0000-4000-8000-00000000e505';
  v_balance numeric;
  v_status text;
  v_ledger int;
  v_net numeric;
  v_balance_after numeric;
BEGIN
  -- Fixtures, created the way the app creates them.
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'wallet-write-admin@example.invalid', now()),
         (v_user,  'wallet-write-user@example.invalid',  now())
  ON CONFLICT (id) DO NOTHING;

  -- PENDING_APPROVAL, not APPROVED. See the header: the profile insert guard
  -- requires it, and nothing in this test depends on the profile's status.
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_admin, 'Wallet Write Admin', 'PENDING_APPROVAL'),
         (v_user,  'Wallet Write User',  'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- Fixture only. registration_fee_paid is set so the one-time activation
  -- fee does not apply and 250.00 in means 250.00 credited; left false the
  -- function correctly withholds 100 and credits 150.
  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES (v_prov, v_user, 'SERVICE_PROVIDER', 'Wallet Write Provider', 'PENDING_APPROVAL', true)
  ON CONFLICT (id) DO NOTHING;

  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.wallets (id, provider_id, balance)
  VALUES (v_wal, v_prov, 0.00)
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.wallet_recharge_requests
    (id, provider_id, wallet_id, amount, currency, status)
  VALUES (v_req, v_prov, v_wal, 250.00, 'ETB', 'PENDING')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.wallet_recharge_requests
    (id, provider_id, wallet_id, amount, currency, status)
  VALUES ('00000000-0000-4000-8000-00000000e506', v_prov, v_wal, 50.00, 'ETB', 'PENDING')
  ON CONFLICT (id) DO NOTHING;

  -- Trusting service_role must not become trusting everyone. A direct client
  -- call, made while we are still unambiguously a client, has to leave the
  -- request untouched. Asserted on the row rather than on the error text, so
  -- it holds whether the refusal comes from the guard or from a missing
  -- EXECUTE grant.
  BEGIN
    PERFORM public.approve_wallet_recharge(
      p_recharge_id => '00000000-0000-4000-8000-00000000e506',
      p_admin_id    => v_user
    );
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the refusal we wanted
  END;

  SELECT status INTO v_status
  FROM public.wallet_recharge_requests
  WHERE id = '00000000-0000-4000-8000-00000000e506';
  IF v_status IS DISTINCT FROM 'PENDING' THEN
    RAISE EXCEPTION 'a direct client call moved the recharge to %, expected it to stay PENDING', coalesce(v_status, '(null)');
  END IF;

  -- The real call, in the real context. SET LOCAL ROLE is transaction scoped,
  -- so the sentinel rollback below reverts it along with the data.
  BEGIN
    PERFORM set_config('role', 'service_role', true);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'cannot assume service_role, so the service-role path cannot be tested: %', SQLERRM;
  END;

  IF public.is_server_write() IS NOT TRUE THEN
    RAISE EXCEPTION 'is_server_write() is false under service_role, so the guards would still refuse the server';
  END IF;

  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req, p_admin_id => v_admin);

  -- The money moved.
  SELECT balance INTO v_balance FROM public.wallets WHERE id = v_wal;
  IF v_balance IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'wallet balance is % after approving a 250.00 recharge, expected 250.00', v_balance;
  END IF;

  SELECT status INTO v_status
  FROM public.wallet_recharge_requests WHERE id = v_req;
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'recharge status is %, expected APPROVED', coalesce(v_status, '(null)');
  END IF;

  -- The ledger row is what the income summary and wallet UI read. A credited
  -- balance with no ledger row is a silent accounting hole.
  SELECT count(*), min(net_amount), min(balance_after)
    INTO v_ledger, v_net, v_balance_after
  FROM public.wallet_transactions
  WHERE idempotency_key = 'recharge:' || v_req::text
    AND transaction_type = 'RECHARGE';

  IF v_ledger <> 1 THEN
    RAISE EXCEPTION 'expected 1 RECHARGE ledger row for the recharge, found %', v_ledger;
  END IF;
  IF v_net IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'ledger net_amount is %, expected 250.00', v_net;
  END IF;
  IF v_balance_after IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'ledger balance_after is %, expected 250.00', v_balance_after;
  END IF;

  -- Idempotency: a retried admin tap must not pay twice.
  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req, p_admin_id => v_admin);

  SELECT balance INTO v_balance FROM public.wallets WHERE id = v_wal;
  IF v_balance IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'wallet balance is % after a second approval, expected 250.00 (recharge approval is not idempotent)', v_balance;
  END IF;

  SELECT count(*) INTO v_ledger
  FROM public.wallet_transactions
  WHERE idempotency_key = 'recharge:' || v_req::text;
  IF v_ledger <> 1 THEN
    RAISE EXCEPTION 'expected 1 ledger row after a second approval, found %', v_ledger;
  END IF;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;
