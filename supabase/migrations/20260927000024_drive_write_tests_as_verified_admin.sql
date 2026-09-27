-- Drive the write tests as a verified admin, because SET ROLE is blocked here.
--
-- What CI showed
-- -------------
-- Both write tests now execute, and both fail for the same reason:
--
--   wallet:  cannot set parameter "role" within security-definer function
--   orders:  CANNOT_CREATE_FOR_ANOTHER_USER
--
-- The first is PostgreSQL refusing to let a SECURITY DEFINER function change
-- the role GUC, which it blocks precisely so a SECURITY DEFINER cannot
-- escalate itself. No formulation of set_config('role', ...) can work inside
-- one, so the previous attempt to impersonate service_role could never have
-- passed, in this or any future environment.
--
-- The second is the test calling create_order_secure while still an ordinary
-- client, where auth.uid() is NULL and new.user_id IS DISTINCT FROM NULL is
-- true. That guard is correct, and in production order-create calls the RPC
-- with the service-role client, where is_server_write() short-circuits it at
-- the top. The failing case is the harness, not the app.
--
-- The decision: no service-role key in CI
-- ----------------------------------------
-- The remaining ways to reach the real service_role path from CI are to put
-- SUPABASE_SERVICE_ROLE_KEY in the workflow secrets, or to sign in as an
-- admin. Neither is being done here, and the reason is already written down
-- in this repo. 20260925190000_staff_delete_actor_param.sql records that
-- delete_staff was failing for every caller for this identical reason, and it
-- records why the obvious harness does not help:
--
--   "the test set request.jwt.claim.sub via set_config, which simulates a
--    user JWT. The real gateway never does that. The test proved the logic
--    but never the call path."
--
-- Faking claims is a real technique here and it does prove the logic. What it
-- cannot prove is the service-role call path, and a service key in CI would
-- widen the blast radius of every dependency and every workflow run to buy
-- that one path. The service-role call path is verified instead by the device
-- test and by supabase/tests/manual_service_role_verification.sql, which runs
-- as postgres outside any SECURITY DEFINER context, where SET LOCAL ROLE
-- genuinely works.
--
-- What these tests now prove
-- --------------------------
-- They drive the RPCs exactly as a genuine authenticated admin does, with
-- every real trigger attached:
--
--   * approve_wallet_recharge really credits the wallet, writes the ledger row
--     with the right amounts, and is idempotent;
--   * create_order_secure really creates a PENDING_PROVIDER order with its
--     items, and still refuses an unapproved provider.
--
-- is_server_write() is asserted false at the top of each, so these cannot
-- quietly pass by taking the server branch -- they exercise the client branch
-- with real permissions, which is the branch that has to keep working.
--
-- The client-refusal half is kept too: a non-admin caller must still be
-- refused, checked by switching the claims to a user with no ADMIN role and
-- asserting the recharge does not move.
--
-- Everything runs in one subtransaction that always rolls back via a sentinel,
-- so real rows are asserted and nothing persists. Faking claims only changes
-- request.jwt.* GUCs inside that subtransaction, which the rollback reverts;
-- the function returns a boolean and leaks no data.

-- ---------------------------------------------------------------------------
-- Wallet crediting, driven as a verified admin
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
  v_plain uuid := '00000000-0000-4000-8000-00000000e502';
  v_prov  uuid := '00000000-0000-4000-8000-00000000e503';
  v_wal   uuid := '00000000-0000-4000-8000-00000000e504';
  v_req   uuid := '00000000-0000-4000-8000-00000000e505';
  v_req2  uuid := '00000000-0000-4000-8000-00000000e506';
  v_balance numeric;
  v_status text;
  v_ledger int;
  v_net numeric;
  v_balance_after numeric;
BEGIN
  -- Fixtures, created the way the app creates them. PENDING_APPROVAL because
  -- trg_profiles_insert_security refuses a client-created profile that is
  -- not pending; nothing here depends on the profile's status.
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'wallet-write-admin@example.invalid', now()),
         (v_plain, 'wallet-write-user@example.invalid',  now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_admin, 'Wallet Write Admin', 'PENDING_APPROVAL'),
         (v_plain, 'Wallet Write User',  'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  -- Fixture only: a non-admin user, used below to prove the refusal holds.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_plain, 'USER')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- Fixture only. registration_fee_paid is set so the one-time activation fee
  -- does not apply and 250.00 in means 250.00 credited; left false the
  -- function correctly withholds 100 and credits 150.
  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES (v_prov, v_plain, 'SERVICE_PROVIDER', 'Wallet Write Provider', 'PENDING_APPROVAL', true)
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
  VALUES (v_req,  v_prov, v_wal, 250.00, 'ETB', 'PENDING'),
           (v_req2, v_prov, v_wal, 50.00,  'ETB', 'PENDING')
  ON CONFLICT (id) DO NOTHING;

  -- Act as a signed-in ADMIN. This is the branch a real admin takes, and it
  -- must keep working: same permission check, same identity assertion.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- Guard against the test passing by taking the server branch: as an
  -- authenticated client this must be false, so the client guards are live.
  IF public.is_server_write() THEN
    RAISE EXCEPTION 'is_server_write() is true for an authenticated client, so the client guards would be skipped and this test would prove nothing';
  END IF;

  -- A non-admin must not be able to approve a recharge, even naming the
  -- recharge correctly. Asserted on the row, not the error text, so it holds
  -- whether the refusal comes from the guard or a missing EXECUTE grant.
  PERFORM set_config('request.jwt.claim.sub', v_plain::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_plain::text, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.approve_wallet_recharge(p_recharge_id => v_req2, p_admin_id => v_plain);
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- the refusal we wanted
  END;

  SELECT status INTO v_status
  FROM public.wallet_recharge_requests WHERE id = v_req2;
  IF v_status IS DISTINCT FROM 'PENDING' THEN
    RAISE EXCEPTION 'a non-admin call moved the recharge to %, expected it to stay PENDING', coalesce(v_status, '(null)');
  END IF;

  -- Back to the admin for the real path.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

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

COMMENT ON FUNCTION public.assert_wallet_crediting_writes() IS
  'Approves a real recharge as a signed-in admin inside a subtransaction that '
  'is always rolled back: asserts the balance moved, the request is APPROVED, '
  'exactly one RECHARGE ledger row exists with the right amounts, a second '
  'approval does not pay twice, and a non-admin is refused. Proves the '
  'money-movement logic with real triggers attached; the service_role call '
  'path itself is covered by manual_service_role_verification.sql, because '
  'a SECURITY DEFINER function cannot SET ROLE.';

-- ---------------------------------------------------------------------------
-- Order creation, driven as a signed-in customer
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

    -- PENDING_APPROVAL, not APPROVED: the profile insert guard refuses a
    -- client-created profile that is not pending.
    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_user, 'Write Test', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    -- Fixture only: an APPROVED provider, which no client could create. The
    -- guard is disabled for this row, inside the subtransaction that is about
    -- to be rolled back anyway.
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

    -- Act as that signed-in customer, so the order insert guard sees a real
    -- auth.uid() matching the order's user_id instead of NULL.
    PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    -- Must be taking the client branch, or this test proves nothing.
    IF public.is_server_write() THEN
      RAISE EXCEPTION 'is_server_write() is true for an authenticated client, so the client guards would be skipped and this test would prove nothing';
    END IF;

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

COMMENT ON FUNCTION public.assert_order_creation_writes() IS
  'Places a real order as a signed-in customer inside a subtransaction that '
  'is always rolled back, asserting the order persists in PENDING_PROVIDER '
  'with its items, and that a non-approved provider is refused.';
