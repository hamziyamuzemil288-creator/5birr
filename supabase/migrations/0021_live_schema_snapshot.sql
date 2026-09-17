-- =========================================================
-- 5BIRR LIVE SCHEMA SNAPSHOT
-- Generated: 2026-09-17 from live database (eu-central-1)
-- This is a FORWARD-ONLY snapshot capturing the current live schema.
-- Do NOT edit past migrations — only add new ones after this.
-- To recreate from scratch, apply this file only.
-- =========================================================

-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enums
CREATE TYPE account_status AS ENUM (  'PENDING_APPROVAL',  'APPROVED',  'REJECTED',  'SUSPENDED',  'INACTIVE');
CREATE TYPE app_role AS ENUM (  'USER',  'VEHICLE_PROVIDER',  'SERVICE_PROVIDER',  'ADMIN');
CREATE TYPE approval_action AS ENUM (  'APPROVE',  'REJECT',  'REQUEST_CORRECTION',  'SUSPEND',  'DELETE');
CREATE TYPE listing_status AS ENUM (  'ACTIVE',  'DRAFT',  'SOLD_OUT',  'ARCHIVED');
CREATE TYPE listing_type AS ENUM (  'PRODUCT',  'FOOD',  'SERVICE',  'ROOM',  'OTHER');
CREATE TYPE notification_type AS ENUM (  'REGISTRATION_RECEIVED',  'APPROVAL',  'REJECTION',  'CORRECTION_REQUIRED',  'ADMIN_MESSAGE',  'ORDER_RECEIVED',  'ORDER_ACCEPTED',  'ORDER_REJECTED',  'RIDE_REQUEST',  'RIDE_CLAIMED',  'RIDE_TAKEN',  'RIDE.NewRequest',  'RIDE.Claimed',  'RIDE.Cancelled',  'RIDE.DriverArriving',  'RIDE.Arrived',  'RIDE.TripStarted',  'RIDE.TripCompleted',  'RIDE.Rated',  'RIDE_STARTED',  'RIDE_COMPLETED',  'PAYMENT_REMINDER',  'PAYMENT_PROOF_REQUIRED',  'WALLET_LOW',  'WALLET_EMPTY',  'SUBSCRIPTION_DUE',  'PROVIDER_INACTIVE',  'TRANSACTION_FEE_DEDUCTED',  'SECURITY');
CREATE TYPE order_status AS ENUM (  'CREATED',  'PENDING_PROVIDER',  'ACCEPTED',  'PAYMENT_PENDING',  'PAYMENT_VERIFICATION',  'APPROVED',  'STARTED',  'COMPLETED',  'CANCELLED',  'DISPUTED',  'REFUNDED',  'REJECTED');
CREATE TYPE recharge_status AS ENUM (  'PENDING',  'APPROVED',  'REJECTED');
CREATE TYPE ride_status AS ENUM (  'REQUESTED',  'CLAIMED',  'DRIVER_ARRIVING',  'DRIVER_EN_ROUTE',  'ARRIVED',  'TRIP_STARTED',  'STARTED',  'COMPLETED',  'CANCELLED');
CREATE TYPE wallet_txn_status AS ENUM (  'PENDING',  'COMPLETED',  'FAILED',  'REVERSED');
CREATE TYPE wallet_txn_type AS ENUM (  'TRANSACTION_FEE',  'SUBSCRIPTION_FEE',  'DEPOSIT',  'RECHARGE',  'WITHDRAWAL',  'ADMIN_CASH',  'ADJUSTMENT',  'REFUND');

