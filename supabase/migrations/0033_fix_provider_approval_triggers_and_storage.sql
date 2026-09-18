-- 5BIRR — Fix provider approval server path + missing storage buckets
-- Migration 0033_fix_provider_approval_triggers_and_storage.sql
--
-- SYMPTOMS
--   1. Admin "Approve"/"Correction"/"Reject" on Provider Management fail:
--      the provider-approval Edge Function returns 400
--      {"error":"An internal error occurred. Please try again."}.
--   2. Provider documents (ID / license) never display — the
--      user-documents bucket does not exist and no uploads ever landed.
--
-- ROOT CAUSES
--   A. prevent_provider_self_privilege_escalation() (hardening pass) blocks
--      ANY status change on provider_profiles unless is_admin(). The
--      SECURITY DEFINER approve_provider() runs as service_role/postgres —
--      is_admin() is false there, so the sanctioned server path was blocked
--      with STATUS_CANNOT_BE_SELF_MODIFIED (unsanitized -> generic 400).
--      Same class of bug already fixed for orders (0029) and wallets (0030).
--      Additionally, the trigger references new.subscription_start_date,
--      a column that does not exist on this schema — a latent crash for any
--      UPDATE that got past the status check.
--   B. prevent_notification_injection() allows only is_admin() or the
--      literal service_role SETTING — but inside a SECURITY DEFINER RPC the
--      current SETTING is the RPC owner (postgres), not service_role, so
--      approve_provider's notification INSERT also raised
--      NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS.
--   C. The storage buckets the app writes/reads (user-documents,
--      product-images, payment-screenshots, payment-proofs) were never
--      created — storage.objects is empty and signed-URL reads 404.
--
-- FIX
--   A. Add the 0029-style trusted-server-path bypass (current_user IN
--      ('postgres','service_role')) to the provider escalation trigger and
--      drop the nonexistent-column check. Client-side restrictions are
--      unchanged: regular users still cannot modify status/type/national_id.
--   B. Same bypass for the notifications guard.
--   C. Create the four buckets with minimal, additive storage policies
--      (owner-folder writes, owner or admin reads; product-images public
--      read). No existing policy is modified.

-- =========================================================
-- A. Provider escalation trigger: allow the sanctioned server path
-- =========================================================
CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role') THEN
    -- Trusted server paths: SECURITY DEFINER RPCs (approve_provider,
    -- reject_provider, request_correction_provider, suspend/unsuspend)
    -- and edge functions. Clients are still restricted below.
    RETURN new;
  END IF;
  IF NOT is_admin() THEN
    IF new.status != old.status THEN
      RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
    END IF;
    IF new.provider_type != old.provider_type THEN
      RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
    END IF;
    -- NOTE: the previous version also compared subscription_start_date,
    -- which does not exist in this schema; that check is intentionally
    -- dropped (the column is absent, so it could never be compared).
    IF old.owner_national_id IS NOT NULL AND new.owner_national_id != old.owner_national_id THEN
      RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
    END IF;
  END IF;
  RETURN new;
END;
$$;

-- =========================================================
-- B. Notifications guard: same trusted-server-path bypass
-- =========================================================
CREATE OR REPLACE FUNCTION public.prevent_notification_injection()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF current_user IN ('postgres', 'service_role') THEN
    RETURN new;
  END IF;
  IF NOT is_admin() THEN
    RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
  END IF;
  RETURN new;
END;
$$;

-- =========================================================
-- C. Missing storage buckets + minimal policies
-- =========================================================
INSERT INTO storage.buckets (id, name, public)
VALUES
  ('user-documents', 'user-documents', false),
  ('product-images', 'product-images', true),
  ('payment-screenshots', 'payment-screenshots', false),
  ('payment-proofs', 'payment-proofs', false)
ON CONFLICT (id) DO NOTHING;

-- Private buckets: users manage objects inside their own folder
-- (paths conventionally start with their auth uid); admins read all.
DO $$
DECLARE b text;
BEGIN
  FOREACH b IN ARRAY ARRAY['user-documents','payment-screenshots','payment-proofs'] LOOP
    EXECUTE format('
      CREATE POLICY %I ON storage.objects FOR INSERT TO authenticated
        WITH CHECK (bucket_id = %L AND (name LIKE auth.uid()::text || %L OR name LIKE %L))',
      b || '_owner_insert', b, '/%', 'product-images/%');
    EXECUTE format('
      CREATE POLICY %I ON storage.objects FOR SELECT TO authenticated
        USING (bucket_id = %L AND (name LIKE auth.uid()::text || %L OR public.is_admin()))',
      b || '_owner_or_admin_read', b, '/%');
  END LOOP;
END $$;

-- product-images: world-readable (listing photos), signed-in providers upload.
DROP POLICY IF EXISTS "product_images_public_read" ON storage.objects;
CREATE POLICY product_images_public_read
  ON storage.objects FOR SELECT
  USING (bucket_id = 'product-images');
DROP POLICY IF EXISTS "product_images_insert" ON storage.objects;
CREATE POLICY product_images_insert
  ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'product-images');

NOTIFY pgrst, 'reload schema';
