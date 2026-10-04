-- ============================================================================
-- 20260929000001_approved_location_and_payment_screenshots
--
-- Buyer-visible, payment-approval-gated provider location + contact, and the
-- admin verification record that unlocks both.
--
-- What this adds
-- 1. approved_location_for_buyers(provider_id, buyer_id, location_lat,
--    location_lng, address_text, created_at)
--    - A provider's EXACT GPS and necessary info is stored separately from
--      provider_profiles, never overwritten by the provider edit screen, so a
--      buyer is always told exactly where the provider is right now.
--    - UNIQUE(provider_id, buyer_id): every buyer gets exactly one approved
--      point per provider. No requirement column, no trigger, no guard.
-- 2. payment_approval_screenshots(id, order_id, provider_id, screenshot_path,
--    approved_by, status, created_at)
--    - status IN ('PENDING', 'APPROVED', 'REJECTED').
--    - The buyer's upload path writes to `payment_proofs` first and calls
--      approve_payment_screenshot() once the admin has verified it, so the
--      photo is never visible before approval.
-- 3. RLS policies.
--
-- Apply this after 20260927000142_provider_payment_methods.sql with psql
-- (the live DB has no supabase db push history). Idempotent.
-- ============================================================================

-- ── 1. Approved location for buyers ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.approved_location_for_buyers (
  provider_id   uuid NOT NULL REFERENCES public.provider_profiles(id)
                  ON DELETE CASCADE,
  buyer_id      uuid NOT NULL REFERENCES auth.users(id)
                  ON DELETE CASCADE,
  location_lat  double precision NOT NULL,
  location_lng  double precision NOT NULL,
  address_text  text NOT NULL DEFAULT '',
  created_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT approved_location_unique UNIQUE (provider_id, buyer_id)
);

Comment on table public.approved_location_for_buyers is
  'The EXACT GPS + necessary info a buyer sees only after a payment proof is '
  'approved. Provider_profiles keeps the editable business GPS; this table '
  'keeps the point a buyer is allowed to see.';

ALTER TABLE public.approved_location_for_buyers ENABLE ROW LEVEL SECURITY;

-- Buyer reads their own approved point.
DROP POLICY IF EXISTS approved_location_for_buyers_buyer_read ON
  public.approved_location_for_buyers;
CREATE POLICY approved_location_for_buyers_buyer_read ON
  public.approved_location_for_buyers
  FOR SELECT
  TO authenticated
  USING (buyer_id = auth.uid());

-- Provider (and admin) writes their approved point; the server-side RPC
-- owns the write and re-checks ownership.
DROP POLICY IF EXISTS approved_location_for_buyers_provider_write ON
  public.approved_location_for_buyers;
CREATE POLICY approved_location_for_buyers_provider_write ON
  public.approved_location_for_buyers
  FOR ALL
  TO authenticated
  USING (provider_id = auth.uid() OR public.is_admin());

REVOKE ALL ON TABLE public.approved_location_for_buyers FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.approved_location_for_buyers TO authenticated;
GRANT ALL ON TABLE public.approved_location_for_buyers TO service_role;