-- Tables
CREATE TABLE admin_actions (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL,
  action text NOT NULL,
  target_type text,
  target_id uuid,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE admin_wallet_actions (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL,
  provider_id uuid NOT NULL,
  wallet_id uuid NOT NULL,
  action_type text NOT NULL,
  amount numeric(12,2) NOT NULL,
  reason text NOT NULL,
  balance_before numeric(12,2) NOT NULL,
  balance_after numeric(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE appeals (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  related_type text NOT NULL,
  related_id uuid NOT NULL,
  reason text NOT NULL,
  status text NOT NULL DEFAULT 'PENDING'::text,
  reviewed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE approval_history (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  approval_request_id uuid,
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  action approval_action NOT NULL,
  reason text,
  performed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE approval_requests (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  subject_type text NOT NULL,
  subject_id uuid NOT NULL,
  status account_status NOT NULL DEFAULT 'PENDING_APPROVAL'::account_status,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE audit_logs (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  actor_id uuid,
  event_type text NOT NULL,
  entity_type text,
  entity_id uuid,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE cart_items (  id uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  product_id uuid NOT NULL,
  quantity integer NOT NULL,
  added_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE categories (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  parent_id uuid,
  name text NOT NULL,
  sector text NOT NULL,
  slug text NOT NULL,
  icon text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  description text,
  image_url text,
  marketplace_sector text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE driver_status (  provider_id uuid NOT NULL,
  is_online boolean NOT NULL DEFAULT false,
  current_location geography,
  last_location_update timestamptz,
  current_ride_id uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE favorites (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE fcm_tokens (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  token text NOT NULL,
  device_type text NOT NULL DEFAULT 'android'::text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE listing_images (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  listing_id uuid NOT NULL,
  storage_path text NOT NULL,
  alt_text text,
  is_primary boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE n8n_events (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  event_type text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  payload jsonb,
  status text NOT NULL DEFAULT 'PENDING'::text,
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);
CREATE TABLE notification_preferences (  user_id uuid NOT NULL,
  push_enabled boolean NOT NULL DEFAULT true,
  in_app_enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE notifications (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  type notification_type NOT NULL,
  title text NOT NULL,
  body text,
  data jsonb,
  is_read boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE order_items (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL,
  product_id uuid,
  quantity integer NOT NULL DEFAULT 1,
  unit_price numeric(12,2) NOT NULL,
  subtotal numeric(12,2)
);
CREATE TABLE order_status_history (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL,
  from_status order_status,
  to_status order_status NOT NULL,
  changed_by uuid,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE orders (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  provider_id uuid NOT NULL,
  status order_status NOT NULL DEFAULT 'CREATED'::order_status,
  total_amount numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'ETB'::text,
  requires_payment_proof boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payment_agreements (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL,
  user_id uuid NOT NULL,
  accepted boolean NOT NULL DEFAULT false,
  accepted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payment_methods (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  name text NOT NULL,
  account_name text,
  account_number text,
  instructions text,
  logo_storage_path text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE payment_proofs (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL,
  transaction_id uuid,
  storage_path text NOT NULL,
  verification_status text NOT NULL DEFAULT 'PENDING'::text,
  verified_by uuid,
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE product_images (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  product_id uuid NOT NULL,
  storage_path text NOT NULL,
  sort_order integer DEFAULT 0
);
CREATE TABLE products (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  category_id uuid,
  name text NOT NULL,
  description text,
  price numeric(12,2) NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'ETB'::text,
  quantity integer,
  is_available boolean NOT NULL DEFAULT true,
  is_active boolean NOT NULL DEFAULT true,
  location geography,
  rating numeric DEFAULT 0,
  review_count integer DEFAULT 0,
  sales_count integer DEFAULT 0,
  search_vector tsvector,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  listing_type listing_type NOT NULL DEFAULT 'PRODUCT'::listing_type,
  stock_quantity integer,
  low_stock_threshold integer DEFAULT 5,
  listing_status listing_status NOT NULL DEFAULT 'ACTIVE'::listing_status,
  metadata jsonb
);
CREATE TABLE profiles (  id uuid NOT NULL,
  full_name text NOT NULL,
  phone text,
  email text,
  national_id text,
  status account_status NOT NULL DEFAULT 'PENDING_APPROVAL'::account_status,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE provider_gallery (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  storage_path text NOT NULL,
  caption text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE provider_profiles (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  business_name text NOT NULL,
  business_description text,
  business_address text,
  location_lat double precision,
  location_lng double precision,
  service_category text,
  price_range text,
  is_active boolean NOT NULL DEFAULT false,
  subscription_paid boolean NOT NULL DEFAULT false,
  subscription_due_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  provider_type app_role,
  owner_national_id text,
  status account_status DEFAULT 'PENDING_APPROVAL'::account_status,
  category_id uuid
);
CREATE TABLE provider_stores (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  business_name text NOT NULL,
  description text,
  category_id uuid,
  location geography,
  address_text text,
  contact_phone text,
  contact_email text,
  website_url text,
  logo_storage_path text,
  cover_image_storage_path text,
  rating numeric(3,2) NOT NULL DEFAULT 0,
  review_count integer NOT NULL DEFAULT 0,
  listing_count integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE reviews (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  target_type text NOT NULL,
  target_id uuid NOT NULL,
  order_id uuid,
  rating integer NOT NULL,
  comment text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE ride_ratings (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  ride_request_id uuid NOT NULL,
  rater_id uuid NOT NULL,
  ratee_provider_id uuid,
  rating integer NOT NULL,
  comment text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE ride_requests (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  pickup_location geography NOT NULL,
  destination_location geography NOT NULL,
  pickup_text text,
  destination_text text,
  vehicle_category_id uuid,
  status ride_status NOT NULL DEFAULT 'REQUESTED'::ride_status,
  claimed_by_provider_id uuid,
  claimed_vehicle_id uuid,
  claimed_at timestamptz,
  fare_estimate numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE ride_status_history (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  ride_request_id uuid NOT NULL,
  from_status ride_status,
  to_status ride_status NOT NULL,
  changed_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE subscriptions (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'ACTIVE'::text,
  next_due_date timestamptz NOT NULL,
  last_charged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE support_tickets (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  subject text NOT NULL,
  status text NOT NULL DEFAULT 'OPEN'::text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE system_settings (  key text NOT NULL,
  value jsonb NOT NULL,
  description text,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE user_documents (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  document_type text NOT NULL,
  storage_path text NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE user_roles (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL,
  role app_role NOT NULL,
  assigned_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE vehicle_images (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  vehicle_id uuid NOT NULL,
  storage_path text NOT NULL,
  sort_order integer DEFAULT 0
);
CREATE TABLE vehicles (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  category_id uuid,
  brand text,
  model text,
  plate_number text NOT NULL,
  color text,
  capacity integer,
  current_location geography,
  is_available boolean NOT NULL DEFAULT true,
  status account_status NOT NULL DEFAULT 'PENDING_APPROVAL'::account_status,
  rating numeric DEFAULT 0,
  rating_count integer DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE wallet_recharge_requests (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  wallet_id uuid NOT NULL,
  payment_method_id uuid,
  amount numeric(12,2) NOT NULL,
  currency text NOT NULL DEFAULT 'ETB'::text,
  payment_reference text,
  screenshot_storage_path text,
  status recharge_status NOT NULL DEFAULT 'PENDING'::recharge_status,
  rejection_reason text,
  approved_by uuid,
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE wallet_transactions (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  wallet_id uuid NOT NULL,
  provider_id uuid NOT NULL,
  order_id uuid,
  ride_request_id uuid,
  transaction_type wallet_txn_type NOT NULL,
  gross_amount numeric(12,2) NOT NULL DEFAULT 0,
  platform_fee numeric(12,2) NOT NULL DEFAULT 0,
  net_amount numeric(12,2) NOT NULL DEFAULT 0,
  balance_after numeric(12,2) NOT NULL,
  status wallet_txn_status NOT NULL DEFAULT 'COMPLETED'::wallet_txn_status,
  idempotency_key text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE wallets (  id uuid NOT NULL DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL,
  balance numeric(12,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'ACTIVE'::text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Primary Keys
ALTER TABLE admin_actions ADD PRIMARY KEY (id);
ALTER TABLE admin_wallet_actions ADD PRIMARY KEY (id);
ALTER TABLE appeals ADD PRIMARY KEY (id);
ALTER TABLE approval_history ADD PRIMARY KEY (id);
ALTER TABLE approval_requests ADD PRIMARY KEY (id);
ALTER TABLE audit_logs ADD PRIMARY KEY (id);
ALTER TABLE cart_items ADD PRIMARY KEY (id);
ALTER TABLE categories ADD PRIMARY KEY (id);
ALTER TABLE driver_status ADD PRIMARY KEY (provider_id);
ALTER TABLE favorites ADD PRIMARY KEY (id);
ALTER TABLE fcm_tokens ADD PRIMARY KEY (id);
ALTER TABLE listing_images ADD PRIMARY KEY (id);
ALTER TABLE n8n_events ADD PRIMARY KEY (id);
ALTER TABLE notification_preferences ADD PRIMARY KEY (user_id);
ALTER TABLE notifications ADD PRIMARY KEY (id);
ALTER TABLE order_items ADD PRIMARY KEY (id);
ALTER TABLE order_status_history ADD PRIMARY KEY (id);
ALTER TABLE orders ADD PRIMARY KEY (id);
ALTER TABLE payment_agreements ADD PRIMARY KEY (id);
ALTER TABLE payment_methods ADD PRIMARY KEY (id);
ALTER TABLE payment_proofs ADD PRIMARY KEY (id);
ALTER TABLE product_images ADD PRIMARY KEY (id);
ALTER TABLE products ADD PRIMARY KEY (id);
ALTER TABLE profiles ADD PRIMARY KEY (id);
ALTER TABLE provider_gallery ADD PRIMARY KEY (id);
ALTER TABLE provider_profiles ADD PRIMARY KEY (id);
ALTER TABLE provider_stores ADD PRIMARY KEY (id);
ALTER TABLE reviews ADD PRIMARY KEY (id);
ALTER TABLE ride_ratings ADD PRIMARY KEY (id);
ALTER TABLE ride_requests ADD PRIMARY KEY (id);
ALTER TABLE ride_status_history ADD PRIMARY KEY (id);
ALTER TABLE spatial_ref_sys ADD PRIMARY KEY (srid);
ALTER TABLE subscriptions ADD PRIMARY KEY (id);
ALTER TABLE support_tickets ADD PRIMARY KEY (id);
ALTER TABLE system_settings ADD PRIMARY KEY (key);
ALTER TABLE user_documents ADD PRIMARY KEY (id);
ALTER TABLE user_roles ADD PRIMARY KEY (id);
ALTER TABLE vehicle_images ADD PRIMARY KEY (id);
ALTER TABLE vehicles ADD PRIMARY KEY (id);
ALTER TABLE wallet_recharge_requests ADD PRIMARY KEY (id);
ALTER TABLE wallet_transactions ADD PRIMARY KEY (id);
ALTER TABLE wallets ADD PRIMARY KEY (id);

-- Foreign Keys
ALTER TABLE admin_actions ADD CONSTRAINT admin_actions_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES auth.users (id);
ALTER TABLE admin_wallet_actions ADD CONSTRAINT admin_wallet_actions_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id);
ALTER TABLE admin_wallet_actions ADD CONSTRAINT admin_wallet_actions_wallet_id_fkey FOREIGN KEY (wallet_id) REFERENCES wallets (id);
ALTER TABLE admin_wallet_actions ADD CONSTRAINT admin_wallet_actions_admin_id_fkey FOREIGN KEY (admin_id) REFERENCES auth.users (id);
ALTER TABLE appeals ADD CONSTRAINT appeals_reviewed_by_fkey FOREIGN KEY (reviewed_by) REFERENCES auth.users (id);
ALTER TABLE appeals ADD CONSTRAINT appeals_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE approval_history ADD CONSTRAINT approval_history_approval_request_id_fkey FOREIGN KEY (approval_request_id) REFERENCES approval_requests (id) ON DELETE SET NULL;
ALTER TABLE approval_history ADD CONSTRAINT approval_history_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES auth.users (id);
ALTER TABLE audit_logs ADD CONSTRAINT audit_logs_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES auth.users (id);
ALTER TABLE cart_items ADD CONSTRAINT cart_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE;
ALTER TABLE cart_items ADD CONSTRAINT cart_items_user_id_fkey FOREIGN KEY (user_id) REFERENCES profiles (id) ON DELETE CASCADE;
ALTER TABLE categories ADD CONSTRAINT categories_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES categories (id) ON DELETE CASCADE;
ALTER TABLE driver_status ADD CONSTRAINT driver_status_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE driver_status ADD CONSTRAINT driver_status_current_ride_id_fkey FOREIGN KEY (current_ride_id) REFERENCES ride_requests (id);
ALTER TABLE favorites ADD CONSTRAINT favorites_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE fcm_tokens ADD CONSTRAINT fcm_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE listing_images ADD CONSTRAINT listing_images_listing_id_fkey FOREIGN KEY (listing_id) REFERENCES products (id) ON DELETE CASCADE;
ALTER TABLE notification_preferences ADD CONSTRAINT notification_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE notifications ADD CONSTRAINT notifications_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE order_items ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES products (id);
ALTER TABLE order_items ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE;
ALTER TABLE order_status_history ADD CONSTRAINT order_status_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users (id);
ALTER TABLE order_status_history ADD CONSTRAINT order_status_history_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE;
ALTER TABLE orders ADD CONSTRAINT orders_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE orders ADD CONSTRAINT orders_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id);
ALTER TABLE payment_agreements ADD CONSTRAINT payment_agreements_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE payment_agreements ADD CONSTRAINT payment_agreements_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE;
ALTER TABLE payment_methods ADD CONSTRAINT payment_methods_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users (id);
ALTER TABLE payment_proofs ADD CONSTRAINT payment_proofs_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE;
ALTER TABLE payment_proofs ADD CONSTRAINT payment_proofs_verified_by_fkey FOREIGN KEY (verified_by) REFERENCES auth.users (id);
ALTER TABLE product_images ADD CONSTRAINT product_images_product_id_fkey FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE;
ALTER TABLE products ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories (id);
ALTER TABLE products ADD CONSTRAINT products_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE profiles ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE provider_gallery ADD CONSTRAINT provider_gallery_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE provider_profiles ADD CONSTRAINT fk_provider_category FOREIGN KEY (category_id) REFERENCES categories (id);
ALTER TABLE provider_profiles ADD CONSTRAINT provider_profiles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE provider_stores ADD CONSTRAINT provider_stores_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE provider_stores ADD CONSTRAINT provider_stores_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories (id);
ALTER TABLE reviews ADD CONSTRAINT reviews_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id);
ALTER TABLE reviews ADD CONSTRAINT reviews_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE ride_ratings ADD CONSTRAINT ride_ratings_ride_request_id_fkey FOREIGN KEY (ride_request_id) REFERENCES ride_requests (id) ON DELETE CASCADE;
ALTER TABLE ride_ratings ADD CONSTRAINT ride_ratings_ratee_provider_id_fkey FOREIGN KEY (ratee_provider_id) REFERENCES provider_profiles (id);
ALTER TABLE ride_ratings ADD CONSTRAINT ride_ratings_rater_id_fkey FOREIGN KEY (rater_id) REFERENCES auth.users (id);
ALTER TABLE ride_requests ADD CONSTRAINT ride_requests_claimed_vehicle_id_fkey FOREIGN KEY (claimed_vehicle_id) REFERENCES vehicles (id);
ALTER TABLE ride_requests ADD CONSTRAINT ride_requests_claimed_by_provider_id_fkey FOREIGN KEY (claimed_by_provider_id) REFERENCES provider_profiles (id);
ALTER TABLE ride_requests ADD CONSTRAINT ride_requests_vehicle_category_id_fkey FOREIGN KEY (vehicle_category_id) REFERENCES categories (id);
ALTER TABLE ride_requests ADD CONSTRAINT ride_requests_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE ride_status_history ADD CONSTRAINT ride_status_history_ride_request_id_fkey FOREIGN KEY (ride_request_id) REFERENCES ride_requests (id) ON DELETE CASCADE;
ALTER TABLE ride_status_history ADD CONSTRAINT ride_status_history_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES auth.users (id);
ALTER TABLE subscriptions ADD CONSTRAINT subscriptions_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE support_tickets ADD CONSTRAINT support_tickets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id);
ALTER TABLE user_documents ADD CONSTRAINT user_documents_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE user_roles ADD CONSTRAINT user_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users (id) ON DELETE CASCADE;
ALTER TABLE vehicle_images ADD CONSTRAINT vehicle_images_vehicle_id_fkey FOREIGN KEY (vehicle_id) REFERENCES vehicles (id) ON DELETE CASCADE;
ALTER TABLE vehicles ADD CONSTRAINT vehicles_category_id_fkey FOREIGN KEY (category_id) REFERENCES categories (id);
ALTER TABLE vehicles ADD CONSTRAINT vehicles_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE wallet_recharge_requests ADD CONSTRAINT wallet_recharge_requests_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;
ALTER TABLE wallet_recharge_requests ADD CONSTRAINT wallet_recharge_requests_wallet_id_fkey FOREIGN KEY (wallet_id) REFERENCES wallets (id) ON DELETE CASCADE;
ALTER TABLE wallet_recharge_requests ADD CONSTRAINT wallet_recharge_requests_payment_method_id_fkey FOREIGN KEY (payment_method_id) REFERENCES payment_methods (id);
ALTER TABLE wallet_recharge_requests ADD CONSTRAINT wallet_recharge_requests_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES auth.users (id);
ALTER TABLE wallet_transactions ADD CONSTRAINT wallet_transactions_ride_request_id_fkey FOREIGN KEY (ride_request_id) REFERENCES ride_requests (id);
ALTER TABLE wallet_transactions ADD CONSTRAINT wallet_transactions_wallet_id_fkey FOREIGN KEY (wallet_id) REFERENCES wallets (id) ON DELETE CASCADE;
ALTER TABLE wallet_transactions ADD CONSTRAINT wallet_transactions_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id);
ALTER TABLE wallet_transactions ADD CONSTRAINT wallet_transactions_order_id_fkey FOREIGN KEY (order_id) REFERENCES orders (id);
ALTER TABLE wallets ADD CONSTRAINT wallets_provider_id_fkey FOREIGN KEY (provider_id) REFERENCES provider_profiles (id) ON DELETE CASCADE;

-- Indexes
CREATE INDEX idx_admin_wallet_actions_admin ON public.admin_wallet_actions USING btree (admin_id);
CREATE INDEX idx_admin_wallet_actions_provider ON public.admin_wallet_actions USING btree (provider_id);
CREATE INDEX idx_approval_history_subject ON public.approval_history USING btree (subject_type, subject_id);
CREATE INDEX idx_audit_logs_actor ON public.audit_logs USING btree (actor_id);
CREATE INDEX idx_audit_logs_entity ON public.audit_logs USING btree (entity_type, entity_id);
CREATE UNIQUE INDEX cart_items_user_id_product_id_key ON public.cart_items USING btree (user_id, product_id);
CREATE UNIQUE INDEX categories_slug_key ON public.categories USING btree (slug);
CREATE INDEX idx_categories_marketplace_sector ON public.categories USING btree (marketplace_sector) WHERE (marketplace_sector IS NOT NULL);
CREATE INDEX idx_categories_parent ON public.categories USING btree (parent_id);
CREATE INDEX idx_categories_sector ON public.categories USING btree (sector);
CREATE INDEX idx_driver_status_location ON public.driver_status USING gist (current_location);
CREATE INDEX idx_driver_status_online ON public.driver_status USING btree (is_online) WHERE (is_online = true);
CREATE INDEX idx_driver_status_provider ON public.driver_status USING btree (provider_id);
CREATE UNIQUE INDEX favorites_user_id_target_type_target_id_key ON public.favorites USING btree (user_id, target_type, target_id);
CREATE UNIQUE INDEX fcm_tokens_user_id_token_key ON public.fcm_tokens USING btree (user_id, token);
CREATE INDEX idx_fcm_tokens_active ON public.fcm_tokens USING btree (is_active) WHERE (is_active = true);
CREATE INDEX idx_fcm_tokens_user ON public.fcm_tokens USING btree (user_id);
CREATE INDEX idx_listing_images_listing ON public.listing_images USING btree (listing_id);
CREATE INDEX idx_listing_images_primary ON public.listing_images USING btree (listing_id) WHERE (is_primary = true);
CREATE INDEX idx_listing_images_sort ON public.listing_images USING btree (listing_id, sort_order);
CREATE INDEX idx_n8n_events_entity ON public.n8n_events USING btree (entity_type, entity_id);
CREATE INDEX idx_n8n_events_status ON public.n8n_events USING btree (status);
CREATE INDEX idx_n8n_events_type ON public.n8n_events USING btree (event_type, entity_type);
CREATE INDEX idx_notifications_user ON public.notifications USING btree (user_id, is_read);
CREATE INDEX idx_order_items_order ON public.order_items USING btree (order_id);
CREATE INDEX idx_order_status_history_order ON public.order_status_history USING btree (order_id);
CREATE INDEX idx_orders_provider ON public.orders USING btree (provider_id);
CREATE INDEX idx_orders_status ON public.orders USING btree (status);
CREATE INDEX idx_orders_user ON public.orders USING btree (user_id);
CREATE UNIQUE INDEX payment_agreements_order_id_key ON public.payment_agreements USING btree (order_id);
CREATE INDEX idx_payment_methods_active ON public.payment_methods USING btree (is_active) WHERE (is_active = true);
CREATE INDEX idx_payment_proofs_order ON public.payment_proofs USING btree (order_id);
CREATE INDEX idx_product_images_product ON public.product_images USING btree (product_id);
CREATE INDEX idx_products_category ON public.products USING btree (category_id);
CREATE INDEX idx_products_category_status ON public.products USING btree (category_id, listing_status) WHERE (listing_status = 'ACTIVE'::listing_status);
CREATE INDEX idx_products_listing_status ON public.products USING btree (listing_status);
CREATE INDEX idx_products_listing_type ON public.products USING btree (listing_type);
CREATE INDEX idx_products_location ON public.products USING gist (location);
CREATE INDEX idx_products_metadata ON public.products USING gin (metadata) WHERE (metadata IS NOT NULL);
CREATE INDEX idx_products_price ON public.products USING btree (price) WHERE ((listing_status = 'ACTIVE'::listing_status) AND (is_active = true));
CREATE INDEX idx_products_provider ON public.products USING btree (provider_id);
CREATE INDEX idx_products_provider_status_active ON public.products USING btree (provider_id, listing_status) WHERE ((listing_status = 'ACTIVE'::listing_status) AND (is_active = true));
CREATE INDEX idx_products_search ON public.products USING gin (search_vector);
CREATE INDEX idx_products_status_created ON public.products USING btree (listing_status, created_at DESC) WHERE (listing_status = 'ACTIVE'::listing_status);
CREATE INDEX idx_products_trgm_name ON public.products USING gin (name gin_trgm_ops);
CREATE INDEX idx_products_type_status ON public.products USING btree (listing_type, listing_status);
CREATE UNIQUE INDEX profiles_phone_key ON public.profiles USING btree (phone);
CREATE INDEX idx_provider_gallery_active ON public.provider_gallery USING btree (provider_id, is_active) WHERE (is_active = true);
CREATE INDEX idx_provider_gallery_order ON public.provider_gallery USING btree (provider_id, display_order);
CREATE INDEX idx_provider_gallery_provider ON public.provider_gallery USING btree (provider_id);
CREATE INDEX idx_provider_profiles_business_name ON public.provider_profiles USING btree (business_name);
CREATE INDEX idx_provider_profiles_business_name_trgm ON public.provider_profiles USING gin (business_name gin_trgm_ops);
CREATE INDEX idx_provider_stores_active ON public.provider_stores USING btree (is_active) WHERE (is_active = true);
CREATE INDEX idx_provider_stores_category ON public.provider_stores USING btree (category_id);
CREATE INDEX idx_provider_stores_location ON public.provider_stores USING gist (location);
CREATE INDEX idx_provider_stores_provider ON public.provider_stores USING btree (provider_id);
CREATE INDEX idx_provider_stores_rating ON public.provider_stores USING btree (rating DESC);
CREATE INDEX idx_provider_stores_sector_active ON public.provider_stores USING btree (is_active) WHERE (is_active = true);
CREATE UNIQUE INDEX provider_stores_provider_id_key ON public.provider_stores USING btree (provider_id);
CREATE INDEX idx_reviews_target ON public.reviews USING btree (target_type, target_id);
CREATE UNIQUE INDEX reviews_user_id_target_type_target_id_order_id_key ON public.reviews USING btree (user_id, target_type, target_id, order_id);
CREATE INDEX idx_ride_ratings_provider ON public.ride_ratings USING btree (ratee_provider_id);
CREATE INDEX idx_ride_ratings_ride ON public.ride_ratings USING btree (ride_request_id);
CREATE UNIQUE INDEX ride_ratings_ride_request_id_rater_id_key ON public.ride_ratings USING btree (ride_request_id, rater_id);
CREATE INDEX idx_ride_requests_pickup ON public.ride_requests USING gist (pickup_location);
CREATE INDEX idx_ride_requests_provider ON public.ride_requests USING btree (claimed_by_provider_id);
CREATE INDEX idx_ride_requests_provider_status ON public.ride_requests USING btree (claimed_by_provider_id, status);
CREATE INDEX idx_ride_requests_status ON public.ride_requests USING btree (status);
CREATE INDEX idx_ride_requests_user_status ON public.ride_requests USING btree (user_id, status);
CREATE UNIQUE INDEX uq_ride_single_claim ON public.ride_requests USING btree (id) WHERE (status = 'CLAIMED'::ride_status);
CREATE UNIQUE INDEX subscriptions_provider_id_key ON public.subscriptions USING btree (provider_id);
CREATE INDEX idx_user_documents_user ON public.user_documents USING btree (user_id);
CREATE UNIQUE INDEX user_roles_user_id_role_key ON public.user_roles USING btree (user_id, role);
CREATE INDEX idx_vehicles_available ON public.vehicles USING btree (is_available) WHERE (is_available = true);
CREATE INDEX idx_vehicles_location ON public.vehicles USING gist (current_location);
CREATE INDEX idx_vehicles_provider ON public.vehicles USING btree (provider_id);
CREATE UNIQUE INDEX vehicles_plate_number_key ON public.vehicles USING btree (plate_number);
CREATE INDEX idx_recharge_requests_provider ON public.wallet_recharge_requests USING btree (provider_id);
CREATE INDEX idx_recharge_requests_status ON public.wallet_recharge_requests USING btree (status);
CREATE INDEX idx_recharge_requests_wallet ON public.wallet_recharge_requests USING btree (wallet_id);
CREATE INDEX idx_wallet_txn_provider ON public.wallet_transactions USING btree (provider_id);
CREATE INDEX idx_wallet_txn_wallet ON public.wallet_transactions USING btree (wallet_id);
CREATE UNIQUE INDEX wallet_transactions_idempotency_key_key ON public.wallet_transactions USING btree (idempotency_key);
CREATE UNIQUE INDEX wallets_provider_id_key ON public.wallets USING btree (provider_id);

-- RLS
ALTER TABLE admin_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_wallet_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcm_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE n8n_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_gallery ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_recharge_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;

CREATE POLICY admin_actions_admin_only ON admin_actions FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY admin_wallet_actions_admin_only ON admin_wallet_actions FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY appeals_admin_update ON appeals FOR UPDATE USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY appeals_owner ON appeals FOR SELECT USING (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY appeals_owner_insert ON appeals FOR INSERT WITH CHECK ((user_id = auth.uid()));
CREATE POLICY approval_history_admin_all ON approval_history FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY approval_history_owner_read ON approval_history FOR SELECT USING ((((subject_type = 'USER'::text) AND (subject_id = auth.uid())) OR ((subject_type = 'PROVIDER'::text) AND owns_provider_profile(subject_id)) OR is_admin()));
CREATE POLICY approval_requests_admin_all ON approval_requests FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY approval_requests_owner_read ON approval_requests FOR SELECT USING ((((subject_type = 'USER'::text) AND (subject_id = auth.uid())) OR ((subject_type = 'PROVIDER'::text) AND owns_provider_profile(subject_id)) OR is_admin()));
CREATE POLICY audit_logs_admin_only ON audit_logs FOR SELECT USING (is_admin());
CREATE POLICY Users manage their own cart ON cart_items FOR ALL USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));
CREATE POLICY categories_admin_write ON categories FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY categories_public_read ON categories FOR SELECT USING (((is_active = true) OR is_admin()));
CREATE POLICY driver_status_admin ON driver_status FOR SELECT USING (is_admin());
CREATE POLICY driver_status_own ON driver_status FOR ALL USING ((provider_id IN ( SELECT provider_profiles.id
   FROM provider_profiles
  WHERE (provider_profiles.user_id = auth.uid())))) WITH CHECK ((provider_id IN ( SELECT provider_profiles.id
   FROM provider_profiles
  WHERE (provider_profiles.user_id = auth.uid()))));
CREATE POLICY favorites_owner_all ON favorites FOR ALL USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY fcm_tokens_admin_all ON fcm_tokens FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY fcm_tokens_owner_all ON fcm_tokens FOR ALL USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY listing_images_admin_all ON listing_images FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY listing_images_owner_delete ON listing_images FOR DELETE USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.provider_id IN ( SELECT pp.id
           FROM provider_profiles pp
          WHERE (pp.user_id = auth.uid())))))));
CREATE POLICY listing_images_owner_insert ON listing_images FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.provider_id IN ( SELECT pp.id
           FROM provider_profiles pp
          WHERE (pp.user_id = auth.uid())))))));
CREATE POLICY listing_images_owner_read ON listing_images FOR SELECT USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.provider_id IN ( SELECT pp.id
           FROM provider_profiles pp
          WHERE (pp.user_id = auth.uid())))))));
CREATE POLICY listing_images_owner_update ON listing_images FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.provider_id IN ( SELECT pp.id
           FROM provider_profiles pp
          WHERE (pp.user_id = auth.uid()))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.provider_id IN ( SELECT pp.id
           FROM provider_profiles pp
          WHERE (pp.user_id = auth.uid())))))));
CREATE POLICY listing_images_public_read ON listing_images FOR SELECT USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = listing_images.listing_id) AND (p.is_active = true) AND (p.listing_status = 'ACTIVE'::listing_status)))));
CREATE POLICY n8n_events_admin_only ON n8n_events FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY notification_prefs_owner ON notification_preferences FOR ALL USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY notifications_admin_all ON notifications FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY notifications_owner_read ON notifications FOR SELECT USING (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY notifications_owner_update ON notifications FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY order_items_read ON order_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND ((o.user_id = auth.uid()) OR owns_provider_profile(o.provider_id) OR is_admin())))));
CREATE POLICY order_items_user_insert ON order_items FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_items.order_id) AND (o.user_id = auth.uid())))));
CREATE POLICY order_status_history_read ON order_status_history FOR SELECT USING ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = order_status_history.order_id) AND ((o.user_id = auth.uid()) OR owns_provider_profile(o.provider_id) OR is_admin())))));
CREATE POLICY orders_admin_all ON orders FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY orders_admin_update ON orders FOR UPDATE USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY orders_user_insert ON orders FOR INSERT WITH CHECK ((user_id = auth.uid()));
CREATE POLICY orders_user_read ON orders FOR SELECT USING (((user_id = auth.uid()) OR owns_provider_profile(provider_id) OR is_admin()));
CREATE POLICY payment_agreements_user ON payment_agreements FOR ALL USING (((user_id = auth.uid()) OR is_admin())) WITH CHECK (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY payment_methods_admin_all ON payment_methods FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY payment_methods_read_active ON payment_methods FOR SELECT USING (((is_active = true) OR is_admin()));
CREATE POLICY payment_proofs_admin_verify ON payment_proofs FOR UPDATE USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY payment_proofs_read ON payment_proofs FOR SELECT USING ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = payment_proofs.order_id) AND ((o.user_id = auth.uid()) OR owns_provider_profile(o.provider_id) OR is_admin())))));
CREATE POLICY payment_proofs_user_insert ON payment_proofs FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = payment_proofs.order_id) AND (o.user_id = auth.uid())))));
CREATE POLICY product_images_owner_write ON product_images FOR ALL USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = product_images.product_id) AND owns_provider_profile(p.provider_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = product_images.product_id) AND owns_provider_profile(p.provider_id)))));
CREATE POLICY product_images_read ON product_images FOR SELECT USING ((EXISTS ( SELECT 1
   FROM products p
  WHERE ((p.id = product_images.product_id) AND ((p.is_active = true) OR owns_provider_profile(p.provider_id) OR is_admin())))));
