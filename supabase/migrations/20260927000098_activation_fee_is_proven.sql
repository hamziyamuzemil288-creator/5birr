-- 20260927000098 — prove the activation fee reaches the ledger, and stop the
-- income assertions passing on an empty wallet table
--
-- THE TWO GAPS THIS CLOSES
-- ------------------------
-- 1. THE ACTIVATION FEE WAS NEVER PROVEN AT ALL.
--
-- The only test that drives a real recharge end to end is
-- assert_wallet_crediting_writes() (20260927000025). Its fixture sets
-- registration_fee_paid = true on purpose, and says so: "left false the
-- function correctly withholds 100 and credits 150" -- which would "make this
-- assertion wrong for the wrong reason". Choosing to keep the arithmetic simple
-- was the right call for that test and it left the withholding branch untested.
--
-- That branch is the one the admin income bug lived on. The activation fee is
-- NOT a TRANSACTION_FEE and NOT a SUBSCRIPTION_FEE: approve_wallet_recharge
-- withholds it from the provider's FIRST approved recharge and records it as
-- platform_fee on a RECHARGE row (gross = amount paid, platform_fee = fee
-- withheld, net = amount credited). Every later recharge writes platform_fee =
-- 0. So a reader that sums platform_fee while filtering on TRANSACTION_FEE and
-- SUBSCRIPTION_FEE sees nothing at all on a deployment whose providers are
-- still activating, and renders a confident ETB 0.00 with no error and no empty
-- state. That is exactly what admin_income_summary_screen.dart and
-- admin_dashboard.dart did.
--
-- assert_activation_fee_writes_income() below drives the real function through
-- the real admin path and asserts the withheld fee lands on the RECHARGE row as
-- platform_fee, that activation is recorded on the provider, and that a second
-- recharge withholds nothing. The whole thing runs inside a subtransaction that
-- is always rolled back, so it is non-vacuous on a brand-new deployment -- which
-- a read-only check of the same property can never be.
--
-- 2. THE MONEY ASSERTIONS PASS WHEN THERE IS NOTHING TO CHECK.
--
-- assert_recent_completed_rides_have_fees, assert_recent_started_orders_have_fees
-- and assert_recent_approved_recharges_credited are all existential negatives:
-- "there is no recent X lacking a Y". On a deployment where no X happened in the
-- last 7 days that is trivially true, so all three stay green while the entire
-- money path is dead. assert_income_ledger_consistent has the same shape one
-- level down: it compares each wallet's balance with the sum of that wallet's
-- COMPLETED net_amount, and with zero wallets it compares nothing.
--
-- The read-only half of the answer is a diagnostic that reports what it actually
-- measured instead of only that something was non-false:
-- assert_income_covers_every_fee_type() returns the row count and summed fee for
-- each of the three fee types, the activation-fee subset, how many providers are
-- activated, and whether the registration switch is on -- and says so plainly
-- when the ledger is empty, rather than reporting a green tick that means
-- nothing was examined. It fails on the two shapes that are wrong no matter what
-- the history is, and it reports (rather than fails) the cross-table join whose
-- benign causes cannot all be enumerated from here.
--
-- The write test is the half that cannot be vacuous. Together they are the
-- de-vacuuming: one proves the write path by writing, the other shows the live
-- figures instead of a boolean.

-- ===========================================================================
-- 1. The activation fee, proven by writing one
-- ===========================================================================
-- Modelled on assert_wallet_crediting_writes() in 20260927000025, which is the
-- version of that test that works: same fixture shape, same verified-admin JWT
-- context (the branch a real admin takes -- the server branch is asserted false
-- so the client guards are live during the call), same sentinel rollback, and
-- the user_roles ADMIN row that 24 lost and 25 restored. Fixture ids are e601-e606
-- so nothing collides with the e501-e506 set the other write test uses.
--
-- SECURITY DEFINER, VOLATILE: it writes, then throws the sentinel to unwind.
CREATE OR REPLACE FUNCTION public.assert_activation_fee_writes_income()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  -- Comfortably above any plausible registration fee, and computed from the
  -- setting rather than asserted as a literal, so changing the fee in the CEO
  -- console cannot make this test fail for the wrong reason.
  c_headroom constant numeric := 400.00;
  c_second  constant numeric := 200.00;
  v_admin uuid := '00000000-0000-4000-8000-00000000e601';
  v_plain uuid := '00000000-0000-4000-8000-00000000e602';
  v_prov  uuid := '00000000-0000-4000-8000-00000000e603';
  v_wal   uuid := '00000000-0000-4000-8000-00000000e604';
  v_req   uuid := '00000000-0000-4000-8000-00000000e605';
  v_req2  uuid := '00000000-0000-4000-8000-00000000e606';
  v_fee_on boolean;
  v_fee numeric;
  v_first_amount numeric;
  v_first_credit numeric;
  v_rows int;
  v_gross numeric;
  v_platform numeric;
  v_net numeric;
  v_after numeric;
  v_paid boolean;
