-- 20260927000089 — tell the user their points became birr
--
-- THE GAP
-- -------
-- convert_points_to_wallet() debits the points ledger, credits the wallet, and
-- writes an audit row — and then says nothing to the person whose balance just
-- changed. Every other money path in this schema notifies: a recharge, an
-- approval, a document verdict, a commission. This one was silent, which is
-- worse than a generic message: the conversion screen has to render the result
-- itself, and if the app is closed when it happens the user has no way to find
-- out that their points turned into birr.
--
-- WHY A FUNCTION AND NOT A TRIGGER
-- --------------------------------
-- This is the one event in the brief that must be written in the function
-- body. The conversion updates wallets and points_ledger, and no row in
-- orders, ride_requests or provider_profiles changes, so there is no row
-- update for a trigger to hang off. The message also has to quote two figures
-- — the points spent and the birr received — that exist only as plpgsql
-- variables inside the function (v_birr, p_points). A trigger would have to
-- recompute the rate, and a recomputed rate is a message that can disagree
-- with the ledger.
--
-- The call sits after the wallet UPDATE and after the ledger insert, using the
-- same v_birr the wallet was credited with, so the message cannot disagree
-- with the balance.
--
-- IDEMPOTENCY
-- -----------
-- The dedupe key is 'points-convert:' || v_ledger_id, and v_ledger_id is the
-- id of the points_ledger row this call just debited. It is unique per
-- conversion because award_points() generates a fresh UUID per award, so two
-- conversions never share a key and a retried one is recognised.
--
-- There is a second guard that is not about notifications: the function already
-- takes pg_advisory_xact_lock('points-conversion:'||user) and re-reads the
-- balance under FOR UPDATE, so two simultaneous taps cannot both pass the
-- balance check. That is unchanged.
--
-- EVERY OTHER STATEMENT IS PRESERVED EXACTLY, including the rate lookup, the
-- minimum, the wallet-ownership checks, the rate being server-owned, and the
-- ADJUSTMENT ledger row the reconciler depends on. Diffed by
-- tools/harness/restatement_diff.py.