CREATE POLICY products_admin_all ON products FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY products_provider_delete ON products FOR DELETE USING (owns_provider_profile(provider_id));
CREATE POLICY products_provider_insert ON products FOR INSERT WITH CHECK (owns_provider_profile(provider_id));
CREATE POLICY products_provider_update ON products FOR UPDATE USING (owns_provider_profile(provider_id)) WITH CHECK (owns_provider_profile(provider_id));
CREATE POLICY products_public_read ON products FOR SELECT USING (((is_active = true) OR owns_provider_profile(provider_id) OR is_admin()));
CREATE POLICY Users can insert own profile ON profiles FOR INSERT WITH CHECK ((auth.uid() = id));
CREATE POLICY Users can read own profile ON profiles FOR SELECT USING ((auth.uid() = id));
CREATE POLICY Users can update own profile ON profiles FOR UPDATE USING ((auth.uid() = id));
CREATE POLICY profiles_admin_all ON profiles FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY profiles_insert_own ON profiles FOR INSERT WITH CHECK ((id = auth.uid()));
CREATE POLICY profiles_select_own ON profiles FOR SELECT USING (((id = auth.uid()) OR is_admin()));
CREATE POLICY profiles_update_own ON profiles FOR UPDATE USING ((id = auth.uid())) WITH CHECK ((id = auth.uid()));
CREATE POLICY provider_gallery_admin_all ON provider_gallery FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY provider_gallery_owner_delete ON provider_gallery FOR DELETE USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_gallery_owner_insert ON provider_gallery FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.user_id = auth.uid()) AND (pp.status = 'APPROVED'::account_status)))));
CREATE POLICY provider_gallery_owner_read ON provider_gallery FOR SELECT USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_gallery_owner_update ON provider_gallery FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_gallery_public_read ON provider_gallery FOR SELECT USING (((is_active = true) AND (EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_gallery.provider_id) AND (pp.status = 'APPROVED'::account_status))))));
CREATE POLICY provider_profiles_admin_all ON provider_profiles FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY provider_profiles_insert_own ON provider_profiles FOR INSERT WITH CHECK ((user_id = auth.uid()));
CREATE POLICY provider_profiles_public_read ON provider_profiles FOR SELECT USING (((status = 'APPROVED'::account_status) OR (user_id = auth.uid()) OR is_admin()));
CREATE POLICY provider_profiles_update_own ON provider_profiles FOR UPDATE USING (((user_id = auth.uid()) AND (status <> 'APPROVED'::account_status))) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY provider_stores_admin_all ON provider_stores FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY provider_stores_owner_delete ON provider_stores FOR DELETE USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_stores_owner_insert ON provider_stores FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.user_id = auth.uid()) AND (pp.status = 'APPROVED'::account_status)))));
CREATE POLICY provider_stores_owner_read ON provider_stores FOR SELECT USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_stores_owner_update ON provider_stores FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.user_id = auth.uid())))));
CREATE POLICY provider_stores_public_read ON provider_stores FOR SELECT USING (((is_active = true) AND (EXISTS ( SELECT 1
   FROM provider_profiles pp
  WHERE ((pp.id = provider_stores.provider_id) AND (pp.status = 'APPROVED'::account_status))))));
