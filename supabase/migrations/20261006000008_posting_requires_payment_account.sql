-- 20261006000008 — posting requires a payment account, and listings without
-- one disappear from buyers
--
-- THE REPORT (item 6)
-- -------------------
-- A provider with nowhere for buyers to send money could still publish, and
-- their existing listings stayed visible — buyers would pay into a hole.
--
-- WHERE THE RULE GOES (and where it deliberately does NOT)
--   create_provider_product   raises NO_PAYMENT_ACCOUNT before the insert.
--   products_public_read      hides every listing of an account-less provider
--                             from buyers (the provider and admins still see
--                             their own rows, so the dashboard can explain).
--   search_products           same predicate inside the search RPC (it is
--                             SECURITY DEFINER, so RLS alone cannot reach it).
--
-- provider_fulfilment_blockers() is deliberately UNTOUCHED: it is shared
-- with claim_ride and the order-acceptance path (migration 20261006000005
-- calls it), and item 6 is about publishing listings — folding the account
-- rule into it would refuse ride claims from drivers who have never needed
-- a payout account to drive, and would break
-- assert_ride_claim_race_has_one_winner. The checklist reads the table
-- directly for its third step instead (PostingGate / ProviderReadiness),
-- and create_provider_product is the rule.
--
-- Deploy: needs a Supabase deploy (function restatements + policy).

-- ---------------------------------------------------------------------------
-- 1. create_provider_product — restated from 20261006000003 with the gate
-- ---------------------------------------------------------------------------

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

  -- Item 6: no active payment account = nowhere for a buyer to send money,
  -- so no listing goes live. Checked HERE rather than inside
  -- provider_fulfilment_blockers() on purpose — that function is shared
  -- with ride claiming and order acceptance, which are not part of this
  -- rule (see the header).
  IF NOT EXISTS (
    SELECT 1 FROM public.provider_payment_methods
     WHERE provider_id = p_provider_id AND is_active
  ) THEN
    RAISE EXCEPTION 'NO_PAYMENT_ACCOUNT';
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

COMMENT ON FUNCTION public.create_provider_product IS
  'Creates a listing. Since 20261006000008 it also refuses with '
  'NO_PAYMENT_ACCOUNT when the provider has no active bank account — a '
  'listing whose buyer has nowhere to send money is a dead listing.';

-- ---------------------------------------------------------------------------
-- 2. Buyers stop seeing listings of account-less providers
-- ---------------------------------------------------------------------------

DROP POLICY IF EXISTS products_public_read ON public.products;
CREATE POLICY products_public_read ON public.products FOR SELECT
  USING (
    (
      is_active = true
      AND EXISTS (
        SELECT 1 FROM public.provider_payment_methods m
         WHERE m.provider_id = products.provider_id
           AND m.is_active = true
      )
    )
    OR owns_provider_profile(provider_id)
    OR is_admin()
  );

COMMENT ON POLICY products_public_read ON public.products IS
  'A buyer sees a listing only when the product is active AND its provider '
  'has an active payment account (item 6 — no account, no visibility). The '
  'provider still sees their own rows so the dashboard can explain why they '
  'are hidden; admins see everything. The partial index '
  'idx_provider_payment_methods_active makes the EXISTS one lookup.';