-- Read-only getter: returns the one approved point that belongs to (provider,
-- buyer). Returns NULL when the provider has never approved a point for that
-- buyer, so no screen has to guess.
CREATE OR REPLACE FUNCTION public.get_approved_location_for_buyer(
  p_provider_id uuid,
  p_buyer_id uuid
)
RETURNS TABLE (
  provider_id   uuid,
  buyer_id      uuid,
  location_lat  double precision,
  location_lng  double precision,
  address_text  text,
  created_at    timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT provider_id, buyer_id, location_lat, location_lng, address_text, created_at
    FROM public.approved_location_for_buyers
   WHERE provider_id = p_provider_id
     AND buyer_id = p_buyer_id;
$$;

REVOKE ALL ON FUNCTION public.get_approved_location_for_buyer(uuid, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_approved_location_for_buyer(uuid, uuid)
  TO authenticated, service_role;

-- ── 2. Payment screenshot approval record ─────────────────────────────────--
CREATE TABLE IF NOT EXISTS public.payment_approval_screenshots (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id      uuid NOT NULL REFERENCES public.orders(id)
                  ON DELETE CASCADE,
  provider_id   uuid NOT NULL REFERENCES public.provider_profiles(id)
                  ON DELETE CASCADE,
  screenshot_path text NOT NULL,
  approved_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  status        text NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED')),
  created_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT payment_approval_owner UNIQUE (provider_id, order_id)
);

Comment on table public.payment_approval_screenshots is
  'One row per payment screenshot the buyer uploaded, with the decision '
  '(PENDING/APPROVED/REJECTED) made by the provider or an admin.';

ALTER TABLE public.payment_approval_screenshots ENABLE ROW LEVEL SECURITY;

-- Buyer/provider read their own pending rows; admin reads everything.
DROP POLICY IF EXISTS payment_approval_screenshots_buyer_read ON
  public.payment_approval_screenshots;
CREATE POLICY payment_approval_screenshots_buyer_read ON
  public.payment_approval_screenshots
  FOR SELECT
  TO authenticated
  USING (auth.uid() = order_id);

DROP POLICY IF EXISTS payment_approval_screenshots_provider_read ON
  public.payment_approval_screenshots;
CREATE POLICY payment_approval_screenshots_provider_read ON
  public.payment_approval_screenshots
  FOR SELECT
  TO authenticated
  USING (provider_id = auth.uid());

DROP POLICY IF EXISTS payment_approval_screenshots_admin_read ON
  public.payment_approval_screenshots;
CREATE POLICY payment_approval_screenshots_admin_read ON
  public.payment_approval_screenshots
  FOR ALL
  TO authenticated
  USING (public.is_admin());

REVOKE ALL ON TABLE public.payment_approval_screenshots FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE
  public.payment_approval_screenshots TO authenticated;
GRANT ALL ON TABLE public.payment_approval_screenshots TO service_role;

-- ── 3. Admin-only RPC: set the approval decision ───────────────────────────
-- The decision lives in the DB, not in the screen, so a provider or a buyer
-- can never set it. `approved_by` is the provider when a provider taps
-- "Approve payment" and an admin when an admin taps the same button.
CREATE OR REPLACE FUNCTION public.approve_payment_screenshot(
  p_order_id    uuid,
  p_status      text,
  p_approved_by uuid DEFAULT NULL
)
RETURNS TABLE (
  id            uuid,
  order_id      uuid,
  provider_id   uuid,
  screenshot_path text,
  approved_by   uuid,
  status        text,
  created_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.payment_approval_screenshots;
  v_owner uuid;
BEGIN
  -- Only an admin or the provider on the order can decide.
  IF NOT (public.is_admin() OR v_owner = auth.uid()) THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED_TO_REVIEW_PAYMENT';
  END IF;

  IF p_status NOT IN ('PENDING', 'APPROVED', 'REJECTED') THEN
    RAISE EXCEPTION 'INVALID_APPROVAL_STATUS';
  END IF;

  SELECT * INTO v_row
    FROM public.payment_approval_screenshots
   WHERE order_id = p_order_id
     AND provider_id = v_owner;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'NO_APPROVAL_ROW_FOUND';
  END IF;

  UPDATE public.payment_approval_screenshots
     SET status = p_status,
         approved_by = p_approved_by,
         created_at = now()
   WHERE id = v_row.id;

  RETURN QUERY
  SELECT * FROM public.payment_approval_screenshots WHERE id = v_row.id;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_payment_screenshot(uuid, text, uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_payment_screenshot(uuid, text, uuid)
  TO authenticated, service_role;

-- ── 4. Provider-side approval (the provider taps "Approve payment") ────────
-- Identical contract to the admin RPC above but scoped to the provider row.
CREATE OR REPLACE FUNCTION public.approve_payment_screenshot_provider(
  p_order_id    uuid,
  p_status      text
)
RETURNS TABLE (
  id            uuid,
  order_id      uuid,
  provider_id   uuid,
  screenshot_path text,
  approved_by   uuid,
  status        text,
  created_at    timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.payment_approval_screenshots;
  v_owner uuid;
BEGIN
  SELECT provider_id INTO v_owner
    FROM public.orders WHERE id = p_order_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF NOT (public.is_admin() OR v_owner = auth.uid()) THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED_TO_REVIEW_PAYMENT';
  END IF;

  IF p_status NOT IN ('PENDING', 'APPROVED', 'REJECTED') THEN
    RAISE EXCEPTION 'INVALID_APPROVAL_STATUS';
  END IF;

  SELECT * INTO v_row
    FROM public.payment_approval_screenshots
   WHERE order_id = p_order_id
     AND provider_id = v_owner;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'NO_APPROVAL_ROW_FOUND';
  END IF;

  UPDATE public.payment_approval_screenshots
     SET status = p_status,
         approved_by = auth.uid(),
         created_at = now()
   WHERE id = v_row.id;

  RETURN QUERY
  SELECT * FROM public.payment_approval_screenshots WHERE id = v_row.id;
END;
$$;

REVOKE ALL ON FUNCTION public.approve_payment_screenshot_provider(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_payment_screenshot_provider(uuid, text)
  TO authenticated, service_role;
