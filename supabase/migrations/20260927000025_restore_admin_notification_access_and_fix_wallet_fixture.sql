-- Restore admin notification access, and fix the wallet test's missing role.
--
-- The regression
-- -------------
-- prevent_notification_injection, as it was in 0022c:
--
--   IF NOT is_admin() AND NOT current_setting('role', true) = 'service_role'
--      THEN RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
--
-- Two ways in: the server, or a verified admin. The admin half is load
-- bearing. Two RPCs the app calls DIRECTLY, with the signed-in admin's own
-- JWT rather than through an Edge Function:
--
--   lib/features/admin/admin_cash_recharge_screen.dart:54  admin_cash_recharge
--   lib/features/admin/admin_cash_recharge_screen.dart:97  admin_wallet_adjustment
--
-- Both write an audit notification from inside the RPC (4 and 3 inserts
-- respectively). Running as the admin's own JWT, the server half is false and
-- the admin half is what let them through.
--
-- 20260927000016 replaced that condition with a session_user whitelist, and
-- 20260927000019 replaced the whitelist with is_server_write(). Neither
-- restored is_admin(). The guard therefore became:
--
--   IF is_server_write() THEN RETURN new; END IF;
--   RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
--
-- which refuses every notification that is not server-initiated -- including
-- a legitimate one written by a real admin acting through a real admin
-- screen. Both of those money screens have been failing with
-- NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS ever since, which is the same
-- class of failure as the recharge and provider-approval bugs this migration
-- series set out to fix, and in this case self-inflicted.
--
-- Why the server half alone was not enough
-- ---------------------------------------
-- 00016/00019 were not wrong to want server writes exempted -- pg_cron and
-- the edge functions genuinely need that, and without it the daily
-- subscription run aborts. They were wrong to treat "is this the server?" as
-- the only question. A client-write guard on a table the server also writes
-- has to distinguish three callers, not two: the server, a verified
-- privileged client, and everyone else. Answering only the first turns a
-- working admin screen into a broken one.
--
-- The fix restores the privileged-client case explicitly rather than
-- dropping the guard. An ordinary signed-in user still cannot create a
-- notification: is_admin() is has_role('ADMIN') against auth.uid(), and for a
-- non-admin it is false, so the raise still fires. That behaviour is asserted
-- by assert_client_guards_are_server_safe, which requires the raise to remain.
--
-- The wallet test fixture
-- -----------------------
-- assert_wallet_crediting_writes lost a line in 20260927000024: the
-- user_roles row granting ADMIN to the acting admin. Only the non-admin
-- fixture user was inserted, so is_admin() was false for the "admin" and
-- approve_wallet_recharge correctly refused with INSUFFICIENT_PERMISSION --
-- the guard working, the fixture wrong. Re-emitted here with the role row
-- restored, and with the notification allowance above it can now complete.
--
-- The order write test is not touched: it passes, and it never writes a
-- notification.

CREATE OR REPLACE FUNCTION public.prevent_notification_injection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- The server: Edge Functions calling as service_role, and pg_cron.
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  -- A verified admin acting directly. admin_cash_recharge and
  -- admin_wallet_adjustment are called from the app with the admin's own JWT
  -- and write their audit notification from inside the RPC, so this case is
  -- required for those screens to work at all.
  IF public.is_admin() THEN
    RETURN new;
  END IF;

  -- Everyone else. is_admin() is has_role('ADMIN') against auth.uid(), so an
  -- ordinary signed-in user still lands here.
  RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
END;
$$;

COMMENT ON FUNCTION public.prevent_notification_injection() IS
  'Notifications are written by the server and by verified admins, never by an '
  'ordinary client. The is_admin() case is not optional: admin_cash_recharge '
  'and admin_wallet_adjustment are called from the app with the admin''s own '
  'JWT and write their audit notification from inside the RPC. Dropping it '
  'broke both screens.';

-- ---------------------------------------------------------------------------
-- Wallet crediting, driven as a verified admin (fixture corrected)
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

  -- The acting admin, and a non-admin used below to prove the refusal holds.
  -- The ADMIN row is what makes is_admin() true and admin_can() pass, so it
  -- is required: without it approve_wallet_recharge refuses with
  -- INSUFFICIENT_PERMISSION, correctly.
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN'),
         (v_plain, 'USER')
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
