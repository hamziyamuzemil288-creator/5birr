-- Points: earn from more than trades, tell the earner, and let the CEO set
-- what a point is worth in birr and convert it.
--
-- WHAT ALREADY EXISTED, AND IS REUSED RATHER THAN REBUILT
-- ------------------------------------------------------
-- 0028_points_system.sql already built the two-table shape this brief asks
-- for: `points_ledger` (immutable, UNIQUE(source_type, source_id, subject_id)
-- so an award is idempotent) and `user_points` (the total, bumped only when
-- the ledger insert actually landed). It awards on orders and rides reaching
-- COMPLETED, to both sides. RLS is self-read + admin-read with no client
-- write policy, and PointsService already reads it.
--
-- So this migration does NOT add a second points system. It fills the four
-- gaps that make it the feature the brief describes:
--
--   1. AWARD SOURCES. Only ORDER and RIDE existed, and both CHECK constraints
--      said so. A provider's first approval, a positive review and a wallet
--      recharge earned nothing.
--   2. AMOUNTS. One knob, `points_per_trade` (default 1), drove both sides of
--      both sources. The brief names five separate amounts, and a ladder whose
--      last rung is 200,000 points cannot be reached at one point per trade.
--      Each is now its own system_settings key, read at award time.
--   3. NOTIFICATIONS. The ledger row was written and the earner was never
--      told. One notification per award — one per transaction, never one per
--      point.
--   4. CONVERSION. There was no way to spend points. There is now, at a rate
--      the CEO sets, debiting the ledger so the audit stays complete.
--
-- ONE THING THIS DELIBERATELY DOES NOT DO
-- ---------------------------------------
-- A conversion credits a WALLET, and a wallet belongs to a provider profile
-- (`wallets.provider_id`, unique, NOT NULL) — there is no user wallet in this
-- schema, and `profiles` carries no balance. So a caller with no provider
-- profile has nowhere to receive birr and is told so rather than being given
-- a second, parallel money store. Their points are not lost: they convert the
-- moment they hold a provider profile ("Become a Partner"). Extending
-- `wallets` to users is a money-schema change and is left for a deliberate
-- decision, not folded in here.

-- ===========================================================================
-- 1. Settings
--
-- trg_system_settings_security refuses every write unless is_admin() — which
-- is auth.uid()-derived, and so is false for a migration connection. 0028
-- lifted it briefly for its own seed and this follows that precedent exactly.
-- ===========================================================================
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

INSERT INTO public.system_settings (key, value, description) VALUES
  ('points_per_order', '50'::jsonb,
   'Points awarded to each side when an order reaches COMPLETED (set 0 to stop awarding)'),
  ('points_per_ride', '50'::jsonb,
   'Points awarded to each side when a ride reaches COMPLETED (set 0 to stop awarding)'),
  ('points_per_review', '25'::jsonb,
   'Points awarded to a provider for a review of 4 or 5 stars (set 0 to stop awarding)'),
  ('points_per_recharge', '20'::jsonb,
   'Points awarded to a provider when a wallet recharge is approved (set 0 to stop awarding)'),
  ('points_first_provider_approval', '100'::jsonb,
   'Points awarded once, on the first approval of a provider profile'),
  ('points_to_birr_rate', '0.01'::jsonb,
   'Birr credited per point converted to a wallet. 0.01 means 100 points = 1 ETB. Must be above 0 and at most 1'),
  ('points_conversion_minimum', '100'::jsonb,
   'Smallest number of points a single conversion may spend')
ON CONFLICT (key) DO NOTHING;

-- Superseded by the two per-source keys above. Left behind it would be a knob
-- that reads as live and changes nothing, so it is removed rather than
-- documented as dead.
DELETE FROM public.system_settings WHERE key = 'points_per_trade';

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;

-- ===========================================================================
-- 2. Ledger: more sources, and a reason worth reading
-- ===========================================================================
ALTER TABLE public.points_ledger
  ADD COLUMN IF NOT EXISTS reason text;

