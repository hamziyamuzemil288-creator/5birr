-- =============================================================================
-- 20260927000107_per_category_and_city_fees.sql
--
-- Fees become per-CATEGORY and per-CITY, editable live from the admin sidebar.
--
-- THE PROBLEM
-- -----------
-- Every money value the platform charges was a single global row in
-- system_settings. `bajaj /km` was therefore the same number as `big truck
-- /km`, and a bajaj driver's monthly subscription was the same number as a
-- hotel's. Per-category ride pricing technically existed -- calculate_fare_
-- estimate() reads `categories.metadata->>'per_km'` -- but no admin screen
-- writes that JSONB, so it had no door. Commission, subscription and
-- activation had no per-category dimension at all, and no fee had a per-city
-- dimension.
--
-- THE SAFETY PROPERTY THAT MATTERS MOST
-- -------------------------------------
-- Every money column here is NULLABLE, and NULL means "inherit the global
-- system_settings value". No row is backfilled. Resolving a fee with this
-- table therefore returns exactly today's number for every category and
-- every city until an administrator edits one. Deploying this migration
-- cannot change a single price; only a later admin write can.
--
-- PRECEDENCE, most specific first
-- ------------------------------
--   1. category_fee_settings row for (category, THIS city)
--   2. category_fee_settings row for (category, all cities)  -- city = ''
--   3. categories.metadata key                              -- the pre-existing
--                                                          -- per-category ride
--                                                          -- override, still
--                                                          -- honoured
--   4. system_settings                                      -- the global default
--   5. the hardcoded default the function already used
--
-- Step 3 is deliberately kept. It is the only per-category pricing that is
-- live today, and a migration that quietly stopped honouring it would raise
-- or lower a real fare.
--
-- CITY MATCHING
-- -------------
-- Cities are matched on lower(btrim(...)), so 'Addis Ababa', 'addis ababa'
-- and '  ADDIS ABABA ' are one city. There is no fuzzy matching on purpose:
-- a fee that silently applied to a city the admin did not name is worse than
-- a fee that does not apply.
--
-- The client is never granted INSERT/UPDATE/DELETE on this table. Writes go
-- through admin_save_category_fee(), which is gated on is_ceo() -- the same
-- gate admin_update_setting() uses for the global fees, so there is one
-- answer to "who may change what the platform charges".
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The table
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.category_fee_settings (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),

  -- The category this row prices. ON DELETE CASCADE is right: a deleted
  -- category cannot be ridden, ordered or subscribed for, so its bespoke
  -- numbers have nothing left to attach to.
  category_id uuid NOT NULL REFERENCES public.categories(id) ON DELETE CASCADE,

  -- '' means "every city". Normalised to lower(btrim()) on write.
  city        text NOT NULL DEFAULT '',

  -- Commission the platform keeps. NULL = inherit the global
  -- transaction_fee_percent / transaction_fee_min.
  commission_percent numeric,
  commission_min     numeric,

  -- Monthly provider subscription. NULL = inherit monthly_subscription_fee.
  subscription_fee   numeric,

  -- One-time activation fee. NULL = inherit provider_registration_fee.
  activation_fee     numeric,

  -- Ride fares. NULL = inherit the global ride_* setting.
  ride_base_fare     numeric,
  ride_per_km        numeric,
  ride_minimum_fare  numeric,

  -- Service/booking fares, kept separate from rides because a plumber's
  -- call-out and a bajaj trip are not the same product.
  booking_base_fee     numeric,
  booking_per_km       numeric,
  booking_minimum_fee  numeric,

  -- Product-side commission and listing fee, so a hotel's marketplace
  -- listings can carry a different take rate from its ride commission.
  product_commission_percent numeric,
  product_commission_min     numeric,
  product_listing_fee        numeric,

  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,

  CONSTRAINT category_fee_settings_city_normalised
    CHECK (city = lower(btrim(city))),

  -- A negative price is not a discount, it is a payout. Refused here so no
  -- editor can reach it, and so the resolvers never have to defend it.
  CONSTRAINT category_fee_settings_non_negative CHECK (
        coalesce(commission_percent, 0) >= 0
    AND coalesce(commission_min, 0) >= 0
    AND coalesce(subscription_fee, 0) >= 0
    AND coalesce(activation_fee, 0) >= 0
    AND coalesce(ride_base_fare, 0) >= 0
    AND coalesce(ride_per_km, 0) >= 0
    AND coalesce(ride_minimum_fare, 0) >= 0
    AND coalesce(booking_base_fee, 0) >= 0
    AND coalesce(booking_per_km, 0) >= 0
    AND coalesce(booking_minimum_fee, 0) >= 0
    AND coalesce(product_commission_percent, 0) >= 0
    AND coalesce(product_commission_min, 0) >= 0
    AND coalesce(product_listing_fee, 0) >= 0
  ),

  -- A commission above 100% would take more than the sale. Only the two
  -- percentage columns are bounded that way.
  CONSTRAINT category_fee_settings_percent_sane CHECK (
    coalesce(commission_percent, 0) <= 100
    AND coalesce(product_commission_percent, 0) <= 100
  ),

  -- One row per (category, city). This is what makes the resolver a lookup
  -- rather than a "which of these three rows wins" argument.
  CONSTRAINT category_fee_settings_unique UNIQUE (category_id, city)
);