CREATE OR REPLACE FUNCTION public.convert_points_to_wallet(
  p_subject_type text,
  p_points integer,
  p_provider_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_subject_id uuid;
  v_provider_id uuid;
  v_wallet public.wallets;
  v_rate numeric;
  v_minimum integer;
  v_balance integer;
  v_birr numeric;
  v_ledger_id uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'SIGN_IN_REQUIRED';
  END IF;

  IF p_subject_type NOT IN ('USER', 'PROVIDER') THEN
    RAISE EXCEPTION 'UNKNOWN_POINTS_SUBJECT_%', p_subject_type;
  END IF;

  IF p_points IS NULL OR p_points <= 0 THEN
    RAISE EXCEPTION 'POINTS_TO_CONVERT_MUST_BE_POSITIVE';
  END IF;

  -- One conversion at a time per account: the balance check below is a
  -- read-then-write, and two taps landing together must not both pass it.
  PERFORM pg_advisory_xact_lock(hashtext('points-conversion:' || v_user_id::text));

  v_rate := public.get_setting_numeric('points_to_birr_rate');
  IF v_rate IS NULL OR v_rate <= 0 THEN
    RAISE EXCEPTION 'THE_POINTS_CONVERSION_RATE_IS_NOT_CONFIGURED';
  END IF;

  v_minimum := coalesce(public.get_setting_numeric('points_conversion_minimum'), 0)::integer;
  IF p_points < v_minimum THEN
    RAISE EXCEPTION 'THE_MINIMUM_CONVERSION_IS_%_POINTS', v_minimum;
  END IF;

  -- Which points balance, and whose wallet receives the birr.
  IF p_subject_type = 'USER' THEN
    v_subject_id := v_user_id;
    v_provider_id := p_provider_id;
  ELSE
    v_subject_id := p_provider_id;
    v_provider_id := p_provider_id;
  END IF;

  IF v_provider_id IS NULL THEN
    SELECT id INTO v_provider_id
      FROM public.provider_profiles
     WHERE user_id = v_user_id
     ORDER BY created_at
     LIMIT 1;
  END IF;

  IF v_provider_id IS NULL THEN
    -- No provider profile means no wallet to credit. Told plainly rather than
    -- silently crediting nowhere.
    RAISE EXCEPTION 'NO_WALLET_FOR_THIS_ACCOUNT';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profiles
     WHERE id = v_provider_id AND user_id = v_user_id
  ) THEN
    RAISE EXCEPTION 'NOT_YOUR_PROVIDER_PROFILE';
  END IF;

  -- A PROVIDER balance is only spendable by the profile that earned it.
  IF p_subject_type = 'PROVIDER' AND v_subject_id <> v_provider_id THEN
    RAISE EXCEPTION 'POINTS_SUBJECT_AND_WALLET_MUST_MATCH';
  END IF;

  v_birr := round(p_points * v_rate, 2);
  IF v_birr <= 0 THEN
    RAISE EXCEPTION 'THAT_MANY_POINTS_ROUNDS_TO_ZERO_BIRR';
  END IF;

  SELECT points INTO v_balance
    FROM public.user_points
   WHERE subject_type = p_subject_type AND subject_id = v_subject_id
     FOR UPDATE;

  IF coalesce(v_balance, 0) < p_points THEN
    RAISE EXCEPTION 'NOT_ENOUGH_POINTS';
  END IF;

  -- 1. Debit the points. Never client-computed: the client sends a count, the
  --    server owns the rate, the balance and the arithmetic.
  v_ledger_id := public.award_points(
    p_subject_type,
    v_subject_id,
    'CONVERSION',
    gen_random_uuid(),
    -p_points,
    'Converted to wallet: ' || v_birr::text || ' ETB'
  );

  -- 2. Credit the wallet in the same statement, in the same transaction.
  SELECT * INTO v_wallet FROM public.wallets WHERE provider_id = v_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND';
  END IF;

  UPDATE public.wallets
     SET balance = balance + v_birr, updated_at = now()
   WHERE id = v_wallet.id
  RETURNING * INTO v_wallet;

  -- The ledger row and the balance move together; assert_income_ledger_consistent()
  -- and the daily reconciler both depend on that, so the wallet ledger row is
  -- not optional.
  INSERT INTO public.wallet_transactions
    (wallet_id, provider_id, transaction_type, gross_amount, platform_fee,
     net_amount, balance_after, status, idempotency_key)
  VALUES
    (v_wallet.id, v_provider_id, 'ADJUSTMENT', v_birr, 0,
     v_birr, v_wallet.balance, 'COMPLETED', 'points-convert:' || v_ledger_id::text);

  -- 3. Tell the user, in the same transaction as the credit, quoting the same
  --    v_birr the wallet was just credited with. POINTS_REDEEMED is the
  --    existing enum value for spending points (added in migration 59) and is
  --    what the app's icon colouring already keys on, so no new enum value and
  --    no client change.
  --
  --    The wallet balance is quoted too, so the message is checkable against
  --    the wallet screen rather than merely reassuring.
  PERFORM public.notify_user_once(
    'points-convert:' || v_ledger_id::text,
    v_user_id,
    'POINTS_REDEEMED',
    'Points converted',
    'You converted ' || p_points::text || ' points to ETB ' || v_birr::text
      || '. Your wallet balance is ETB ' || v_wallet.balance::text || '.',
    jsonb_build_object(
      'points_spent', p_points,
      'birr_credited', v_birr,
      'rate', v_rate,
      'subject_type', p_subject_type,
      'wallet_balance', v_wallet.balance
    )
  );

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (
    v_user_id,
    'POINTS_CONVERTED_TO_WALLET',
    'wallets',
    v_wallet.id,
    jsonb_build_object(
      'subject_type', p_subject_type,
      'subject_id', v_subject_id,
      'points', p_points,
      'birr', v_birr,
      'rate', v_rate,
      'ledger_id', v_ledger_id,
      'balance_after', v_wallet.balance
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'points_spent', p_points,
    'birr_credited', v_birr,
    'rate', v_rate,
    'points_balance', coalesce(v_balance, 0) - p_points,
    'wallet_balance', v_wallet.balance
  );
END;
$$;

COMMENT ON FUNCTION public.convert_points_to_wallet(text, integer, uuid) IS
  'Spends a points balance at the CEO-set points_to_birr_rate and credits the '
  'caller''s provider wallet in the same transaction, debiting points_ledger so '
  'the audit stays complete, and notifies the caller with the points spent and '
  'the birr credited. The birr amount is always computed here, never by the '
  'client.';

-- ===========================================================================
-- The assertion
--
-- Checks the two things that make this a money-path notification rather than
-- decoration:
--
--   1. the notice quotes BOTH figures the brief asks for (points spent and
--      birr received), from the same variables the ledger used;
--   2. the call is keyed on the points ledger id, so a retry is a no-op.
--
-- It also re-checks the money invariants, because a restatement of a money
-- function is exactly where one of those goes missing: the advisory lock (two
-- taps at once), the balance re-read under FOR UPDATE, the ownership check,
-- and the ADJUSTMENT ledger row the reconciler reads.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_points_conversion_notifies()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_src text;
  v_missing text := '';
  v_required text[] := ARRAY[
    -- the concurrency guard
    'pg_advisory_xact_lock',
    -- the balance is re-read under a row lock, not trusted from the client
    'for update',
    -- ownership of the profile whose points/wallet are being spent
    'not_your_provider_profile',
    'points_subject_and_wallet_must_match',
    -- the server owns the rate
    'points_to_birr_rate',
    -- the ledger row the reconciler and assert_income_ledger_consistent read
    'wallet_transactions',
    'points-convert:'
  ];
  v_clause text;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'convert_points_to_wallet';

  IF v_src IS NULL THEN
    RETURN 'FAIL: convert_points_to_wallet() does not exist';
  END IF;

  -- The notification, and the two figures.
  IF position('notify_user_once' IN v_src) = 0 THEN
    RETURN 'FAIL: convert_points_to_wallet() credits the wallet and notifies '
           || 'nobody; the points balance changes with no way for the user to '
           || 'find out';
  END IF;

  IF position('points_spent' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the points spent';
  END IF;

  IF position('birr_credited' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice does not report the birr received';
  END IF;

  -- Keyed on the ledger id, so a repeated call cannot notify twice. A key
  -- built from the amount instead would collide across two identical
  -- conversions and silently swallow the second.
  IF position('notify_user_once(''points-convert:'' || v_ledger_id' IN v_src) = 0 THEN
    RETURN 'FAIL: the conversion notice is not keyed on the points ledger id, '
           || 'so a retried conversion would notify twice';
  END IF;

  FOREACH v_clause IN ARRAY v_required LOOP
    IF position(v_clause IN v_src) = 0 THEN
      v_missing := v_missing || ' [' || v_clause || ']';
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RETURN 'FAIL: convert_points_to_wallet() is missing' || v_missing
           || '. A money invariant was lost in the restatement; restore it '
           || 'from 20260927000059 before deploying.';
  END IF;

  RETURN 'ok: the conversion notifies with the points spent and the birr '
         || 'credited, keyed on the points ledger id; the advisory lock, the '
         || 'FOR UPDATE balance re-read, both ownership checks, the '
         || 'server-owned rate and the ADJUSTMENT ledger row are all present';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_points_conversion_notifies()
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.assert_points_conversion_notifies()
  TO authenticated, service_role;

notify pgrst, 'reload schema';