CREATE POLICY reviews_admin_moderate ON reviews FOR DELETE USING (is_admin());
CREATE POLICY reviews_owner_delete ON reviews FOR DELETE USING ((user_id = auth.uid()));
CREATE POLICY reviews_owner_update ON reviews FOR UPDATE USING ((user_id = auth.uid())) WITH CHECK ((user_id = auth.uid()));
CREATE POLICY reviews_public_read ON reviews FOR SELECT USING (true);
CREATE POLICY reviews_user_insert ON reviews FOR INSERT WITH CHECK (((user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM orders o
  WHERE ((o.id = reviews.order_id) AND (o.user_id = auth.uid()) AND (o.status = 'COMPLETED'::order_status))))));
CREATE POLICY ride_ratings_admin ON ride_ratings FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY ride_ratings_insert_own ON ride_ratings FOR INSERT WITH CHECK ((rater_id = auth.uid()));
CREATE POLICY ride_ratings_read ON ride_ratings FOR SELECT USING (true);
CREATE POLICY ride_requests_admin_all ON ride_requests FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY ride_requests_claimed_provider_read ON ride_requests FOR SELECT USING (owns_provider_profile(claimed_by_provider_id));
CREATE POLICY ride_requests_provider_read_open ON ride_requests FOR SELECT USING (((status = 'REQUESTED'::ride_status) AND has_role('VEHICLE_PROVIDER'::app_role)));
CREATE POLICY ride_requests_user_cancel ON ride_requests FOR UPDATE USING (((user_id = auth.uid()) AND (status = 'REQUESTED'::ride_status))) WITH CHECK ((status = 'CANCELLED'::ride_status));
CREATE POLICY ride_requests_user_insert ON ride_requests FOR INSERT WITH CHECK ((user_id = auth.uid()));
CREATE POLICY ride_requests_user_read ON ride_requests FOR SELECT USING (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY ride_status_history_read ON ride_status_history FOR SELECT USING ((EXISTS ( SELECT 1
   FROM ride_requests r
  WHERE ((r.id = ride_status_history.ride_request_id) AND ((r.user_id = auth.uid()) OR owns_provider_profile(r.claimed_by_provider_id) OR is_admin())))));
CREATE POLICY subscriptions_admin_all ON subscriptions FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY subscriptions_owner_read ON subscriptions FOR SELECT USING ((owns_provider_profile(provider_id) OR is_admin()));
CREATE POLICY support_tickets_owner ON support_tickets FOR ALL USING (((user_id = auth.uid()) OR is_admin())) WITH CHECK (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY system_settings_admin_write ON system_settings FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY system_settings_read ON system_settings FOR SELECT USING (true);
CREATE POLICY user_documents_admin_manage ON user_documents FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY user_documents_insert_own ON user_documents FOR INSERT WITH CHECK ((user_id = auth.uid()));
CREATE POLICY user_documents_owner ON user_documents FOR SELECT USING (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY Service role can insert roles ON user_roles FOR INSERT WITH CHECK (true);
CREATE POLICY Users can read own roles ON user_roles FOR SELECT USING ((auth.uid() = user_id));
CREATE POLICY user_roles_admin_delete ON user_roles FOR DELETE USING (is_admin());
CREATE POLICY user_roles_admin_update ON user_roles FOR UPDATE USING (is_admin());
CREATE POLICY user_roles_admin_write ON user_roles FOR INSERT WITH CHECK (is_admin());
CREATE POLICY user_roles_select_own ON user_roles FOR SELECT USING (((user_id = auth.uid()) OR is_admin()));
CREATE POLICY vehicle_images_owner_write ON vehicle_images FOR ALL USING ((EXISTS ( SELECT 1
   FROM vehicles v
  WHERE ((v.id = vehicle_images.vehicle_id) AND owns_provider_profile(v.provider_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM vehicles v
  WHERE ((v.id = vehicle_images.vehicle_id) AND owns_provider_profile(v.provider_id)))));
CREATE POLICY vehicle_images_read ON vehicle_images FOR SELECT USING ((EXISTS ( SELECT 1
   FROM vehicles v
  WHERE ((v.id = vehicle_images.vehicle_id) AND ((v.status = 'APPROVED'::account_status) OR owns_provider_profile(v.provider_id) OR is_admin())))));
CREATE POLICY vehicles_admin_all ON vehicles FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY vehicles_provider_delete ON vehicles FOR DELETE USING (owns_provider_profile(provider_id));
CREATE POLICY vehicles_provider_insert ON vehicles FOR INSERT WITH CHECK (owns_provider_profile(provider_id));
CREATE POLICY vehicles_provider_update ON vehicles FOR UPDATE USING (owns_provider_profile(provider_id)) WITH CHECK (owns_provider_profile(provider_id));
CREATE POLICY vehicles_public_read ON vehicles FOR SELECT USING (((status = 'APPROVED'::account_status) OR owns_provider_profile(provider_id) OR is_admin()));
CREATE POLICY recharge_requests_admin_all ON wallet_recharge_requests FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY recharge_requests_provider_insert ON wallet_recharge_requests FOR INSERT WITH CHECK ((provider_id IN ( SELECT provider_profiles.id
   FROM provider_profiles
  WHERE (provider_profiles.user_id = auth.uid()))));
CREATE POLICY recharge_requests_provider_read_own ON wallet_recharge_requests FOR SELECT USING ((provider_id IN ( SELECT provider_profiles.id
   FROM provider_profiles
  WHERE (provider_profiles.user_id = auth.uid()))));
CREATE POLICY wallet_transactions_admin_all ON wallet_transactions FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY wallet_transactions_owner_read ON wallet_transactions FOR SELECT USING ((owns_provider_profile(provider_id) OR is_admin()));
CREATE POLICY wallets_admin_all ON wallets FOR ALL USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY wallets_owner_read ON wallets FOR SELECT USING ((owns_provider_profile(provider_id) OR is_admin()));

-- Triggers
CREATE TRIGGER trg_approval_history_immutable
  BEFORE UPDATE OR DELETE
  ON approval_history FOR EACH ROW
  EXECUTE FUNCTION prevent_approval_history_mutation();
CREATE TRIGGER trg_audit_logs_immutable
  BEFORE UPDATE OR DELETE
  ON audit_logs FOR EACH ROW
  EXECUTE FUNCTION prevent_audit_log_deletion();
CREATE TRIGGER trg_categories_updated
  BEFORE UPDATE
  ON categories FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_notifications_security
  BEFORE INSERT
  ON notifications FOR EACH ROW
  EXECUTE FUNCTION prevent_notification_injection();
CREATE TRIGGER trg_orders_insert_security
  BEFORE INSERT
  ON orders FOR EACH ROW
  EXECUTE FUNCTION prevent_order_insert_privilege_escalation();
CREATE TRIGGER trg_orders_security
  BEFORE UPDATE
  ON orders FOR EACH ROW
  EXECUTE FUNCTION prevent_order_self_privilege_escalation();
CREATE TRIGGER trg_orders_updated
  BEFORE UPDATE
  ON orders FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_payment_agreements_security
  BEFORE UPDATE
  ON payment_agreements FOR EACH ROW
  EXECUTE FUNCTION prevent_payment_agreement_unaccept();
CREATE TRIGGER trg_payment_methods_updated
  BEFORE UPDATE
  ON payment_methods FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_payment_proofs_security
  BEFORE UPDATE
  ON payment_proofs FOR EACH ROW
  EXECUTE FUNCTION prevent_payment_proof_self_verification();
CREATE TRIGGER trg_products_insert_security
  BEFORE INSERT
  ON products FOR EACH ROW
  EXECUTE FUNCTION prevent_product_insert_privilege_escalation();
CREATE TRIGGER trg_products_listing_status_security
  BEFORE UPDATE
  ON products FOR EACH ROW
  EXECUTE FUNCTION prevent_inactive_provider_publish();
CREATE TRIGGER trg_products_listing_status_security_insert
  BEFORE INSERT
  ON products FOR EACH ROW
  EXECUTE FUNCTION prevent_inactive_provider_publish_insert();
CREATE TRIGGER trg_products_sync_store_count
  AFTER INSERT OR DELETE
  ON products FOR EACH ROW
  EXECUTE FUNCTION sync_store_listing_count();
CREATE TRIGGER trg_products_sync_store_count_status
  AFTER UPDATE
  ON products FOR EACH ROW
  EXECUTE FUNCTION sync_store_listing_count_on_status();
CREATE TRIGGER trg_products_updated
  BEFORE UPDATE
  ON products FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_profiles_auto_approval_request
  AFTER INSERT
  ON profiles FOR EACH ROW
  EXECUTE FUNCTION auto_create_user_approval_request();
CREATE TRIGGER trg_profiles_insert_security
  BEFORE INSERT
  ON profiles FOR EACH ROW
  EXECUTE FUNCTION prevent_profile_insert_privilege_escalation();
CREATE TRIGGER trg_profiles_security
  BEFORE UPDATE
  ON profiles FOR EACH ROW
  EXECUTE FUNCTION prevent_profile_self_privilege_escalation();
CREATE TRIGGER trg_profiles_updated
  BEFORE UPDATE
  ON profiles FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_provider_gallery_updated
  BEFORE UPDATE
  ON provider_gallery FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_provider_profiles_auto_setup
  AFTER INSERT
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION handle_new_provider_profile();
CREATE TRIGGER trg_provider_profiles_driver_status
  AFTER UPDATE
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION auto_create_driver_status();
CREATE TRIGGER trg_provider_profiles_driver_status_insert
  AFTER INSERT
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION auto_create_driver_status_insert();
CREATE TRIGGER trg_provider_profiles_insert_security
  BEFORE INSERT
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION prevent_provider_insert_privilege_escalation();
CREATE TRIGGER trg_provider_profiles_security
  BEFORE UPDATE
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION prevent_provider_self_privilege_escalation();
CREATE TRIGGER trg_provider_profiles_updated
  BEFORE UPDATE
  ON provider_profiles FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_provider_stores_updated
  BEFORE UPDATE
  ON provider_stores FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_reviews_insert_security
  BEFORE INSERT
  ON reviews FOR EACH ROW
  EXECUTE FUNCTION prevent_review_insert_privilege_escalation();
CREATE TRIGGER trg_reviews_product_rating
  AFTER INSERT OR UPDATE
  ON reviews FOR EACH ROW
  EXECUTE FUNCTION update_product_rating();
CREATE TRIGGER trg_ride_requests_insert_security
  BEFORE INSERT
  ON ride_requests FOR EACH ROW
  EXECUTE FUNCTION prevent_ride_insert_privilege_escalation();
CREATE TRIGGER trg_ride_requests_updated
  BEFORE UPDATE
  ON ride_requests FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_subscriptions_security
  BEFORE UPDATE
  ON subscriptions FOR EACH ROW
  EXECUTE FUNCTION prevent_subscription_self_modification();
CREATE TRIGGER trg_subscriptions_updated
  BEFORE UPDATE
  ON subscriptions FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_support_tickets_security
  BEFORE INSERT OR UPDATE
  ON support_tickets FOR EACH ROW
  EXECUTE FUNCTION prevent_support_ticket_status_escalation();
CREATE TRIGGER trg_system_settings_security
  BEFORE INSERT OR UPDATE
  ON system_settings FOR EACH ROW
  EXECUTE FUNCTION prevent_system_settings_self_modification();
CREATE TRIGGER trg_user_roles_security
  BEFORE INSERT OR UPDATE
  ON user_roles FOR EACH ROW
  EXECUTE FUNCTION prevent_role_escalation();
CREATE TRIGGER trg_vehicles_insert_security
  BEFORE INSERT
  ON vehicles FOR EACH ROW
  EXECUTE FUNCTION prevent_vehicle_insert_privilege_escalation();
CREATE TRIGGER trg_vehicles_security
  BEFORE UPDATE
  ON vehicles FOR EACH ROW
  EXECUTE FUNCTION prevent_vehicle_self_privilege_escalation();
CREATE TRIGGER trg_recharge_requests_updated
  BEFORE UPDATE
  ON wallet_recharge_requests FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_wallet_transactions_immutable
  BEFORE UPDATE
  ON wallet_transactions FOR EACH ROW
  EXECUTE FUNCTION prevent_wallet_txn_mutation();
CREATE TRIGGER trg_wallets_security
  BEFORE UPDATE
  ON wallets FOR EACH ROW
  EXECUTE FUNCTION prevent_wallet_direct_balance_edit();
CREATE TRIGGER trg_wallets_updated
  BEFORE UPDATE
  ON wallets FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- SECURITY DEFINER Functions
CREATE OR REPLACE FUNCTION public.admin_cash_recharge(p_provider_id uuid, p_amount numeric, p_reason text, p_admin_id uuid)
 RETURNS wallets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_balance_before numeric; BEGIN IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ADMIN_ONLY'; END IF; IF p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_MUST_BE_POSITIVE'; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; v_balance_before := v_wallet.balance; UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, 'ADMIN_CASH', p_amount, 0, p_amount, v_wallet.balance, 'COMPLETED', 'admin-cash:' || p_provider_id::text || ':' || now()::text); INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, 'CASH_RECHARGE', p_amount, p_reason, v_balance_before, v_wallet.balance); INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'APPROVAL', 'Cash Recharge', p_amount::text || ' ETB credited' FROM provider_profiles pp WHERE pp.id = p_provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_CASH_RECHARGE', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount)); RETURN v_wallet; END; $function$
;
CREATE OR REPLACE FUNCTION public.admin_wallet_adjustment(p_provider_id uuid, p_amount numeric, p_reason text, p_admin_id uuid)
 RETURNS wallets
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_balance_before numeric; v_action_type text; BEGIN IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ADMIN_ONLY'; END IF; IF p_amount = 0 THEN RAISE EXCEPTION 'AMOUNT_CANNOT_BE_ZERO'; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; v_balance_before := v_wallet.balance; IF p_amount > 0 THEN v_action_type := 'ADJUSTMENT_CREDIT'; ELSE v_action_type := 'ADJUSTMENT_DEBIT'; END IF; IF p_amount < 0 AND v_wallet.balance + p_amount < 0 THEN IF NOT get_setting_bool('allow_negative_wallet') THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE'; END IF; END IF; UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, 'ADJUSTMENT', abs(p_amount), 0, abs(p_amount), v_wallet.balance, 'COMPLETED', 'adjustment:' || p_provider_id::text || ':' || now()::text); INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, v_action_type, abs(p_amount), p_reason, v_balance_before, v_wallet.balance); INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'ADMIN_MESSAGE', 'Wallet Adjustment', 'Adjusted by ' || p_amount::text || ' ETB' FROM provider_profiles pp WHERE pp.id = p_provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_WALLET_ADJUSTMENT', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount)); RETURN v_wallet; END; $function$
;
CREATE OR REPLACE FUNCTION public.approve_provider(p_provider_id uuid, p_admin_id uuid)
 RETURNS provider_profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_provider provider_profiles; v_is_admin boolean; BEGIN SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin; IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE'; END IF; IF exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = p_admin_id) THEN RAISE EXCEPTION 'CANNOT_APPROVE_OWN_ACCOUNT'; END IF; UPDATE provider_profiles SET status = 'APPROVED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider; IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF; INSERT INTO wallets (provider_id, balance) VALUES (p_provider_id, 0) ON CONFLICT (provider_id) DO NOTHING; INSERT INTO subscriptions (provider_id, next_due_date) VALUES (p_provider_id, v_provider.subscription_start_date) ON CONFLICT (provider_id) DO NOTHING; INSERT INTO approval_history (subject_type, subject_id, action, performed_by) VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'APPROVAL', 'Application approved', 'Your provider account is now active.' FROM provider_profiles WHERE id = p_provider_id; INSERT INTO admin_actions (admin_id, action, target_type, target_id) VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id); RETURN v_provider; END; $function$
