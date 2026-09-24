-- Task 11 critical security hardening.
-- This migration is intentionally separate from the Task 10 CAPTCHA migration so
-- the already-created objects can be tightened without rewriting history.

-- ============================================================================
-- 1. Documents: client inserts can never assert a successful verification.
-- ============================================================================
ALTER TABLE public.user_documents
  ADD COLUMN IF NOT EXISTS verification_status text DEFAULT 'MANUAL_REVIEW',
  ADD COLUMN IF NOT EXISTS qr_payload text,
  ADD COLUMN IF NOT EXISTS agent_verdict jsonb,
  ADD COLUMN IF NOT EXISTS verified_at timestamptz;

UPDATE public.user_documents
SET verification_status = 'MANUAL_REVIEW'
WHERE verification_status IS NULL;

ALTER TABLE public.user_documents
  ALTER COLUMN verification_status SET DEFAULT 'MANUAL_REVIEW',
  ALTER COLUMN verification_status SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_verification_status_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_verification_status_check
      CHECK (verification_status IN ('MANUAL_REVIEW','AUTO_APPROVED','SUSPECTED_FRAUD'));
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.prevent_document_verification_forgery()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Every new client record starts in the manual-review queue. The
    -- document-verify Edge Function is the only normal path to a verdict.
    NEW.verification_status := 'MANUAL_REVIEW';
    NEW.qr_payload := NULL;
    NEW.agent_verdict := NULL;
    NEW.verified_at := NULL;
    RETURN NEW;
  END IF;

  -- Authenticated non-verifiers cannot change any verification field. A
  -- service-role Edge Function is allowed through by its trusted JWT role.
  IF auth.uid() IS NOT NULL
     AND current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role'
     AND NOT public.is_admin() THEN
    IF NEW.verification_status IS DISTINCT FROM OLD.verification_status
       OR NEW.qr_payload IS DISTINCT FROM OLD.qr_payload
       OR NEW.agent_verdict IS DISTINCT FROM OLD.agent_verdict
       OR NEW.verified_at IS DISTINCT FROM OLD.verified_at THEN
      RAISE EXCEPTION 'DOCUMENT_VERIFICATION_REQUIRES_VERIFIER';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_documents_verification_security ON public.user_documents;
CREATE TRIGGER trg_user_documents_verification_security
BEFORE INSERT OR UPDATE ON public.user_documents
FOR EACH ROW EXECUTE FUNCTION public.prevent_document_verification_forgery();

-- ============================================================================
-- 2. Public provider exposure: explicit safe-field view only.
-- ============================================================================
CREATE OR REPLACE VIEW public.public_provider_profiles
WITH (security_barrier = true)
AS
SELECT
  p.id,
  p.business_name,
  p.business_description,
  p.business_address,
  p.business_address AS address_text,
  p.location_lat,
  p.location_lng,
  p.service_category,
  p.price_range,
  p.is_active,
  p.subscription_paid,
  p.subscription_due_date,
  p.provider_type,
  p.status,
  p.category_id,
  p.city,
  p.kebele,
  p.street_road,
  p.registration_fee_paid,
  p.created_at
FROM public.provider_profiles AS p
WHERE p.status = 'APPROVED';

DROP POLICY IF EXISTS provider_profiles_public_read ON public.provider_profiles;
DROP POLICY IF EXISTS provider_profiles_private_read ON public.provider_profiles;
CREATE POLICY provider_profiles_private_read ON public.provider_profiles
FOR SELECT
USING (
  user_id = auth.uid()
  OR public.is_admin()
  OR public.staff_has_permission(auth.uid(), 'registrations')
  OR public.staff_has_permission(auth.uid(), 'payment_verification')
  OR public.staff_has_permission(auth.uid(), 'sales_transactions')
);

REVOKE SELECT ON public.provider_profiles FROM PUBLIC, anon;
GRANT SELECT ON public.provider_profiles TO authenticated, service_role;
GRANT SELECT ON public.public_provider_profiles TO anon, authenticated;

-- ============================================================================
-- 3. Provider write gates: server-side product/vehicle RPCs and triggers.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.provider_can_publish(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.provider_profiles AS pp
    WHERE pp.id = p_provider_id
      AND pp.status = 'APPROVED'
      AND pp.registration_fee_paid
      AND public.provider_docs_satisfied(pp.user_id)
  );
$$;

