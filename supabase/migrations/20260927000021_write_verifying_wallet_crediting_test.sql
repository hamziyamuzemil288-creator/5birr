-- Prove wallet crediting works, by actually crediting a wallet.
--
-- Why this test exists
-- --------------------
-- assert_recent_approved_recharges_credited cannot answer the question. It
-- asks whether there is no approved recharge from the last 7 days lacking a
-- ledger row. When nothing has been approved in a week that is trivially
-- true, so it passes while the feature is completely dead -- which is exactly
-- what happened: approve_wallet_recharge raised INSUFFICIENT_PERMISSION on
-- every call for as long as it has existed, and that test stayed green.
--
-- A vacuous pass is worse than no test, because it reports safety. So this one
-- writes.
--
-- How it writes
-- -------------
-- The interesting half of the bug is that the failure only appears under
-- service_role: auth.uid() is NULL there and normal everywhere else. A test
-- that simply called the function as itself would have passed against the
-- broken code, which is the same mistake in a new place. So the test
-- reproduces the Edge Function's exact context with
--
--   set_config('role', 'service_role', true)
--
-- and only then calls approve_wallet_recharge, passing an admin id the way
-- admin-wallet-recharge does after its own requireRole(ADMIN) check. Against
-- the unfixed function this raises INSUFFICIENT_PERMISSION immediately; there
-- is no way for it to pass without the real path working.
--
-- It then checks the money actually moved -- balance, request status, and the
-- ledger row the income summary and wallet UI read -- and that a second
-- approval of the same request does not pay twice, since a retried admin tap
-- would otherwise credit the provider again.
--
-- The provider fixture has registration_fee_paid set, so the one-time
-- activation fee does not apply and 250.00 in means 250.00 credited. (Left
-- false, the function withholds 100 and credits 150, which is correct
-- behaviour and would make this assertion wrong for the wrong reason.)
--
-- Everything runs inside one subtransaction that is always rolled back by
-- raising a sentinel the handler recognises, so the rows are real while the
-- assertions run and gone afterwards. There is no cleanup step that can fail
-- and no residue. A genuine failure re-raises with its own error rather than
-- being swallowed. The provider INSERT guard is disabled only for the fixture
-- row and restored immediately; both wallet triggers stay attached throughout,
-- because the wallet UPDATE under test is precisely what they guard.

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
  -- ---------------------------------------------------------------
  -- Fixtures.
  -- ---------------------------------------------------------------
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'wallet-write-admin@example.invalid', now()),
         (v_user,  'wallet-write-user@example.invalid',  now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_admin, 'Wallet Write Admin', 'APPROVED'),
         (v_user,  'Wallet Write User',  'APPROVED')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- The provider guard blocks a client-shaped insert; disabled only here,
  -- inside the subtransaction that is about to be rolled back anyway.
  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES (v_prov, v_user, 'SERVICE_PROVIDER', 'Wallet Write Provider', 'APPROVED', true)
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

  -- ---------------------------------------------------------------
  -- Trusting service_role must not become trusting everyone. A direct
  -- client call, made while we are still unambiguously a client, has to
  -- leave the request untouched. Asserted on the row rather than on the
  -- error text, so it holds whether the refusal comes from the guard or
  -- from a missing EXECUTE grant.
  -- ---------------------------------------------------------------
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

  -- ---------------------------------------------------------------
  -- The real call, in the real context.
  --
  -- SET LOCAL ROLE is transaction scoped, so the sentinel rollback below
  -- reverts it along with the data. If the role switch is not permitted in
  -- this environment the test says so plainly rather than passing quietly.
  -- ---------------------------------------------------------------
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

COMMENT ON FUNCTION public.assert_wallet_crediting_writes() IS
  'Approves a real recharge through the actual service_role call path used by '
  'the admin-wallet-recharge Edge Function, inside a subtransaction that is '
  'always rolled back. Asserts the balance moved, the request is APPROVED, '
  'exactly one RECHARGE ledger row exists with the right amounts, a second '
  'approval does not pay twice, and a direct client call is still refused. '
  'Leaves no data behind.';

GRANT EXECUTE ON FUNCTION public.assert_wallet_crediting_writes() TO anon, authenticated;