-- ---------------------------------------------------------------------------
-- 3. search_products — restated from 20260922000003 with the same predicate
--    (SECURITY DEFINER, so the policy above cannot reach it)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.search_products(
  p_query text DEFAULT NULL,
  p_category_id uuid DEFAULT NULL,
  p_sector text DEFAULT NULL,
  p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL,
  p_radius_km NUMERIC DEFAULT NULL,
  p_min_price NUMERIC DEFAULT NULL,
  p_max_price NUMERIC DEFAULT NULL,
  p_min_rating NUMERIC DEFAULT NULL,
  p_sort_by text DEFAULT 'relevance',
  p_limit int DEFAULT 20,
  p_offset int DEFAULT 0,
  p_city text DEFAULT NULL,
  p_include_global boolean DEFAULT true
)
RETURNS TABLE (
  id uuid, name text, description text, price NUMERIC, currency text,
  rating NUMERIC, review_count int, sales_count int, category_id uuid,
  provider_id uuid, provider_name text, distance_km NUMERIC,
  is_available boolean, image_path text, rank_score NUMERIC
)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN
    v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  END IF;
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.price, p.currency, p.rating,
    p.review_count, p.sales_count, p.category_id, p.provider_id,
    pp.business_name AS provider_name,
    CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
      THEN ROUND((ST_Distance(p.location, v_location) / 1000.0)::numeric, 2)
      ELSE null END AS distance_km,
    p.is_available,
    (SELECT pi.storage_path FROM product_images pi
     WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1) AS image_path,
    CASE WHEN p_query IS NOT NULL AND p_query != ''
      THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
           + (1.0 / (1.0 + coalesce(
             CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
               THEN ST_Distance(p.location, v_location) / 1000.0
               ELSE 9999 END, 9999))))::numeric
      ELSE 0::numeric END AS rank_score
  FROM products p
  JOIN provider_profiles pp ON pp.id = p.provider_id AND pp.status = 'APPROVED'
  WHERE p.is_active = true AND p.is_available = true
    -- Item 6: an account-less provider's listings are hidden from buyers,
    -- exactly like the products_public_read policy (this function runs as
    -- its owner, so the policy alone cannot reach it).
    AND EXISTS (
      SELECT 1 FROM public.provider_payment_methods m
       WHERE m.provider_id = p.provider_id AND m.is_active = true)
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR EXISTS (
      SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL
         OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price)
    AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
    -- Phase 1: city scope. NULL param = no filter (old behavior).
    AND (p_city IS NULL OR p.city IS NULL OR p.city = p_city)
  ORDER BY
    CASE p_sort_by WHEN 'price_asc' THEN p.price ELSE null END ASC,
    CASE p_sort_by WHEN 'price_desc' THEN p.price ELSE null END DESC,
    CASE p_sort_by WHEN 'rating' THEN p.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN p.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN
      CASE WHEN p_query IS NOT NULL AND p_query != ''
        THEN (ts_rank(p.search_vector, plainto_tsquery('simple', p_query))
             + (1.0 / (1.0 + coalesce(
               CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
                 THEN ST_Distance(p.location, v_location) / 1000.0
                 ELSE 9999 END, 9999))))::numeric
        ELSE 0::numeric END
      ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN
      CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL
        THEN ST_Distance(p.location, v_location) ELSE 999999999 END
      ELSE null END ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.search_products(text, uuid, text, double precision, double precision, numeric, numeric, numeric, numeric, text, int, int, text, boolean)
  TO authenticated, anon;

-- ---------------------------------------------------------------------------
-- 4. The assertion Connectivity CI runs
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.assert_posting_requires_payment_account()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_create text;
  v_search text;
  v_policy text;
  v_bad text[] := '{}'::text[];
BEGIN
  SELECT prosrc INTO v_create
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'create_provider_product';
  IF v_create IS NULL OR v_create NOT ILIKE '%NO_PAYMENT_ACCOUNT%' THEN
    v_bad := v_bad || ARRAY[
      'create_provider_product no longer refuses without an active payment '
      'account — an account-less provider can publish'];
  END IF;

  SELECT prosrc INTO v_search
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'search_products';
  IF v_search IS NULL
     OR v_search NOT ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'search_products no longer hides account-less providers — the search '
      'screen shows listings buyers cannot pay for'];
  END IF;

  SELECT coalesce(p.qual, '') INTO v_policy
    FROM pg_policies p
   WHERE p.schemaname = 'public' AND p.tablename = 'products'
     AND p.policyname = 'products_public_read';
  IF v_policy NOT ILIKE '%provider_payment_methods%' THEN
    v_bad := v_bad || ARRAY[
      'products_public_read lost the payment-account predicate — direct '
      'buyer reads see listings they cannot pay for'];
  END IF;

  IF COALESCE(array_length(v_bad, 1), 0) > 0 THEN
    RAISE EXCEPTION 'the payment-account posting gate is not wired: %',
      array_to_string(v_bad, '; ');
  END IF;
  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.assert_posting_requires_payment_account()
  TO anon, authenticated;

COMMENT ON FUNCTION public.assert_posting_requires_payment_account() IS
  'True when a provider without an active payment account can neither '
  'publish (create_provider_product), nor be found (search_products), nor '
  'be browsed (products_public_read).';