COMMENT ON TABLE public.category_fee_settings IS
  'Per-category, per-city fee overrides. Every money column is nullable and '
  'NULL means "inherit the global system_settings value", so this table is '
  'empty until an administrator fills it in and costs nothing to leave empty.';

CREATE INDEX IF NOT EXISTS idx_category_fee_settings_category
  ON public.category_fee_settings (category_id, city);

-- RLS on, no INSERT/UPDATE/DELETE policy at all: the only writer is the
-- SECURITY DEFINER RPC below. Migration
-- 20260927000050_close_the_client_write_surface.sql independently revokes
-- client writes to any public table outside its 22-name allowlist, and this
-- table is not on it -- so this is the second of two independent locks, not
-- the only one.
ALTER TABLE public.category_fee_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS category_fee_settings_admin_read ON public.category_fee_settings;
CREATE POLICY category_fee_settings_admin_read ON public.category_fee_settings
  FOR SELECT TO authenticated
  USING (public.is_admin());

REVOKE ALL ON TABLE public.category_fee_settings FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.category_fee_settings TO authenticated;
GRANT ALL ON TABLE public.category_fee_settings TO service_role;

-- -----------------------------------------------------------------------------
-- 2. Keep updated_at honest
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.touch_category_fee_settings()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  IF TG_OP = 'INSERT' THEN
    NEW.updated_by := auth.uid();
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_category_fee_settings_touch ON public.category_fee_settings;
CREATE TRIGGER trg_category_fee_settings_touch
  BEFORE INSERT OR UPDATE ON public.category_fee_settings
  FOR EACH ROW EXECUTE FUNCTION public.touch_category_fee_settings();

-- -----------------------------------------------------------------------------
-- 3. The resolver: which row prices (category, city)?
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.category_fee(
  p_category_id uuid,
  p_city text
)
RETURNS public.category_fee_settings
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_city text := lower(btrim(coalesce(p_city, '')));
  v_row  public.category_fee_settings;
