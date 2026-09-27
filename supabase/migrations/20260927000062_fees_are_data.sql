-- 20260927000062_fees_are_data.sql
--
-- Feature: "every fee in the system must be editable live by the CEO/admin,
-- fully functional and immediately reflected app-wide — no fee should be
-- hardcoded in a way that requires a code deploy to change."
--
-- Findings from the audit this migration acts on:
--
--   1. THE 1%-WITH-5-BIRR-MINIMUM FEE DID NOT EXIST.  The product documents
--      it in three places — `admin_income_summary_screen.dart` ("fee =
--      max(1%, 5 birr), idempotent") and two lines of the repo-chat system
--      prompt — but `deduct_transaction_fee()` actually charged a FLAT fee
--      read from the `transaction_fee` key (seeded at 5 in 0001).  A 10,000
--      birr order and a 10 birr order paid the same fee.  The documented rule
--      was only ever a comment.
--        Fix: `transaction_fee_percent` (1) + the existing
--        `transaction_fee_min` (5), read at charge time, with
--        `platform_transaction_fee()` as the single implementation.  The
--        stale flat `transaction_fee` key is deleted, so a reader cannot
--        silently keep using the old number.
--
--   2. THE FEE CALCULATION WAS DUPLICATED IN THE CLIENT.  `user_checkout_
--      screen.dart` read `transaction_fee` itself to display what would be
--      charged — a second implementation of a money calculation, which is
--      how a display and a charge drift apart.  The screen now calls
--      `platform_transaction_fee()` for both.
--
--   3. RIDE PRICING WAS ALREADY DATA-DRIVEN but had no editor and no
--      assertions: `calculate_fare_estimate()` (20260922000012) reads
--      `ride_base_fare` / `ride_per_km` / `ride_minimum_fare` and honours
--      per-category overrides in `categories.metadata`.  Confirmed, kept,
--      and now surfaced in the CEO screen plus a setter with validation.
--
--   4. NOTHING COULD CHANGE A FEE.  `admin_update_setting()` (59) was
--      admin-gated but had no fee-specific validation, so a fee could be set
--      to -1 or to a string.  Fee keys are now CEO-only and bounds-checked.
--
--   5. FEE CHANGES HAD NO HISTORY VIEW.  They were already written to
--      `audit_logs` as SYSTEM_SETTING_UPDATED; `admin_fee_change_history()`
--      surfaces them.
--
-- Safety: no policy, escrow, status-machine or RLS change.  `system_settings`
-- values are never overwritten by this migration — every seed is
-- ON CONFLICT DO NOTHING, so a live fee the CEO has already tuned is kept.
-- Idempotent — safe to re-run.

-- =========================================================
-- 1. What counts as a fee
-- =========================================================
-- One predicate, used by the validator, the catalogue and the assertions, so
-- "is this a fee?" has exactly one answer.  Pattern-based as well as
-- list-based on purpose: a fee key added by a future migration is protected
-- and labelled without anyone remembering to update this list.
CREATE OR REPLACE FUNCTION public.is_fee_key(p_key text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT coalesce(
    p_key IN (
      'transaction_fee_percent', 'transaction_fee_min', 'provider_registration_fee',
      'provider_subscription_fee', 'ride_base_fare', 'ride_per_km', 'ride_minimum_fare'
    )
    OR p_key ~ '(_fee|_fee_min|_fee_percent|_fare|_per_km)$'
    OR p_key ~ '^ride_'
    OR p_key ~ '^provider_(registration|subscription)',
    false
  );
$$;

-- =========================================================
-- 2. The fee keys: present, described, and never clobbered
-- =========================================================
INSERT INTO public.system_settings (key, value, description) VALUES
  ('transaction_fee_percent', '1'::jsonb,
   'Platform commission taken from each completed order/ride, as a PERCENT of the gross amount. Charged together with transaction_fee_min — the fee is whichever of the two is larger'),
  ('transaction_fee_min', '5'::jsonb,
   'Minimum platform commission in birr. The order or ride fee is GREATEST(percent of gross, this value)'),
  ('ride_base_fare', '50'::jsonb,
   'Flat flag-fall added to every ride estimate ("base" or starting fare)'),
  ('ride_per_km', '20'::jsonb,
   'Birr charged per kilometre of estimated ride distance. Set 0 to make ride pricing flat (base + minimum only)'),
  ('ride_minimum_fare', '80'::jsonb,
   'Lowest a ride estimate may be, whatever base + distance works out to')
ON CONFLICT (key) DO NOTHING;

-- The one-time provider activation fee.  Seeded only if this deployment does
-- not already have some registration/activation fee key, so an existing
-- (differently named) live value is never shadowed by a duplicate.
DO $$
DECLARE
  v_key text;
  v_name text;
BEGIN
  SELECT k INTO v_name
    FROM unnest(ARRAY['provider_registration_fee', 'registration_fee', 'activation_fee']) AS k
   WHERE EXISTS (SELECT 1 FROM public.system_settings WHERE key = k)
   LIMIT 1;

  IF v_name IS NULL THEN
    INSERT INTO public.system_settings (key, value, description)
    VALUES ('provider_registration_fee', '100'::jsonb,
            'One-time provider activation fee in birr, charged inside the first wallet recharge. Change it here and the next first-recharge uses the new amount')
    ON CONFLICT (key) DO NOTHING;
    v_key := 'provider_registration_fee';
  ELSE
    v_key := v_name;
  END IF;

  -- Backfill a description on the key that exists, so it is not an anonymous
  -- number on the CEO screen.  Value is untouched.
  UPDATE public.system_settings
     SET description = coalesce(description,
           'One-time provider activation fee in birr, charged inside the first wallet recharge')
   WHERE key = v_key AND description IS NULL;
END;
$$;

-- The 5 birr monthly subscription/shop fee.  Same approach: only seed if no
-- subscription-shaped key exists yet, because the exact key name is not
-- something this migration should decide for an existing deployment.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.system_settings
     WHERE key ILIKE '%subscription%' OR key ILIKE '%monthly%'
  ) THEN
    INSERT INTO public.system_settings (key, value, description)
    VALUES ('provider_subscription_fee', '5'::jsonb,
            'Monthly provider subscription/shop fee in birr. Editable live — takes effect for the next billing cycle')
    ON CONFLICT (key) DO NOTHING;
  END IF;
END;
$$;

-- =========================================================
-- 3. One implementation of the transaction fee
-- =========================================================
-- Callable from SQL and from the app.  Exists so the number the checkout
-- screen shows and the number the wallet is charged can never disagree:
-- both call this.
CREATE OR REPLACE FUNCTION public.platform_transaction_fee(p_amount numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_percent numeric;
  v_min numeric;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'AMOUNT_MUST_BE_A_NON_NEGATIVE_NUMBER';
  END IF;

  v_percent := coalesce(public.get_setting_numeric('transaction_fee_percent'), 0);
  v_min := coalesce(public.get_setting_numeric('transaction_fee_min'), 0);

  IF v_percent < 0 OR v_min < 0 THEN
    RAISE EXCEPTION 'TRANSACTION_FEE_SETTINGS_CANNOT_BE_NEGATIVE';
  END IF;

  -- GREATEST(percentage, floor) is the documented 1%-with-5-birr-minimum
  -- rule, now charged instead of only described.
  RETURN greatest(round(p_amount * v_percent / 100.0, 2), v_min);
END;
$$;

COMMENT ON FUNCTION public.platform_transaction_fee(numeric) IS
  'The single source of truth for the platform commission: '
  'GREATEST(transaction_fee_percent% of the amount, transaction_fee_min). '
  'Read live from system_settings on every call so a CEO fee change applies '
  'to the next charge with no deploy.';

REVOKE EXECUTE ON FUNCTION public.platform_transaction_fee(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.platform_transaction_fee(numeric) TO authenticated, service_role;

-- =========================================================
-- 4. deduct_transaction_fee reads the fee from settings
-- =========================================================
-- Body reproduced from the live definition (0021 snapshot) and unchanged
-- except for `v_fee`: every guard, ledger row, idempotency branch, audit
-- entry and notification is byte-for-byte the same, so the money path itself
-- is not being re-engineered here.
CREATE OR REPLACE FUNCTION public.deduct_transaction_fee(
  p_provider_id uuid,
  p_order_id uuid,
  p_ride_id uuid,
  p_gross_amount numeric,
  p_idempotency_key text
)
RETURNS public.wallet_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet public.wallets;
  v_fee numeric := public.platform_transaction_fee(p_gross_amount);
  v_allow boolean := public.get_setting_bool('allow_negative_wallet');
  v_txn public.wallet_transactions;
  v_existing public.wallet_transactions;
BEGIN
  SELECT * INTO v_existing FROM public.wallet_transactions WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND';
  END IF;

  IF NOT v_allow AND (v_wallet.balance - v_fee) < 0 THEN
    INSERT INTO public.wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
    VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'FAILED', p_idempotency_key)
    RETURNING * INTO v_txn;

    INSERT INTO public.notifications (user_id, type, title, body)
    SELECT user_id, 'WALLET_EMPTY', 'Wallet balance too low', 'Transaction fee could not be deducted'
      FROM public.provider_profiles WHERE id = p_provider_id;

    RAISE EXCEPTION 'INSUFFICIENT_WALLET_BALANCE';
  END IF;

  UPDATE public.wallets
     SET balance = balance - v_fee, updated_at = now()
   WHERE id = v_wallet.id
  RETURNING * INTO v_wallet;

  INSERT INTO public.wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'COMPLETED', p_idempotency_key)
  RETURNING * INTO v_txn;

  INSERT INTO public.audit_logs (event_type, entity_type, entity_id, metadata)
  VALUES ('TRANSACTION_FEE_DEDUCTED', 'wallets', v_wallet.id,
          jsonb_build_object('provider_id', p_provider_id, 'fee', v_fee, 'balance_after', v_wallet.balance));

  INSERT INTO public.notifications (user_id, type, title, body)
  SELECT user_id, 'TRANSACTION_FEE_DEDUCTED', 'Platform fee deducted', v_fee::text || ' Birr deducted'
    FROM public.provider_profiles WHERE id = p_provider_id;

  IF v_wallet.balance <= public.get_setting_numeric('low_wallet_threshold') THEN
    INSERT INTO public.notifications (user_id, type, title, body)
    SELECT user_id, 'WALLET_LOW', 'Wallet balance low', 'Your wallet balance is low'
      FROM public.provider_profiles WHERE id = p_provider_id;
  END IF;

  RETURN v_txn;
END;
$$;

-- 0011 revoked this from authenticated; anon was never explicitly revoked.
-- The function takes a provider id with no ownership check of its own, so it
-- must stay unreachable from the client either way.
REVOKE EXECUTE ON FUNCTION public.deduct_transaction_fee(uuid, uuid, uuid, numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_transaction_fee(uuid, uuid, uuid, numeric, text) TO service_role;

-- The flat key is now read by nothing (the checkout screen moved to
-- platform_transaction_fee() in the same change).  Deleting it rather than
-- leaving it behind is the point: a stale money key is an invitation for the
-- next reader to use the wrong number.  Same precedent as 59 dropping
-- points_per_trade.
DELETE FROM public.system_settings WHERE key = 'transaction_fee';

-- =========================================================
-- 5. Fee writes are CEO-only and validated
-- =========================================================
-- Full replacement of the function from 59.  Behaviour is preserved exactly
-- (shape preservation per key, the points checks, the conversion-rate and
-- rank-tier validators, the audit entry) with two additions: the fee gate and
-- fee bounds.
CREATE OR REPLACE FUNCTION public.admin_update_setting(
  p_key text,
  p_value jsonb,
  p_description text DEFAULT NULL
)
RETURNS public.system_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.system_settings;
  v_old jsonb;
  v_problem text;
  v_numeric numeric;
BEGIN
  IF p_key IS NULL OR btrim(p_key) = '' THEN
    RAISE EXCEPTION 'SETTING_KEY_REQUIRED';
  END IF;

  -- Fees are the owner's call, not any admin's.  The product already
  -- distinguishes the two (is_ceo(), 20260923000003), so the distinction the
  -- brief asks for already exists and is used here rather than inventing a
  -- new role.  Everything that is not a fee stays ordinary-admin editable,
  -- which is all the rest of this screen.
  IF public.is_fee_key(p_key) THEN
    IF NOT public.is_ceo() THEN
      RAISE EXCEPTION 'FEES_CAN_ONLY_BE_CHANGED_BY_THE_CEO_OR_OWNER';
    END IF;
  ELSIF NOT public.is_admin() THEN
    RAISE EXCEPTION 'SYSTEM_SETTINGS_CAN_ONLY_BE_MODIFIED_BY_ADMINISTRATORS';
  END IF;

  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RAISE EXCEPTION 'SETTING_VALUE_REQUIRED';
  END IF;

  SELECT value INTO v_old FROM public.system_settings WHERE key = p_key;

  -- Shape is preserved per key.  get_setting_numeric() casts
  -- (value #>> '{}')::numeric, so flipping a numeric key to a string turns
  -- every reader into a runtime cast failure; the same holds for
  -- get_setting_bool(). Caught here, where there is a message.
  IF v_old IS NOT NULL THEN
    IF jsonb_typeof(v_old) IN ('number', 'boolean')
       AND jsonb_typeof(v_old) <> jsonb_typeof(p_value) THEN
      RAISE EXCEPTION 'SETTING_%_MUST_STAY_A_%', p_key, upper(jsonb_typeof(v_old));
    END IF;
  END IF;

  -- Fee bounds.  A negative fee pays providers to trade; an absurd one is
  -- almost always a typo (a birr value entered in cents), and either way it
  -- would be silently live for the next transaction.
  IF public.is_fee_key(p_key) THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'FEE_%_MUST_BE_A_NUMBER', p_key;
    END IF;
    v_numeric := (p_value #>> '{}')::numeric;

    IF v_numeric < 0 THEN
      RAISE EXCEPTION 'FEE_%_CANNOT_BE_NEGATIVE', p_key;
    END IF;

    IF p_key ~ 'percent$' AND v_numeric > 100 THEN
      RAISE EXCEPTION 'FEE_%_MUST_BE_AT_MOST_100_PERCENT', p_key;
    ELSIF p_key !~ 'percent$' AND v_numeric > 1000000 THEN
      RAISE EXCEPTION 'FEE_%_IS_ABOVE_THE_SANITY_LIMIT_OF_1000000_BIRR', p_key;
    END IF;

    -- A zero-percent commission with no floor would mean free trades.  Legal
    -- if that is the deliberate choice, but not by accident: the pair must
    -- leave some fee standing.
    IF p_key = 'transaction_fee_percent'
       AND v_numeric = 0
       AND coalesce(public.get_setting_numeric('transaction_fee_min'), 0) = 0 THEN
      RAISE EXCEPTION 'SETTING_BOTH_THE_FEE_PERCENT_AND_THE_MINIMUM_TO_ZERO_REMOVES_ALL_PLATFORM_COMMISSION';
    END IF;
    IF p_key = 'transaction_fee_min'
       AND v_numeric = 0
       AND coalesce(public.get_setting_numeric('transaction_fee_percent'), 0) = 0 THEN
      RAISE EXCEPTION 'SETTING_BOTH_THE_FEE_PERCENT_AND_THE_MINIMUM_TO_ZERO_REMOVES_ALL_PLATFORM_COMMISSION';
    END IF;
  END IF;

  IF p_key IN (
    'points_per_order', 'points_per_ride', 'points_per_review',
    'points_per_recharge', 'points_first_provider_approval',
    'points_conversion_minimum'
  ) THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'SETTING_%_MUST_BE_A_NUMBER', p_key;
    END IF;
    IF (p_value #>> '{}')::numeric < 0 THEN
      RAISE EXCEPTION 'SETTING_%_CANNOT_BE_NEGATIVE', p_key;
    END IF;
  END IF;

  IF p_key = 'points_to_birr_rate' THEN
    IF jsonb_typeof(p_value) <> 'number' THEN
      RAISE EXCEPTION 'POINTS_TO_BIRR_RATE_MUST_BE_A_NUMBER';
    END IF;
    IF (p_value #>> '{}')::numeric <= 0 OR (p_value #>> '{}')::numeric > 1 THEN
      RAISE EXCEPTION 'POINTS_TO_BIRR_RATE_MUST_BE_ABOVE_0_AND_AT_MOST_1';
    END IF;
  END IF;

  IF p_key = 'rank_tiers' THEN
    v_problem := public.validate_rank_tiers(p_value);
    IF v_problem IS NOT NULL THEN
      RAISE EXCEPTION '%', v_problem;
    END IF;
  END IF;

  INSERT INTO public.system_settings (key, value, description, updated_by, updated_at)
  VALUES (
    p_key,
    p_value,
    COALESCE(NULLIF(btrim(coalesce(p_description, '')), ''), 'Set from the admin settings screen'),
    auth.uid(),
    now()
  )
  ON CONFLICT (key) DO UPDATE
    SET value = excluded.value,
        description = CASE
                        WHEN NULLIF(btrim(coalesce(p_description, '')), '') IS NULL
                          THEN public.system_settings.description
                        ELSE excluded.description
                      END,
        updated_by = auth.uid(),
        updated_at = now()
  RETURNING * INTO v_row;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (
    auth.uid(),
    'SYSTEM_SETTING_UPDATED',
    'system_settings',
    NULL,
    jsonb_build_object(
      'key', p_key,
      'old_value', v_old,
      'new_value', p_value,
      'is_fee', public.is_fee_key(p_key)
    )
  );

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.admin_update_setting(text, jsonb, text) IS
  'The only client path that writes system_settings. Fee keys are CEO-only '
  'and bounds-checked, other keys are admin-gated; type-checked per key so a '
  'reader cannot be broken by a shape change, and audited.';

REVOKE ALL ON FUNCTION public.admin_update_setting(text, jsonb, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_setting(text, jsonb, text) TO authenticated, service_role;

-- =========================================================
-- 6. Per-category ride pricing (the override calculate_fare_estimate honours)
-- =========================================================
CREATE OR REPLACE FUNCTION public.set_ride_category_pricing(
  p_category_id uuid,
  p_base_fare numeric DEFAULT NULL,
  p_per_km numeric DEFAULT NULL,
  p_minimum_fare numeric DEFAULT NULL
)
RETURNS public.categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cat public.categories;
  v_meta jsonb;
  v_numeric numeric;
  v_pair text;
BEGIN
  IF NOT public.is_ceo() THEN
    RAISE EXCEPTION 'RIDE_PRICING_CAN_ONLY_BE_CHANGED_BY_THE_CEO_OR_OWNER';
  END IF;

  SELECT * INTO v_cat FROM public.categories WHERE id = p_category_id;
  IF v_cat.id IS NULL THEN
    RAISE EXCEPTION 'CATEGORY_NOT_FOUND';
  END IF;

  FOREACH v_pair IN ARRAY ARRAY['base_fare', 'per_km', 'minimum_fare']
  LOOP
    v_numeric := CASE v_pair
                   WHEN 'base_fare' THEN p_base_fare
                   WHEN 'per_km' THEN p_per_km
                   ELSE p_minimum_fare
                 END;
    IF v_numeric IS NOT NULL AND (v_numeric < 0 OR v_numeric > 1000000) THEN
      RAISE EXCEPTION 'RIDE_PRICING_%_MUST_BE_BETWEEN_0_AND_1000000', upper(v_pair);
    END IF;
  END LOOP;

  -- NULL means "remove the override and fall back to the global setting"
  -- rather than "set it to nothing" — the sentinel calculate_fare_estimate's
  -- COALESCE already treats as absent.
  v_meta := coalesce(v_cat.metadata, '{}'::jsonb)
            || jsonb_strip_nulls(jsonb_build_object(
                 'base_fare', p_base_fare,
                 'per_km', p_per_km,
                 'minimum_fare', p_minimum_fare
               ));

  UPDATE public.categories
     SET metadata = v_meta,
         updated_at = now()
   WHERE id = p_category_id
  RETURNING * INTO v_cat;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'RIDE_CATEGORY_PRICING_UPDATED', 'categories', p_category_id,
          jsonb_build_object('category', v_cat.name, 'pricing', v_meta));

  RETURN v_cat;
END;
$$;

REVOKE ALL ON FUNCTION public.set_ride_category_pricing(uuid, numeric, numeric, numeric) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_ride_category_pricing(uuid, numeric, numeric, numeric) TO authenticated, service_role;

-- One screen's worth of data: every fee, whether or not it currently exists
-- as a row.  A fee that is missing from system_settings is shown as missing
-- rather than silently omitted, because "the CEO cannot see it" is how a
-- hardcoded fee survives an audit.
CREATE OR REPLACE FUNCTION public.admin_fee_catalogue()
RETURNS TABLE (
  key text,
  value jsonb,
  description text,
  fee_group text,
  is_percent boolean,
  min_value numeric,
  max_value numeric,
  updated_at timestamptz,
  is_missing boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FEE_SETTINGS_CAN_ONLY_BE_VIEWED_BY_ADMINISTRATORS';
  END IF;

  RETURN QUERY
  WITH known(k, g, is_pct, lo, hi) AS (
    VALUES
      ('transaction_fee_percent'::text,   'TRANSACTION'::text, true,  0::numeric, 100::numeric),
      ('transaction_fee_min',             'TRANSACTION',         false, 0::numeric, 1000000::numeric),
      ('provider_registration_fee',       'ACTIVATION',          false, 0::numeric, 1000000::numeric),
      ('provider_subscription_fee',       'SUBSCRIPTION',        false, 0::numeric, 1000000::numeric),
      ('ride_base_fare',                  'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric),
      ('ride_per_km',                     'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric),
      ('ride_minimum_fare',               'RIDE DEFAULTS',       false, 0::numeric, 1000000::numeric)
  )
  SELECT kn.k, s.value, s.description, kn.g, kn.is_pct, kn.lo, kn.hi, s.updated_at, (s.key IS NULL)
    FROM known kn
    LEFT JOIN public.system_settings s ON s.key = kn.k
  UNION ALL
  SELECT s.key, s.value, s.description, 'OTHER DETECTED', (s.key ~ 'percent$'),
         (CASE WHEN jsonb_typeof(s.value) = 'number' THEN 0::numeric ELSE NULL::numeric END),
         1000000, s.updated_at, false
    FROM public.system_settings s
   WHERE public.is_fee_key(s.key)
     AND s.key NOT IN ('transaction_fee_percent', 'transaction_fee_min',
                       'provider_registration_fee', 'provider_subscription_fee',
                       'ride_base_fare', 'ride_per_km', 'ride_minimum_fare')
   ORDER BY 4, 1;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_fee_catalogue() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_fee_catalogue() TO authenticated, service_role;

-- Lets the CEO screen tell "you can edit these" from "you can read them"
-- without the app guessing at the role rules, which live server-side in
-- is_ceo().  Read-only for a non-CEO admin by design.
CREATE OR REPLACE FUNCTION public.is_fee_editor()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.is_ceo();
$$;

REVOKE ALL ON FUNCTION public.is_fee_editor() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.is_fee_editor() TO authenticated, service_role;

-- Who changed which fee, when, and from what.  Reads the audit rows
-- admin_update_setting() already wrote — no second history table.
CREATE OR REPLACE FUNCTION public.admin_fee_change_history(p_limit integer DEFAULT 50)
RETURNS TABLE (
  changed_at timestamptz,
  key text,
  old_value jsonb,
  new_value jsonb,
  actor_id uuid,
  actor_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'FEE_HISTORY_CAN_ONLY_BE_VIEWED_BY_ADMINISTRATORS';
  END IF;

  RETURN QUERY
  SELECT a.created_at,
         a.metadata ->> 'key',
         a.metadata -> 'old_value',
         a.metadata -> 'new_value',
         a.actor_id,
         coalesce(p.full_name, 'Unknown')
    FROM public.audit_logs a
    LEFT JOIN public.profiles p ON p.id = a.actor_id
   WHERE a.event_type = 'SYSTEM_SETTING_UPDATED'
     AND public.is_fee_key(a.metadata ->> 'key')
   ORDER BY a.created_at DESC
   LIMIT least(greatest(coalesce(p_limit, 50), 1), 500);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_fee_change_history(integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_fee_change_history(integer) TO authenticated, service_role;

-- =========================================================
-- 7. Assertions
-- =========================================================
-- Behavioural, not declarative: this compares the fee the system would
-- actually charge against the arithmetic implied by the settings, so a fee
-- hardcoded back into the function fails the test instead of quietly
-- charging the wrong amount.
CREATE OR REPLACE FUNCTION public.assert_fees_are_data_driven()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_percent numeric;
  v_min numeric;
  v_actual numeric;
  v_expected numeric;
  v_src text;
  v_key text;
  v_distance numeric;
  v_base numeric;
  v_per_km numeric;
  v_fare_min numeric;
  v_estimate numeric;
  v_expected_estimate numeric;
  -- Two fixed points in Addis Ababa, matching calculate_fare_estimate's own
  -- (lng, lat) argument order.
  v_pickup_lat double precision := 9.010800;
  v_pickup_lng double precision := 38.761300;
  v_dest_lat double precision := 9.030000;
  v_dest_lng double precision := 38.790000;
BEGIN
  -- Every fee the product charges must have a row.  A missing key means some
  -- reader is falling back to a literal in code.
  FOREACH v_key IN ARRAY ARRAY[
    'transaction_fee_percent', 'transaction_fee_min',
    'provider_registration_fee',
    'ride_base_fare', 'ride_per_km', 'ride_minimum_fare'
  ]
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.system_settings WHERE key = v_key) THEN
      RAISE EXCEPTION
        'FEE_%_IS_NOT_IN_system_settings, so it is still code-driven and cannot be changed without a deploy',
        v_key;
    END IF;

    IF (SELECT jsonb_typeof(value) FROM public.system_settings WHERE key = v_key) <> 'number' THEN
      RAISE EXCEPTION 'FEE_%_IS_NOT_STORED_AS_A_NUMBER', v_key;
    END IF;

    IF (SELECT (value #>> '{}')::numeric < 0 FROM public.system_settings WHERE key = v_key) THEN
      RAISE EXCEPTION 'FEE_%_IS_NEGATIVE', v_key;
    END IF;
  END LOOP;

  v_percent := public.get_setting_numeric('transaction_fee_percent');
  v_min := public.get_setting_numeric('transaction_fee_min');

  -- (a) the charged fee equals the settings arithmetic, at two magnitudes
  v_actual := public.platform_transaction_fee(1000);
  v_expected := greatest(round(1000 * v_percent / 100.0, 2), v_min);
  IF v_actual <> v_expected THEN
    RAISE EXCEPTION
      'TRANSACTION_FEE_DOES_NOT_FOLLOW_SETTINGS: platform_transaction_fee(1000) is % but transaction_fee_percent=%/transaction_fee_min=% imply %',
      v_actual, v_percent, v_min, v_expected;
  END IF;

  -- (b) and the fee is percentage-driven, not a flat number wearing a
  -- setting's name: with a percent above zero a larger trade must cost more.
  IF v_percent > 0 AND public.platform_transaction_fee(100000) <= public.platform_transaction_fee(1000) THEN
    RAISE EXCEPTION
      'TRANSACTION_FEE_IS_FLAT: a 100000 gross and a 1000 gross are charged % and % even though transaction_fee_percent is %',
      public.platform_transaction_fee(100000), public.platform_transaction_fee(1000), v_percent;
  END IF;

  -- (c) the fee writer must still go through the settings-backed calculator.
  v_src := pg_get_functiondef('public.deduct_transaction_fee(uuid,uuid,uuid,numeric,text)'::regprocedure);
  IF position('platform_transaction_fee' in v_src) = 0 THEN
    RAISE EXCEPTION 'deduct_transaction_fee() no longer reads the fee from system_settings';
  END IF;
  -- Built with chr(39) rather than an escaped quote so the needle cannot
  -- unbalance this function's own dollar-quoted body.
  IF position(('get_setting_numeric(' || chr(39) || 'transaction_fee' || chr(39)) in v_src) > 0 THEN
    RAISE EXCEPTION 'deduct_transaction_fee() is reading the deleted flat transaction_fee key again';
  END IF;

  -- (d) the fare estimate equals the configured pricing for a known distance.
  v_base := coalesce(public.get_setting_numeric('ride_base_fare'), 50);
  v_per_km := coalesce(public.get_setting_numeric('ride_per_km'), 20);
  v_fare_min := coalesce(public.get_setting_numeric('ride_minimum_fare'), 80);

  v_distance := round((
    st_distance(
      st_setsrid(st_makepoint(v_pickup_lng, v_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(v_dest_lng, v_dest_lat), 4326)::geography
    ) / 1000.0
  )::numeric, 2);

  v_expected_estimate := round(greatest(v_fare_min, v_base + v_per_km * v_distance), 2);
  v_estimate := public.calculate_fare_estimate(
    v_pickup_lat, v_pickup_lng, v_dest_lat, v_dest_lng, NULL::uuid
  );

  IF v_estimate <> v_expected_estimate THEN
    RAISE EXCEPTION
      'RIDE_FARE_DOES_NOT_FOLLOW_SETTINGS: calculate_fare_estimate() returned % but ride_base_fare=% + ride_per_km=% x %km (floor ride_minimum_fare=%) implies %',
      v_estimate, v_base, v_per_km, v_distance, v_fare_min, v_expected_estimate;
  END IF;

  -- (e) distance-based pricing must exist as a concept: a ride fee that does
  -- not vary with distance is not distance-based pricing.
  IF public.calculate_fare_estimate(9.0108, 38.7613, 9.0300, 38.7900, NULL::uuid)
     = public.calculate_fare_estimate(9.0108, 38.7613, 9.0109, 38.7614, NULL::uuid)
     AND v_per_km > 0 THEN
    RAISE EXCEPTION 'RIDE_PRICING_IS_NOT_DISTANCE_BASED: ride_per_km is % but a 3km and a 30m trip estimate the same fare', v_per_km;
  END IF;

  -- (f) the CEO gate on fee writes must still be in place.
  v_src := pg_get_functiondef('public.admin_update_setting(text,jsonb,text)'::regprocedure);
  IF position('FEES_CAN_ONLY_BE_CHANGED_BY_THE_CEO_OR_OWNER' in v_src) = 0 THEN
    RAISE EXCEPTION 'the CEO-only gate on fee settings has been removed from admin_update_setting()';
  END IF;

  RETURN format(
    'fees are data-driven OK: commission = GREATEST(%s%% of gross, %s birr) (1000 -> %s, 100000 -> %s); ride = %s + %s/km (floor %s, %s km -> %s)',
    v_percent, v_min,
    public.platform_transaction_fee(1000), public.platform_transaction_fee(100000),
    v_base, v_per_km, v_fare_min, v_distance, v_estimate
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_fees_are_data_driven() TO anon, authenticated;