REVOKE ALL ON FUNCTION public.provider_can_publish(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.provider_can_publish(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.enforce_provider_write_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  -- Service-role verification/maintenance paths are trusted by role.
  IF auth.uid() IS NULL
     OR current_setting('request.jwt.claim.role', true) = 'service_role'
     OR public.is_admin() THEN
    RETURN NEW;
  END IF;

  SELECT user_id INTO v_user_id
  FROM public.provider_profiles
  WHERE id = NEW.provider_id;

  IF v_user_id IS DISTINCT FROM auth.uid() OR NOT public.provider_can_publish(NEW.provider_id) THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_provider_product_write_gate ON public.products;
CREATE TRIGGER trg_provider_product_write_gate
BEFORE INSERT OR UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.enforce_provider_write_gate();

DROP TRIGGER IF EXISTS trg_provider_vehicle_write_gate ON public.vehicles;
CREATE TRIGGER trg_provider_vehicle_write_gate
BEFORE INSERT OR UPDATE ON public.vehicles
FOR EACH ROW EXECUTE FUNCTION public.enforce_provider_write_gate();

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
  IF NOT public.provider_can_publish(p_provider_id) THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED';
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
  IF NOT public.provider_can_publish(p_provider_id) THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED';
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

REVOKE ALL ON FUNCTION public.create_provider_product(uuid, text, text, numeric, uuid, integer, numeric, text, boolean, double precision, double precision) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.create_provider_vehicle(uuid, text, text, text, text, integer, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_provider_product(uuid, text, text, numeric, uuid, integer, numeric, text, boolean, double precision, double precision) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_provider_vehicle(uuid, text, text, text, text, integer, uuid) TO authenticated;

-- ============================================================================
-- 4. CAPTCHA: explicit consumption and fail-closed configuration.
-- ============================================================================
ALTER TABLE public.captcha_challenges
  ADD COLUMN IF NOT EXISTS consumed_at timestamptz,
  ADD COLUMN IF NOT EXISTS consumed_target text;

CREATE INDEX IF NOT EXISTS idx_captcha_challenges_consumed
  ON public.captcha_challenges (consumed_at)
  WHERE consumed_at IS NOT NULL;

CREATE OR REPLACE FUNCTION public.captcha_required()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_required boolean;
BEGIN
  v_required := public.get_setting_bool('captcha_enforced');
  IF v_required IS NULL THEN
    RAISE EXCEPTION 'CAPTCHA_CONFIG_UNAVAILABLE';
  END IF;
  RETURN v_required;
END;
$$;

CREATE OR REPLACE FUNCTION public.captcha_ok(p_captcha_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.captcha_challenges
    WHERE id = p_captcha_id
      AND solved_at IS NOT NULL
      AND used_at IS NOT NULL
      AND consumed_at IS NULL
      AND expires_at > now()
  );
$$;

CREATE OR REPLACE FUNCTION public.consume_captcha(
  p_captcha_id uuid,
  p_target text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.captcha_challenges%ROWTYPE;
BEGIN
  IF p_captcha_id IS NULL THEN
    RETURN false;
  END IF;

  SELECT * INTO v_row
  FROM public.captcha_challenges
  WHERE id = p_captcha_id
  FOR UPDATE;

  IF v_row.id IS NULL
     OR v_row.expires_at <= now()
     OR v_row.solved_at IS NULL
     OR v_row.consumed_at IS NOT NULL THEN
    RETURN false;
  END IF;

  UPDATE public.captcha_challenges
     SET consumed_at = now(),
         consumed_target = p_target
   WHERE id = p_captcha_id
     AND consumed_at IS NULL;
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_appeal_captcha()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF public.captcha_required() THEN
    IF NEW.captcha_id IS NULL
       OR NOT public.consume_captcha(NEW.captcha_id, 'appeal:' || NEW.user_id::text) THEN
      RAISE EXCEPTION 'CAPTCHA_REQUIRED';
    END IF;
  END IF;
  NEW.captcha_id := NULL;
  RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION public.consume_captcha(uuid, text) TO anon, authenticated;

-- Ensure the enforcement toggle exists without weakening an explicit owner
-- choice. The RPC above fails closed if the value is absent or malformed.
INSERT INTO public.system_settings (key, value, description)
VALUES ('captcha_enforced', 'true'::jsonb,
        'Require the tick+math captcha on OTP requests and appeal submissions.')
ON CONFLICT (key) DO NOTHING;
