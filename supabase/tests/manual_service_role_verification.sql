-- Manual verification of the REAL service_role call path.
--
-- Run this once in the Supabase SQL editor (Dashboard -> SQL Editor -> New
-- query -> paste -> Run). It is not applied by any migration and is not run
-- by CI. It exists because that path cannot be reached any other way:
--
--   * The connectivity suite calls the RPCs with the anon key, so
--     auth.uid() is NULL and the request is a client. It proves the
--     money-movement logic with real triggers attached.
--   * It cannot promote itself to service_role, because the anon key has no
--     membership in that role -- correctly so.
--   * A SECURITY DEFINER function cannot SET ROLE at all; PostgreSQL blocks
--     it so a SECURITY DEFINER cannot escalate itself.
--   * Putting SUPABASE_SERVICE_ROLE_KEY in CI would work, but widens the
--     blast radius of every workflow run to buy one path, and this repo has
--     already been bitten by exactly this class: see the header of
--     20260925190000_staff_delete_actor_param.sql.
--
-- The SQL editor connects as postgres directly, outside any SECURITY DEFINER
-- context, so SET LOCAL ROLE service_role works here and nowhere else.
--
-- This reproduces precisely what admin-wallet-recharge and order-create do:
-- build a service-role client, call the RPC with a p_admin_id the edge
-- function has already verified, and nothing else.
--
-- SAFETY
-- ------
-- The whole thing runs inside BEGIN ... ROLLBACK, so nothing it creates can
-- survive, even if it fails partway. Nothing here touches real data: every
-- row uses a fixed synthetic id in a reserved-looking range, and the only
-- pre-existing rows it reads are its own.
--
-- Look for: 'SERVICE ROLE PATH OK' and 'SERVICE ROLE PATH FAILED: <reason>'.
-- A failure prints the reason; the ROLLBACK still runs.

BEGIN;

DO $verify$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_admin uuid := '00000000-0000-4000-8000-00000000f001';
  v_plain uuid := '00000000-0000-4000-8000-00000000f002';
  v_prov  uuid := '00000000-0000-4000-8000-00000000f003';
  v_wal   uuid := '00000000-0000-4000-8000-00000000f004';
  v_req   uuid := '00000000-0000-4000-8000-00000000f005';
  v_prod  uuid := '00000000-0000-4000-8000-00000000f006';
  v_other uuid := '00000000-0000-4000-8000-00000000f007';
  v_balance numeric;
  v_status text;
  v_ledger int;
  v_order jsonb;
  v_row record;
BEGIN
  -- ------------------------------------------------------------------
  -- Fixtures, created as postgres.
  -- ------------------------------------------------------------------
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'svcrole-verify-admin@example.invalid', now()),
         (v_plain, 'svcrole-verify-user@example.invalid',  now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_admin, 'SvcRole Verify Admin', 'PENDING_APPROVAL'),
         (v_plain, 'SvcRole Verify User',  'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES (v_prov,  v_plain, 'SERVICE_PROVIDER', 'SvcRole Verify Provider', 'APPROVED', true),
         (v_other, v_plain, 'SERVICE_PROVIDER', 'SvcRole Verify Other',   'APPROVED', true)
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

  INSERT INTO public.products (id, provider_id, name, price, currency,
                               is_active, is_available, listing_status, stock_quantity)
  VALUES (v_prod, v_prov, 'SvcRole Verify Product', 10.00, 'ETB',
          true, true, 'ACTIVE', 100)
  ON CONFLICT (id) DO NOTHING;

  -- ------------------------------------------------------------------
  -- Become service_role, exactly as PostgREST does for an edge function.
  -- ------------------------------------------------------------------
  PERFORM set_config('role', 'service_role', true);

  IF public.is_server_write() IS NOT TRUE THEN
    RAISE EXCEPTION 'is_server_write() is false under service_role -- the guards would still refuse the server';
  END IF;
  RAISE NOTICE 'is_server_write() is true under service_role: OK';

  -- The auth.uid() this is working around, stated explicitly.
  IF auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'auth.uid() is %, expected NULL under service_role', auth.uid();
  END IF;
  RAISE NOTICE 'auth.uid() is NULL under service_role, as the edge function sees it: OK';

  -- ------------------------------------------------------------------
  -- 1. Wallet crediting through the real RPC.
  -- ------------------------------------------------------------------
  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req, p_admin_id => v_admin);

  SELECT balance INTO v_balance FROM public.wallets WHERE id = v_wal;
  IF v_balance IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'wallet balance is %, expected 250.00', v_balance;
  END IF;

  SELECT status INTO v_status FROM public.wallet_recharge_requests WHERE id = v_req;
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    RAISE EXCEPTION 'recharge status is %, expected APPROVED', coalesce(v_status, '(null)');
  END IF;

  SELECT count(*) INTO v_ledger
  FROM public.wallet_transactions
  WHERE idempotency_key = 'recharge:' || v_req::text AND transaction_type = 'RECHARGE';
  IF v_ledger <> 1 THEN
    RAISE EXCEPTION 'expected 1 RECHARGE ledger row, found %', v_ledger;
  END IF;

  RAISE NOTICE 'approve_wallet_recharge credited 250.00 and wrote the ledger row under service_role: OK';

  -- Idempotency: a retried admin tap must not pay twice.
  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req, p_admin_id => v_admin);
  SELECT balance INTO v_balance FROM public.wallets WHERE id = v_wal;
  IF v_balance IS DISTINCT FROM 250.00 THEN
    RAISE EXCEPTION 'balance is % after a second approval, expected 250.00', v_balance;
  END IF;
  RAISE NOTICE 'a second approval did not pay twice: OK';

  -- ------------------------------------------------------------------
  -- 2. Order creation through the real RPC.
  -- ------------------------------------------------------------------
  v_order := public.create_order_secure(
    p_user_id          => v_plain,
    p_provider_id      => v_other,
    p_items            => jsonb_build_array(
                           jsonb_build_object('product_id', v_prod,
                                              'quantity', 2, 'unit_price', 10.00)),
    p_total_amount     => 20.00,
    p_currency         => 'ETB',
    p_fulfillment_mode => 'DELIVERY',
    p_delivery_address => 'SvcRole Verify Address',
    p_city             => 'Addis Ababa'
  );

  IF v_order IS NULL THEN
    RAISE EXCEPTION 'create_order_secure returned null';
  END IF;

  SELECT o.status INTO v_row FROM public.orders o WHERE o.id = (v_order->>'id')::uuid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_order_secure did not persist an order row';
  END IF;
  IF v_row.status <> 'PENDING_PROVIDER' THEN
    RAISE EXCEPTION 'order created in status %, expected PENDING_PROVIDER', v_row.status;
  END IF;
  RAISE NOTICE 'create_order_secure created a PENDING_PROVIDER order under service_role: OK';

  RAISE NOTICE 'SERVICE ROLE PATH OK -- both RPCs work the way the edge functions call them.';

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN;
    END IF;
    RAISE NOTICE 'SERVICE ROLE PATH FAILED: %', SQLERRM;
    RAISE;
END;
$verify$;

RESET ROLE;
ROLLBACK;
