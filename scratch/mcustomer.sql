-- Scratch-fixture companion to the local replay, for migration 0125.
--
-- NOT a migration and must never be deployed. It exists so
-- assert_customer_write_paths_are_reachable() can be proven in BOTH directions:
-- green with every function at its real signature and grant, red when a name
-- drifts, a GRANT is missing, or an overload appears.
--
-- Signatures transcribed from the migrations that define each function.

CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid, p_pickup_lat double precision, p_pickup_lng double precision,
  p_destination_lat double precision, p_destination_lng double precision,
  p_pickup_text text DEFAULT NULL, p_destination_text text DEFAULT NULL,
  p_vehicle_category_id uuid DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate_at(
  p_pickup_lat double precision, p_pickup_lng double precision,
  p_dest_lat double precision, p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL, p_city text DEFAULT NULL
) RETURNS numeric LANGUAGE sql AS $$ SELECT 0::numeric $$;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate(
  p_pickup_lat double precision, p_pickup_lng double precision,
  p_dest_lat double precision, p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL
) RETURNS numeric LANGUAGE sql AS $$ SELECT 0::numeric $$;

CREATE OR REPLACE FUNCTION public.find_nearby_drivers(
  p_lat double precision, p_lng double precision,
  p_radius_km numeric DEFAULT 10, p_vehicle_category_id uuid DEFAULT NULL
) RETURNS SETOF record LANGUAGE sql AS $$ SELECT 1 AS one $$;

CREATE OR REPLACE FUNCTION public.set_driver_online(
  p_provider_id uuid, p_online boolean,
  p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.update_driver_location(
  p_provider_id uuid, p_lat double precision, p_lng double precision
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid, p_provider_id uuid, p_items jsonb,
  p_total_amount numeric, p_currency text, p_note text DEFAULT NULL,
  p_fulfillment_mode text DEFAULT 'DELIVERY',
  p_delivery_address text DEFAULT NULL, p_city text DEFAULT NULL
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.search_products(
  p_query text DEFAULT NULL, p_category_id uuid DEFAULT NULL,
  p_sector text DEFAULT NULL, p_lat double precision DEFAULT NULL,
  p_lng double precision DEFAULT NULL, p_radius_km numeric DEFAULT NULL,
  p_min_price numeric DEFAULT NULL, p_max_price numeric DEFAULT NULL,
  p_min_rating numeric DEFAULT NULL, p_sort_by text DEFAULT 'relevance',
  p_limit int DEFAULT 20, p_offset int DEFAULT 0,
  p_city text DEFAULT NULL, p_include_global boolean DEFAULT true
) RETURNS SETOF record LANGUAGE sql AS $$ SELECT 1 AS one $$;

CREATE OR REPLACE FUNCTION public.platform_transaction_fee_for(
  p_amount numeric, p_category_id uuid DEFAULT NULL, p_city text DEFAULT NULL,
  p_is_product boolean DEFAULT false
) RETURNS numeric LANGUAGE sql AS $$ SELECT 0::numeric $$;

CREATE OR REPLACE FUNCTION public.platform_transaction_fee(
  p_amount numeric
) RETURNS numeric LANGUAGE sql AS $$ SELECT 0::numeric $$;

CREATE OR REPLACE FUNCTION public.get_order_delivery_location(
  p_order_id uuid
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.set_order_delivery_location(
  p_order_id uuid, p_lat double precision, p_lng double precision
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

CREATE OR REPLACE FUNCTION public.release_order_contact(
  p_order_id uuid
) RETURNS text LANGUAGE sql AS $$ SELECT 'ok' $$;

GRANT EXECUTE ON FUNCTION public.create_ride_request(uuid,double precision,double precision,double precision,double precision,text,text,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate_at(double precision,double precision,double precision,double precision,uuid,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate(double precision,double precision,double precision,double precision,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.find_nearby_drivers(double precision,double precision,numeric,uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_driver_online(uuid,boolean,double precision,double precision) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_driver_location(uuid,double precision,double precision) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_order_secure(uuid,uuid,jsonb,numeric,text,text,text,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.search_products(text,uuid,text,double precision,double precision,numeric,numeric,numeric,numeric,text,int,int,text,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.platform_transaction_fee_for(numeric,uuid,text,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.platform_transaction_fee(numeric) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_order_delivery_location(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_order_delivery_location(uuid,double precision,double precision) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.release_order_contact(uuid) TO authenticated, service_role;
