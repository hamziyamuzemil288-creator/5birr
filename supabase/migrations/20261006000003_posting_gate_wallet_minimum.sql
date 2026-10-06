-- =============================================================================
-- 20261006000003 - the posting gate, enforced: wallet minimum + posting fee
-- =============================================================================
--
-- Migration 0113 made `provider_fulfilment_blockers()` the single server
-- authority for "may this provider work", and 0117 made the create paths
-- refuse with the reason list. What was missing is the admin-configured
-- half of the posting gate:
--
--   * a MINIMUM WALLET BALANCE a provider must hold before posting
--     (`posting_min_wallet_balance`, 0 = disabled);
--   * an optional FEE charged from the wallet each time a listing is created
--     (`posting_fee`, 0 = disabled), logged in wallet_transactions.
--
-- The document-verification half already exists: `enforce_verified_documents`
-- (0113) is the admin switch, and the app's posting checklist reads the same
-- server function this migration extends, so client and server cannot drift.
--
-- WHAT CHANGES
--
--   1. Two new system_settings rows, seeded 0 (off) — the requested behaviour
--      is available, and nothing changes until the CEO turns a knob.
--   2. `provider_fulfilment_blockers()` gains WALLET_BELOW_MINIMUM when the
--      balance is below GREATEST(posting_min_wallet_balance, posting_fee).
--      Every existing code and their order are untouched; the new code is
--      appended, and the app folds any WALLET_* code into the same checklist
--      step ("Wallet recharge"), so one row covers both knobs.
--   3. `create_provider_product()` (same signature, so every installed app
--      keeps working) charges the posting fee AFTER a successful insert and
--      writes the ledger row, audit log and notification — same shape as
--      deduct_transaction_fee(), so the wallet screen, the income readers
--      and the low-wallet notifier all see it with no further change.
--   4. `assert_posting_gate_is_wired()` reads pg_proc source text (no user
--      data) and is registered in the anon-role connectivity suite.
--
-- LEDGER SHAPE — read before changing the fee row
--
-- assert_income_ledger_consistent() compares each wallet's balance with the
-- SUM of that wallet's COMPLETED net_amount. A fee row whose net_amount
-- disagrees with the balance movement it caused therefore plants drift. The
-- row below writes net_amount = -fee — the exact delta — while gross_amount
-- and platform_fee carry the fee so the platform income readers (which sum
-- platform_fee over TRANSACTION_FEE) count it. The transaction type is
-- TRANSACTION_FEE rather than a new enum value on purpose: ADD VALUE cannot
-- be used in the same transaction that inserts rows, and the existing type
-- is already labelled, filtered and counted correctly everywhere.
--
-- IDEMPOTENCY: one row per product, key `posting_fee:<product_id>`. A
-- retried insert creates a NEW product (the create path has no idempotency
-- of its own), so each product pays once and the key can never collide.
--
-- =============================================================================

SET search_path = public, pg_temp;

-- -----------------------------------------------------------------------------
-- 1. The admin knobs
-- -----------------------------------------------------------------------------
--
-- `system_settings` carries trg_system_settings_security ->
-- prevent_system_settings_self_modification() -> is_admin() -> auth.uid(),
-- and a migration connection has no JWT, so auth.uid() is NULL and the guard
-- raises SETTINGS_ARE_ADMIN_ONLY regardless of role. 0113 hit exactly this.
-- The trigger is discovered from pg_trigger (by its guard FUNCTION, so a
-- rename cannot hide it) and lifted session-locally for the seed only — every
-- app-level write stays guarded exactly as before.
do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings disable trigger %I', r.tgname);
  end loop;
end $$;