BEGIN
  -- The expectation is read from the same two settings the function reads.
  -- Hardcoding 100 here would make this test wrong the first time a CEO changed
  -- the fee -- which is precisely the bug 20260927000073 fixed in the notice
  -- text, and it must not be reintroduced in the test.
  v_fee_on := coalesce(public.get_setting_bool('fee_enabled_registration'), true);
  v_fee := CASE
    WHEN v_fee_on
      THEN coalesce(public.get_setting_numeric('provider_registration_fee'), 100)
    ELSE 0
  END;
  v_first_amount := v_fee + c_headroom;
  v_first_credit := v_first_amount - v_fee;

  -- ----------------------------------------------------------------- fixtures
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_admin, 'activation-fee-admin@example.invalid',    now()),
         (v_plain, 'activation-fee-provider@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_admin, 'Activation Fee Admin',    'PENDING_APPROVAL'),
         (v_plain, 'Activation Fee Provider', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  -- The acting admin needs the ADMIN row: is_admin() is has_role('ADMIN')
  -- against auth.uid(), and approve_wallet_recharge refuses a caller that is
  -- not an admin. Also what lets the notification insert past
  -- prevent_notification_injection(), whose admin case 25 restored.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN'), (v_plain, 'USER')
  ON CONFLICT (user_id, role) DO NOTHING;

  BEGIN
    EXECUTE 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- registration_fee_paid = false. This is the whole point of the test: it is
  -- the state a genuinely new provider is in, and the state the existing wallet
  -- write test deliberately avoids.
  INSERT INTO public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  VALUES
    (v_prov, v_plain, 'SERVICE_PROVIDER', 'Activation Fee Provider', 'PENDING_APPROVAL', false)
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
  VALUES (v_req,  v_prov, v_wal, v_first_amount, 'ETB', 'PENDING'),
         (v_req2, v_prov, v_wal, c_second,       'ETB', 'PENDING')
  ON CONFLICT (id) DO NOTHING;

  -- --------------------------------------------------- act as a verified admin
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text, 'role', 'authenticated')::text, true);

  -- Guard against the test passing by taking the server branch: as an
  -- authenticated client this must be false, so the client guards — the
  -- permission check this test exists to exercise — are live.
  IF public.is_server_write() THEN
    RAISE EXCEPTION 'is_server_write() is true for an authenticated client, so the client guards would be skipped and this test would prove nothing';
  END IF;

  -- --------------------------------------------------------- the first recharge
  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req, p_admin_id => v_admin);

  SELECT count(*), max(gross_amount), max(platform_fee), max(net_amount),
         max(balance_after)
    INTO v_rows, v_gross, v_platform, v_net, v_after
  FROM public.wallet_transactions
  WHERE idempotency_key = 'recharge:' || v_req::text
    AND transaction_type = 'RECHARGE';

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'expected 1 RECHARGE ledger row for a provider''s first approved recharge, found %', v_rows;
  END IF;
  IF v_gross IS DISTINCT FROM v_first_amount THEN
    RAISE EXCEPTION 'ledger gross_amount is %, expected the % the provider actually paid', coalesce(v_gross::text, '(null)'), v_first_amount;
  END IF;
  IF v_platform IS DISTINCT FROM v_fee THEN
    RAISE EXCEPTION 'the first approved recharge recorded platform_fee = % while the registration switch is %, expected %. The activation fee is stored as platform_fee on a RECHARGE row: a reader that filters on TRANSACTION_FEE and SUBSCRIPTION_FEE cannot see it, which is how admin income rendered 0.00 while money had been collected.',
      coalesce(v_platform::text, '(null)'),
      CASE WHEN v_fee_on THEN 'on' ELSE 'off' END, v_fee;
  END IF;
  IF v_net IS DISTINCT FROM v_first_credit THEN
    RAISE EXCEPTION 'ledger net_amount is %, expected % (% paid minus the % registration fee)', coalesce(v_net::text, '(null)'), v_first_credit, v_first_amount, v_fee;
  END IF;
  IF v_after IS DISTINCT FROM v_first_credit THEN
    RAISE EXCEPTION 'ledger balance_after is %, expected % on a wallet that started at 0', coalesce(v_after::text, '(null)'), v_first_credit;
  END IF;

  -- The withholding has to activate the provider too, or the test would pass
  -- while the fee was taken from somebody who never got an account.
  SELECT registration_fee_paid INTO v_paid
    FROM public.provider_profiles WHERE id = v_prov;
  IF v_paid IS NOT TRUE THEN
    RAISE EXCEPTION 'the first approved recharge did not set registration_fee_paid, so the activation fee was withheld without activating the provider';
  END IF;

  -- -------------------------------------------------------- the second recharge
  -- One-time means one-time: now that registration_fee_paid is true the function
  -- must credit the full amount and record no fee.
  PERFORM public.approve_wallet_recharge(p_recharge_id => v_req2, p_admin_id => v_admin);

  SELECT count(*), max(platform_fee), max(net_amount)
    INTO v_rows, v_platform, v_net
  FROM public.wallet_transactions
  WHERE idempotency_key = 'recharge:' || v_req2::text
    AND transaction_type = 'RECHARGE';

  IF v_rows <> 1 THEN
    RAISE EXCEPTION 'expected 1 RECHARGE ledger row for a second approved recharge, found %', v_rows;
  END IF;
  IF v_platform IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'a second approved recharge recorded platform_fee = %, expected 0 (the activation fee is one-time)', coalesce(v_platform::text, '(null)');
  END IF;
  IF v_net IS DISTINCT FROM c_second THEN
    RAISE EXCEPTION 'a second approved recharge credited %, expected the full %', coalesce(v_net::text, '(null)'), c_second;
  END IF;

  -- Everything held. Unwind.
  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    -- A genuine failure re-raises with its own error rather than being
    -- swallowed into a false pass.
    RAISE;