;
CREATE OR REPLACE FUNCTION public.approve_wallet_recharge(p_recharge_id uuid, p_admin_id uuid)
 RETURNS wallet_recharge_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_recharge wallet_recharge_requests; v_wallet wallets; v_txn wallet_transactions; BEGIN IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ADMIN_ONLY'; END IF; SELECT * INTO v_recharge FROM wallet_recharge_requests WHERE id = p_recharge_id FOR UPDATE; IF v_recharge.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND'; END IF; IF v_recharge.status = 'APPROVED' THEN RETURN v_recharge; END IF; IF v_recharge.status != 'PENDING' THEN RAISE EXCEPTION 'NOT_PENDING'; END IF; SELECT * INTO v_wallet FROM wallets WHERE id = v_recharge.wallet_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; UPDATE wallets SET balance = balance + v_recharge.amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, v_recharge.provider_id, 'RECHARGE', v_recharge.amount, 0, v_recharge.amount, v_wallet.balance, 'COMPLETED', 'recharge:' || v_recharge.id::text) RETURNING * INTO v_txn; UPDATE wallet_recharge_requests SET status = 'APPROVED', approved_by = p_admin_id, approved_at = now(), updated_at = now() WHERE id = p_recharge_id RETURNING * INTO v_recharge; INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'APPROVAL', 'Recharge Approved', v_recharge.amount::text || ' ETB credited' FROM provider_profiles pp WHERE pp.id = v_recharge.provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'WALLET_RECHARGE_APPROVED', 'wallets', v_wallet.id, jsonb_build_object('recharge_id', p_recharge_id, 'amount', v_recharge.amount)); RETURN v_recharge; END; $function$