INSERT INTO public.system_settings (key, value, description)
VALUES (
  'posting_min_wallet_balance',
  '0'::jsonb,
  'Minimum wallet balance, in ETB, a provider must hold before they may post '
  'a listing. 0 disables the minimum. provider_fulfilment_blockers() refuses '
  'with WALLET_BELOW_MINIMUM when the wallet is short, the app posting '
  'checklist shows this figure as the wallet step, and the check re-runs on '
  'every attempt — a balance that drops below the minimum blocks the next '
  'listing, not past ones.'
),
(
  'posting_fee',
  '0'::jsonb,
  'Optional fee, in ETB, charged from the provider wallet each time a listing '
  'is created. 0 disables it. Charged after the insert succeeds, logged as a '
  'TRANSACTION_FEE row keyed posting_fee:<product_id> (visible in the wallet '
  'screen and counted as platform income), and the gate requires the wallet '
  'to cover it before posting.'
)
ON CONFLICT (key) DO NOTHING;

do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings enable trigger %I', r.tgname);
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- 2. provider_fulfilment_blockers() — restated with WALLET_BELOW_MINIMUM
-- -----------------------------------------------------------------------------
--
-- Body from 0113 with one addition. The wallet balance is now read once,
-- up front, because two checks need it (the pre-existing WALLET_EMPTY rule,
-- which stays behind allow_negative_wallet exactly as it was, and the new
-- minimum, which is NOT behind that switch: the minimum is the CEO's posting
-- rule, not a consequence of negative-balance tolerance). Existing codes keep
-- their order; the new code is appended after WALLET_EMPTY.
CREATE OR REPLACE FUNCTION public.provider_fulfilment_blockers(p_provider_id uuid)
RETURNS text[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id    uuid;
  v_status     text;
  v_fee_paid   boolean;
  v_balance    numeric;
  v_allow_neg  boolean := public.get_setting_bool('allow_negative_wallet');
  v_enforce    boolean := public.get_setting_bool('enforce_verified_documents');
  v_min_wallet numeric := COALESCE(public.get_setting_numeric('posting_min_wallet_balance'), 0);
  v_post_fee   numeric := COALESCE(public.get_setting_numeric('posting_fee'), 0);
  v_required   numeric;
  v_out        text[] := '{}'::text[];
BEGIN
  IF p_provider_id IS NULL THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  SELECT pp.user_id, pp.status, pp.registration_fee_paid
    INTO v_user_id, v_status, v_fee_paid
    FROM public.provider_profiles pp
   WHERE pp.id = p_provider_id;

  IF NOT FOUND THEN
    RETURN ARRAY['PROVIDER_NOT_FOUND']::text[];
  END IF;

  -- A suspended profile is already the subscription scheduler's own verdict
  -- (it sets SUSPENDED when the monthly fee cannot be paid), so that is the
  -- only status word worth giving: it names the cause, and it tells the
  -- provider to recharge rather than to contact support.
  IF v_status IS DISTINCT FROM 'APPROVED' THEN
    v_out := v_out || ARRAY[
      CASE WHEN v_status = 'SUSPENDED'
           THEN 'SUBSCRIPTION_UNPAID'
           ELSE 'ACCOUNT_NOT_APPROVED' END];
  END IF;

  IF COALESCE(v_fee_paid, false) IS NOT TRUE THEN
    v_out := v_out || ARRAY['ACTIVATION_FEE_UNPAID']::text[];
  END IF;

  IF v_enforce AND NOT public.provider_documents_verified(v_user_id) THEN
    v_out := v_out || ARRAY['DOCUMENTS_UNVERIFIED']::text[];
  END IF;

  -- The wallet, in two rules that share one read.
  SELECT balance INTO v_balance
    FROM public.wallets WHERE provider_id = p_provider_id;

  -- An unfunded provider cannot cover the platform fee, and the failure would
  -- otherwise surface at the moment a buyer is waiting. Unchanged from 0113.
  IF NOT v_allow_neg AND COALESCE(v_balance, 0) <= 0 THEN
    v_out := v_out || ARRAY['WALLET_EMPTY']::text[];
  END IF;

  -- The admin's posting minimum (this migration): the wallet must hold at
  -- least posting_min_wallet_balance AND enough headroom to cover the
  -- optional posting_fee. One code covers both knobs because the remedy is
  -- identical — recharge — and the app folds every WALLET_* code into the
  -- same checklist step. Runs even when allow_negative_wallet is on: that
  -- switch tolerates negative balances for fees, it does not waive the CEO's
  -- posting rule.
  v_required := GREATEST(v_min_wallet, COALESCE(v_post_fee, 0));
  IF v_required > 0 AND COALESCE(v_balance, 0) < v_required THEN
    v_out := v_out || ARRAY['WALLET_BELOW_MINIMUM']::text[];
  END IF;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.provider_fulfilment_blockers(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_fulfilment_blockers(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.provider_fulfilment_blockers(uuid) IS
  'Every reason this provider may not post a listing, add a vehicle, claim a '
  'ride or accept an order. Empty array = may work. Exists so a refusal can '
  'name itself instead of saying "you cannot do that". Since 20261006000003 '
  'also enforces the admin posting minimum: WALLET_BELOW_MINIMUM when the '
  'wallet is below GREATEST(posting_min_wallet_balance, posting_fee).';

-- -----------------------------------------------------------------------------
-- 3. create_provider_product() — restated: same signature, optional fee
-- -----------------------------------------------------------------------------
--
-- Signature and gate verbatim from 20260927000117 (which is verbatim from
-- 20260924000004 apart from the refusal message). The grants are restated
-- for the record: a CREATE OR REPLACE that dropped them would leave the one
-- path a new provider uses first unreachable.
CREATE OR REPLACE FUNCTION public.create_provider_product(
  p_provider_id uuid,
  p_name text,
  p_description text,
  p_price numeric,
  p_category_id uuid,
  p_quantity integer,
  p_price_per_unit numeric DEFAULT 0,
  p_unit text DEFAULT NULL,
  p_is_available boolean DEFAULT true,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_product public.products;
  v_blockers text[];
  v_post_fee numeric := COALESCE(public.get_setting_numeric('posting_fee'), 0);
  v_wallet public.wallets;
  v_balance_after numeric;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.provider_profiles
    WHERE id = p_provider_id AND user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'NOT_YOUR_PROVIDER';
  END IF;

  v_blockers := public.provider_fulfilment_blockers(p_provider_id);
  IF COALESCE(array_length(v_blockers, 1), 0) > 0 THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %',
      array_to_string(v_blockers, ',');
  END IF;

  -- Optional posting fee. The gate above already required the wallet to
  -- cover GREATEST(minimum, fee), so the lock and the second check only
  -- catch a balance that moved between the two reads. Refusing BEFORE the
  -- insert keeps the invariant simple: a product exists only when its fee
  -- was payable — no listing is ever created that the fee check would have
  -- refused.
  IF v_post_fee > 0 THEN
    SELECT * INTO v_wallet
      FROM public.wallets WHERE provider_id = p_provider_id FOR UPDATE;
    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'WALLET_NOT_FOUND';
    END IF;
    IF NOT public.get_setting_bool('allow_negative_wallet')
       AND v_wallet.balance < v_post_fee THEN
      RAISE EXCEPTION 'POSTING_FEE_INSUFFICIENT: %', v_post_fee::text;
    END IF;
  END IF;

  INSERT INTO public.products (
    provider_id, name, description, price, category_id, quantity,
    price_per_unit, unit, is_available, location
  ) VALUES (
    p_provider_id,
    coalesce(nullif(btrim(p_name), ''), 'Untitled listing'),
    nullif(btrim(coalesce(p_description, '')), ''),
    coalesce(p_price, 0),
    p_category_id,
    p_quantity,
    coalesce(p_price_per_unit, 0),
    p_unit,
    coalesce(p_is_available, true),
    CASE WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL
      THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
      ELSE NULL END
  ) RETURNING * INTO v_product;

  -- Charge and log. One TRANSACTION_FEE ledger row per product, keyed by the
  -- product id, so the charge is idempotent per listing and the platform's
  -- existing income readers (which sum platform_fee across TRANSACTION_FEE)
  -- count posting fees without knowing this key exists. net_amount is the
  -- BALANCE DELTA (-fee), not gross - fee: assert_income_ledger_consistent
  -- compares each wallet's balance with the sum of its COMPLETED net_amount,
  -- so a row whose net_amount disagrees with the movement it caused plants
  -- drift in exactly the check that exists to catch missing ledger rows.
  IF v_post_fee > 0 THEN
    UPDATE public.wallets
       SET balance = balance - v_post_fee, updated_at = now()
     WHERE id = v_wallet.id
    RETURNING balance INTO v_balance_after;

    INSERT INTO public.wallet_transactions (
      wallet_id, provider_id, order_id, ride_request_id, transaction_type,
      gross_amount, platform_fee, net_amount, balance_after, status,
      idempotency_key
    ) VALUES (
      v_wallet.id, p_provider_id, NULL, NULL, 'TRANSACTION_FEE',
      v_post_fee, v_post_fee, -v_post_fee, v_balance_after, 'COMPLETED',
      'posting_fee:' || v_product.id::text
    );

    INSERT INTO public.audit_logs (event_type, entity_type, entity_id, metadata)
    VALUES ('POSTING_FEE_DEDUCTED', 'wallets', v_wallet.id,
            jsonb_build_object(
              'provider_id', p_provider_id,
              'product_id', v_product.id,
              'fee', v_post_fee,
              'balance_after', v_balance_after));

    INSERT INTO public.notifications (user_id, type, title, body)
    SELECT user_id, 'POSTING_FEE_DEDUCTED', 'Listing fee deducted',
           v_post_fee::text || ' ETB deducted for a new listing'
      FROM public.provider_profiles WHERE id = p_provider_id;
  END IF;

  RETURN v_product;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_provider_product(
  uuid, text, text, numeric, uuid, integer, numeric, text, boolean,
  double precision, double precision) TO authenticated;

-- -----------------------------------------------------------------------------
-- 4. The assertion
-- -----------------------------------------------------------------------------
--
-- Reads pg_proc source text and touches no user data, which is why it is safe
-- to expose to anon — the role the connectivity suite actually runs as. Same
-- shape as assert_provider_fulfilment_gate_is_wired() (0113): an assertion
-- that reads the function bodies cannot go stale when the bodies are restated,
-- because it reads whatever body is live.
CREATE OR REPLACE FUNCTION public.assert_posting_gate_is_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_blockers text;
  v_create   text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_blockers
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'provider_fulfilment_blockers';
  IF v_blockers IS NULL THEN
    RAISE EXCEPTION 'provider_fulfilment_blockers is missing -- nothing can explain a posting refusal';
  ELSIF v_blockers NOT ILIKE '%WALLET_BELOW_MINIMUM%' THEN
    v_bad := v_bad || ARRAY['provider_fulfilment_blockers does not enforce the posting minimum (WALLET_BELOW_MINIMUM is absent)'];
  ELSIF v_blockers NOT ILIKE '%posting_min_wallet_balance%' THEN
    v_bad := v_bad || ARRAY['provider_fulfilment_blockers never reads posting_min_wallet_balance, so the admin knob does nothing'];
  END IF;

  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_provider_product';
  IF v_create IS NULL THEN
    RAISE EXCEPTION 'create_provider_product is missing -- the app has no create path';
  ELSIF v_create NOT ILIKE '%posting_fee%' THEN
    v_bad := v_bad || ARRAY['create_provider_product does not charge the optional posting fee'];
  ELSIF v_create NOT ILIKE '%posting_fee:%' THEN
    v_bad := v_bad || ARRAY['create_provider_product charges the fee without the idempotency key posting_fee:<product_id>, so a retried call could double-charge'];
  ELSIF v_create NOT ILIKE '%PROVIDER_NOT_FULFILMENT_READY%' THEN
    v_bad := v_bad || ARRAY['create_provider_product no longer refuses with the reason list, so the app cannot say WHY'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'The posting gate is not fully wired: %',
      array_to_string(v_bad, '; ');
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_posting_gate_is_wired()
  FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_posting_gate_is_wired()
  TO anon, authenticated, service_role;