END;
$$;

COMMENT ON FUNCTION public.assert_activation_fee_writes_income() IS
  'Drives approve_wallet_recharge through the real verified-admin path for a '
  'provider whose registration_fee_paid is false -- the withholding branch the '
  'existing wallet write test deliberately skips -- inside a subtransaction that '
  'is always rolled back. Asserts the activation fee is recorded as platform_fee '
  'on a RECHARGE row with the right gross, net and balance_after, that the '
  'provider is activated, and that a second recharge withholds nothing. The '
  'expectation is read from provider_registration_fee and '
  'fee_enabled_registration, so it stays correct when either changes. Leaves no '
  'data behind.';

REVOKE ALL ON FUNCTION public.assert_activation_fee_writes_income()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_activation_fee_writes_income()
  TO anon, authenticated, service_role;

-- ===========================================================================
-- 2. What the income actually is, reported instead of merely non-false
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_income_covers_every_fee_type()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows bigint := 0;
  v_tx_rows bigint; v_tx_fee numeric;
  v_sub_rows bigint; v_sub_fee numeric;
  v_rc_rows bigint; v_rc_fee numeric;
  v_act_rows bigint; v_act_fee numeric;
  v_activated bigint;
  v_fee_on boolean;
  v_bad_arithmetic bigint;
  v_unrecorded bigint;
  v_orphan_activation bigint;