;
CREATE OR REPLACE FUNCTION public.auto_create_driver_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF new.status = 'APPROVED' AND new.provider_type = 'VEHICLE_PROVIDER' THEN INSERT INTO driver_status (provider_id, is_online) VALUES (new.id, false) ON CONFLICT (provider_id) DO NOTHING; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.auto_create_driver_status_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF new.status = 'APPROVED' AND new.provider_type = 'VEHICLE_PROVIDER' THEN INSERT INTO driver_status (provider_id, is_online) VALUES (new.id, false) ON CONFLICT (provider_id) DO NOTHING; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.auto_create_user_approval_request()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN INSERT INTO approval_requests (subject_type, subject_id, status) VALUES ('USER', NEW.id, 'PENDING_APPROVAL'); RETURN NEW; END; $function$
;
CREATE OR REPLACE FUNCTION public.claim_ride(p_ride_id uuid, p_provider_id uuid, p_vehicle_id uuid)
 RETURNS ride_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_ride ride_requests; BEGIN IF NOT exists (SELECT 1 FROM vehicles WHERE id = p_vehicle_id AND provider_id = p_provider_id AND is_available = true) THEN RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE'; END IF; IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND provider_type = 'VEHICLE_PROVIDER' AND status = 'APPROVED') THEN RAISE EXCEPTION 'PROVIDER_NOT_ELIGIBLE'; END IF; UPDATE ride_requests SET status = 'CLAIMED', claimed_by_provider_id = p_provider_id, claimed_vehicle_id = p_vehicle_id, claimed_at = now(), updated_at = now() WHERE id = p_ride_id AND status = 'REQUESTED' RETURNING * INTO v_ride; IF v_ride.id IS NULL THEN RAISE EXCEPTION 'RIDE_ALREADY_TAKEN'; END IF; INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (p_ride_id, 'REQUESTED', 'CLAIMED', auth.uid()); INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (auth.uid(), 'RIDE_CLAIMED', 'ride_requests', p_ride_id, jsonb_build_object('provider_id', p_provider_id, 'vehicle_id', p_vehicle_id)); RETURN v_ride; END; $function$
;
CREATE OR REPLACE FUNCTION public.create_n8n_event(p_event_type text, p_entity_type text, p_entity_id uuid DEFAULT NULL::uuid, p_payload jsonb DEFAULT NULL::jsonb)
 RETURNS n8n_events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_event n8n_events; BEGIN INSERT INTO n8n_events (event_type, entity_type, entity_id, payload) VALUES (p_event_type, p_entity_type, p_entity_id, p_payload) RETURNING * INTO v_event; RETURN v_event; END; $function$
;
CREATE OR REPLACE FUNCTION public.create_order_secure(p_user_id uuid, p_provider_id uuid, p_items jsonb, p_total_amount numeric, p_currency text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_order_id uuid; v_item jsonb; BEGIN IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'p_items must be non-empty'; END IF; INSERT INTO orders (id, user_id, provider_id, status, total_amount, currency, requires_payment_proof, created_at) VALUES (gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount, coalesce(p_currency, 'ETB'), true, now()) RETURNING id INTO v_order_id; FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP INSERT INTO order_items (id, order_id, product_id, quantity, unit_price) VALUES (gen_random_uuid(), v_order_id, (v_item->>'product_id')::uuid, (v_item->>'quantity')::int, (v_item->>'unit_price')::numeric); END LOOP; INSERT INTO order_status_history (id, order_id, from_status, to_status, changed_by, note) VALUES (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note); RETURN (SELECT to_jsonb(o) FROM orders o WHERE o.id = v_order_id); END; $function$
;
CREATE OR REPLACE FUNCTION public.create_ride_request(p_user_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_destination_lat double precision, p_destination_lng double precision, p_pickup_text text DEFAULT NULL::text, p_destination_text text DEFAULT NULL::text, p_vehicle_category_id uuid DEFAULT NULL::uuid)
 RETURNS ride_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_ride ride_requests; BEGIN IF p_user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER'; END IF; INSERT INTO ride_requests (user_id, pickup_location, destination_location, pickup_text, destination_text, vehicle_category_id, status) VALUES (p_user_id, ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography, ST_SetSRID(ST_MakePoint(p_destination_lng, p_destination_lat), 4326)::geography, p_pickup_text, p_destination_text, p_vehicle_category_id, 'REQUESTED') RETURNING * INTO v_ride; INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (v_ride.id, null, 'REQUESTED', p_user_id); RETURN v_ride; END; $function$
;
CREATE OR REPLACE FUNCTION public.deduct_subscription_fee(p_provider_id uuid, p_period text)
 RETURNS wallet_transactions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_fee numeric := get_setting_numeric('monthly_subscription_fee'); v_key text := 'sub:' || p_provider_id::text || ':' || p_period; v_existing wallet_transactions; v_txn wallet_transactions; BEGIN SELECT * INTO v_existing FROM wallet_transactions WHERE idempotency_key = v_key; IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; UPDATE wallets SET balance = balance - v_fee, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, 'SUBSCRIPTION_FEE', v_fee, v_fee, 0, v_wallet.balance, 'COMPLETED', v_key) RETURNING * INTO v_txn; UPDATE subscriptions SET last_charged_at = now(), next_due_date = next_due_date + interval '1 month', status = 'ACTIVE' WHERE provider_id = p_provider_id; INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'SUBSCRIPTION_DUE', 'Subscription charged', v_fee::text || ' Birr deducted' FROM provider_profiles WHERE id = p_provider_id; RETURN v_txn; END; $function$
;
CREATE OR REPLACE FUNCTION public.deduct_transaction_fee(p_provider_id uuid, p_order_id uuid, p_ride_id uuid, p_gross_amount numeric, p_idempotency_key text)
 RETURNS wallet_transactions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_wallet wallets; v_fee numeric := get_setting_numeric('transaction_fee'); v_allow boolean := get_setting_bool('allow_negative_wallet'); v_txn wallet_transactions; v_existing wallet_transactions; BEGIN SELECT * INTO v_existing FROM wallet_transactions WHERE idempotency_key = p_idempotency_key; IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF; SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE; IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF; IF NOT v_allow AND (v_wallet.balance - v_fee) < 0 THEN INSERT INTO wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'FAILED', p_idempotency_key) RETURNING * INTO v_txn; INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'WALLET_EMPTY', 'Wallet balance too low', 'Transaction fee could not be deducted' FROM provider_profiles WHERE id = p_provider_id; RAISE EXCEPTION 'INSUFFICIENT_WALLET_BALANCE'; END IF; UPDATE wallets SET balance = balance - v_fee, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet; INSERT INTO wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key) VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'COMPLETED', p_idempotency_key) RETURNING * INTO v_txn; INSERT INTO audit_logs (event_type, entity_type, entity_id, metadata) VALUES ('TRANSACTION_FEE_DEDUCTED', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'fee', v_fee, 'balance_after', v_wallet.balance)); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'TRANSACTION_FEE_DEDUCTED', 'Platform fee deducted', v_fee::text || ' Birr deducted' FROM provider_profiles WHERE id = p_provider_id; IF v_wallet.balance <= get_setting_numeric('low_wallet_threshold') THEN INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'WALLET_LOW', 'Wallet balance low', 'Your wallet balance is low' FROM provider_profiles WHERE id = p_provider_id; END IF; RETURN v_txn; END; $function$
