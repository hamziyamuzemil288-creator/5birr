-- Follow-up to 20260924000004: the hardened public_provider_profiles view must
-- ship as a NEW version because db push tracks applied migrations by version
-- string only — editing 20260924000004 in place left the leaky first revision
-- live. The live view still carries kebele/street_road/business_address, and
-- CREATE OR REPLACE VIEW cannot drop columns (SQLSTATE 42P16), so it must be
-- dropped and recreated.
--
-- Restricted out (verified by the live probe + regression harness):
--   owner_national_id, national_id, user_id, owner_name,
--   kebele, street_road, business_address

DROP VIEW IF EXISTS public.public_provider_profiles;

CREATE VIEW public.public_provider_profiles
WITH (security_barrier = true)
AS
SELECT
  p.id,
  p.business_name,
  p.business_description,
  -- City-level location only: kebele/street_road/business_address are address
  -- data and stay private to the owner and admins.
  p.city AS address_text,
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
  p.registration_fee_paid,
  p.created_at
FROM public.provider_profiles AS p
WHERE p.status = 'APPROVED';

GRANT SELECT ON public.public_provider_profiles TO anon, authenticated;
