-- Scratch-fixture companion to the local replay: the six admin RPCs from 0107
-- and 0062 that the hand-built schema files omit, defined here at their real
-- signatures and grants so 0124's reachability report can be proven GREEN as
-- well as red. Signatures copied from:
--   20260927000107_per_category_and_city_fees.sql  (category + city fees)
--   20260927000062_fees_are_data.sql               (settings, is_fee_editor)
--
-- This file lives outside supabase/ on purpose. It is NOT a migration and must
-- never be deployed; it exists only so the local scratch database can prove
-- 0124's assertion in both directions.

CREATE OR REPLACE FUNCTION public.is_fee_editor() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT true $$;

CREATE OR REPLACE FUNCTION public.admin_fee_catalogue() RETURNS SETOF record
LANGUAGE sql STABLE AS $$ SELECT 1 AS one $$;

CREATE OR REPLACE FUNCTION public.admin_category_fee_catalogue() RETURNS SETOF record
LANGUAGE sql STABLE AS $$ SELECT 1 AS one $$;

CREATE OR REPLACE FUNCTION public.admin_update_setting(
  p_key text, p_value jsonb, p_description text DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.admin_clear_category_fee(
  p_category_id uuid, p_city text DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.admin_save_category_fee(
  p_category_id uuid,
  p_city text DEFAULT NULL,
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
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

GRANT EXECUTE ON FUNCTION public.is_fee_editor() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_fee_catalogue() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_category_fee_catalogue() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_update_setting(text, jsonb, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_clear_category_fee(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_save_category_fee(uuid, text, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric, numeric) TO authenticated, service_role;