;
CREATE OR REPLACE FUNCTION public.find_nearby_drivers(p_lat double precision, p_lng double precision, p_radius_km numeric DEFAULT 10, p_vehicle_category_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(provider_id uuid, vehicle_id uuid, provider_name text, vehicle_brand text, vehicle_model text, vehicle_plate text, distance_km numeric, vehicle_category uuid)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_location geography(Point,4326); BEGIN v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography; RETURN QUERY SELECT ds.provider_id, v.id, coalesce(pp.business_name, pr.full_name), v.brand, v.model, v.plate_number, ROUND((ST_Distance(ds.current_location, v_location) / 1000.0)::numeric, 2), v.category_id FROM driver_status ds JOIN provider_profiles pp ON pp.id = ds.provider_id AND pp.status = 'APPROVED' JOIN profiles pr ON pr.id = pp.user_id JOIN vehicles v ON v.provider_id = ds.provider_id AND v.is_available = true AND v.status = 'APPROVED' WHERE ds.is_online = true AND ds.current_location IS NOT NULL AND ds.current_ride_id IS NULL AND ST_DWithin(ds.current_location, v_location, p_radius_km * 1000) AND (p_vehicle_category_id IS NULL OR v.category_id = p_vehicle_category_id) ORDER BY ST_Distance(ds.current_location, v_location) LIMIT 20; END; $function$
;
CREATE OR REPLACE FUNCTION public.handle_new_provider_profile()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN INSERT INTO public.user_roles (user_id, role) VALUES (new.user_id, new.provider_type::app_role) ON CONFLICT (user_id, role) DO NOTHING; INSERT INTO public.approval_requests (subject_type, subject_id, status) VALUES ('PROVIDER', new.id, 'PENDING_APPROVAL'::account_status) ON CONFLICT DO NOTHING; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.handle_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN INSERT INTO public.profiles (id, full_name, phone, email, status) VALUES (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', 'New User'), new.phone, new.email, 'PENDING_APPROVAL'::account_status) ON CONFLICT (id) DO NOTHING; INSERT INTO public.user_roles (user_id, role) VALUES (new.id, 'USER'::app_role) ON CONFLICT (user_id, role) DO NOTHING; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.has_role(check_role app_role)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT exists (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = check_role); $function$
;
CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT has_role('ADMIN'::app_role); $function$
;
CREATE OR REPLACE FUNCTION public.mark_all_notifications_read()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_count int; BEGIN UPDATE notifications SET is_read = true WHERE user_id = auth.uid() AND is_read = false; GET DIAGNOSTICS v_count = row_count; RETURN v_count; END; $function$
;
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id uuid)
 RETURNS notifications
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_notification notifications; BEGIN UPDATE notifications SET is_read = true WHERE id = p_notification_id AND user_id = auth.uid() RETURNING * INTO v_notification; IF v_notification.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND'; END IF; RETURN v_notification; END; $function$
;
CREATE OR REPLACE FUNCTION public.owns_provider_profile(p_provider_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ SELECT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = auth.uid()); $function$
;
CREATE OR REPLACE FUNCTION public.prevent_approval_history_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN RAISE EXCEPTION 'APPROVAL_HISTORY_IS_IMMUTABLE'; RETURN null; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_audit_log_deletion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'AUDIT_LOGS_CANNOT_BE_MODIFIED';
  ELSIF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'AUDIT_LOGS_CANNOT_BE_DELETED';
  END IF;
  RETURN NULL;
END;
$function$
;
CREATE OR REPLACE FUNCTION public.prevent_inactive_provider_publish()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF NEW.listing_status = 'ACTIVE' AND OLD.listing_status != 'ACTIVE' THEN IF NOT exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = NEW.provider_id AND pp.status = 'APPROVED') THEN RAISE EXCEPTION 'SUSPENDED_PROVIDERS_CANNOT_PUBLISH'; END IF; END IF; END IF; RETURN NEW; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_inactive_provider_publish_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF NEW.listing_status = 'ACTIVE' THEN IF NOT exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = NEW.provider_id AND pp.status = 'APPROVED') THEN RAISE EXCEPTION 'SUSPENDED_PROVIDERS_CANNOT_PUBLISH'; END IF; END IF; END IF; RETURN NEW; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_notification_injection()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() AND NOT pg_catalog.current_setting('role', true) = 'service_role' THEN RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS'; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_order_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != 'CREATED' THEN RAISE EXCEPTION 'ORDERS_MUST_START_AS_CREATED'; END IF; IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_order_self_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'ORDER_STATUS_CHANGE_REQUIRES_SERVER_FUNCTION'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_payment_agreement_unaccept()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF old.accepted = true AND new.accepted = false THEN RAISE EXCEPTION 'CANNOT_UNACCEPT'; END IF; IF new.accepted = true AND (old.accepted = false OR old.accepted IS NULL) THEN new.accepted_at := now(); END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_payment_proof_self_verification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.verification_status != old.verification_status THEN RAISE EXCEPTION 'VERIFICATION_IS_ADMIN_ONLY'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_product_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN new.rating := 0; new.review_count := 0; new.sales_count := 0; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_profile_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'MUST_START_AS_PENDING'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_profile_self_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_provider_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'MUST_START_AS_PENDING'; END IF; IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED'; END IF; IF new.provider_type != old.provider_type THEN RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED'; END IF; IF new.subscription_start_date != old.subscription_start_date THEN RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED'; END IF; IF old.owner_national_id IS NOT NULL AND new.owner_national_id != old.owner_national_id THEN RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_review_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_ride_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != 'REQUESTED' THEN RAISE EXCEPTION 'MUST_START_AS_REQUESTED'; END IF; IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_FOR_ANOTHER_USER'; END IF; IF new.claimed_by_provider_id IS NOT NULL THEN RAISE EXCEPTION 'CLAIM_FIELDS_CANNOT_BE_SET'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_role_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN RAISE EXCEPTION 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY'; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_subscription_self_modification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF; IF new.next_due_date != old.next_due_date THEN RAISE EXCEPTION 'SUBSCRIPTION_DATES_CANNOT_BE_SELF_MODIFIED'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_support_ticket_status_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF TG_OP = 'INSERT' AND new.status != 'OPEN' THEN RAISE EXCEPTION 'NEW_TICKETS_MUST_START_AS_OPEN'; END IF; IF TG_OP = 'UPDATE' AND new.status != old.status AND new.status != 'CLOSED' THEN RAISE EXCEPTION 'USERS_CAN_ONLY_CLOSE'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_system_settings_self_modification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN RAISE EXCEPTION 'SETTINGS_ARE_ADMIN_ONLY'; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_vehicle_insert_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'MUST_START_AS_PENDING'; END IF; IF new.is_available != false THEN RAISE EXCEPTION 'NEW_VEHICLES_NOT_AVAILABLE'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_vehicle_self_privilege_escalation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'VEHICLE_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_wallet_direct_balance_edit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NOT is_admin() THEN IF new.balance != old.balance THEN RAISE EXCEPTION 'BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION'; END IF; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.prevent_wallet_txn_mutation()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF old.status = 'COMPLETED' AND NOT is_admin() THEN RAISE EXCEPTION 'COMPLETED_TRANSACTIONS_CANNOT_BE_MODIFIED'; END IF; RETURN new; END; $function$
;
CREATE OR REPLACE FUNCTION public.reject_provider(p_provider_id uuid, p_admin_id uuid, p_reason text)
 RETURNS provider_profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_provider provider_profiles; v_is_admin boolean; BEGIN SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin; IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT'; END IF; UPDATE provider_profiles SET status = 'REJECTED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider; IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF; INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'REJECT', p_reason, p_admin_id); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'REJECTION', 'Application rejected', p_reason FROM provider_profiles WHERE id = p_provider_id; INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'REJECT_PROVIDER', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason)); RETURN v_provider; END; $function$
;
CREATE OR REPLACE FUNCTION public.reject_wallet_recharge(p_recharge_id uuid, p_admin_id uuid, p_reason text)
 RETURNS wallet_recharge_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_recharge wallet_recharge_requests; BEGIN IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ADMIN_ONLY'; END IF; SELECT * INTO v_recharge FROM wallet_recharge_requests WHERE id = p_recharge_id FOR UPDATE; IF v_recharge.id IS NULL THEN RAISE EXCEPTION 'NOT_FOUND'; END IF; IF v_recharge.status != 'PENDING' THEN RAISE EXCEPTION 'NOT_PENDING'; END IF; UPDATE wallet_recharge_requests SET status = 'REJECTED', rejection_reason = p_reason, approved_by = p_admin_id, approved_at = now(), updated_at = now() WHERE id = p_recharge_id RETURNING * INTO v_recharge; INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'REJECTION', 'Recharge Rejected', 'Reason: ' || p_reason FROM provider_profiles pp WHERE pp.id = v_recharge.provider_id; INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'WALLET_RECHARGE_REJECTED', 'wallets', v_recharge.wallet_id, jsonb_build_object('recharge_id', p_recharge_id, 'reason', p_reason)); RETURN v_recharge; END; $function$
;
CREATE OR REPLACE FUNCTION public.request_correction_provider(p_provider_id uuid, p_admin_id uuid, p_reason text)
 RETURNS provider_profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_provider provider_profiles; v_is_admin boolean; BEGIN SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin; IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REQUEST_CORRECTION'; END IF; UPDATE provider_profiles SET status = 'REJECTED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider; IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF; INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'REQUEST_CORRECTION', p_reason, p_admin_id); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'CORRECTION_REQUIRED', 'Correction requested', 'Please update your submission: ' || p_reason FROM provider_profiles WHERE id = p_provider_id; INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'REQUEST_CORRECTION', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason)); RETURN v_provider; END; $function$
;
CREATE OR REPLACE FUNCTION public.set_driver_online(p_provider_id uuid, p_online boolean, p_lat double precision DEFAULT NULL::double precision, p_lng double precision DEFAULT NULL::double precision)
 RETURNS driver_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_status driver_status; BEGIN IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = auth.uid() AND status = 'APPROVED') THEN RAISE EXCEPTION 'NOT_APPROVED'; END IF; IF p_online AND (p_lat IS NULL OR p_lng IS NULL) THEN RAISE EXCEPTION 'LOCATION_REQUIRED'; END IF; INSERT INTO driver_status (provider_id, is_online, current_location, last_location_update, updated_at) VALUES (p_provider_id, p_online, CASE WHEN p_online THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography ELSE null END, CASE WHEN p_online THEN now() ELSE null END, now()) ON CONFLICT (provider_id) DO UPDATE SET is_online = p_online, current_location = CASE WHEN p_online THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography ELSE driver_status.current_location END, last_location_update = CASE WHEN p_online THEN now() ELSE driver_status.last_location_update END, updated_at = now() RETURNING * INTO v_status; RETURN v_status; END; $function$