BEGIN
  -- No category means no override. Returning NULL here is what makes every
  -- downstream COALESCE fall through to the global value.
  IF p_category_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- 1. this exact city
  SELECT * INTO v_row
    FROM public.category_fee_settings f
   WHERE f.category_id = p_category_id AND f.city = v_city
   LIMIT 1;
  IF v_row.id IS NOT NULL THEN
    RETURN v_row;
  END IF;

  -- 2. the category-wide row
  SELECT * INTO v_row
    FROM public.category_fee_settings f
   WHERE f.category_id = p_category_id AND f.city = ''
   LIMIT 1;

  -- v_row is NULL when neither row exists, which is the expected state for
  -- every category until an administrator says otherwise.
  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.category_fee(uuid, text) IS
  'The fee row that prices (category, city): exact city first, then the '
  'category-wide row (city=''''), then no row at all. NULL means inherit.';

REVOKE ALL ON FUNCTION public.category_fee(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.category_fee(uuid, text)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. Scalar readers -- one per fee, each carrying the full fallback chain
-- -----------------------------------------------------------------------------
-- Each is a separate function rather than one function with a text key
-- because the return type differs (percent vs money vs metadata lookup) and
-- because a mis-typed key would then be a silent zero instead of a compile
-- error. `categories.metadata` is consulted before system_settings because
-- that per-category override is live today and must keep winning.

CREATE OR REPLACE FUNCTION public.fee_ride_base_fare(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.ride_base_fare FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    (SELECT (c.metadata ->> 'base_fare')::numeric FROM public.categories c
      WHERE c.id = p_category_id),
    coalesce(public.get_setting_numeric('ride_base_fare'), 50));
$$;

CREATE OR REPLACE FUNCTION public.fee_ride_per_km(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.ride_per_km FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    (SELECT (c.metadata ->> 'per_km')::numeric FROM public.categories c
      WHERE c.id = p_category_id),
    coalesce(public.get_setting_numeric('ride_per_km'), 20));
$$;

CREATE OR REPLACE FUNCTION public.fee_ride_minimum_fare(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.ride_minimum_fare FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    (SELECT (c.metadata ->> 'minimum_fare')::numeric FROM public.categories c
      WHERE c.id = p_category_id),
    coalesce(public.get_setting_numeric('ride_minimum_fare'), 80));
$$;

CREATE OR REPLACE FUNCTION public.fee_booking_base_fare(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.booking_base_fee FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('booking_base_fee'), 0));
$$;

CREATE OR REPLACE FUNCTION public.fee_booking_per_km(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.booking_per_km FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('booking_per_km'), 0));
$$;

CREATE OR REPLACE FUNCTION public.fee_booking_minimum_fee(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.booking_minimum_fee FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('booking_minimum_fee'), 0));
$$;

-- [p_is_product] picks between the product-side commission columns and the
-- general ones. FALSE means "this is a ride or a service booking"; TRUE
-- means "this is a marketplace product sale".
CREATE OR REPLACE FUNCTION public.fee_commission_percent(
  p_category_id uuid, p_city text, p_is_product boolean DEFAULT false)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT CASE WHEN p_is_product THEN f.product_commission_percent
                 ELSE f.commission_percent END
       FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('transaction_fee_percent'), 0));
$$;

CREATE OR REPLACE FUNCTION public.fee_commission_min(
  p_category_id uuid, p_city text, p_is_product boolean DEFAULT false)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT CASE WHEN p_is_product THEN f.product_commission_min
                 ELSE f.commission_min END
       FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('transaction_fee_min'), 0));
$$;

CREATE OR REPLACE FUNCTION public.fee_subscription(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.subscription_fee FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('monthly_subscription_fee'), 0));
$$;

CREATE OR REPLACE FUNCTION public.fee_activation(
  p_category_id uuid, p_city text)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT coalesce(
    (SELECT f.activation_fee FROM public.category_fee_settings f
      WHERE f.id = (SELECT (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('provider_registration_fee'), 0));
$$;

-- Privileges for the ten scalar readers.
--
-- Only `fee_commission_percent` and `fee_commission_min` take the third
-- `p_is_product` argument; the other eight are (uuid, text) only. Granting a
-- signature that does not exist is not a no-op -- it is
-- `ERROR: function public.fee_ride_base_fare(uuid, text, boolean) does not
-- exist (SQLSTATE 42883)`, which aborts the whole push. The loop therefore
-- asks pg_proc which overloads are really there and touches only those, so
-- adding a third argument to one of these readers later cannot silently break
-- the deploy the way the hard-coded pair did.
DO $$
DECLARE
  v_fn text;
  v_sig text;
  v_oid oid;
  v_args text[];
BEGIN
  FOREACH v_fn IN ARRAY ARRAY[
    'fee_ride_base_fare', 'fee_ride_per_km', 'fee_ride_minimum_fare',
    'fee_booking_base_fare', 'fee_booking_per_km', 'fee_booking_minimum_fee',
    'fee_commission_percent', 'fee_commission_min',
    'fee_subscription', 'fee_activation']
  LOOP
    FOREACH v_args IN ARRAY ARRAY[
      ARRAY['uuid', 'text'], ARRAY['uuid', 'text', 'boolean']]
    LOOP
      SELECT p.oid INTO v_oid
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = v_fn
        AND p.pronargs = array_length(v_args, 1)
        AND (
          SELECT array_agg(pg_get_function_arguments(p.oid)
                           || ' ' || t.typname ORDER BY x.ord)
          FROM unnest(p.proargtypes::oid[]) WITH ORDINALITY AS x(oid, ord)
          JOIN pg_type t ON t.oid = x.oid
        ) = v_args;

      IF v_oid IS NULL THEN
        CONTINUE;
      END IF;

      v_sig := format('%I(%s)', v_fn, array_to_string(v_args, ', '));
      EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC, anon', v_sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated, service_role', v_sig);
    END LOOP;
  END LOOP;
END;
$$;

-- -----------------------------------------------------------------------------
-- 5. Which category and city is a provider in?
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.provider_fee_context(p_provider_id uuid)
RETURNS TABLE (category_id uuid, city text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT pp.category_id,
         -- provider_profiles.city first, then the owner's profile city.
         -- A provider registered before the city column existed has it on
         -- profiles, and dropping that to '' would silently put them on the
         -- category-wide rate instead of their own city's.
         coalesce(
           nullif(btrim(pp.city), ''),
           nullif(btrim(pr.city), '')
         )
    FROM public.provider_profiles pp
    LEFT JOIN public.profiles pr ON pr.id = pp.user_id
   WHERE pp.id = p_provider_id;
$$;

REVOKE ALL ON FUNCTION public.provider_fee_context(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_fee_context(uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 6. Commission, made category- and city-aware
-- -----------------------------------------------------------------------------
-- A NEW name rather than a new arity on platform_transaction_fee(). Postgres
-- treats a different parameter list as an OVERLOAD, and PostgREST cannot pick
-- between two functions it considers equally good -- it answers PGRST203.
-- The one-argument function is kept and made to delegate, so every existing
-- caller keeps working and keeps its exact grant posture.

CREATE OR REPLACE FUNCTION public.platform_transaction_fee_for(
  p_amount numeric,
  p_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL,
  p_is_product boolean DEFAULT false
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_percent numeric;
  v_min     numeric;
BEGIN
  IF p_amount IS NULL OR p_amount < 0 THEN
    RAISE EXCEPTION 'AMOUNT_MUST_BE_A_NON_NEGATIVE_NUMBER';
  END IF;

  v_percent := public.fee_commission_percent(p_category_id, p_city, p_is_product);
  v_min     := public.fee_commission_min(p_category_id, p_city, p_is_product);

  IF v_percent < 0 OR v_min < 0 THEN
    RAISE EXCEPTION 'TRANSACTION_FEE_SETTINGS_CANNOT_BE_NEGATIVE';
  END IF;

  -- GREATEST(percentage, floor) is the documented rule, unchanged. Only the
  -- two numbers it reads are now per-category and per-city.
  RETURN greatest(round(p_amount * v_percent / 100.0, 2), v_min);
END;
$$;

COMMENT ON FUNCTION public.platform_transaction_fee_for(numeric, uuid, text, boolean) IS
  'The platform commission for an amount in a given category and city. '
  'Falls back to the global transaction_fee_percent / transaction_fee_min '
  'whenever no override is configured.';

REVOKE ALL ON FUNCTION public.platform_transaction_fee_for(numeric, uuid, text, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.platform_transaction_fee_for(numeric, uuid, text, boolean)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.platform_transaction_fee(p_amount numeric)
RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp
AS $$
  SELECT public.platform_transaction_fee_for(p_amount, NULL, NULL, false);
$$;

COMMENT ON FUNCTION public.platform_transaction_fee(numeric) IS
  'The global-rate commission. Kept as a separate one-argument function '
  'rather than an overload of platform_transaction_fee_for() because '
  'PostgREST cannot disambiguate two candidates (PGRST203).';

REVOKE ALL ON FUNCTION public.platform_transaction_fee(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.platform_transaction_fee(numeric)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 7. deduct_transaction_fee: same signature, same guards, category-aware fee
-- -----------------------------------------------------------------------------
-- Body reproduced from 20260927000062 and changed in ONE place: `v_fee`.
-- Every guard, ledger row, idempotency branch, audit entry and notification
-- is byte-for-byte the same, so the money path itself is not being
-- re-engineered -- only the number it charges.
--
-- p_order_id IS NOT NULL marks a product/booking sale (products and service
-- bookings both bill through `orders`); a ride passes p_ride_id instead. That
-- is what selects between the product commission columns and the general
-- ones, and it is the same signal the two ledger rows are already
-- distinguished by.
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
  v_ctx    record;
  v_fee    numeric;
  v_allow  boolean := public.get_setting_bool('allow_negative_wallet');
  v_txn    public.wallet_transactions;
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

  -- THE ONE CHANGE: resolve the fee for this provider's own category and
  -- city instead of one global rate. Done after the idempotency check and
  -- the wallet lock, and before any money moves, so a provider with no
  -- override still gets exactly the global number.
  SELECT * INTO v_ctx FROM public.provider_fee_context(p_provider_id);
  v_fee := public.platform_transaction_fee_for(
             p_gross_amount, v_ctx.category_id, v_ctx.city, p_order_id IS NOT NULL);

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

REVOKE ALL ON FUNCTION public.deduct_transaction_fee(uuid, uuid, uuid, numeric, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_transaction_fee(uuid, uuid, uuid, numeric, text)
  TO service_role;

-- -----------------------------------------------------------------------------
-- 8. deduct_subscription_fee: same signature, same switch, category-aware fee
-- -----------------------------------------------------------------------------
-- Body reproduced from 20260927000073. The fee_enabled_subscription switch,
-- the idempotency short-circuit, the period-consumed-while-off behaviour, the
-- ledger row, the notification and the low-wallet call are all preserved
-- exactly -- assert_fee_switches_are_wired() checks that this function still
-- reads fee_enabled_subscription, and it does.
CREATE OR REPLACE FUNCTION public.deduct_subscription_fee(p_provider_id uuid, p_period text)
RETURNS public.wallet_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_wallet wallets;
  v_ctx    record;
  v_fee    numeric;
  v_key    text := 'sub:' || p_provider_id::text || ':' || p_period;
  v_existing wallet_transactions;
  v_txn wallet_transactions;
BEGIN
  SELECT * INTO v_existing FROM wallet_transactions WHERE idempotency_key = v_key;
  IF v_existing.id IS NOT NULL THEN
    RETURN v_existing;
  END IF;

  -- The switch. Same shape as the idempotency short-circuit above: the period
  -- is consumed either way, so a switch that is turned back on does not
  -- retro-charge the months it was off.
  IF NOT coalesce(get_setting_bool('fee_enabled_subscription'), true) THEN
    UPDATE subscriptions
       SET last_charged_at = now(),
           next_due_date = next_due_date + interval '1 month',
           status = 'ACTIVE'
     WHERE provider_id = p_provider_id;
    RETURN NULL;
  END IF;

  -- THE ONE CHANGE: this provider's own subscription rate.
  SELECT * INTO v_ctx FROM public.provider_fee_context(p_provider_id);
  v_fee := public.fee_subscription(v_ctx.category_id, v_ctx.city);

  SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'WALLET_NOT_FOUND';
  END IF;

  UPDATE wallets SET balance = balance - v_fee, updated_at = now()
   WHERE id = v_wallet.id
   RETURNING * INTO v_wallet;

  INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, 'SUBSCRIPTION_FEE', v_fee, v_fee, 0, v_wallet.balance, 'COMPLETED', v_key)
  RETURNING * INTO v_txn;

  UPDATE subscriptions SET last_charged_at = now(), next_due_date = next_due_date + interval '1 month', status = 'ACTIVE'
  WHERE provider_id = p_provider_id;

  PERFORM insert_notification(
    (SELECT user_id FROM provider_profiles WHERE id = p_provider_id),
    'SUBSCRIPTION_DUE',
    'Subscription charged',
    v_fee::text || ' birr deducted',
    jsonb_build_object('wallet_id', v_wallet.id, 'fee', v_fee)
  );

  PERFORM maybe_notify_low_wallet(v_wallet, p_provider_id);

  RETURN v_txn;
END;
$$;

REVOKE ALL ON FUNCTION public.deduct_subscription_fee(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_subscription_fee(uuid, text) TO service_role;

-- -----------------------------------------------------------------------------
-- 9. Ride fares: a NEW city-aware entry point, the old one kept
-- -----------------------------------------------------------------------------
-- calculate_fare_estimate() keeps its exact five-parameter signature and
-- delegates with p_city = NULL, which resolves to the category-wide row.
-- Every existing caller -- the ride form, the live map, anything in SQL --
-- is unchanged and cannot be broken by adding a city dimension.
CREATE OR REPLACE FUNCTION public.calculate_fare_estimate_at(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL,
  p_city text DEFAULT NULL
)
RETURNS numeric(12,2)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_distance_km numeric;
  v_base    numeric;
  v_per_km  numeric;
  v_min     numeric;
  v_estimate numeric;
BEGIN
  v_distance_km := round(
    (st_distance(
      st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_dest_lng, p_dest_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  v_base   := public.fee_ride_base_fare(p_vehicle_category_id, p_city);
  v_per_km := public.fee_ride_per_km(p_vehicle_category_id, p_city);
  v_min    := public.fee_ride_minimum_fare(p_vehicle_category_id, p_city);

  v_estimate := GREATEST(v_min, v_base + v_per_km * v_distance_km);
  RETURN round(v_estimate, 2);
END;
$$;

COMMENT ON FUNCTION public.calculate_fare_estimate_at(double precision, double precision, double precision, double precision, uuid, text) IS
  'Fare for a trip in a given vehicle category AND city. The five-argument '
  'calculate_fare_estimate() delegates here with no city, so existing '
  'callers are unaffected.';

GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate_at(double precision, double precision, double precision, double precision, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.calculate_fare_estimate_at(double precision, double precision, double precision, double precision, uuid, text) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL
)
RETURNS numeric(12,2)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.calculate_fare_estimate_at(
    p_pickup_lat, p_pickup_lng, p_dest_lat, p_dest_lng,
    p_vehicle_category_id, NULL);
$$;

GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate(double precision, double precision, double precision, double precision, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.calculate_fare_estimate(double precision, double precision, double precision, double precision, uuid) FROM PUBLIC, anon;

-- create_ride_request stamps the fare. It must stamp the SAME number the
-- rider was shown, so it is restated to call the city-aware entry point. The
-- ride's city is the rider's saved city, which is what the app priced with.
CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text default null,
  p_destination_text text default null,
  p_vehicle_category_id uuid default null
) RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride ride_requests;
  v_status text;
  v_city text;
BEGIN
  IF p_user_id != auth.uid() THEN
    RAISE EXCEPTION 'CANNOT_CREATE_RIDE_FOR_ANOTHER_USER';
  END IF;

  SELECT status::text INTO v_status FROM public.profiles WHERE id = p_user_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND';
  END IF;

  SELECT city INTO v_city FROM public.profiles WHERE id = p_user_id;

  INSERT INTO ride_requests (
    user_id, pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text, vehicle_category_id,
    fare_estimate, status, requested_at
  ) VALUES (
    p_user_id, p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
    p_pickup_text, p_destination_text, p_vehicle_category_id,
    public.calculate_fare_estimate_at(
      p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng,
      p_vehicle_category_id, v_city),
    'REQUESTED', now()
  ) RETURNING * INTO v_ride;

  -- 'RIDE_REQUEST', which IS a member of the notification_type enum. This
  -- said 'RIDE_REQUESTED', which is not, and insert_notification()'s second
  -- parameter is typed `notification_type` -- so the cast raised
  -- `invalid input value for enum notification_type` and the WHOLE ride
  -- request failed, for every rider, on every call.
  --
  -- Neither pglast nor the plpgsql gate can see this: an enum literal is just
  -- a string to the parser, so "the migration parses" said nothing about
  -- whether the value existed. check_notification_types_exist does.
  PERFORM insert_notification(
    p_user_id, 'RIDE_REQUEST', 'Ride requested',
    'Looking for a driver near ' || coalesce(p_pickup_text, 'your location'),
    jsonb_build_object('ride_request_id', v_ride.id));

  RETURN v_ride;
END;
$$;

-- -----------------------------------------------------------------------------
-- 10. Admin read/write surface
-- -----------------------------------------------------------------------------
-- One catalogue for the sidebar screen: every category, every city that has
-- an override, and the EFFECTIVE numbers -- what will actually be charged,
-- not what was typed. An editor that showed the stored NULLs would look
-- broken even when the fallback chain is working perfectly.
CREATE OR REPLACE FUNCTION public.admin_category_fee_catalogue()
RETURNS TABLE (
  category_id uuid,
  category_name text,
  sector text,
  city text,
  has_city_override boolean,
  commission_percent numeric,
  commission_min numeric,
  subscription_fee numeric,
  activation_fee numeric,
  ride_base_fare numeric,
  ride_per_km numeric,
  ride_minimum_fare numeric,
  booking_base_fee numeric,
  booking_per_km numeric,
  booking_minimum_fee numeric,
  product_commission_percent numeric,
  product_commission_min numeric,
  product_listing_fee numeric,
  is_configured boolean,
  updated_at timestamptz,
  updated_by_name text
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
  -- Every active category at its city-wide tier, whether or not an override
  -- exists. This half is what lets the screen show "Bajaj is on the platform
  -- default" instead of hiding Bajaj until someone has touched it.
  SELECT c.id, c.name, c.sector::text, ''::text, false,
         public.fee_commission_percent(c.id, '', false),
         public.fee_commission_min(c.id, '', false),
         public.fee_subscription(c.id, ''),
         public.fee_activation(c.id, ''),
         public.fee_ride_base_fare(c.id, ''),
         public.fee_ride_per_km(c.id, ''),
         public.fee_ride_minimum_fare(c.id, ''),
         public.fee_booking_base_fare(c.id, ''),
         public.fee_booking_per_km(c.id, ''),
         public.fee_booking_minimum_fee(c.id, ''),
         public.fee_commission_percent(c.id, '', true),
         public.fee_commission_min(c.id, '', true),
         coalesce(f.product_listing_fee, 0),
         f.id IS NOT NULL,
         f.updated_at,
         coalesce(up.full_name, '')
    FROM public.categories c
    LEFT JOIN public.category_fee_settings f
           ON f.category_id = c.id AND f.city = ''
    LEFT JOIN public.profiles up ON up.id = f.updated_by
   WHERE c.is_active

  UNION ALL

  -- Plus every city-specific override that actually exists, resolved at its
  -- own city so the admin sees the number that will really be charged.
  SELECT c.id, c.name, c.sector::text, f.city, true,
         public.fee_commission_percent(c.id, f.city, false),
         public.fee_commission_min(c.id, f.city, false),
         public.fee_subscription(c.id, f.city),
         public.fee_activation(c.id, f.city),
         public.fee_ride_base_fare(c.id, f.city),
         public.fee_ride_per_km(c.id, f.city),
         public.fee_ride_minimum_fare(c.id, f.city),
         public.fee_booking_base_fare(c.id, f.city),
         public.fee_booking_per_km(c.id, f.city),
         public.fee_booking_minimum_fee(c.id, f.city),
         public.fee_commission_percent(c.id, f.city, true),
         public.fee_commission_min(c.id, f.city, true),
         coalesce(f.product_listing_fee, 0),
         true,
         f.updated_at,
         coalesce(up.full_name, '')
    FROM public.category_fee_settings f
    JOIN public.categories c ON c.id = f.category_id
    LEFT JOIN public.profiles up ON up.id = f.updated_by
   WHERE f.city <> ''
     AND c.is_active

   ORDER BY 2, 4;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_category_fee_catalogue() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_category_fee_catalogue() TO authenticated, service_role;

-- The write. One row per (category, city). A NULL argument means "inherit the
-- global value", which is what makes the screen usable: clearing a field is
-- how an admin says "go back to the platform default" without deleting the
-- whole row and losing their other overrides.
CREATE OR REPLACE FUNCTION public.admin_save_category_fee(
  p_category_id uuid,
  p_city text DEFAULT '',
  p_commission_percent numeric DEFAULT NULL,
  p_commission_min numeric DEFAULT NULL,
  p_subscription_fee numeric DEFAULT NULL,
  p_activation_fee numeric DEFAULT NULL,
  p_ride_base_fare numeric DEFAULT NULL,
  p_ride_per_km numeric DEFAULT NULL,
  p_ride_minimum_fare numeric DEFAULT NULL,
  p_booking_base_fee numeric DEFAULT NULL,
  p_booking_per_km numeric DEFAULT NULL,
  p_booking_minimum_fee numeric DEFAULT NULL,
  p_product_commission_percent numeric DEFAULT NULL,
  p_product_commission_min numeric DEFAULT NULL,
  p_product_listing_fee numeric DEFAULT NULL
)
RETURNS public.category_fee_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.category_fee_settings;
  v_city text := lower(btrim(coalesce(p_city, '')));
BEGIN
  -- The same gate as admin_update_setting(), so there is one answer to "who
  -- may change what the platform charges".
  IF NOT public.is_fee_editor() THEN
    RAISE EXCEPTION 'ONLY_THE_OWNER_CAN_CHANGE_FEES';
  END IF;

  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'CATEGORY_ID_REQUIRED';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.categories WHERE id = p_category_id) THEN
    RAISE EXCEPTION 'CATEGORY_NOT_FOUND';
  END IF;

  -- Shape check, not a membership check. The app's city list lives in Dart
  -- (lib/core/utils/ethiopia_cities.dart) and has no table behind it, so the
  -- only honest server-side test is that the name is a plausible city name.
  -- Checking membership against a hardcoded SQL list would reject a city the
  -- app genuinely offers, and checking against profiles.city would reject a
  -- city nobody has registered in yet -- which is exactly the new city an
  -- admin most wants to price differently.
  IF v_city <> '' AND v_city !~ '^[a-z][a-z .''-]*$' THEN
    RAISE EXCEPTION 'CITY_NAME_IS_NOT_A_CITY_NAME';
  END IF;

  INSERT INTO public.category_fee_settings AS f (
    category_id, city,
    commission_percent, commission_min, subscription_fee, activation_fee,
    ride_base_fare, ride_per_km, ride_minimum_fare,
    booking_base_fee, booking_per_km, booking_minimum_fee,
    product_commission_percent, product_commission_min, product_listing_fee
  ) VALUES (
    p_category_id, v_city,
    p_commission_percent, p_commission_min, p_subscription_fee,
    p_activation_fee,
    p_ride_base_fare, p_ride_per_km, p_ride_minimum_fare,
    p_booking_base_fee, p_booking_per_km, p_booking_minimum_fee,
    p_product_commission_percent, p_product_commission_min,
    p_product_listing_fee
  )
  ON CONFLICT (category_id, city) DO UPDATE SET
    commission_percent = EXCLUDED.commission_percent,
    commission_min = EXCLUDED.commission_min,
    subscription_fee = EXCLUDED.subscription_fee,
    activation_fee = EXCLUDED.activation_fee,
    ride_base_fare = EXCLUDED.ride_base_fare,
    ride_per_km = EXCLUDED.ride_per_km,
    ride_minimum_fare = EXCLUDED.ride_minimum_fare,
    booking_base_fare = EXCLUDED.booking_base_fee,
    booking_per_km = EXCLUDED.booking_per_km,
    booking_minimum_fee = EXCLUDED.booking_minimum_fee,
    product_commission_percent = EXCLUDED.product_commission_percent,
    product_commission_min = EXCLUDED.product_commission_min,
    product_listing_fee = EXCLUDED.product_listing_fee,
    updated_at = now(),
    updated_by = auth.uid()
  RETURNING * INTO v_row;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'CATEGORY_FEE_UPDATED', 'category_fee_settings', v_row.id,
          jsonb_build_object(
            'category_id', p_category_id,
            'city', v_city,
            'commission_percent', p_commission_percent,
            'commission_min', p_commission_min,
            'subscription_fee', p_subscription_fee,
            'activation_fee', p_activation_fee,
            'ride_base_fare', p_ride_base_fare,
            'ride_per_km', p_ride_per_km,
            'ride_minimum_fare', p_ride_minimum_fare,
            'booking_base_fare', p_booking_base_fee,
            'booking_per_km', p_booking_per_km,
            'booking_minimum_fee', p_booking_minimum_fee,
            'product_commission_percent', p_product_commission_percent,
            'product_commission_min', p_product_commission_min,
            'product_listing_fee', p_product_listing_fee));

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_save_category_fee(uuid, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_category_fee(uuid, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) TO authenticated, service_role;

-- "Go back to the platform default for this category and city."
CREATE OR REPLACE FUNCTION public.admin_clear_category_fee(
  p_category_id uuid,
  p_city text DEFAULT ''
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.is_fee_editor() THEN
    RAISE EXCEPTION 'ONLY_THE_OWNER_CAN_CHANGE_FEES';
  END IF;

  DELETE FROM public.category_fee_settings
   WHERE category_id = p_category_id
     AND city = lower(btrim(coalesce(p_city, '')));

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_OVERRIDE_TO_CLEAR';
  END IF;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (auth.uid(), 'CATEGORY_FEE_CLEARED', 'category_fee_settings',
          p_category_id, jsonb_build_object('city', lower(btrim(coalesce(p_city, '')))));

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_clear_category_fee(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_clear_category_fee(uuid, text) TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 11. A report the connectivity suite can read, and an assertion
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.category_fee_surface_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rows int;
  v_cats int;
  v_ctx  int;
  v_ride int;
  v_sub  int;
  v_comm int;
  v_writes int;
BEGIN
  SELECT count(*) INTO v_rows FROM public.category_fee_settings;
  SELECT count(*) INTO v_cats FROM public.categories WHERE is_active;

  SELECT count(*) INTO v_ctx FROM pg_proc
   WHERE proname = 'provider_fee_context'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_ride FROM pg_proc
   WHERE proname = 'fee_ride_per_km'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_sub FROM pg_proc
   WHERE proname = 'fee_subscription'
     AND pronamespace = 'public'::regnamespace;
  SELECT count(*) INTO v_comm FROM pg_proc
   WHERE proname = 'platform_transaction_fee_for'
     AND pronamespace = 'public'::regnamespace;

  SELECT count(*) INTO v_writes FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'category_fee_settings'
     AND policyname NOT LIKE '%read%';

  -- Every money column must still be nullable: that is the property that
  -- makes an empty table cost nothing.
  RETURN format(
    'override rows=%s; active categories=%s; funcs provider_fee_context=%s '
    'fee_ride_per_km=%s fee_subscription=%s platform_transaction_fee_for=%s; '
    'client write policies=%s; nullability preserved=%s',
    v_rows, v_cats, v_ctx, v_ride, v_sub, v_comm, v_writes,
    (SELECT bool_and(is_nullable)
       FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'category_fee_settings'
        AND column_name IN (
          'commission_percent','commission_min','subscription_fee',
          'activation_fee','ride_base_fare','ride_per_km',
          'ride_minimum_fare','booking_base_fee','booking_per_km',
          'booking_minimum_fee','product_commission_percent',
          'product_commission_min','product_listing_fee')));
END;
$$;

REVOKE ALL ON FUNCTION public.category_fee_surface_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.category_fee_surface_report()
  TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.assert_category_fees_are_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
BEGIN
  -- The table exists, and every money column is still nullable.
  IF to_regclass('public.category_fee_settings') IS NULL THEN
    RAISE EXCEPTION 'category_fee_settings is missing';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public' AND table_name = 'category_fee_settings'
       AND column_name IN ('commission_percent','commission_min',
                           'subscription_fee','activation_fee',
                           'ride_base_fare','ride_per_km','ride_minimum_fare')
       AND is_nullable <> 'YES'
  ) THEN
    RAISE EXCEPTION 'a category fee column is NOT NULL -- an empty table would no longer mean "inherit the global rate"';
  END IF;

  -- The three money paths must consult the resolver, not a global setting.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = 'deduct_subscription_fee'
       AND pronamespace = 'public'::regnamespace
       AND prosrc LIKE '%fee_subscription%'
  ) THEN
    RAISE EXCEPTION 'deduct_subscription_fee no longer reads fee_subscription() -- a per-category subscription rate would be silently ignored';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = 'deduct_transaction_fee'
       AND pronamespace = 'public'::regnamespace
       AND prosrc LIKE '%platform_transaction_fee_for%'
  ) THEN
    RAISE EXCEPTION 'deduct_transaction_fee no longer reads platform_transaction_fee_for() -- a per-category commission would be silently ignored';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE proname = 'calculate_fare_estimate_at'
       AND pronamespace = 'public'::regnamespace
  ) THEN
    RAISE EXCEPTION 'calculate_fare_estimate_at is missing -- the city-aware fare entry point does not exist';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_category_fees_are_wired() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_category_fees_are_wired()
  TO anon, authenticated, service_role;

-- PostgREST caches the function list; without this the new RPCs 404 until the
-- next schema reload.
NOTIFY pgrst, 'reload schema';
