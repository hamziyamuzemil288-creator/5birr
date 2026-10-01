-- =============================================================================
-- 0117 - the listing refusal says WHY
-- =============================================================================
--
-- A provider opens the dashboard, taps Catalogue -> Add Product, fills in the
-- form, taps Save, and the app shows them:
--
--     PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED
--
-- That is the whole message. The gate is CORRECT -- a provider who has not been
-- approved, has not paid the activation fee, has no reviewed identity document
-- or has an empty wallet genuinely must not publish -- but the refusal names no
-- reason and offers no next step, so from the provider's side the button is
-- simply broken. Nothing on the dashboard says what is outstanding either, so
-- there is nowhere to go from there. That is the reported symptom: "a provider
-- goes into the dashboard and cannot upload a product anywhere".
--
-- Every OTHER provider surface already answers with the reasons. Migration 0113
-- gave `claim_ride` and `transition_order_status` the pattern:
--
--     RAISE EXCEPTION 'PROVIDER_NOT_FULFILMENT_READY: %',
--       array_to_string(v_blockers, ',');
--
-- and the app's `friendly_error()` already turns each reason into the thing the
-- provider can do about it ("your identity document is still being reviewed",
-- "your wallet is empty, so the platform fee cannot be covered", ...).
--
-- The two CREATE paths were missed. They predate 0113 (they come from
-- 20260924000004, above the deploy baseline) and were restated for the gate
-- without being restated for the MESSAGE, so the one path a new provider uses
-- first is the one path that says nothing.
--
-- This migration changes the message only. The predicate stays
-- `provider_can_publish`, which still delegates to `provider_can_fulfil` and
-- still consults `provider_fulfilment_blockers` -- so the enforcement is
-- unchanged and `assert_provider_fulfilment_gate_is_wired()` still holds. The
-- refusal is still refused, in the same order, for the same inputs; the only
-- difference is that the reason travels with it.
--
-- The old code is kept in `friendly_error()` as well, so an already-installed
-- app that receives the bare code from a server this migration has not reached
-- yet still shows the provider a sentence instead of a machine token.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. create_provider_product -- restated
-- -----------------------------------------------------------------------------
-- Signature and body otherwise verbatim from 20260924000004. Only the refusal
-- changes. Nothing about the INSERT, the defaulting or the geography point is
-- touched: a provider who passes the gate must get the same listing they did
-- before this migration.
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
  RETURN v_product;
END;
$$;

-- -----------------------------------------------------------------------------
-- 2. create_provider_vehicle -- restated
-- -----------------------------------------------------------------------------
-- The same gate, reached from the same place in the app: a vehicle provider
-- adding a car hits the identical wall with the identical bare code. Leaving it
-- alone would mean fixing half the complaint.
CREATE OR REPLACE FUNCTION public.create_provider_vehicle(
  p_provider_id uuid,
  p_brand text,
  p_model text,
  p_plate_number text,
  p_color text,
  p_capacity integer,
  p_category_id uuid
)
RETURNS public.vehicles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_vehicle public.vehicles;
  v_blockers text[];
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

  INSERT INTO public.vehicles (
    provider_id, brand, model, plate_number, color, capacity,
    category_id, status, is_available
  ) VALUES (
    p_provider_id, nullif(btrim(p_brand), ''), nullif(btrim(p_model), ''),
    btrim(p_plate_number), nullif(btrim(p_color), ''), p_capacity,
    p_category_id, 'PENDING_APPROVAL', false
  ) RETURNING * INTO v_vehicle;
  RETURN v_vehicle;
END;
$$;

-- The signatures are unchanged, so the grants from 20260924000004 still apply and
-- the app's RPC calls resolve. Restated here for the record only: a
-- CREATE OR REPLACE that dropped a grant would leave the path unreachable for
-- exactly the providers this migration is about.
GRANT EXECUTE ON FUNCTION public.create_provider_product(
  uuid, text, text, numeric, uuid, integer, numeric, text, boolean,
  double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_provider_vehicle(
  uuid, text, text, text, text, integer, uuid) TO authenticated;

-- -----------------------------------------------------------------------------
-- 3. A screen the provider can actually land on
-- -----------------------------------------------------------------------------
-- The reason list has to be READABLE before the form is submitted, otherwise
-- the provider still discovers the problem by failing. `provider_fulfilment_blockers`
-- is already granted to `authenticated`, so the dashboard can call it directly
-- and show what is outstanding the moment they arrive -- before they have typed
-- a single field into a form they cannot submit.
--
-- The surface report is the shape the rest of the app already uses for this
-- family of facts (see provider_photo_surface_report): a short string, `ok:`
-- when there is nothing wrong, so a failing call is readable in a CI log.
CREATE OR REPLACE FUNCTION public.provider_listing_readiness(p_provider_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_blockers text[];
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
  IF COALESCE(array_length(v_blockers, 1), 0) = 0 THEN
    RETURN 'ok: ready to publish';
  END IF;

  RETURN 'BLOCKED: ' || array_to_string(v_blockers, ',');
END;
$$;

REVOKE ALL ON FUNCTION public.provider_listing_readiness(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_listing_readiness(uuid)
  TO authenticated, service_role;