;
CREATE OR REPLACE FUNCTION public.st_estimatedextent(text, text, text, boolean)
 RETURNS box2d
 LANGUAGE c
 STABLE STRICT SECURITY DEFINER
AS '$libdir/postgis-3', $function$gserialized_estimated_extent$function$
;
CREATE OR REPLACE FUNCTION public.st_estimatedextent(text, text, text)
 RETURNS box2d
 LANGUAGE c
 STABLE STRICT SECURITY DEFINER
AS '$libdir/postgis-3', $function$gserialized_estimated_extent$function$
;
CREATE OR REPLACE FUNCTION public.st_estimatedextent(text, text)
 RETURNS box2d
 LANGUAGE c
 STABLE STRICT SECURITY DEFINER
AS '$libdir/postgis-3', $function$gserialized_estimated_extent$function$
;
CREATE OR REPLACE FUNCTION public.suspend_provider(p_provider_id uuid, p_admin_id uuid, p_reason text DEFAULT NULL::text)
 RETURNS provider_profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_provider provider_profiles; v_is_admin boolean; BEGIN SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin; IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_SUSPEND'; END IF; UPDATE provider_profiles SET status = 'SUSPENDED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider; IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF; UPDATE vehicles SET is_available = false WHERE provider_id = p_provider_id AND status = 'APPROVED'; INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'SUSPEND', p_reason, p_admin_id); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'PROVIDER_INACTIVE', 'Account suspended', coalesce(p_reason, 'Your provider account has been suspended.') FROM provider_profiles WHERE id = p_provider_id; INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'SUSPEND_PROVIDER', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason)); RETURN v_provider; END; $function$
;
CREATE OR REPLACE FUNCTION public.sync_store_listing_count()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF TG_OP = 'INSERT' THEN UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = NEW.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = NEW.provider_id; RETURN NEW; ELSIF TG_OP = 'DELETE' THEN UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = OLD.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = OLD.provider_id; RETURN OLD; END IF; RETURN NULL; END; $function$
;
CREATE OR REPLACE FUNCTION public.sync_store_listing_count_on_status()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ BEGIN IF NEW.listing_status IS DISTINCT FROM OLD.listing_status THEN UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = NEW.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = NEW.provider_id; END IF; RETURN NEW; END; $function$
;
CREATE OR REPLACE FUNCTION public.transition_order_status(p_order_id uuid, p_new_status order_status, p_actor uuid, p_note text DEFAULT NULL::text)
 RETURNS orders
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_order orders; v_old order_status; v_valid boolean := false; v_actor_is_provider boolean := false; v_actor_is_admin boolean := false; BEGIN SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE; IF v_order.id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF; v_old := v_order.status; SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN') INTO v_actor_is_admin; SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_order.provider_id AND user_id = p_actor) INTO v_actor_is_provider; v_valid := case v_old when 'CREATED' then p_new_status in ('PENDING_PROVIDER','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin) when 'PENDING_PROVIDER' then (p_new_status in ('ACCEPTED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin)) when 'ACCEPTED' then (p_new_status = 'PAYMENT_PENDING' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin)) when 'PAYMENT_PENDING' then (p_new_status = 'PAYMENT_VERIFICATION' AND v_order.user_id = p_actor) OR (p_new_status = 'CANCELLED' AND v_actor_is_admin) when 'PAYMENT_VERIFICATION' then p_new_status in ('APPROVED','REJECTED') AND v_actor_is_admin when 'APPROVED' then (p_new_status = 'STARTED' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin)) when 'STARTED' then (p_new_status = 'COMPLETED' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status in ('DISPUTED','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin)) when 'COMPLETED' then p_new_status in ('DISPUTED','REFUNDED') AND (v_order.user_id = p_actor OR v_actor_is_admin) when 'DISPUTED' then p_new_status in ('REFUNDED','COMPLETED') AND v_actor_is_admin else false end; IF NOT v_valid THEN RAISE EXCEPTION 'INVALID_TRANSITION_%_TO_%_FOR_ACTOR', v_old, p_new_status; END IF; IF p_new_status = 'APPROVED' AND v_order.requires_payment_proof THEN IF NOT exists (SELECT 1 FROM payment_proofs WHERE order_id = p_order_id AND verification_status = 'VERIFIED') THEN RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED'; END IF; END IF; UPDATE orders SET status = p_new_status, updated_at = now() WHERE id = p_order_id RETURNING * INTO v_order; INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, note) VALUES (p_order_id, v_old, p_new_status, p_actor, p_note); IF p_new_status = 'STARTED' THEN PERFORM deduct_transaction_fee(v_order.provider_id, p_order_id, null, v_order.total_amount, 'order:' || p_order_id::text); END IF; RETURN v_order; END; $function$
;
CREATE OR REPLACE FUNCTION public.transition_ride_status(p_ride_id uuid, p_new_status ride_status, p_actor uuid)
 RETURNS ride_requests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_ride ride_requests; v_old ride_status; v_actor_is_admin boolean := false; v_actor_is_claiming_provider boolean := false; BEGIN SELECT * INTO v_ride FROM ride_requests WHERE id = p_ride_id FOR UPDATE; IF v_ride.id IS NULL THEN RAISE EXCEPTION 'RIDE_NOT_FOUND'; END IF; v_old := v_ride.status; IF v_old = 'CANCELLED' OR v_old = 'COMPLETED' THEN RAISE EXCEPTION 'RIDE_ALREADY_TERMINAL'; END IF; SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN') INTO v_actor_is_admin; IF v_ride.claimed_by_provider_id IS NOT NULL THEN SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_ride.claimed_by_provider_id AND user_id = p_actor) INTO v_actor_is_claiming_provider; END IF; CASE v_old WHEN 'REQUESTED' THEN IF p_new_status != 'CANCELLED' THEN RAISE EXCEPTION 'USE_CLAIM_RIDE'; END IF; IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN'; END IF; WHEN 'CLAIMED' THEN IF p_new_status = 'CANCELLED' THEN IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN'; END IF; ELSIF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN'; END IF; WHEN 'DRIVER_ARRIVING' THEN IF p_new_status = 'CANCELLED' THEN IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN'; END IF; ELSIF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN'; END IF; WHEN 'STARTED' THEN IF p_new_status = 'COMPLETED' THEN IF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN'; END IF; ELSIF p_new_status = 'CANCELLED' THEN IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN'; END IF; END IF; ELSE RAISE EXCEPTION 'UNEXPECTED_STATUS_%', v_old; END CASE; UPDATE ride_requests SET status = p_new_status, updated_at = now() WHERE id = p_ride_id RETURNING * INTO v_ride; INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (p_ride_id, v_old, p_new_status, p_actor); IF p_new_status = 'COMPLETED' THEN PERFORM deduct_transaction_fee(v_ride.claimed_by_provider_id, null, p_ride_id, coalesce(v_ride.fare_estimate, 0), 'ride:' || p_ride_id::text); END IF; RETURN v_ride; END; $function$
;
CREATE OR REPLACE FUNCTION public.unsuspend_provider(p_provider_id uuid, p_admin_id uuid)
 RETURNS provider_profiles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_provider provider_profiles; v_is_admin boolean; BEGIN SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin; IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_UNSUSPEND'; END IF; UPDATE provider_profiles SET status = 'APPROVED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider; IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF; UPDATE vehicles SET is_available = true WHERE provider_id = p_provider_id AND status = 'APPROVED'; INSERT INTO approval_history (subject_type, subject_id, action, performed_by) VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id); INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'APPROVAL', 'Account reactivated', 'Your provider account has been reactivated.' FROM provider_profiles WHERE id = p_provider_id; INSERT INTO admin_actions (admin_id, action, target_type, target_id) VALUES (p_admin_id, 'UNSUSPEND_PROVIDER', 'provider_profiles', p_provider_id); RETURN v_provider; END; $function$
;
CREATE OR REPLACE FUNCTION public.update_driver_location(p_provider_id uuid, p_lat double precision, p_lng double precision)
 RETURNS driver_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_status driver_status; BEGIN IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = auth.uid()) THEN RAISE EXCEPTION 'NOT_YOUR_STATUS'; END IF; INSERT INTO driver_status (provider_id, current_location, last_location_update, updated_at) VALUES (p_provider_id, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, now(), now()) ON CONFLICT (provider_id) DO UPDATE SET current_location = ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, last_location_update = now(), updated_at = now() RETURNING * INTO v_status; RETURN v_status; END; $function$
;
CREATE OR REPLACE FUNCTION public.update_vehicle_location(p_vehicle_id uuid, p_lat double precision, p_lng double precision)
 RETURNS vehicles
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_vehicle vehicles; BEGIN IF NOT exists (SELECT 1 FROM vehicles v WHERE v.id = p_vehicle_id AND owns_provider_profile(v.provider_id)) THEN RAISE EXCEPTION 'NOT_OWNED'; END IF; UPDATE vehicles SET current_location = ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography WHERE id = p_vehicle_id RETURNING * INTO v_vehicle; RETURN v_vehicle; END; $function$
;
CREATE OR REPLACE FUNCTION public.upsert_notification_preferences(p_push_enabled boolean DEFAULT NULL::boolean, p_in_app_enabled boolean DEFAULT NULL::boolean)
 RETURNS notification_preferences
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ DECLARE v_prefs notification_preferences; BEGIN INSERT INTO notification_preferences (user_id, push_enabled, in_app_enabled) VALUES (auth.uid(), coalesce(p_push_enabled, true), coalesce(p_in_app_enabled, true)) ON CONFLICT (user_id) DO UPDATE SET push_enabled = coalesce(p_push_enabled, notification_preferences.push_enabled), in_app_enabled = coalesce(p_in_app_enabled, notification_preferences.in_app_enabled) RETURNING * INTO v_prefs; RETURN v_prefs; END; $function$
;

-- Seed Data
INSERT INTO system_settings (key, value) VALUES ('allow_negative_wallet', 'false'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('default_ride_search_radius_km', '5'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('low_wallet_threshold', '15'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('minimum_wallet_balance', '0'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('monthly_subscription_fee', '5'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('payment_proof_required', 'true'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('provider_approval_required', 'true'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('subscription_grace_period_days', '3'::jsonb) ON CONFLICT (key) DO NOTHING;
INSERT INTO system_settings (key, value) VALUES ('transaction_fee', '5'::jsonb) ON CONFLICT (key) DO NOTHING;