BEGIN
  SELECT count(*) INTO v_rows FROM public.wallet_transactions;

  SELECT count(*), coalesce(sum(platform_fee), 0)
    INTO v_tx_rows, v_tx_fee
    FROM public.wallet_transactions WHERE transaction_type = 'TRANSACTION_FEE';

  SELECT count(*), coalesce(sum(platform_fee), 0)
    INTO v_sub_rows, v_sub_fee
    FROM public.wallet_transactions WHERE transaction_type = 'SUBSCRIPTION_FEE';

  SELECT count(*), coalesce(sum(platform_fee), 0)
    INTO v_rc_rows, v_rc_fee
    FROM public.wallet_transactions WHERE transaction_type = 'RECHARGE';

  -- The activation fee specifically: money withheld from a first recharge and
  -- recorded as platform_fee on the RECHARGE row. This is the subset the two
  -- Dart income readers were blind to.
  SELECT count(*), coalesce(sum(platform_fee), 0)
    INTO v_act_rows, v_act_fee
    FROM public.wallet_transactions
   WHERE transaction_type = 'RECHARGE' AND platform_fee > 0;

  SELECT count(*) INTO v_activated
    FROM public.provider_profiles WHERE registration_fee_paid;

  v_fee_on := coalesce(public.get_setting_bool('fee_enabled_registration'), true);

  -- 1. A row's own arithmetic. gross_amount is what moved, net_amount is what
  --    was credited, platform_fee is what the platform kept: the fee cannot be
  --    negative and cannot exceed what was paid.
  SELECT count(*) INTO v_bad_arithmetic
    FROM public.wallet_transactions
   WHERE platform_fee < 0 OR platform_fee > gross_amount;

  -- 2. If less was credited than was paid, something was withheld -- and the
  --    withheld part IS the platform's income, so it has to be recorded as
  --    platform_fee. This is the exact shape of the bug, and it is unambiguous:
  --    both columns are written by the same INSERT, so no history can explain
  --    gross > net with platform_fee <= 0 on the same row.
  SELECT count(*) INTO v_unrecorded
    FROM public.wallet_transactions
   WHERE transaction_type = 'RECHARGE'
     AND gross_amount > net_amount
     AND platform_fee <= 0;

  -- 3. A withholding on a RECHARGE row can only come from the activation path,
  --    which also sets registration_fee_paid. Reported rather than failed: it
  --    is a cross-table join over history, and a provider row deleted or reset
  --    out of band would trip it without anything being wrong today.
  SELECT count(*) INTO v_orphan_activation
    FROM public.wallet_transactions t
    LEFT JOIN public.provider_profiles pp ON pp.id = t.provider_id
   WHERE t.transaction_type = 'RECHARGE'
     AND t.platform_fee > 0
     AND (pp.id IS NULL OR NOT pp.registration_fee_paid);

  -- A check that examined nothing must never report success. Two of the three
  -- shapes above are safe to fail on; the empty-ledger case is not wrong, but it
  -- must SAY that it saw nothing rather than returning a bare tick.
  IF v_bad_arithmetic > 0 THEN
    RETURN 'FAIL: ' || v_bad_arithmetic::text
      || ' wallet_transactions row(s) keep more as platform_fee than the gross '
      || 'amount, or keep a negative fee, so the ledger''s own arithmetic is '
      || 'inconsistent and every income figure built from it is wrong';
  END IF;

  IF v_unrecorded > 0 THEN
    RETURN 'FAIL: ' || v_unrecorded::text
      || ' RECHARGE row(s) credited less than the provider paid without '
      || 'recording the difference as platform_fee. The withheld amount is the '
      || 'activation fee and it is income: written anywhere other than '
      || 'platform_fee it is invisible to every income reader, which is how the '
      || 'admin income summary rendered ETB 0.00 while money had been collected';
  END IF;

  RETURN 'ok: income sources -- TRANSACTION_FEE rows=' || v_tx_rows::text
    || ' whose platform_fee sums to ' || v_tx_fee::text
    || '; SUBSCRIPTION_FEE rows=' || v_sub_rows::text
    || ' whose platform_fee sums to ' || v_sub_fee::text
    || '; RECHARGE rows=' || v_rc_rows::text
    || ' whose platform_fee sums to ' || v_rc_fee::text
    || ' (' || v_act_rows::text
    || ' of them carried a withheld activation fee, summing to '
    || v_act_fee::text || ')'
    || '; providers activated=' || v_activated::text
    || ' (registration fee switch '
    || CASE WHEN v_fee_on THEN 'on' ELSE 'off' END || ')'
    || '; RECHARGE rows carrying a fee with no activated provider='
    || v_orphan_activation::text || ' [reported, not failed]'
    || '; ' || v_rows::text || ' ledger row(s) examined'
    || CASE
         WHEN v_rows = 0 THEN
           ', so no fee path has been exercised on this deployment yet and this '
           || 'assertion is reporting success without evidence'
         ELSE ''
       END;
END;
$$;

COMMENT ON FUNCTION public.assert_income_covers_every_fee_type() IS
  'Reports the live income picture rather than a bare boolean: the row count and '
  'summed platform_fee for each of TRANSACTION_FEE, SUBSCRIPTION_FEE and '
  'RECHARGE, the activation-fee subset of the RECHARGE rows, how many providers '
  'are activated, and whether the registration switch is on. Fails on the two '
  'shapes that are wrong regardless of history -- a fee exceeding the gross, and '
  'a recharge that withheld money without recording it as platform_fee -- and '
  'says so explicitly when the ledger is empty instead of returning a tick that '
  'examined nothing. The RECHARGE-fee-without-an-activated-provider count is '
  'reported, not failed. Replaces the existential-negative shape that stayed '
  'green while the whole money path was dead.';

REVOKE ALL ON FUNCTION public.assert_income_covers_every_fee_type()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_income_covers_every_fee_type()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