-- The CHECK is dropped by definition-matching rather than by a guessed name:
-- the constraint was declared inline in 0028, so its generated name depends on
-- how PostgreSQL named it, and a wrong guess would leave the old CHECK in
-- place and reject every new source with a confusing message.
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT con.conname
      FROM pg_constraint con
      JOIN pg_class rel ON rel.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
     WHERE n.nspname = 'public'
       AND rel.relname = 'points_ledger'
       AND con.contype = 'c'
       AND pg_get_constraintdef(con.oid) ILIKE '%source_type%'
  LOOP
    EXECUTE format('ALTER TABLE public.points_ledger DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE public.points_ledger
  ADD CONSTRAINT points_ledger_source_type_check
  CHECK (source_type IN ('ORDER', 'RIDE', 'REVIEW', 'APPROVAL', 'RECHARGE', 'CONVERSION', 'ADJUSTMENT'));

-- A zero-point row is not an award and not a redemption; it is noise in an
-- immutable table.
ALTER TABLE public.points_ledger
  DROP CONSTRAINT IF EXISTS points_ledger_points_not_zero;
ALTER TABLE public.points_ledger
  ADD CONSTRAINT points_ledger_points_not_zero CHECK (points <> 0);

COMMENT ON TABLE public.points_ledger IS
  'Immutable points audit. One row per awarded or redeemed transaction (never '
  'per point). UNIQUE(source_type, source_id, subject_id) makes an award '
  'idempotent; a CONVERSION uses a fresh source_id so each redemption is its '
  'own row.';

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'POINTS_REDEEMED';

-- ===========================================================================
-- 3. award_points — the single writer of both tables
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.award_points(
  p_subject_type text,
  p_subject_id uuid,
  p_source_type text,
  p_source_id uuid,
  p_points integer,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ledger_id uuid;
BEGIN
  IF p_subject_id IS NULL OR p_source_id IS NULL OR p_points IS NULL OR p_points = 0 THEN
    RETURN NULL;
  END IF;

  IF p_subject_type NOT IN ('USER', 'PROVIDER') THEN
    RAISE EXCEPTION 'UNKNOWN_POINTS_SUBJECT_%', p_subject_type;
  END IF;

  -- The ledger is the record; the total is the cache. Insert first, and only
  -- bump the total if this insert was the one that landed.
  INSERT INTO public.points_ledger
    (subject_type, subject_id, source_type, source_id, points, reason)
  VALUES
    (p_subject_type, p_subject_id, p_source_type, p_source_id, p_points, p_reason)
  ON CONFLICT (source_type, source_id, subject_id) DO NOTHING
  RETURNING id INTO v_ledger_id;

  IF v_ledger_id IS NULL THEN
    -- Already awarded. A COMPLETED -> DISPUTED -> COMPLETED round trip, or a
    -- replayed approval, must not pay twice.
    RETURN NULL;
  END IF;

  INSERT INTO public.user_points (subject_type, subject_id, points)
  VALUES (p_subject_type, p_subject_id, p_points)
  ON CONFLICT (subject_type, subject_id)
  DO UPDATE SET points = public.user_points.points + p_points, updated_at = now();

  RETURN v_ledger_id;
END;
$$;

COMMENT ON FUNCTION public.award_points(text, uuid, text, uuid, integer, text) IS
  'The only writer of points_ledger and user_points. Returns the new ledger id, '
  'or NULL when the award already existed.';

-- Nothing a client can call. A callable award function would be a mint.
REVOKE ALL ON FUNCTION public.award_points(text, uuid, text, uuid, integer, text)
  FROM public, anon, authenticated;

-- ===========================================================================
-- 4. One notification per award
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_points_awarded()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_note text;
BEGIN
  -- A USER subject is an auth user; a PROVIDER subject is a provider profile
  -- and has to be resolved back to the person who owns it.
  IF NEW.subject_type = 'USER' THEN
    v_user_id := NEW.subject_id;
  ELSE
    SELECT user_id INTO v_user_id
      FROM public.provider_profiles WHERE id = NEW.subject_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_note := NULLIF(btrim(coalesce(NEW.reason, '')), '');

  IF NEW.points > 0 THEN
    PERFORM public.notify_user(
      v_user_id, 'POINTS_EARNED', 'Points earned',
      '+' || NEW.points::text || ' points' || coalesce(' — ' || v_note, ''),
      jsonb_build_object(
        'points', NEW.points,
        'source_type', NEW.source_type,
        'source_id', NEW.source_id
      ));
  ELSE
    PERFORM public.notify_user(
      v_user_id, 'POINTS_REDEEMED', 'Points converted',
      abs(NEW.points)::text || ' points spent' || coalesce(' — ' || v_note, ''),
      jsonb_build_object(
        'points', NEW.points,
        'source_type', NEW.source_type,
        'source_id', NEW.source_id
      ));
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_points_ledger_notify ON public.points_ledger;
CREATE TRIGGER trg_points_ledger_notify
  AFTER INSERT ON public.points_ledger
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_points_awarded();

-- ===========================================================================
-- 5. Re-point the two existing award paths at their own settings keys
--    (same triggers, same idempotency, now settings-driven and notifying)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_award_order_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_points integer := coalesce(public.get_setting_numeric('points_per_order'), 0)::integer;
BEGIN
  IF v_points <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.award_points('USER', NEW.user_id, 'ORDER', NEW.id, v_points, 'Order completed');
  PERFORM public.award_points('PROVIDER', NEW.provider_id, 'ORDER', NEW.id, v_points, 'Order completed');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_orders_points ON public.orders;
CREATE TRIGGER trg_orders_points
  AFTER UPDATE ON public.orders
  FOR EACH ROW
  WHEN (NEW.status = 'COMPLETED' AND OLD.status IS DISTINCT FROM 'COMPLETED')
  EXECUTE FUNCTION public.fn_award_order_points();

CREATE OR REPLACE FUNCTION public.fn_award_ride_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_points integer := coalesce(public.get_setting_numeric('points_per_ride'), 0)::integer;
BEGIN
  IF v_points <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.award_points('USER', NEW.user_id, 'RIDE', NEW.id, v_points, 'Ride completed');

  -- An unclaimed ride completed with no provider on it.
  IF NEW.claimed_by_provider_id IS NOT NULL THEN
    PERFORM public.award_points('PROVIDER', NEW.claimed_by_provider_id, 'RIDE', NEW.id,
                                v_points, 'Ride completed');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_rides_points ON public.ride_requests;
CREATE TRIGGER trg_rides_points
  AFTER UPDATE ON public.ride_requests
  FOR EACH ROW
  WHEN (NEW.status = 'COMPLETED' AND OLD.status IS DISTINCT FROM 'COMPLETED')
  EXECUTE FUNCTION public.fn_award_ride_points();

-- ===========================================================================
-- 6. New award paths
-- ===========================================================================

-- A provider's first approval. "First" is enforced by the ledger's unique key
-- rather than by a flag: source_id is the provider profile, so an approval
-- after a suspension-and-reinstate pays nothing more.
CREATE OR REPLACE FUNCTION public.fn_award_provider_approval_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_points integer := coalesce(public.get_setting_numeric('points_first_provider_approval'), 0)::integer;
BEGIN
  IF v_points <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.award_points('PROVIDER', NEW.id, 'APPROVAL', NEW.id, v_points,
                              'Application approved');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_profiles_points ON public.provider_profiles;
CREATE TRIGGER trg_provider_profiles_points
  AFTER UPDATE ON public.provider_profiles
  FOR EACH ROW
  WHEN (NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED')
  EXECUTE FUNCTION public.fn_award_provider_approval_points();

-- A positive review. 4 or 5 stars only: the point of the award is to reward
-- being rated well, and the ledger has no way to take it back.
CREATE OR REPLACE FUNCTION public.fn_award_review_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_points integer := coalesce(public.get_setting_numeric('points_per_review'), 0)::integer;
BEGIN
  -- target_type PROVIDER is the only one that has a points subject: a review
  -- of a PRODUCT or VEHICLE has no owner balance to credit.
  IF NEW.target_type <> 'PROVIDER' OR NEW.rating < 4 OR v_points <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.award_points('PROVIDER', NEW.target_id, 'REVIEW', NEW.id, v_points,
                              'Positive review received');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_reviews_points ON public.reviews;
CREATE TRIGGER trg_reviews_points
  AFTER INSERT ON public.reviews
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_award_review_points();

-- A wallet recharge, once the money is actually in the wallet.
CREATE OR REPLACE FUNCTION public.fn_award_recharge_points()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_points integer := coalesce(public.get_setting_numeric('points_per_recharge'), 0)::integer;
BEGIN
  IF v_points <= 0 THEN
    RETURN NEW;
  END IF;

  PERFORM public.award_points('PROVIDER', NEW.provider_id, 'RECHARGE', NEW.id, v_points,
                              'Wallet recharged');

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_recharge_points ON public.wallet_recharge_requests;
CREATE TRIGGER trg_recharge_points
  AFTER UPDATE ON public.wallet_recharge_requests
  FOR EACH ROW
  WHEN (NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED')
  EXECUTE FUNCTION public.fn_award_recharge_points();

-- ===========================================================================
-- 7. Conversion — server-side, atomic, and in the ledger
-- ===========================================================================
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
  'the audit stays complete. The birr amount is always computed here, never by '
  'the client.';

REVOKE ALL ON FUNCTION public.convert_points_to_wallet(text, integer, uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.convert_points_to_wallet(text, integer, uuid)
  TO authenticated, service_role;

-- ===========================================================================
-- 8. Admin settings editor RPC
--
-- system_settings has SELECT granted to authenticated (0011) but its write
-- privileges were removed by the client-write-surface work, and
-- trg_system_settings_security refuses every non-admin write. A settings
-- editor therefore has to be a function: admin-gated here, and again by the
-- trigger underneath.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.validate_rank_tiers(p_value jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_prev integer := -1;
  v_count integer;
  v_tier jsonb;
  v_min integer;
  v_code text;
  v_seen text[] := ARRAY[]::text[];
BEGIN
  IF jsonb_typeof(p_value) <> 'array' THEN
    RETURN 'RANK_TIERS_MUST_BE_A_JSON_ARRAY';
  END IF;

  v_count := jsonb_array_length(p_value);
  IF v_count < 2 THEN
    RETURN 'RANK_TIERS_NEEDS_AT_LEAST_TWO_TIERS';
  END IF;

  FOR v_tier IN SELECT * FROM jsonb_array_elements(p_value) LOOP
    IF jsonb_typeof(v_tier) <> 'object' THEN
      RETURN 'EACH_RANK_TIER_MUST_BE_AN_OBJECT';
    END IF;
    IF jsonb_typeof(v_tier -> 'min_points') <> 'number' THEN
      RETURN 'EACH_RANK_TIER_NEEDS_A_NUMERIC_min_points';
    END IF;
    v_code := btrim(coalesce(v_tier ->> 'code', ''));
    IF v_code = '' THEN
      RETURN 'EACH_RANK_TIER_NEEDS_A_code';
    END IF;
    IF btrim(coalesce(v_tier ->> 'name', '')) = '' THEN
      RETURN 'EACH_RANK_TIER_NEEDS_A_name';
    END IF;
    IF v_code = ANY (v_seen) THEN
      RETURN 'RANK_TIER_CODES_MUST_BE_UNIQUE';
    END IF;
    v_seen := v_seen || v_code;

    v_min := (v_tier ->> 'min_points')::integer;
    IF v_min < 0 THEN
      RETURN 'min_points_CANNOT_BE_NEGATIVE';
    END IF;
    -- Ascending, so "the next tier" is well defined and the ladder is walkable
    -- in the order it is stored.
    IF v_min <= v_prev THEN
      RETURN 'RANK_TIERS_MUST_ASCEND_BY_min_points';
    END IF;
    v_prev := v_min;
  END LOOP;

  RETURN NULL;
END;
$$;

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
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'SYSTEM_SETTINGS_CAN_ONLY_BE_MODIFIED_BY_ADMINISTRATORS';
  END IF;

  IF p_key IS NULL OR btrim(p_key) = '' THEN
    RAISE EXCEPTION 'SETTING_KEY_REQUIRED';
  END IF;
  IF p_value IS NULL OR p_value = 'null'::jsonb THEN
    RAISE EXCEPTION 'SETTING_VALUE_REQUIRED';
  END IF;

  SELECT value INTO v_old FROM public.system_settings WHERE key = p_key;

  -- Shape is preserved per key. get_setting_numeric() casts
  -- (value #>> '{}')::numeric, so flipping a numeric key to a string turns
  -- every reader into a runtime cast failure; the same holds for
  -- get_setting_bool(). Caught here, where there is a message.
  IF v_old IS NOT NULL THEN
    IF jsonb_typeof(v_old) IN ('number', 'boolean')
       AND jsonb_typeof(v_old) <> jsonb_typeof(p_value) THEN
      RAISE EXCEPTION 'SETTING_%_MUST_STAY_A_%', p_key, upper(jsonb_typeof(v_old));
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
      'new_value', p_value
    )
  );

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.admin_update_setting(text, jsonb, text) IS
  'The only client path that writes system_settings. Admin-gated, type-checked '
  'per key so a reader cannot be broken by a shape change, and audited.';

REVOKE ALL ON FUNCTION public.admin_update_setting(text, jsonb, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_setting(text, jsonb, text)
  TO authenticated, service_role;

-- ===========================================================================
-- 9. Assertions
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_points_awards_are_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pair record;
  v_src text;
BEGIN
  -- Every award path must exist, must be attached to its table as a trigger,
  -- and must route through award_points (the one writer of both tables).
  FOR v_pair IN
    SELECT * FROM (VALUES
      ('orders',                  'trg_orders_points',              'fn_award_order_points'),
      ('ride_requests',           'trg_rides_points',               'fn_award_ride_points'),
      ('provider_profiles',       'trg_provider_profiles_points',   'fn_award_provider_approval_points'),
      ('reviews',                 'trg_reviews_points',             'fn_award_review_points'),
      ('wallet_recharge_requests','trg_recharge_points',            'fn_award_recharge_points')
    ) AS t(tbl, trg, fn)
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger tg
        JOIN pg_class c ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public'
         AND c.relname = v_pair.tbl
         AND tg.tgname = v_pair.trg
         AND NOT tg.tgisinternal
    ) THEN
      RETURN false;
    END IF;

    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_pair.fn;

    IF v_src IS NULL OR position('award_points' in v_src) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  -- ...and the ledger must be the source of truth for the total, for every
  -- subject active in the last 7 days. A mismatch means an award bumped one
  -- and not the other — the same drift class as a wallet balance that does not
  -- equal its ledger.
  RETURN NOT EXISTS (
    SELECT 1
      FROM public.user_points up
     WHERE up.updated_at > now() - interval '7 days'
       AND up.points <> coalesce((
             SELECT sum(pl.points) FROM public.points_ledger pl
              WHERE pl.subject_type = up.subject_type
                AND pl.subject_id = up.subject_id
           ), 0)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.assert_points_conversion_is_configurable()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_keys text[] := ARRAY[
    'points_per_order', 'points_per_ride', 'points_per_review',
    'points_per_recharge', 'points_first_provider_approval',
    'points_to_birr_rate', 'points_conversion_minimum'
  ];
  v_key text;
  v_value jsonb;
BEGIN
  FOREACH v_key IN ARRAY v_keys LOOP
    SELECT value INTO v_value FROM public.system_settings WHERE key = v_key;
    IF v_value IS NULL OR jsonb_typeof(v_value) <> 'number' THEN
      RETURN false;
    END IF;
  END LOOP;

  -- The rate is money and must be usable as one: above zero, at most one birr
  -- per point.
  SELECT value INTO v_value FROM public.system_settings WHERE key = 'points_to_birr_rate';
  IF (v_value #>> '{}')::numeric <= 0 OR (v_value #>> '{}')::numeric > 1 THEN
    RETURN false;
  END IF;

  -- The superseded knob must be gone, so nobody tunes a setting that does
  -- nothing.
  IF EXISTS (SELECT 1 FROM public.system_settings WHERE key = 'points_per_trade') THEN
    RETURN false;
  END IF;

  -- A conversion that cannot be called is not a feature.
  RETURN has_function_privilege(
    'authenticated',
    'public.convert_points_to_wallet(text, integer, uuid)',
    'EXECUTE'
  );
END;
$$;

REVOKE ALL ON FUNCTION public.assert_points_awards_are_wired()
  FROM public, anon, authenticated;
REVOKE ALL ON FUNCTION public.assert_points_conversion_is_configurable()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_points_awards_are_wired()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_points_conversion_is_configurable()
  TO anon, authenticated, service_role;
