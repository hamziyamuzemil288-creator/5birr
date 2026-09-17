-- 5BIRR — Completion Migration
-- Migration 0022_complete_schema.sql
--
-- PURPOSE: Bring the live database from its current partial state
-- (profiles, user_roles, provider_profiles, system_settings with 3 seed rows)
-- to the full intended state across all 21 previous migrations.
--
-- SAFETY: Uses IF NOT EXISTS / ON CONFLICT / CREATE OR REPLACE throughout.
-- Existing tables, functions, and enums are never dropped or altered (except
-- adding new enum values). This migration is idempotent — safe to re-run.
--
-- APPLY: supabase db push  (or via SQL editor in order: just this file)

-- ============================================================================
-- EXTENSIONS
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================================
-- ENUMS (created only if they don't exist)
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE app_role AS ENUM ('USER','VEHICLE_PROVIDER','SERVICE_PROVIDER','ADMIN');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED','SUSPENDED','INACTIVE');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE approval_action AS ENUM ('APPROVE','REJECT','REQUEST_CORRECTION','SUSPEND','DELETE');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE ride_status AS ENUM ('REQUESTED','CLAIMED','DRIVER_ARRIVING','STARTED','COMPLETED','CANCELLED');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE order_status AS ENUM (
    'CREATED','PENDING_PROVIDER','ACCEPTED','PAYMENT_PENDING','PAYMENT_VERIFICATION',
    'APPROVED','STARTED','COMPLETED','CANCELLED','DISPUTED','REFUNDED','REJECTED'
  );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE wallet_txn_type AS ENUM ('TRANSACTION_FEE','SUBSCRIPTION_FEE','DEPOSIT','WITHDRAWAL','ADJUSTMENT','REFUND');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE wallet_txn_status AS ENUM ('PENDING','COMPLETED','FAILED','REVERSED');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE notification_type AS ENUM (
    'REGISTRATION_RECEIVED','APPROVAL','REJECTION','CORRECTION_REQUIRED','ADMIN_MESSAGE',
    'ORDER_RECEIVED','ORDER_ACCEPTED','ORDER_REJECTED','RIDE_REQUEST','RIDE_CLAIMED','RIDE_TAKEN',
    'RIDE_STARTED','RIDE_COMPLETED','PAYMENT_REMINDER','PAYMENT_PROOF_REQUIRED','WALLET_LOW',
    'WALLET_EMPTY','SUBSCRIPTION_DUE','PROVIDER_INACTIVE','TRANSACTION_FEE_DEDUCTED','SECURITY'
  );
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE listing_type AS ENUM ('PRODUCT', 'FOOD', 'SERVICE', 'ROOM', 'OTHER');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE listing_status AS ENUM ('ACTIVE', 'DRAFT', 'SOLD_OUT', 'ARCHIVED');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
  CREATE TYPE recharge_status AS ENUM ('PENDING','APPROVED','REJECTED');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- Enum extensions from0009
ALTER TYPE wallet_txn_type ADD VALUE IF NOT EXISTS 'RECHARGE' BEFORE 'WITHDRAWAL';
ALTER TYPE wallet_txn_type ADD VALUE IF NOT EXISTS 'ADMIN_CASH' BEFORE 'ADJUSTMENT';

-- Enum extensions from0010
ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'DRIVER_EN_ROUTE' AFTER 'DRIVER_ARRIVING';
ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'ARRIVED' AFTER 'DRIVER_EN_ROUTE';
ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'TRIP_STARTED' AFTER 'ARRIVED';

ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.NewRequest' AFTER 'RIDE_TAKEN';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Claimed' AFTER 'RIDE.NewRequest';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Cancelled' AFTER 'RIDE.Claimed';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.DriverArriving' AFTER 'RIDE.Cancelled';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Arrived' AFTER 'RIDE.DriverArriving';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.TripStarted' AFTER 'RIDE.Arrived';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.TripCompleted' AFTER 'RIDE.TripStarted';
ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Rated' AFTER 'RIDE.TripCompleted';

-- ============================================================================
-- MISSING SEED DATA for system_settings (only 3 of 9 rows exist)
-- ============================================================================
INSERT INTO system_settings (key, value, description) VALUES
  ('subscription_grace_period_days', '3', 'Days after due date before restriction'),
  ('low_wallet_threshold', '15', 'Balance below this triggers low-wallet warning'),
  ('minimum_wallet_balance', '0', 'Floor for wallet balance; negative not allowed unless changed'),
  ('allow_negative_wallet', 'false', 'Whether wallet can go negative'),
  ('default_ride_search_radius_km', '5', 'Default radius for nearby ride/provider search'),
  ('payment_proof_required', 'true', 'Whether payment screenshot proof is required before protected stage')
ON CONFLICT (key) DO NOTHING;

-- ============================================================================
-- MISSING TABLES (CREATE TABLE IF NOT EXISTS — skips existing 4)
-- ============================================================================

-- user_documents
CREATE TABLE IF NOT EXISTS user_documents (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  document_type TEXT NOT NULL,
  storage_path TEXT NOT NULL,
  uploaded_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_user_documents_user ON user_documents(user_id);

-- approval_requests
CREATE TABLE IF NOT EXISTS approval_requests (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  subject_type TEXT NOT NULL,
  subject_id uuid NOT NULL,
  status account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- approval_history
CREATE TABLE IF NOT EXISTS approval_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  approval_request_id uuid REFERENCES approval_requests(id) ON DELETE SET NULL,
  subject_type TEXT NOT NULL,
  subject_id uuid NOT NULL,
  action approval_action NOT NULL,
  reason TEXT,
  performed_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_approval_history_subject ON approval_history(subject_type, subject_id);

-- categories
CREATE TABLE IF NOT EXISTS categories (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  parent_id uuid REFERENCES categories(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  sector TEXT NOT NULL CHECK (sector IN ('SERVICE','VEHICLE')),
  slug TEXT NOT NULL UNIQUE,
  icon TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  description TEXT,
  image_url TEXT,
  marketplace_sector TEXT CHECK (marketplace_sector IN ('FOOD','RETAIL','ACCOMMODATION','SERVICES','TRANSPORT','OTHER')),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_categories_parent ON categories(parent_id);
CREATE INDEX IF NOT EXISTS idx_categories_sector ON categories(sector);
CREATE INDEX IF NOT EXISTS idx_categories_marketplace_sector ON categories(marketplace_sector) WHERE marketplace_sector IS NOT NULL;

-- vehicles
CREATE TABLE IF NOT EXISTS vehicles (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
  category_id uuid REFERENCES categories(id),
  brand TEXT,
  model TEXT,
  plate_number TEXT NOT NULL,
  color TEXT,
  capacity INT,
  current_location geography(Point,4326),
  is_available BOOLEAN NOT NULL DEFAULT true,
  status account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  rating NUMERIC DEFAULT 0,
  rating_count INT DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plate_number)
);
CREATE INDEX IF NOT EXISTS idx_vehicles_provider ON vehicles(provider_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_location ON vehicles USING gist(current_location);
CREATE INDEX IF NOT EXISTS idx_vehicles_available ON vehicles(is_available) WHERE is_available = true;

-- Add FK from provider_profiles to categories (if not already present)
DO $$ BEGIN
  ALTER TABLE provider_profiles ADD CONSTRAINT fk_provider_category FOREIGN KEY (category_id) REFERENCES categories(id);
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- vehicle_images
CREATE TABLE IF NOT EXISTS vehicle_images (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id uuid NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  sort_order INT DEFAULT 0
);

-- products
CREATE TABLE IF NOT EXISTS products (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
  category_id uuid REFERENCES categories(id),
  name TEXT NOT NULL,
  description TEXT,
  price NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'ETB',
  quantity INT,
  is_available BOOLEAN NOT NULL DEFAULT true,
  is_active BOOLEAN NOT NULL DEFAULT true,
  location geography(Point,4326),
  rating NUMERIC DEFAULT 0,
  review_count INT DEFAULT 0,
  sales_count INT DEFAULT 0,
  search_vector tsvector GENERATED ALWAYS AS (
    setweight(to_tsvector('simple', coalesce(name,'')), 'A') ||
    setweight(to_tsvector('simple', coalesce(description,'')), 'B')
  ) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  listing_type listing_type NOT NULL DEFAULT 'PRODUCT',
  stock_quantity INT,
  low_stock_threshold INT DEFAULT 5,
  listing_status listing_status NOT NULL DEFAULT 'ACTIVE',
  metadata jsonb
);
CREATE INDEX IF NOT EXISTS idx_products_provider ON products(provider_id);
CREATE INDEX IF NOT EXISTS idx_products_category ON products(category_id);
CREATE INDEX IF NOT EXISTS idx_products_location ON products USING gist(location);
CREATE INDEX IF NOT EXISTS idx_products_search ON products USING gin(search_vector);
CREATE INDEX IF NOT EXISTS idx_products_trgm_name ON products USING gin(name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_products_listing_type ON products(listing_type);
CREATE INDEX IF NOT EXISTS idx_products_listing_status ON products(listing_status);
CREATE INDEX IF NOT EXISTS idx_products_type_status ON products(listing_type, listing_status);
CREATE INDEX IF NOT EXISTS idx_products_provider_status_active ON products(provider_id, listing_status) WHERE listing_status = 'ACTIVE' AND is_active = true;
CREATE INDEX IF NOT EXISTS idx_products_category_status ON products(category_id, listing_status) WHERE listing_status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_products_status_created ON products(listing_status, created_at DESC) WHERE listing_status = 'ACTIVE';
CREATE INDEX IF NOT EXISTS idx_products_price ON products(price) WHERE listing_status = 'ACTIVE' AND is_active = true;
CREATE INDEX IF NOT EXISTS idx_products_metadata ON products USING gin(metadata) WHERE metadata IS NOT NULL;

-- product_images
CREATE TABLE IF NOT EXISTS product_images (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  sort_order INT DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images(product_id);

-- orders
CREATE TABLE IF NOT EXISTS orders (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id),
  status order_status NOT NULL DEFAULT 'CREATED',
  total_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  currency TEXT NOT NULL DEFAULT 'ETB',
  requires_payment_proof BOOLEAN NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_provider ON orders(provider_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

-- order_items
CREATE TABLE IF NOT EXISTS order_items (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  product_id uuid REFERENCES products(id),
  quantity INT NOT NULL DEFAULT 1,
  unit_price NUMERIC(12,2) NOT NULL,
  subtotal NUMERIC(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED
);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);

-- order_status_history
CREATE TABLE IF NOT EXISTS order_status_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  from_status order_status,
  to_status order_status NOT NULL,
  changed_by uuid REFERENCES auth.users(id),
  note TEXT,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_order_status_history_order ON order_status_history(order_id);

-- payment_agreements
CREATE TABLE IF NOT EXISTS payment_agreements (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id),
  accepted BOOLEAN NOT NULL DEFAULT false,
  accepted_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (order_id)
);

-- payment_proofs
CREATE TABLE IF NOT EXISTS payment_proofs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  transaction_id uuid,
  storage_path TEXT NOT NULL,
  verification_status TEXT NOT NULL DEFAULT 'PENDING' CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED')),
  verified_by uuid REFERENCES auth.users(id),
  verified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payment_proofs_order ON payment_proofs(order_id);

-- ride_requests
CREATE TABLE IF NOT EXISTS ride_requests (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  pickup_location geography(Point,4326) NOT NULL,
  destination_location geography(Point,4326) NOT NULL,
  pickup_text TEXT,
  destination_text TEXT,
  vehicle_category_id uuid REFERENCES categories(id),
  status ride_status NOT NULL DEFAULT 'REQUESTED',
  claimed_by_provider_id uuid REFERENCES provider_profiles(id),
  claimed_vehicle_id uuid REFERENCES vehicles(id),
  claimed_at timestamptz,
  fare_estimate NUMERIC(12,2),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ride_requests_status ON ride_requests(status);
CREATE INDEX IF NOT EXISTS idx_ride_requests_pickup ON ride_requests USING gist(pickup_location);
CREATE INDEX IF NOT EXISTS idx_ride_requests_provider ON ride_requests(claimed_by_provider_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ride_single_claim ON ride_requests(id) WHERE status = 'CLAIMED';
CREATE INDEX IF NOT EXISTS idx_ride_requests_user_status ON ride_requests(user_id, status);
CREATE INDEX IF NOT EXISTS idx_ride_requests_provider_status ON ride_requests(claimed_by_provider_id, status);

-- ride_status_history
CREATE TABLE IF NOT EXISTS ride_status_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_request_id uuid NOT NULL REFERENCES ride_requests(id) ON DELETE CASCADE,
  from_status ride_status,
  to_status ride_status NOT NULL,
  changed_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- wallets
CREATE TABLE IF NOT EXISTS wallets (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE,
  balance NUMERIC(12,2) NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RESTRICTED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- wallet_transactions
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  provider_id uuid NOT NULL REFERENCES provider_profiles(id),
  order_id uuid REFERENCES orders(id),
  ride_request_id uuid REFERENCES ride_requests(id),
  transaction_type wallet_txn_type NOT NULL,
  gross_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  platform_fee NUMERIC(12,2) NOT NULL DEFAULT 0,
  net_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
  balance_after NUMERIC(12,2) NOT NULL,
  status wallet_txn_status NOT NULL DEFAULT 'COMPLETED',
  idempotency_key TEXT NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wallet_txn_wallet ON wallet_transactions(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_txn_provider ON wallet_transactions(provider_id);

-- subscriptions
CREATE TABLE IF NOT EXISTS subscriptions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DUE','GRACE','SUSPENDED')),
  next_due_date timestamptz NOT NULL,
  last_charged_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- reviews
CREATE TABLE IF NOT EXISTS reviews (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  target_type TEXT NOT NULL CHECK (target_type IN ('PRODUCT','PROVIDER','VEHICLE')),
  target_id uuid NOT NULL,
  order_id uuid REFERENCES orders(id),
  rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, target_type, target_id, order_id)
);
CREATE INDEX IF NOT EXISTS idx_reviews_target ON reviews(target_type, target_id);

-- favorites
CREATE TABLE IF NOT EXISTS favorites (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  target_type TEXT NOT NULL CHECK (target_type IN ('PRODUCT','PROVIDER','VEHICLE')),
  target_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, target_type, target_id)
);

-- notifications
CREATE TABLE IF NOT EXISTS notifications (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  type notification_type NOT NULL,
  title TEXT NOT NULL,
  body TEXT,
  data jsonb,
  is_read BOOLEAN NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, is_read);

-- notification_preferences
CREATE TABLE IF NOT EXISTS notification_preferences (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  push_enabled BOOLEAN NOT NULL DEFAULT true,
  in_app_enabled BOOLEAN NOT NULL DEFAULT true
);

-- admin_actions
CREATE TABLE IF NOT EXISTS admin_actions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  action TEXT NOT NULL,
  target_type TEXT,
  target_id uuid,
  details jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- support_tickets
CREATE TABLE IF NOT EXISTS support_tickets (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  subject TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','RESOLVED','CLOSED')),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- appeals
CREATE TABLE IF NOT EXISTS appeals (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id),
  related_type TEXT NOT NULL,
  related_id uuid NOT NULL,
  reason TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','DENIED')),
  reviewed_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- audit_logs
CREATE TABLE IF NOT EXISTS audit_logs (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  actor_id uuid REFERENCES auth.users(id),
  event_type TEXT NOT NULL,
  entity_type TEXT,
  entity_id uuid,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON audit_logs(actor_id);

-- cart_items (from0005)
CREATE TABLE IF NOT EXISTS cart_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  quantity INT NOT NULL CHECK (quantity > 0),
  added_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, product_id)
);

-- fcm_tokens (from0007)
CREATE TABLE IF NOT EXISTS fcm_tokens (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token TEXT NOT NULL,
  device_type TEXT NOT NULL DEFAULT 'android' CHECK (device_type IN ('android','ios','web')),
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, token)
);
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_user ON fcm_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_active ON fcm_tokens(is_active) WHERE is_active = true;

-- n8n_events (from0007)
CREATE TABLE IF NOT EXISTS n8n_events (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id uuid,
  payload jsonb,
  status TEXT NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','FAILED','RETRYING')),
  attempts INT NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_n8n_events_status ON n8n_events(status);
CREATE INDEX IF NOT EXISTS idx_n8n_events_type ON n8n_events(event_type, entity_type);
CREATE INDEX IF NOT EXISTS idx_n8n_events_entity ON n8n_events(entity_type, entity_id);

-- payment_methods (from0009)
CREATE TABLE IF NOT EXISTS payment_methods (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  account_name TEXT,
  account_number TEXT,
  instructions TEXT,
  logo_storage_path TEXT,
  is_active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payment_methods_active ON payment_methods(is_active) WHERE is_active = true;

-- wallet_recharge_requests (from0009)
CREATE TABLE IF NOT EXISTS wallet_recharge_requests (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
  wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  payment_method_id uuid REFERENCES payment_methods(id),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  currency TEXT NOT NULL DEFAULT 'ETB',
  payment_reference TEXT,
  screenshot_storage_path TEXT,
  status recharge_status NOT NULL DEFAULT 'PENDING',
  rejection_reason TEXT,
  approved_by uuid REFERENCES auth.users(id),
  approved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_recharge_requests_provider ON wallet_recharge_requests(provider_id);
CREATE INDEX IF NOT EXISTS idx_recharge_requests_status ON wallet_recharge_requests(status);
CREATE INDEX IF NOT EXISTS idx_recharge_requests_wallet ON wallet_recharge_requests(wallet_id);

-- admin_wallet_actions (from0009)
CREATE TABLE IF NOT EXISTS admin_wallet_actions (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  admin_id uuid NOT NULL REFERENCES auth.users(id),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id),
  wallet_id uuid NOT NULL REFERENCES wallets(id),
  action_type TEXT NOT NULL CHECK (action_type IN ('CASH_RECHARGE','ADJUSTMENT_CREDIT','ADJUSTMENT_DEBIT')),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  reason TEXT NOT NULL,
  balance_before NUMERIC(12,2) NOT NULL,
  balance_after NUMERIC(12,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_admin_wallet_actions_admin ON admin_wallet_actions(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_wallet_actions_provider ON admin_wallet_actions(provider_id);

-- driver_status (from0010)
CREATE TABLE IF NOT EXISTS driver_status (
  provider_id uuid PRIMARY KEY REFERENCES provider_profiles(id) ON DELETE CASCADE,
  is_online BOOLEAN NOT NULL DEFAULT false,
  current_location geography(Point,4326),
  last_location_update timestamptz,
  current_ride_id uuid REFERENCES ride_requests(id),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_driver_status_online ON driver_status(is_online) WHERE is_online = true;
CREATE INDEX IF NOT EXISTS idx_driver_status_location ON driver_status USING gist(current_location);
CREATE INDEX IF NOT EXISTS idx_driver_status_provider ON driver_status(provider_id);

-- ride_ratings (from0010)
CREATE TABLE IF NOT EXISTS ride_ratings (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_request_id uuid NOT NULL REFERENCES ride_requests(id) ON DELETE CASCADE,
  rater_id uuid NOT NULL REFERENCES auth.users(id),
  ratee_provider_id uuid REFERENCES provider_profiles(id),
  rating INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment TEXT,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (ride_request_id, rater_id)
);
CREATE INDEX IF NOT EXISTS idx_ride_ratings_ride ON ride_ratings(ride_request_id);
CREATE INDEX IF NOT EXISTS idx_ride_ratings_provider ON ride_ratings(ratee_provider_id);

-- provider_stores (from0013)
CREATE TABLE IF NOT EXISTS provider_stores (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE,
  business_name TEXT NOT NULL,
  description TEXT,
  category_id uuid REFERENCES categories(id),
  location geography(Point,4326),
  address_text TEXT,
  contact_phone TEXT,
  contact_email TEXT,
  website_url TEXT,
  logo_storage_path TEXT,
  cover_image_storage_path TEXT,
  rating NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (rating >= 0 AND rating <= 5),
  review_count INT NOT NULL DEFAULT 0,
  listing_count INT NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  metadata jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_provider_stores_provider ON provider_stores(provider_id);
CREATE INDEX IF NOT EXISTS idx_provider_stores_category ON provider_stores(category_id);
CREATE INDEX IF NOT EXISTS idx_provider_stores_active ON provider_stores(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_provider_stores_location ON provider_stores USING gist(location);
CREATE INDEX IF NOT EXISTS idx_provider_stores_rating ON provider_stores(rating DESC);
CREATE INDEX IF NOT EXISTS idx_provider_stores_sector_active ON provider_stores(is_active) WHERE is_active = true;

-- listing_images (from0013)
CREATE TABLE IF NOT EXISTS listing_images (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  listing_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  alt_text TEXT,
  is_primary BOOLEAN NOT NULL DEFAULT false,
  sort_order INT NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_listing_images_listing ON listing_images(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_images_primary ON listing_images(listing_id) WHERE is_primary = true;
CREATE INDEX IF NOT EXISTS idx_listing_images_sort ON listing_images(listing_id, sort_order);

-- provider_gallery (from0013)
CREATE TABLE IF NOT EXISTS provider_gallery (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  caption TEXT,
  display_order INT NOT NULL DEFAULT 0,
  is_active BOOLEAN NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_provider_gallery_provider ON provider_gallery(provider_id);
CREATE INDEX IF NOT EXISTS idx_provider_gallery_active ON provider_gallery(provider_id, is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_provider_gallery_order ON provider_gallery(provider_id, display_order);

-- Add vehicle_category_id to ride_requests if not exists (from0010)
DO $$ BEGIN
  ALTER TABLE ride_requests ADD COLUMN vehicle_category_id uuid REFERENCES categories(id);
EXCEPTION WHEN duplicate_column THEN null;
END $$;

-- Provider profiles trigram index (from0006)
CREATE INDEX IF NOT EXISTS idx_provider_profiles_business_name_trgm ON provider_profiles USING gin(business_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_provider_profiles_business_name ON provider_profiles(business_name);

-- ============================================================================
-- ENABLE ROW LEVEL SECURITY ON ALL TABLES
-- ============================================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_agreements ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_proofs ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE favorites ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY;
ALTER TABLE appeals ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE fcm_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE n8n_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_recharge_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_wallet_actions ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE ride_ratings ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_stores ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_images ENABLE ROW LEVEL SECURITY;
ALTER TABLE provider_gallery ENABLE ROW LEVEL SECURITY;

-- ============================================================================
-- HELPER FUNCTIONS (security definer)
-- ============================================================================

CREATE OR REPLACE FUNCTION has_role(check_role app_role)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT exists (
    SELECT 1 FROM user_roles
    WHERE user_id = auth.uid() AND role = check_role
  );
$$;

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT has_role('ADMIN'::app_role);
$$;

CREATE OR REPLACE FUNCTION owns_provider_profile(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT exists (
    SELECT 1 FROM provider_profiles
    WHERE id = p_provider_id AND user_id = auth.uid()
  );
$$;

-- ============================================================================
-- RLS POLICIES (safe to re-create via DO blocks)
-- ============================================================================

-- PROFILES
DO $$ BEGIN CREATE POLICY profiles_select_own ON profiles FOR select USING (id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY profiles_update_own ON profiles FOR update USING (id = auth.uid()) WITH CHECK (id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY profiles_insert_own ON profiles FOR insert WITH CHECK (id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY profiles_admin_all ON profiles FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- USER_ROLES
DO $$ BEGIN CREATE POLICY user_roles_select_own ON user_roles FOR select USING (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY user_roles_admin_write ON user_roles FOR insert WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY user_roles_admin_update ON user_roles FOR update USING (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY user_roles_admin_delete ON user_roles FOR delete USING (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- USER_DOCUMENTS
DO $$ BEGIN CREATE POLICY user_documents_owner ON user_documents FOR select USING (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY user_documents_insert_own ON user_documents FOR insert WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY user_documents_admin_manage ON user_documents FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PROVIDER_PROFILES
DO $$ BEGIN CREATE POLICY provider_profiles_public_read ON provider_profiles FOR select USING (status = 'APPROVED' OR user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_profiles_insert_own ON provider_profiles FOR insert WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_profiles_update_own ON provider_profiles FOR update USING (user_id = auth.uid() AND status != 'APPROVED') WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_profiles_admin_all ON provider_profiles FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- APPROVAL_REQUESTS
DO $$ BEGIN CREATE POLICY approval_requests_admin_all ON approval_requests FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY approval_requests_owner_read ON approval_requests FOR select USING (
  (subject_type = 'USER' AND subject_id = auth.uid())
  OR (subject_type = 'PROVIDER' AND owns_provider_profile(subject_id))
  OR is_admin()
); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- APPROVAL_HISTORY
DO $$ BEGIN CREATE POLICY approval_history_admin_all ON approval_history FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY approval_history_owner_read ON approval_history FOR select USING (
  (subject_type = 'USER' AND subject_id = auth.uid())
  OR (subject_type = 'PROVIDER' AND owns_provider_profile(subject_id))
  OR is_admin()
); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- CATEGORIES
DO $$ BEGIN CREATE POLICY categories_public_read ON categories FOR select USING (is_active = true OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY categories_admin_write ON categories FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- VEHICLES
DO $$ BEGIN CREATE POLICY vehicles_public_read ON vehicles FOR select USING (status = 'APPROVED' OR owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY vehicles_provider_insert ON vehicles FOR insert WITH CHECK (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY vehicles_provider_update ON vehicles FOR update USING (owns_provider_profile(provider_id)) WITH CHECK (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY vehicles_provider_delete ON vehicles FOR delete USING (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY vehicles_admin_all ON vehicles FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- VEHICLE_IMAGES
DO $$ BEGIN CREATE POLICY vehicle_images_read ON vehicle_images FOR select USING (exists (SELECT 1 FROM vehicles v WHERE v.id = vehicle_id AND (v.status = 'APPROVED' OR owns_provider_profile(v.provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY vehicle_images_owner_write ON vehicle_images FOR all USING (exists (SELECT 1 FROM vehicles v WHERE v.id = vehicle_id AND owns_provider_profile(v.provider_id))) WITH CHECK (exists (SELECT 1 FROM vehicles v WHERE v.id = vehicle_id AND owns_provider_profile(v.provider_id))); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PRODUCTS
DO $$ BEGIN CREATE POLICY products_public_read ON products FOR select USING (is_active = true OR owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY products_provider_insert ON products FOR insert WITH CHECK (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY products_provider_update ON products FOR update USING (owns_provider_profile(provider_id)) WITH CHECK (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY products_provider_delete ON products FOR delete USING (owns_provider_profile(provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY products_admin_all ON products FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PRODUCT_IMAGES
DO $$ BEGIN CREATE POLICY product_images_read ON product_images FOR select USING (exists (SELECT 1 FROM products p WHERE p.id = product_id AND (p.is_active = true OR owns_provider_profile(p.provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY product_images_owner_write ON product_images FOR all USING (exists (SELECT 1 FROM products p WHERE p.id = product_id AND owns_provider_profile(p.provider_id))) WITH CHECK (exists (SELECT 1 FROM products p WHERE p.id = product_id AND owns_provider_profile(p.provider_id))); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ORDERS
DO $$ BEGIN CREATE POLICY orders_user_read ON orders FOR select USING (user_id = auth.uid() OR owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY orders_user_insert ON orders FOR insert WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY orders_admin_update ON orders FOR update USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY orders_admin_all ON orders FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ORDER_ITEMS
DO $$ BEGIN CREATE POLICY order_items_read ON order_items FOR select USING (exists (SELECT 1 FROM orders o WHERE o.id = order_id AND (o.user_id = auth.uid() OR owns_provider_profile(o.provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY order_items_user_insert ON order_items FOR insert WITH CHECK (exists (SELECT 1 FROM orders o WHERE o.id = order_id AND o.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ORDER_STATUS_HISTORY
DO $$ BEGIN CREATE POLICY order_status_history_read ON order_status_history FOR select USING (exists (SELECT 1 FROM orders o WHERE o.id = order_id AND (o.user_id = auth.uid() OR owns_provider_profile(o.provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PAYMENT AGREEMENTS
DO $$ BEGIN CREATE POLICY payment_agreements_user ON payment_agreements FOR all USING (user_id = auth.uid() OR is_admin()) WITH CHECK (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PAYMENT PROOFS
DO $$ BEGIN CREATE POLICY payment_proofs_read ON payment_proofs FOR select USING (exists (SELECT 1 FROM orders o WHERE o.id = order_id AND (o.user_id = auth.uid() OR owns_provider_profile(o.provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY payment_proofs_user_insert ON payment_proofs FOR insert WITH CHECK (exists (SELECT 1 FROM orders o WHERE o.id = order_id AND o.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY payment_proofs_admin_verify ON payment_proofs FOR update USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- RIDE_REQUESTS
DO $$ BEGIN CREATE POLICY ride_requests_user_read ON ride_requests FOR select USING (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_requests_provider_read_open ON ride_requests FOR select USING (status = 'REQUESTED' AND has_role('VEHICLE_PROVIDER'::app_role)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_requests_claimed_provider_read ON ride_requests FOR select USING (owns_provider_profile(claimed_by_provider_id)); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_requests_user_insert ON ride_requests FOR insert WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_requests_user_cancel ON ride_requests FOR update USING (user_id = auth.uid() AND status = 'REQUESTED') WITH CHECK (status = 'CANCELLED'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_requests_admin_all ON ride_requests FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- RIDE_STATUS_HISTORY
DO $$ BEGIN CREATE POLICY ride_status_history_read ON ride_status_history FOR select USING (exists (SELECT 1 FROM ride_requests r WHERE r.id = ride_request_id AND (r.user_id = auth.uid() OR owns_provider_profile(r.claimed_by_provider_id) OR is_admin()))); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- WALLETS
DO $$ BEGIN CREATE POLICY wallets_owner_read ON wallets FOR select USING (owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY wallets_admin_all ON wallets FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- WALLET_TRANSACTIONS
DO $$ BEGIN CREATE POLICY wallet_transactions_owner_read ON wallet_transactions FOR select USING (owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY wallet_transactions_admin_all ON wallet_transactions FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- SUBSCRIPTIONS
DO $$ BEGIN CREATE POLICY subscriptions_owner_read ON subscriptions FOR select USING (owns_provider_profile(provider_id) OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY subscriptions_admin_all ON subscriptions FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- REVIEWS
DO $$ BEGIN CREATE POLICY reviews_public_read ON reviews FOR select USING (true); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY reviews_user_insert ON reviews FOR insert WITH CHECK (
  user_id = auth.uid()
  AND exists (SELECT 1 FROM orders o WHERE o.id = order_id AND o.user_id = auth.uid() AND o.status = 'COMPLETED')
); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY reviews_owner_update ON reviews FOR update USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY reviews_owner_delete ON reviews FOR delete USING (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY reviews_admin_moderate ON reviews FOR delete USING (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- FAVORITES
DO $$ BEGIN CREATE POLICY favorites_owner_all ON favorites FOR all USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- NOTIFICATIONS
DO $$ BEGIN CREATE POLICY notifications_owner_read ON notifications FOR select USING (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY notifications_owner_update ON notifications FOR update USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY notifications_admin_all ON notifications FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- NOTIFICATION_PREFERENCES
DO $$ BEGIN CREATE POLICY notification_prefs_owner ON notification_preferences FOR all USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ADMIN_ACTIONS
DO $$ BEGIN CREATE POLICY admin_actions_admin_only ON admin_actions FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- SUPPORT_TICKETS
DO $$ BEGIN CREATE POLICY support_tickets_owner ON support_tickets FOR all USING (user_id = auth.uid() OR is_admin()) WITH CHECK (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- APPEALS
DO $$ BEGIN CREATE POLICY appeals_owner ON appeals FOR select USING (user_id = auth.uid() OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY appeals_owner_insert ON appeals FOR insert WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY appeals_admin_update ON appeals FOR update USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- AUDIT_LOGS
DO $$ BEGIN CREATE POLICY audit_logs_admin_only ON audit_logs FOR select USING (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- SYSTEM_SETTINGS
DO $$ BEGIN CREATE POLICY system_settings_read ON system_settings FOR select USING (true); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY system_settings_admin_write ON system_settings FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- CART_ITEMS
DO $$ BEGIN CREATE POLICY "Users manage their own cart" ON cart_items FOR all USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- FCM_TOKENS
DO $$ BEGIN CREATE POLICY fcm_tokens_owner_all ON fcm_tokens FOR all USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY fcm_tokens_admin_all ON fcm_tokens FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- N8N_EVENTS
DO $$ BEGIN CREATE POLICY n8n_events_admin_only ON n8n_events FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PAYMENT_METHODS
DO $$ BEGIN CREATE POLICY payment_methods_admin_all ON payment_methods FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY payment_methods_read_active ON payment_methods FOR select USING (is_active = true OR is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- WALLET_RECHARGE_REQUESTS
DO $$ BEGIN CREATE POLICY recharge_requests_provider_insert ON wallet_recharge_requests FOR insert WITH CHECK (provider_id IN (SELECT id FROM provider_profiles WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY recharge_requests_provider_read_own ON wallet_recharge_requests FOR select USING (provider_id IN (SELECT id FROM provider_profiles WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY recharge_requests_admin_all ON wallet_recharge_requests FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ADMIN_WALLET_ACTIONS
DO $$ BEGIN CREATE POLICY admin_wallet_actions_admin_only ON admin_wallet_actions FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- DRIVER_STATUS
DO $$ BEGIN CREATE POLICY driver_status_own ON driver_status FOR all USING (provider_id IN (SELECT id FROM provider_profiles WHERE user_id = auth.uid())) WITH CHECK (provider_id IN (SELECT id FROM provider_profiles WHERE user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY driver_status_admin ON driver_status FOR select USING (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- RIDE_RATINGS
DO $$ BEGIN CREATE POLICY ride_ratings_insert_own ON ride_ratings FOR insert WITH CHECK (rater_id = auth.uid()); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_ratings_read ON ride_ratings FOR select USING (true); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY ride_ratings_admin ON ride_ratings FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PROVIDER_STORES
DO $$ BEGIN CREATE POLICY provider_stores_public_read ON provider_stores FOR select USING (is_active = true AND exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.status = 'APPROVED')); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_stores_owner_read ON provider_stores FOR select USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_stores_owner_insert ON provider_stores FOR insert WITH CHECK (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid() AND pp.status = 'APPROVED')); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_stores_owner_update ON provider_stores FOR update USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())) WITH CHECK (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_stores_owner_delete ON provider_stores FOR delete USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_stores_admin_all ON provider_stores FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- LISTING_IMAGES
DO $$ BEGIN CREATE POLICY listing_images_public_read ON listing_images FOR select USING (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.is_active = true AND p.listing_status = 'ACTIVE')); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY listing_images_owner_read ON listing_images FOR select USING (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.provider_id IN (SELECT pp.id FROM provider_profiles pp WHERE pp.user_id = auth.uid()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY listing_images_owner_insert ON listing_images FOR insert WITH CHECK (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.provider_id IN (SELECT pp.id FROM provider_profiles pp WHERE pp.user_id = auth.uid()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY listing_images_owner_update ON listing_images FOR update USING (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.provider_id IN (SELECT pp.id FROM provider_profiles pp WHERE pp.user_id = auth.uid()))) WITH CHECK (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.provider_id IN (SELECT pp.id FROM provider_profiles pp WHERE pp.user_id = auth.uid()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY listing_images_owner_delete ON listing_images FOR delete USING (exists (SELECT 1 FROM products p WHERE p.id = listing_id AND p.provider_id IN (SELECT pp.id FROM provider_profiles pp WHERE pp.user_id = auth.uid()))); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY listing_images_admin_all ON listing_images FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- PROVIDER_GALLERY
DO $$ BEGIN CREATE POLICY provider_gallery_public_read ON provider_gallery FOR select USING (is_active = true AND exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.status = 'APPROVED')); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_gallery_owner_read ON provider_gallery FOR select USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_gallery_owner_insert ON provider_gallery FOR insert WITH CHECK (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid() AND pp.status = 'APPROVED')); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_gallery_owner_update ON provider_gallery FOR update USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())) WITH CHECK (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_gallery_owner_delete ON provider_gallery FOR delete USING (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = provider_id AND pp.user_id = auth.uid())); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE POLICY provider_gallery_admin_all ON provider_gallery FOR all USING (is_admin()) WITH CHECK (is_admin()); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ============================================================================
-- BUSINESS LOGIC FUNCTIONS (CREATE OR REPLACE = idempotent)
-- ============================================================================

-- Config helpers
CREATE OR REPLACE FUNCTION get_setting_numeric(p_key text)
RETURNS NUMERIC LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT (value #>> '{}')::NUMERIC FROM system_settings WHERE key = p_key;
$$;

CREATE OR REPLACE FUNCTION get_setting_bool(p_key text)
RETURNS BOOLEAN LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT (value #>> '{}')::BOOLEAN FROM system_settings WHERE key = p_key;
$$;

-- updated_at trigger function
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  new.updated_at = now();
  return new;
END;
$$;

-- Atomic ride claim
CREATE OR REPLACE FUNCTION claim_ride(p_ride_id uuid, p_provider_id uuid, p_vehicle_id uuid)
RETURNS ride_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ride ride_requests;
BEGIN
  IF NOT exists (SELECT 1 FROM vehicles WHERE id = p_vehicle_id AND provider_id = p_provider_id AND is_available = true) THEN
    RAISE EXCEPTION 'VEHICLE_NOT_ELIGIBLE';
  END IF;
  IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND provider_type = 'VEHICLE_PROVIDER' AND status = 'APPROVED') THEN
    RAISE EXCEPTION 'PROVIDER_NOT_ELIGIBLE';
  END IF;
  UPDATE ride_requests SET status = 'CLAIMED', claimed_by_provider_id = p_provider_id, claimed_vehicle_id = p_vehicle_id, claimed_at = now(), updated_at = now()
  WHERE id = p_ride_id AND status = 'REQUESTED' RETURNING * INTO v_ride;
  IF v_ride.id IS NULL THEN RAISE EXCEPTION 'RIDE_ALREADY_TAKEN'; END IF;
  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (p_ride_id, 'REQUESTED', 'CLAIMED', auth.uid());
  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (auth.uid(), 'RIDE_CLAIMED', 'ride_requests', p_ride_id, jsonb_build_object('provider_id', p_provider_id, 'vehicle_id', p_vehicle_id));
  RETURN v_ride;
END;
$$;

-- Deduct transaction fee (idempotent)
CREATE OR REPLACE FUNCTION deduct_transaction_fee(p_provider_id uuid, p_order_id uuid, p_ride_id uuid, p_gross_amount NUMERIC, p_idempotency_key text)
RETURNS wallet_transactions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wallet wallets; v_fee NUMERIC := get_setting_numeric('transaction_fee'); v_allow BOOLEAN := get_setting_bool('allow_negative_wallet'); v_txn wallet_transactions; v_existing wallet_transactions;
BEGIN
  SELECT * INTO v_existing FROM wallet_transactions WHERE idempotency_key = p_idempotency_key;
  IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
  SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  IF NOT v_allow AND (v_wallet.balance - v_fee) < 0 THEN
    INSERT INTO wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
    VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'FAILED', p_idempotency_key) RETURNING * INTO v_txn;
    INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'WALLET_EMPTY', 'Wallet balance too low', 'Transaction fee could not be deducted — please recharge your wallet.' FROM provider_profiles WHERE id = p_provider_id;
    RAISE EXCEPTION 'INSUFFICIENT_WALLET_BALANCE';
  END IF;
  UPDATE wallets SET balance = balance - v_fee, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet;
  INSERT INTO wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'COMPLETED', p_idempotency_key) RETURNING * INTO v_txn;
  INSERT INTO audit_logs (event_type, entity_type, entity_id, metadata) VALUES ('TRANSACTION_FEE_DEDUCTED', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'fee', v_fee, 'balance_after', v_wallet.balance));
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'TRANSACTION_FEE_DEDUCTED', 'Platform fee deducted', v_fee::text || ' Birr deducted from your wallet.' FROM provider_profiles WHERE id = p_provider_id;
  IF v_wallet.balance <= get_setting_numeric('low_wallet_threshold') THEN
    INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'WALLET_LOW', 'Wallet balance low', 'Your wallet balance is low. Please recharge soon.' FROM provider_profiles WHERE id = p_provider_id;
  END IF;
  RETURN v_txn;
END;
$$;

-- Deduct subscription fee (idempotent)
CREATE OR REPLACE FUNCTION deduct_subscription_fee(p_provider_id uuid, p_period text)
RETURNS wallet_transactions LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wallet wallets; v_fee NUMERIC := get_setting_numeric('monthly_subscription_fee'); v_key text := 'sub:' || p_provider_id::text || ':' || p_period; v_existing wallet_transactions; v_txn wallet_transactions;
BEGIN
  SELECT * INTO v_existing FROM wallet_transactions WHERE idempotency_key = v_key;
  IF v_existing.id IS NOT NULL THEN RETURN v_existing; END IF;
  SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  UPDATE wallets SET balance = balance - v_fee, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet;
  INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, 'SUBSCRIPTION_FEE', v_fee, v_fee, 0, v_wallet.balance, 'COMPLETED', v_key) RETURNING * INTO v_txn;
  UPDATE subscriptions SET last_charged_at = now(), next_due_date = next_due_date + interval '1 month', status = 'ACTIVE' WHERE provider_id = p_provider_id;
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'SUBSCRIPTION_DUE', 'Subscription charged', v_fee::text || ' Birr monthly subscription deducted.' FROM provider_profiles WHERE id = p_provider_id;
  RETURN v_txn;
END;
$$;

-- Order state machine (latest version from0008)
CREATE OR REPLACE FUNCTION transition_order_status(p_order_id uuid, p_new_status order_status, p_actor uuid, p_note text DEFAULT null)
RETURNS orders LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order orders; v_old order_status; v_valid boolean := false; v_actor_is_provider boolean := false; v_actor_is_admin boolean := false;
BEGIN
  SELECT * INTO v_order FROM orders WHERE id = p_order_id FOR UPDATE;
  IF v_order.id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  v_old := v_order.status;
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN') INTO v_actor_is_admin;
  SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_order.provider_id AND user_id = p_actor) INTO v_actor_is_provider;
  v_valid := case v_old
    when 'CREATED' then p_new_status in ('PENDING_PROVIDER','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin)
    when 'PENDING_PROVIDER' then (p_new_status in ('ACCEPTED','REJECTED') AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))
    when 'ACCEPTED' then (p_new_status = 'PAYMENT_PENDING' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))
    when 'PAYMENT_PENDING' then (p_new_status = 'PAYMENT_VERIFICATION' AND v_order.user_id = p_actor) OR (p_new_status = 'CANCELLED' AND v_actor_is_admin)
    when 'PAYMENT_VERIFICATION' then p_new_status in ('APPROVED','REJECTED') AND v_actor_is_admin
    when 'APPROVED' then (p_new_status = 'STARTED' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status = 'CANCELLED' AND (v_order.user_id = p_actor OR v_actor_is_admin))
    when 'STARTED' then (p_new_status = 'COMPLETED' AND (v_actor_is_provider OR v_actor_is_admin)) OR (p_new_status in ('DISPUTED','CANCELLED') AND (v_order.user_id = p_actor OR v_actor_is_admin))
    when 'COMPLETED' then p_new_status in ('DISPUTED','REFUNDED') AND (v_order.user_id = p_actor OR v_actor_is_admin)
    when 'DISPUTED' then p_new_status in ('REFUNDED','COMPLETED') AND v_actor_is_admin
    else false
  end;
  IF NOT v_valid THEN RAISE EXCEPTION 'INVALID_TRANSITION_%_TO_%_FOR_ACTOR', v_old, p_new_status; END IF;
  IF p_new_status = 'APPROVED' AND v_order.requires_payment_proof THEN
    IF NOT exists (SELECT 1 FROM payment_proofs WHERE order_id = p_order_id AND verification_status = 'VERIFIED') THEN RAISE EXCEPTION 'PAYMENT_PROOF_REQUIRED'; END IF;
  END IF;
  UPDATE orders SET status = p_new_status, updated_at = now() WHERE id = p_order_id RETURNING * INTO v_order;
  INSERT INTO order_status_history (order_id, from_status, to_status, changed_by, note) VALUES (p_order_id, v_old, p_new_status, p_actor, p_note);
  IF p_new_status = 'STARTED' THEN PERFORM deduct_transaction_fee(v_order.provider_id, p_order_id, null, v_order.total_amount, 'order:' || p_order_id::text); END IF;
  RETURN v_order;
END;
$$;

-- Ride status transition (latest version from0008)
CREATE OR REPLACE FUNCTION transition_ride_status(p_ride_id uuid, p_new_status ride_status, p_actor uuid)
RETURNS ride_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ride ride_requests; v_old ride_status; v_actor_is_admin boolean := false; v_actor_is_claiming_provider boolean := false;
BEGIN
  SELECT * INTO v_ride FROM ride_requests WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN RAISE EXCEPTION 'RIDE_NOT_FOUND'; END IF;
  v_old := v_ride.status;
  IF v_old = 'CANCELLED' OR v_old = 'COMPLETED' THEN RAISE EXCEPTION 'RIDE_ALREADY_TERMINAL'; END IF;
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_actor AND role = 'ADMIN') INTO v_actor_is_admin;
  IF v_ride.claimed_by_provider_id IS NOT NULL THEN
    SELECT exists (SELECT 1 FROM provider_profiles WHERE id = v_ride.claimed_by_provider_id AND user_id = p_actor) INTO v_actor_is_claiming_provider;
  END IF;
  CASE v_old
    WHEN 'REQUESTED' THEN
      IF p_new_status != 'CANCELLED' THEN RAISE EXCEPTION 'ONLY_CANCELLATION_ALLOWED_FROM_REQUESTED_USE_CLAIM_RIDE'; END IF;
      IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL_BEFORE_CLAIM'; END IF;
    WHEN 'CLAIMED' THEN
      IF p_new_status = 'CANCELLED' THEN
        IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL_CLAIMED_RIDE'; END IF;
      ELSIF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_PROGRESS_RIDE'; END IF;
    WHEN 'DRIVER_ARRIVING' THEN
      IF p_new_status = 'CANCELLED' THEN
        IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL'; END IF;
      ELSIF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_PROGRESS_RIDE'; END IF;
    WHEN 'STARTED' THEN
      IF p_new_status IN ('COMPLETED') THEN
        IF NOT v_actor_is_claiming_provider AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_CLAIMING_PROVIDER_OR_ADMIN_CAN_COMPLETE_RIDE'; END IF;
      ELSIF p_new_status = 'CANCELLED' THEN
        IF v_ride.user_id != p_actor AND NOT v_actor_is_admin THEN RAISE EXCEPTION 'ONLY_RIDER_OR_ADMIN_CAN_CANCEL'; END IF;
      END IF;
    ELSE RAISE EXCEPTION 'UNEXPECTED_RIDE_STATUS_%', v_old;
  END CASE;
  UPDATE ride_requests SET status = p_new_status, updated_at = now() WHERE id = p_ride_id RETURNING * INTO v_ride;
  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (p_ride_id, v_old, p_new_status, p_actor);
  IF p_new_status = 'COMPLETED' THEN PERFORM deduct_transaction_fee(v_ride.claimed_by_provider_id, null, p_ride_id, coalesce(v_ride.fare_estimate, 0), 'ride:' || p_ride_id::text); END IF;
  RETURN v_ride;
END;
$$;

-- Approve provider (latest hardened version from0019)
CREATE OR REPLACE FUNCTION approve_provider(p_provider_id uuid, p_admin_id uuid)
RETURNS provider_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE_PROVIDERS'; END IF;
  IF exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = p_admin_id) THEN RAISE EXCEPTION 'ADMINISTRATORS_CANNOT_APPROVE_THEIR_OWN_PROVIDER_ACCOUNT'; END IF;
  UPDATE provider_profiles SET status = 'APPROVED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF;
  INSERT INTO wallets (provider_id, balance) VALUES (p_provider_id, 0) ON CONFLICT (provider_id) DO NOTHING;
  INSERT INTO subscriptions (provider_id, next_due_date) VALUES (p_provider_id, v_provider.subscription_start_date) ON CONFLICT (provider_id) DO NOTHING;
  INSERT INTO approval_history (subject_type, subject_id, action, performed_by) VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'APPROVAL', 'Application approved', 'Your provider account is now active.' FROM provider_profiles WHERE id = p_provider_id;
  INSERT INTO admin_actions (admin_id, action, target_type, target_id) VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id);
  RETURN v_provider;
END;
$$;

-- Reject provider (latest hardened version from0019)
CREATE OR REPLACE FUNCTION reject_provider(p_provider_id uuid, p_admin_id uuid, p_reason text)
RETURNS provider_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT_PROVIDERS'; END IF;
  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF;
  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'REJECT', p_reason, p_admin_id);
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'REJECTION', 'Application rejected', p_reason FROM provider_profiles WHERE id = p_provider_id;
  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'REJECT_PROVIDER', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason));
  RETURN v_provider;
END;
$$;

-- Request correction
CREATE OR REPLACE FUNCTION request_correction_provider(p_provider_id uuid, p_admin_id uuid, p_reason text)
RETURNS provider_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REQUEST_CORRECTION'; END IF;
  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF;
  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'REQUEST_CORRECTION', p_reason, p_admin_id);
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'CORRECTION_REQUIRED', 'Correction requested', 'Please update your submission: ' || p_reason FROM provider_profiles WHERE id = p_provider_id;
  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'REQUEST_CORRECTION', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason));
  RETURN v_provider;
END;
$$;

-- Suspend / unsuspend provider
CREATE OR REPLACE FUNCTION suspend_provider(p_provider_id uuid, p_admin_id uuid, p_reason text DEFAULT null)
RETURNS provider_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_SUSPEND_PROVIDERS'; END IF;
  UPDATE provider_profiles SET status = 'SUSPENDED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF;
  UPDATE vehicles SET is_available = false WHERE provider_id = p_provider_id AND status = 'APPROVED';
  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by) VALUES ('PROVIDER', p_provider_id, 'SUSPEND', p_reason, p_admin_id);
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'PROVIDER_INACTIVE', 'Account suspended', coalesce(p_reason, 'Your provider account has been suspended.') FROM provider_profiles WHERE id = p_provider_id;
  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details) VALUES (p_admin_id, 'SUSPEND_PROVIDER', 'provider_profiles', p_provider_id, jsonb_build_object('reason', p_reason));
  RETURN v_provider;
END;
$$;

CREATE OR REPLACE FUNCTION unsuspend_provider(p_provider_id uuid, p_admin_id uuid)
RETURNS provider_profiles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_is_admin boolean;
BEGIN
  SELECT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') INTO v_is_admin;
  IF NOT v_is_admin THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_UNSUSPEND_PROVIDERS'; END IF;
  UPDATE provider_profiles SET status = 'APPROVED', updated_at = now() WHERE id = p_provider_id RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN RAISE EXCEPTION 'PROVIDER_NOT_FOUND'; END IF;
  UPDATE vehicles SET is_available = true WHERE provider_id = p_provider_id AND status = 'APPROVED';
  INSERT INTO approval_history (subject_type, subject_id, action, performed_by) VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);
  INSERT INTO notifications (user_id, type, title, body) SELECT user_id, 'APPROVAL', 'Account reactivated', 'Your provider account has been reactivated.' FROM provider_profiles WHERE id = p_provider_id;
  INSERT INTO admin_actions (admin_id, action, target_type, target_id) VALUES (p_admin_id, 'UNSUSPEND_PROVIDER', 'provider_profiles', p_provider_id);
  RETURN v_provider;
END;
$$;

-- Create order securely
CREATE OR REPLACE FUNCTION create_order_secure(p_user_id uuid, p_provider_id uuid, p_items jsonb, p_total_amount NUMERIC, p_currency text, p_note text DEFAULT null)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_order_id uuid; v_item jsonb;
BEGIN
  IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN RAISE EXCEPTION 'p_items must be a non-empty array'; END IF;
  INSERT INTO orders (id, user_id, provider_id, status, total_amount, currency, requires_payment_proof, created_at)
  VALUES (gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount, coalesce(p_currency, 'ETB'), true, now()) RETURNING id INTO v_order_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO order_items (id, order_id, product_id, quantity, unit_price)
    VALUES (gen_random_uuid(), v_order_id, (v_item->>'product_id')::uuid, (v_item->>'quantity')::int, (v_item->>'unit_price')::numeric);
  END LOOP;
  INSERT INTO order_status_history (id, order_id, from_status, to_status, changed_by, note) VALUES (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note);
  RETURN (SELECT to_jsonb(o) FROM orders o WHERE o.id = v_order_id);
END;
$$;

REVOKE EXECUTE ON FUNCTION create_order_secure(uuid, uuid, jsonb, NUMERIC, text, text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION create_order_secure(uuid, uuid, jsonb, NUMERIC, text, text) TO service_role;

-- Search functions (from0006, 0015)
CREATE OR REPLACE FUNCTION search_products(p_query text DEFAULT null, p_category_id uuid DEFAULT null, p_sector text DEFAULT null, p_lat double precision DEFAULT null, p_lng double precision DEFAULT null, p_radius_km NUMERIC DEFAULT null, p_min_price NUMERIC DEFAULT null, p_max_price NUMERIC DEFAULT null, p_min_rating NUMERIC DEFAULT null, p_sort_by text DEFAULT 'relevance', p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (id uuid, name text, description text, price NUMERIC, currency text, rating NUMERIC, review_count int, sales_count int, category_id uuid, provider_id uuid, provider_name text, distance_km NUMERIC, is_available boolean, image_path text, rank_score NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography; END IF;
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.price, p.currency, p.rating, p.review_count, p.sales_count, p.category_id, p.provider_id, pp.business_name AS provider_name,
    CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ROUND((ST_Distance(p.location, v_location) / 1000.0)::numeric, 2) ELSE null END AS distance_km,
    p.is_available,
    (SELECT pi.storage_path FROM product_images pi WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1) AS image_path,
    CASE WHEN p_query IS NOT NULL AND p_query != '' THEN ts_rank(p.search_vector, plainto_tsquery('simple', p_query)) + (1.0 / (1.0 + coalesce(CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) / 1000.0 ELSE 9999 END, 9999))) ELSE 0 END AS rank_score
  FROM products p JOIN provider_profiles pp ON pp.id = p.provider_id AND pp.status = 'APPROVED'
  WHERE p.is_active = true AND p.is_available = true
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query))
    AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_sector IS NULL OR exists (SELECT 1 FROM categories c WHERE c.id = p.category_id AND c.sector = p_sector))
    AND (v_location IS NULL OR p.location IS NULL OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price) AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating)
  ORDER BY
    CASE p_sort_by WHEN 'price_asc' THEN p.price ELSE null END ASC,
    CASE p_sort_by WHEN 'price_desc' THEN p.price ELSE null END DESC,
    CASE p_sort_by WHEN 'rating' THEN p.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN p.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN CASE WHEN p_query IS NOT NULL AND p_query != '' THEN ts_rank(p.search_vector, plainto_tsquery('simple', p_query)) + (1.0 / (1.0 + coalesce(CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) / 1000.0 ELSE 9999 END, 9999))) ELSE 0 END ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) ELSE 999999999 END ELSE null END ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION get_nearby_providers(p_lat double precision, p_lng double precision, p_radius_km NUMERIC DEFAULT 5, p_provider_type app_role DEFAULT null, p_category_id uuid DEFAULT null, p_limit int DEFAULT 20)
RETURNS TABLE (id uuid, user_id uuid, provider_type app_role, business_name text, status account_status, rating NUMERIC, distance_km NUMERIC, service_area_radius_km NUMERIC, category_id uuid, category_name text)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name, pp.status, 0::NUMERIC AS rating,
    ROUND((ST_Distance(pp.location, v_location) / 1000.0)::numeric, 2) AS distance_km,
    pp.service_area_radius_km, pp.category_id, c.name AS category_name
  FROM provider_profiles pp LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED' AND pp.location IS NOT NULL AND ST_DWithin(pp.location, v_location, p_radius_km * 1000)
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type) AND (p_category_id IS NULL OR pp.category_id = p_category_id)
  ORDER BY ST_Distance(pp.location, v_location) LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION get_nearby_ride_providers(p_lat double precision, p_lng double precision, p_radius_km NUMERIC DEFAULT 5, p_vehicle_category_id uuid DEFAULT null, p_limit int DEFAULT 10)
RETURNS TABLE (provider_id uuid, vehicle_id uuid, provider_name text, plate_number text, vehicle_brand text, vehicle_model text, distance_km NUMERIC, rating NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN QUERY
  SELECT v.provider_id, v.id AS vehicle_id, pp.business_name AS provider_name, v.plate_number, v.brand AS vehicle_brand, v.model AS vehicle_model,
    ROUND((ST_Distance(v.current_location, v_location) / 1000.0)::numeric, 2) AS distance_km, v.rating
  FROM vehicles v JOIN provider_profiles pp ON pp.id = v.provider_id AND pp.status = 'APPROVED'
  WHERE v.is_available = true AND v.status = 'APPROVED' AND v.current_location IS NOT NULL AND ST_DWithin(v.current_location, v_location, p_radius_km * 1000)
    AND (p_vehicle_category_id IS NULL OR v.category_id = p_vehicle_category_id)
  ORDER BY ST_Distance(v.current_location, v_location) LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION search_providers(p_query text DEFAULT null, p_provider_type app_role DEFAULT null, p_category_id uuid DEFAULT null, p_lat double precision DEFAULT null, p_lng double precision DEFAULT null, p_radius_km NUMERIC DEFAULT null, p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (id uuid, user_id uuid, provider_type app_role, business_name text, owner_national_id text, status account_status, category_id uuid, category_name text, distance_km NUMERIC, address_text text, created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography; END IF;
  RETURN QUERY
  SELECT pp.id, pp.user_id, pp.provider_type, pp.business_name, pp.owner_national_id, pp.status, pp.category_id, c.name AS category_name,
    CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL THEN ROUND((ST_Distance(pp.location, v_location) / 1000.0)::numeric, 2) ELSE null END AS distance_km,
    pp.address_text, pp.created_at
  FROM provider_profiles pp LEFT JOIN categories c ON c.id = pp.category_id
  WHERE pp.status = 'APPROVED'
    AND (p_query IS NULL OR p_query = '' OR pp.business_name ILIKE '%' || p_query || '%' OR pp.address_text ILIKE '%' || p_query || '%')
    AND (p_provider_type IS NULL OR pp.provider_type = p_provider_type) AND (p_category_id IS NULL OR pp.category_id = p_category_id)
    AND (v_location IS NULL OR pp.location IS NULL OR ST_DWithin(pp.location, v_location, p_radius_km * 1000))
  ORDER BY CASE WHEN v_location IS NOT NULL AND pp.location IS NOT NULL THEN ST_Distance(pp.location, v_location) ELSE 999999999 END
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION check_delivery_zone(p_provider_id uuid, p_lat double precision, p_lng double precision)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_provider provider_profiles; v_point geography(Point,4326);
BEGIN
  SELECT * INTO v_provider FROM provider_profiles WHERE id = p_provider_id;
  IF v_provider IS NULL OR v_provider.location IS NULL THEN RETURN false; END IF;
  v_point := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN ST_DWithin(v_provider.location, v_point, v_provider.service_area_radius_km * 1000);
END;
$$;

CREATE OR REPLACE FUNCTION update_vehicle_location(p_vehicle_id uuid, p_lat double precision, p_lng double precision)
RETURNS vehicles LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_vehicle vehicles;
BEGIN
  IF NOT exists (SELECT 1 FROM vehicles v WHERE v.id = p_vehicle_id AND owns_provider_profile(v.provider_id)) THEN RAISE EXCEPTION 'VEHICLE_NOT_OWNED_BY_PROVIDER'; END IF;
  UPDATE vehicles SET current_location = ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography WHERE id = p_vehicle_id RETURNING * INTO v_vehicle;
  RETURN v_vehicle;
END;
$$;

-- Notification functions (from0007)
CREATE OR REPLACE FUNCTION mark_notification_read(p_notification_id uuid)
RETURNS notifications LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_notification notifications;
BEGIN
  UPDATE notifications SET is_read = true WHERE id = p_notification_id AND user_id = auth.uid() RETURNING * INTO v_notification;
  IF v_notification.id IS NULL THEN RAISE EXCEPTION 'NOTIFICATION_NOT_FOUND_OR_UNAUTHORIZED'; END IF;
  RETURN v_notification;
END;
$$;

CREATE OR REPLACE FUNCTION mark_all_notifications_read()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_count int;
BEGIN
  UPDATE notifications SET is_read = true WHERE user_id = auth.uid() AND is_read = false;
  GET DIAGNOSTICS v_count = row_count;
  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION upsert_notification_preferences(p_push_enabled boolean DEFAULT null, p_in_app_enabled boolean DEFAULT null)
RETURNS notification_preferences LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_prefs notification_preferences;
BEGIN
  INSERT INTO notification_preferences (user_id, push_enabled, in_app_enabled) VALUES (auth.uid(), coalesce(p_push_enabled, true), coalesce(p_in_app_enabled, true))
  ON CONFLICT (user_id) DO UPDATE SET push_enabled = coalesce(p_push_enabled, notification_preferences.push_enabled), in_app_enabled = coalesce(p_in_app_enabled, notification_preferences.in_app_enabled)
  RETURNING * INTO v_prefs;
  RETURN v_prefs;
END;
$$;

CREATE OR REPLACE FUNCTION create_n8n_event(p_event_type text, p_entity_type text, p_entity_id uuid DEFAULT null, p_payload jsonb DEFAULT null)
RETURNS n8n_events LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_event n8n_events;
BEGIN
  INSERT INTO n8n_events (event_type, entity_type, entity_id, payload) VALUES (p_event_type, p_entity_type, p_entity_id, p_payload) RETURNING * INTO v_event;
  RETURN v_event;
END;
$$;

-- Wallet recharge functions (from0009)
CREATE OR REPLACE FUNCTION approve_wallet_recharge(p_recharge_id uuid, p_admin_id uuid)
RETURNS wallet_recharge_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_recharge wallet_recharge_requests; v_wallet wallets; v_txn wallet_transactions;
BEGIN
  IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_APPROVE_RECHARGES'; END IF;
  SELECT * INTO v_recharge FROM wallet_recharge_requests WHERE id = p_recharge_id FOR UPDATE;
  IF v_recharge.id IS NULL THEN RAISE EXCEPTION 'RECHARGE_REQUEST_NOT_FOUND'; END IF;
  IF v_recharge.status = 'APPROVED' THEN RETURN v_recharge; END IF;
  IF v_recharge.status != 'PENDING' THEN RAISE EXCEPTION 'RECHARGE_REQUEST_IS_NOT_PENDING'; END IF;
  SELECT * INTO v_wallet FROM wallets WHERE id = v_recharge.wallet_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND'; END IF;
  UPDATE wallets SET balance = balance + v_recharge.amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet;
  INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, v_recharge.provider_id, 'RECHARGE', v_recharge.amount, 0, v_recharge.amount, v_wallet.balance, 'COMPLETED', 'recharge:' || v_recharge.id::text) RETURNING * INTO v_txn;
  UPDATE wallet_recharge_requests SET status = 'APPROVED', approved_by = p_admin_id, approved_at = now(), updated_at = now() WHERE id = p_recharge_id RETURNING * INTO v_recharge;
  INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'APPROVAL', 'Recharge Approved', v_recharge.amount::text || ' ETB has been credited to your wallet.' FROM provider_profiles pp WHERE pp.id = v_recharge.provider_id;
  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'WALLET_RECHARGE_APPROVED', 'wallets', v_wallet.id, jsonb_build_object('recharge_id', p_recharge_id, 'amount', v_recharge.amount, 'provider_id', v_recharge.provider_id));
  RETURN v_recharge;
END;
$$;

CREATE OR REPLACE FUNCTION reject_wallet_recharge(p_recharge_id uuid, p_admin_id uuid, p_reason text)
RETURNS wallet_recharge_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_recharge wallet_recharge_requests;
BEGIN
  IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_REJECT_RECHARGES'; END IF;
  SELECT * INTO v_recharge FROM wallet_recharge_requests WHERE id = p_recharge_id FOR UPDATE;
  IF v_recharge.id IS NULL THEN RAISE EXCEPTION 'RECHARGE_REQUEST_NOT_FOUND'; END IF;
  IF v_recharge.status != 'PENDING' THEN RAISE EXCEPTION 'RECHARGE_REQUEST_IS_NOT_PENDING'; END IF;
  UPDATE wallet_recharge_requests SET status = 'REJECTED', rejection_reason = p_reason, approved_by = p_admin_id, approved_at = now(), updated_at = now() WHERE id = p_recharge_id RETURNING * INTO v_recharge;
  INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'REJECTION', 'Recharge Rejected', 'Your recharge of ' || v_recharge.amount::text || ' ETB was rejected. Reason: ' || p_reason FROM provider_profiles pp WHERE pp.id = v_recharge.provider_id;
  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'WALLET_RECHARGE_REJECTED', 'wallets', (SELECT wallet_id FROM wallet_recharge_requests WHERE id = p_recharge_id), jsonb_build_object('recharge_id', p_recharge_id, 'reason', p_reason, 'provider_id', v_recharge.provider_id));
  RETURN v_recharge;
END;
$$;

CREATE OR REPLACE FUNCTION admin_cash_recharge(p_provider_id uuid, p_amount NUMERIC, p_reason text, p_admin_id uuid)
RETURNS wallets LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wallet wallets; v_balance_before NUMERIC;
BEGIN
  IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_PERFORM_CASH_RECHARGE'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'AMOUNT_MUST_BE_POSITIVE'; END IF;
  SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND_FOR_PROVIDER'; END IF;
  v_balance_before := v_wallet.balance;
  UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet;
  INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, 'ADMIN_CASH', p_amount, 0, p_amount, v_wallet.balance, 'COMPLETED', 'admin-cash:' || p_provider_id::text || ':' || now()::text);
  INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, 'CASH_RECHARGE', p_amount, p_reason, v_balance_before, v_wallet.balance);
  INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'APPROVAL', 'Cash Recharge', p_amount::text || ' ETB has been credited to your wallet (cash payment).' FROM provider_profiles pp WHERE pp.id = p_provider_id;
  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_CASH_RECHARGE', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount, 'reason', p_reason));
  RETURN v_wallet;
END;
$$;

CREATE OR REPLACE FUNCTION admin_wallet_adjustment(p_provider_id uuid, p_amount NUMERIC, p_reason text, p_admin_id uuid)
RETURNS wallets LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_wallet wallets; v_balance_before NUMERIC; v_action_type text;
BEGIN
  IF NOT exists (SELECT 1 FROM user_roles WHERE user_id = p_admin_id AND role = 'ADMIN') THEN RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_ADJUST_WALLETS'; END IF;
  IF p_amount = 0 THEN RAISE EXCEPTION 'AMOUNT_CANNOT_BE_ZERO'; END IF;
  SELECT * INTO v_wallet FROM wallets WHERE provider_id = p_provider_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN RAISE EXCEPTION 'WALLET_NOT_FOUND_FOR_PROVIDER'; END IF;
  v_balance_before := v_wallet.balance;
  IF p_amount > 0 THEN v_action_type := 'ADJUSTMENT_CREDIT'; ELSE v_action_type := 'ADJUSTMENT_DEBIT'; END IF;
  IF p_amount < 0 AND v_wallet.balance + p_amount < 0 THEN
    IF NOT (SELECT (value #>> '{}')::boolean FROM system_settings WHERE key = 'allow_negative_wallet') THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE_FOR_DEBIT'; END IF;
  END IF;
  UPDATE wallets SET balance = balance + p_amount, updated_at = now() WHERE id = v_wallet.id RETURNING * INTO v_wallet;
  INSERT INTO wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  VALUES (v_wallet.id, p_provider_id, 'ADJUSTMENT', abs(p_amount), 0, abs(p_amount), v_wallet.balance, 'COMPLETED', 'adjustment:' || p_provider_id::text || ':' || now()::text);
  INSERT INTO admin_wallet_actions (admin_id, provider_id, wallet_id, action_type, amount, reason, balance_before, balance_after) VALUES (p_admin_id, p_provider_id, v_wallet.id, v_action_type, abs(p_amount), p_reason, v_balance_before, v_wallet.balance);
  INSERT INTO notifications (user_id, type, title, body) SELECT pp.user_id, 'ADMIN_MESSAGE', 'Wallet Adjustment', 'Your wallet has been adjusted by ' || p_amount::text || ' ETB. Reason: ' || p_reason FROM provider_profiles pp WHERE pp.id = p_provider_id;
  INSERT INTO audit_logs (actor_id, event_type, entity_type, entity_id, metadata) VALUES (p_admin_id, 'ADMIN_WALLET_ADJUSTMENT', 'wallets', v_wallet.id, jsonb_build_object('provider_id', p_provider_id, 'amount', p_amount, 'reason', p_reason));
  RETURN v_wallet;
END;
$$;

-- Transportation functions (from0010)
CREATE OR REPLACE FUNCTION find_nearby_drivers(p_lat double precision, p_lng double precision, p_radius_km NUMERIC DEFAULT 10, p_vehicle_category_id uuid DEFAULT null)
RETURNS TABLE (provider_id uuid, vehicle_id uuid, provider_name text, vehicle_brand text, vehicle_model text, vehicle_plate text, distance_km NUMERIC, vehicle_category uuid)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography;
  RETURN QUERY
  SELECT ds.provider_id, v.id AS vehicle_id, coalesce(pp.business_name, pr.full_name) AS provider_name, v.brand AS vehicle_brand, v.model AS vehicle_model, v.plate_number AS vehicle_plate,
    ROUND((ST_Distance(ds.current_location, v_location) / 1000.0)::numeric, 2) AS distance_km, v.category_id AS vehicle_category
  FROM driver_status ds JOIN provider_profiles pp ON pp.id = ds.provider_id AND pp.status = 'APPROVED' JOIN profiles pr ON pr.id = pp.user_id
  JOIN vehicles v ON v.provider_id = ds.provider_id AND v.is_available = true AND v.status = 'APPROVED'
  WHERE ds.is_online = true AND ds.current_location IS NOT NULL AND ds.current_ride_id IS NULL AND ST_DWithin(ds.current_location, v_location, p_radius_km * 1000)
    AND (p_vehicle_category_id IS NULL OR v.category_id = p_vehicle_category_id)
  ORDER BY ST_Distance(ds.current_location, v_location) LIMIT 20;
END;
$$;

CREATE OR REPLACE FUNCTION update_driver_location(p_provider_id uuid, p_lat double precision, p_lng double precision)
RETURNS driver_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status driver_status;
BEGIN
  IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = auth.uid()) THEN RAISE EXCEPTION 'NOT_YOUR_DRIVER_STATUS'; END IF;
  INSERT INTO driver_status (provider_id, current_location, last_location_update, updated_at)
  VALUES (p_provider_id, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, now(), now())
  ON CONFLICT (provider_id) DO UPDATE SET current_location = ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, last_location_update = now(), updated_at = now()
  RETURNING * INTO v_status;
  RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION set_driver_online(p_provider_id uuid, p_online boolean, p_lat double precision DEFAULT null, p_lng double precision DEFAULT null)
RETURNS driver_status LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_status driver_status;
BEGIN
  IF NOT exists (SELECT 1 FROM provider_profiles WHERE id = p_provider_id AND user_id = auth.uid() AND status = 'APPROVED') THEN RAISE EXCEPTION 'PROVIDER_NOT_APPROVED'; END IF;
  IF p_online AND (p_lat IS NULL OR p_lng IS NULL) THEN RAISE EXCEPTION 'LOCATION_REQUIRED_TO_GO_ONLINE'; END IF;
  INSERT INTO driver_status (provider_id, is_online, current_location, last_location_update, updated_at)
  VALUES (p_provider_id, p_online, CASE WHEN p_online THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography ELSE null END, CASE WHEN p_online THEN now() ELSE null END, now())
  ON CONFLICT (provider_id) DO UPDATE SET is_online = p_online,
    current_location = CASE WHEN p_online THEN ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography ELSE driver_status.current_location END,
    last_location_update = CASE WHEN p_online THEN now() ELSE driver_status.last_location_update END, updated_at = now()
  RETURNING * INTO v_status;
  RETURN v_status;
END;
$$;

CREATE OR REPLACE FUNCTION create_ride_request(p_user_id uuid, p_pickup_lat double precision, p_pickup_lng double precision, p_destination_lat double precision, p_destination_lng double precision, p_pickup_text text DEFAULT null, p_destination_text text DEFAULT null, p_vehicle_category_id uuid DEFAULT null)
RETURNS ride_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ride ride_requests;
BEGIN
  IF p_user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_RIDE_FOR_ANOTHER_USER'; END IF;
  INSERT INTO ride_requests (user_id, pickup_location, destination_location, pickup_text, destination_text, vehicle_category_id, status)
  VALUES (p_user_id, ST_SetSRID(ST_MakePoint(p_pickup_lng, p_pickup_lat), 4326)::geography, ST_SetSRID(ST_MakePoint(p_destination_lng, p_destination_lat), 4326)::geography, p_pickup_text, p_destination_text, p_vehicle_category_id, 'REQUESTED')
  RETURNING * INTO v_ride;
  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by) VALUES (v_ride.id, null, 'REQUESTED', p_user_id);
  RETURN v_ride;
END;
$$;

-- Marketplace search functions (from0015)
CREATE OR REPLACE FUNCTION search_marketplace(p_query text DEFAULT NULL, p_listing_type listing_type DEFAULT NULL, p_category_id uuid DEFAULT NULL, p_marketplace_sector text DEFAULT NULL, p_provider_id uuid DEFAULT NULL, p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL, p_radius_km NUMERIC DEFAULT NULL, p_min_price NUMERIC DEFAULT NULL, p_max_price NUMERIC DEFAULT NULL, p_min_rating NUMERIC DEFAULT NULL, p_in_stock_only boolean DEFAULT true, p_sort_by text DEFAULT 'relevance', p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (id uuid, name text, description text, price NUMERIC, currency text, listing_type listing_type, listing_status listing_status, stock_quantity int, rating NUMERIC, review_count int, sales_count int, category_id uuid, category_name text, marketplace_sector text, provider_id uuid, provider_name text, store_id uuid, distance_km NUMERIC, is_available boolean, image_path text, metadata jsonb, created_at timestamptz, rank_score NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography; END IF;
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.price, p.currency, p.listing_type, p.listing_status, p.stock_quantity, p.rating, p.review_count, p.sales_count, p.category_id, c.name AS category_name, c.marketplace_sector,
    p.provider_id, COALESCE(pp.business_name, pr.full_name) AS provider_name, ps.id AS store_id,
    CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ROUND((ST_Distance(p.location, v_location) / 1000.0)::numeric, 2) ELSE null END AS distance_km,
    p.is_available,
    COALESCE((SELECT li.storage_path FROM listing_images li WHERE li.listing_id = p.id AND li.is_primary = true LIMIT 1), (SELECT li.storage_path FROM listing_images li WHERE li.listing_id = p.id ORDER BY li.sort_order LIMIT 1), (SELECT pi.storage_path FROM product_images pi WHERE pi.product_id = p.id ORDER BY pi.sort_order LIMIT 1)) AS image_path,
    p.metadata, p.created_at,
    CASE WHEN p_query IS NOT NULL AND p_query != '' THEN TS_Rank(p.search_vector, plainto_tsquery('simple', p_query)) + (1.0 / (1.0 + COALESCE(CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) / 1000.0 ELSE 9999 END, 9999))) ELSE 0 END AS rank_score
  FROM products p JOIN provider_profiles pp ON pp.id = p.provider_id AND pp.status = 'APPROVED' JOIN profiles pr ON pr.id = pp.user_id
  LEFT JOIN provider_stores ps ON ps.provider_id = p.provider_id AND ps.is_active = true LEFT JOIN categories c ON c.id = p.category_id
  WHERE p.listing_status = 'ACTIVE' AND p.is_active = true
    AND (p_query IS NULL OR p_query = '' OR p.search_vector @@ plainto_tsquery('simple', p_query) OR p.name ILIKE '%' || p_query || '%')
    AND (p_listing_type IS NULL OR p.listing_type = p_listing_type) AND (p_category_id IS NULL OR p.category_id = p_category_id)
    AND (p_marketplace_sector IS NULL OR c.marketplace_sector = p_marketplace_sector) AND (p_provider_id IS NULL OR p.provider_id = p_provider_id)
    AND (v_location IS NULL OR p.location IS NULL OR ST_DWithin(p.location, v_location, p_radius_km * 1000))
    AND (p_min_price IS NULL OR p.price >= p_min_price) AND (p_max_price IS NULL OR p.price <= p_max_price)
    AND (p_min_rating IS NULL OR p.rating >= p_min_rating) AND (p_in_stock_only = false OR p.stock_quantity IS NULL OR p.stock_quantity > 0)
  ORDER BY
    CASE p_sort_by WHEN 'price_asc' THEN p.price ELSE null END ASC,
    CASE p_sort_by WHEN 'price_desc' THEN p.price ELSE null END DESC,
    CASE p_sort_by WHEN 'rating' THEN p.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN p.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN CASE WHEN p_query IS NOT NULL AND p_query != '' THEN TS_Rank(p.search_vector, plainto_tsquery('simple', p_query)) + (1.0 / (1.0 + COALESCE(CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) / 1000.0 ELSE 9999 END, 9999))) ELSE 0 END ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN CASE WHEN v_location IS NOT NULL AND p.location IS NOT NULL THEN ST_Distance(p.location, v_location) ELSE 999999999 END ELSE null END ASC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION search_marketplace_stores(p_query text DEFAULT NULL, p_marketplace_sector text DEFAULT NULL, p_category_id uuid DEFAULT NULL, p_lat double precision DEFAULT NULL, p_lng double precision DEFAULT NULL, p_radius_km NUMERIC DEFAULT NULL, p_min_rating NUMERIC DEFAULT NULL, p_sort_by text DEFAULT 'relevance', p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (id uuid, provider_id uuid, business_name text, description text, category_id uuid, category_name text, marketplace_sector text, address_text text, contact_phone text, contact_email text, logo_storage_path text, cover_image_storage_path text, rating NUMERIC, review_count int, listing_count int, distance_km NUMERIC, created_at timestamptz, rank_score NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
DECLARE v_location geography(Point,4326);
BEGIN
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL THEN v_location := ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography; END IF;
  RETURN QUERY
  SELECT ps.id, ps.provider_id, ps.business_name, ps.description, ps.category_id, c.name AS category_name, c.marketplace_sector, ps.address_text, ps.contact_phone, ps.contact_email, ps.logo_storage_path, ps.cover_image_storage_path, ps.rating, ps.review_count, ps.listing_count,
    CASE WHEN v_location IS NOT NULL AND ps.location IS NOT NULL THEN ROUND((ST_Distance(ps.location, v_location) / 1000.0)::numeric, 2) ELSE null END AS distance_km,
    ps.created_at,
    CASE WHEN p_query IS NOT NULL AND p_query != '' THEN TS_RANK(to_tsvector('simple', coalesce(ps.business_name, '') || ' ' || coalesce(ps.description, '')), plainto_tsquery('simple', p_query)) ELSE 0 END AS rank_score
  FROM provider_stores ps JOIN provider_profiles pp ON pp.id = ps.provider_id AND pp.status = 'APPROVED' LEFT JOIN categories c ON c.id = ps.category_id
  WHERE ps.is_active = true
    AND (p_query IS NULL OR p_query = '' OR ps.business_name ILIKE '%' || p_query || '%' OR ps.description ILIKE '%' || p_query || '%')
    AND (p_marketplace_sector IS NULL OR c.marketplace_sector = p_marketplace_sector) AND (p_category_id IS NULL OR ps.category_id = p_category_id)
    AND (v_location IS NULL OR ps.location IS NULL OR ST_DWithin(ps.location, v_location, p_radius_km * 1000))
    AND (p_min_rating IS NULL OR ps.rating >= p_min_rating)
  ORDER BY
    CASE p_sort_by WHEN 'rating' THEN ps.rating ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'distance' THEN CASE WHEN v_location IS NOT NULL AND ps.location IS NOT NULL THEN ST_Distance(ps.location, v_location) ELSE 999999999 END ELSE null END ASC NULLS LAST,
    CASE p_sort_by WHEN 'newest' THEN ps.created_at ELSE null END DESC NULLS LAST,
    CASE p_sort_by WHEN 'relevance' THEN CASE WHEN p_query IS NOT NULL AND p_query != '' THEN TS_RANK(to_tsvector('simple', coalesce(ps.business_name, '') || ' ' || coalesce(ps.description, '')), plainto_tsquery('simple', p_query)) ELSE 0 END ELSE null END DESC NULLS LAST
  LIMIT p_limit OFFSET p_offset;
END;
$$;

CREATE OR REPLACE FUNCTION get_marketplace_categories(p_marketplace_sector text DEFAULT NULL)
RETURNS TABLE (id uuid, parent_id uuid, name text, description text, slug text, icon text, image_url text, marketplace_sector text, sort_order int, subcategory_count bigint)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
BEGIN
  RETURN QUERY SELECT c.id, c.parent_id, c.name, c.description, c.slug, c.icon, c.image_url, c.marketplace_sector, c.sort_order,
    (SELECT COUNT(*) FROM categories sub WHERE sub.parent_id = c.id AND sub.is_active = true)
  FROM categories c WHERE c.is_active = true AND c.parent_id IS NULL AND (p_marketplace_sector IS NULL OR c.marketplace_sector = p_marketplace_sector) ORDER BY c.sort_order;
END;
$$;

CREATE OR REPLACE FUNCTION get_listing_detail(p_listing_id uuid)
RETURNS TABLE (id uuid, name text, description text, price NUMERIC, currency text, listing_type listing_type, listing_status listing_status, stock_quantity int, low_stock_threshold int, is_available boolean, rating NUMERIC, review_count int, sales_count int, category_id uuid, category_name text, marketplace_sector text, provider_id uuid, provider_name text, store_id uuid, store_business_name text, metadata jsonb, location_lat double precision, location_lng double precision, created_at timestamptz, updated_at timestamptz, images jsonb)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT p.id, p.name, p.description, p.price, p.currency, p.listing_type, p.listing_status, p.stock_quantity, p.low_stock_threshold, p.is_available, p.rating, p.review_count, p.sales_count, p.category_id, c.name AS category_name, c.marketplace_sector,
    p.provider_id, COALESCE(pp.business_name, pr.full_name) AS provider_name, ps.id AS store_id, ps.business_name AS store_business_name, p.metadata,
    CASE WHEN p.location IS NOT NULL THEN ST_Y(p.location::geometry) ELSE null END AS location_lat,
    CASE WHEN p.location IS NOT NULL THEN ST_X(p.location::geometry) ELSE null END AS location_lng,
    p.created_at, p.updated_at,
    (SELECT COALESCE((SELECT jsonb_agg(jsonb_build_object('id', li.id, 'storage_path', li.storage_path, 'alt_text', li.alt_text, 'is_primary', li.is_primary, 'sort_order', li.sort_order) ORDER BY li.sort_order) FROM listing_images li WHERE li.listing_id = p.id),
      (SELECT jsonb_agg(jsonb_build_object('id', pi.id, 'storage_path', pi.storage_path, 'alt_text', null, 'is_primary', (pi.sort_order = 0), 'sort_order', pi.sort_order) ORDER BY pi.sort_order) FROM product_images pi WHERE pi.product_id = p.id), '[]'::jsonb)) AS images
  FROM products p JOIN provider_profiles pp ON pp.id = p.provider_id JOIN profiles pr ON pr.id = pp.user_id
  LEFT JOIN provider_stores ps ON ps.provider_id = p.provider_id AND ps.is_active = true LEFT JOIN categories c ON c.id = p.category_id
  WHERE p.id = p_listing_id AND p.is_active = true AND (p.listing_status = 'ACTIVE' OR pp.user_id = auth.uid() OR is_admin());
END;
$$;

CREATE OR REPLACE FUNCTION get_provider_store_detail(p_store_id uuid DEFAULT null, p_provider_id uuid DEFAULT null)
RETURNS TABLE (id uuid, provider_id uuid, business_name text, description text, category_id uuid, category_name text, marketplace_sector text, address_text text, contact_phone text, contact_email text, website_url text, logo_storage_path text, cover_image_storage_path text, rating NUMERIC, review_count int, listing_count int, metadata jsonb, created_at timestamptz, gallery jsonb)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
BEGIN
  RETURN QUERY
  SELECT ps.id, ps.provider_id, ps.business_name, ps.description, ps.category_id, c.name AS category_name, c.marketplace_sector, ps.address_text, ps.contact_phone, ps.contact_email, ps.website_url, ps.logo_storage_path, ps.cover_image_storage_path, ps.rating, ps.review_count, ps.listing_count, ps.metadata, ps.created_at,
    (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', pg.id, 'storage_path', pg.storage_path, 'caption', pg.caption, 'display_order', pg.display_order) ORDER BY pg.display_order), '[]'::jsonb) FROM provider_gallery pg WHERE pg.provider_id = ps.provider_id AND pg.is_active = true) AS gallery
  FROM provider_stores ps LEFT JOIN categories c ON c.id = ps.category_id
  WHERE ps.is_active = true AND ((p_store_id IS NOT NULL AND ps.id = p_store_id) OR (p_provider_id IS NOT NULL AND ps.provider_id = p_provider_id))
    AND (exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = ps.provider_id AND pp.status = 'APPROVED') OR ps.provider_id IN (SELECT pp2.id FROM provider_profiles pp2 WHERE pp2.user_id = auth.uid()) OR is_admin());
END;
$$;

CREATE OR REPLACE FUNCTION get_categories_with_counts()
RETURNS TABLE (id uuid, parent_id uuid, name text, description text, slug text, icon text, marketplace_sector text, sort_order int, active_listing_count bigint)
LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public AS $$
BEGIN
  RETURN QUERY SELECT c.id, c.parent_id, c.name, c.description, c.slug, c.icon, c.marketplace_sector, c.sort_order, COUNT(p.id) AS active_listing_count
  FROM categories c LEFT JOIN products p ON p.category_id = c.id AND p.is_active = true AND p.listing_status = 'ACTIVE'
  WHERE c.is_active = true GROUP BY c.id, c.parent_id, c.name, c.description, c.slug, c.icon, c.marketplace_sector, c.sort_order ORDER BY c.sort_order;
END;
$$;

-- Auto-profile on auth signup (from0020)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, phone, email, status) VALUES (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', 'New User'), new.phone, new.email, 'PENDING_APPROVAL'::account_status) ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.user_roles (user_id, role) VALUES (new.id, 'USER'::app_role) ON CONFLICT (user_id, role) DO NOTHING;
  RETURN new;
END;
$$;

-- Auto-provider setup (from0021)
CREATE OR REPLACE FUNCTION public.handle_new_provider_profile()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.user_roles (user_id, role) VALUES (new.user_id, new.provider_type::app_role) ON CONFLICT (user_id, role) DO NOTHING;
  INSERT INTO public.approval_requests (subject_type, subject_id, status) VALUES ('PROVIDER', new.id, 'PENDING_APPROVAL'::account_status) ON CONFLICT DO NOTHING;
  RETURN new;
END;
$$;

-- Auto-create approval request on profile insert (from0008)
CREATE OR REPLACE FUNCTION auto_create_user_approval_request()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO approval_requests (subject_type, subject_id, status) VALUES ('USER', NEW.id, 'PENDING_APPROVAL');
  RETURN NEW;
END;
$$;

-- Auto-create driver status (from0010)
CREATE OR REPLACE FUNCTION auto_create_driver_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF new.status = 'APPROVED' AND new.provider_type = 'VEHICLE_PROVIDER' THEN
    INSERT INTO driver_status (provider_id, is_online) VALUES (new.id, false) ON CONFLICT (provider_id) DO NOTHING;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION auto_create_driver_status_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF new.status = 'APPROVED' AND new.provider_type = 'VEHICLE_PROVIDER' THEN
    INSERT INTO driver_status (provider_id, is_online) VALUES (new.id, false) ON CONFLICT (provider_id) DO NOTHING;
  END IF;
  RETURN new;
END;
$$;

-- Security trigger functions (from0008, 0019)
CREATE OR REPLACE FUNCTION prevent_provider_self_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != old.status THEN RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED'; END IF;
    IF new.provider_type != old.provider_type THEN RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED'; END IF;
    IF new.subscription_start_date != old.subscription_start_date THEN RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED'; END IF;
    IF old.owner_national_id IS NOT NULL AND new.owner_national_id != old.owner_national_id THEN RAISE EXCEPTION 'OWNER_NATIONAL_ID_CANNOT_BE_CHANGED_AFTER_REGISTRATION'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_profile_self_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != old.status THEN RAISE EXCEPTION 'PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_notification_injection()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() AND NOT pg_catalog.current_setting('role', true) = 'service_role' THEN
    RAISE EXCEPTION 'NOTIFICATIONS_CANNOT_BE_CREATED_BY_CLIENTS';
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_support_ticket_status_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF TG_OP = 'INSERT' AND new.status != 'OPEN' THEN RAISE EXCEPTION 'NEW_TICKETS_MUST_START_AS_OPEN'; END IF;
    IF TG_OP = 'UPDATE' AND new.status != old.status AND new.status != 'CLOSED' THEN RAISE EXCEPTION 'USERS_CAN_ONLY_CLOSE_THEIR_OWN_TICKETS'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_payment_agreement_unaccept()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF old.accepted = true AND new.accepted = false THEN RAISE EXCEPTION 'ACCEPTED_AGREEMENTS_CANNOT_BE_UNACCEPTED'; END IF;
    IF new.accepted = true AND (old.accepted = false OR old.accepted IS NULL) THEN new.accepted_at := now(); END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_vehicle_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'VEHICLE_MUST_START_AS_PENDING_APPROVAL'; END IF;
    IF new.is_available != false THEN RAISE EXCEPTION 'NEW_VEHICLES_ARE_NOT_AVAILABLE_UNTIL_APPROVED'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_product_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN new.rating := 0; new.review_count := 0; new.sales_count := 0; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_review_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_REVIEW_FOR_ANOTHER_USER'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_order_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != 'CREATED' THEN RAISE EXCEPTION 'ORDERS_MUST_START_AS_CREATED'; END IF;
    IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_ORDER_FOR_ANOTHER_USER'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_ride_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != 'REQUESTED' THEN RAISE EXCEPTION 'RIDE_REQUESTS_MUST_START_AS_REQUESTED'; END IF;
    IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_RIDE_REQUEST_FOR_ANOTHER_USER'; END IF;
    IF new.claimed_by_provider_id IS NOT NULL THEN RAISE EXCEPTION 'CLAIM_FIELDS_CANNOT_BE_SET_ON_INSERT'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_provider_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'PROVIDER_PROFILES_MUST_START_AS_PENDING_APPROVAL'; END IF;
    IF new.user_id != auth.uid() THEN RAISE EXCEPTION 'CANNOT_CREATE_PROVIDER_PROFILE_FOR_ANOTHER_USER'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_profile_insert_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.status != 'PENDING_APPROVAL' THEN RAISE EXCEPTION 'PROFILES_MUST_START_AS_PENDING_APPROVAL'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_vehicle_self_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'VEHICLE_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_payment_proof_self_verification()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.verification_status != old.verification_status THEN RAISE EXCEPTION 'PAYMENT_PROOF_VERIFICATION_IS_ADMIN_ONLY'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_order_self_privilege_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.status != old.status THEN RAISE EXCEPTION 'ORDER_STATUS_CAN_ONLY_BE_CHANGED_VIA_SERVER_FUNCTION'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_subscription_self_modification()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF new.status != old.status THEN RAISE EXCEPTION 'SUBSCRIPTION_STATUS_CANNOT_BE_SELF_MODIFIED'; END IF;
    IF new.next_due_date != old.next_due_date THEN RAISE EXCEPTION 'SUBSCRIPTION_DATES_CANNOT_BE_SELF_MODIFIED'; END IF;
  END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_role_escalation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY'; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_wallet_direct_balance_edit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN IF new.balance != old.balance THEN RAISE EXCEPTION 'WALLET_BALANCE_CAN_ONLY_BE_MODIFIED_BY_SECURE_FUNCTIONS'; END IF; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_system_settings_self_modification()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'SYSTEM_SETTINGS_CAN_ONLY_BE_MODIFIED_BY_ADMINISTRATORS'; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_audit_log_deletion()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'AUDIT_LOGS_CANNOT_BE_DELETED'; RETURN null; END;
$$;

CREATE OR REPLACE FUNCTION prevent_wallet_txn_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF old.status = 'COMPLETED' AND NOT is_admin() THEN RAISE EXCEPTION 'COMPLETED_TRANSACTIONS_CANNOT_BE_MODIFIED'; END IF;
  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_approval_history_mutation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'APPROVAL_HISTORY_IS_IMMUTABLE_AND_CANNOT_BE_MODIFIED'; RETURN null; END;
$$;

CREATE OR REPLACE FUNCTION prevent_inactive_provider_publish()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF NEW.listing_status = 'ACTIVE' AND OLD.listing_status != 'ACTIVE' THEN
      IF NOT exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = NEW.provider_id AND pp.status = 'APPROVED') THEN
        RAISE EXCEPTION 'SUSPENDED_OR_REJECTED_PROVIDERS_CANNOT_PUBLISH_ACTIVE_LISTINGS';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION prevent_inactive_provider_publish_insert()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT is_admin() THEN
    IF NEW.listing_status = 'ACTIVE' THEN
      IF NOT exists (SELECT 1 FROM provider_profiles pp WHERE pp.id = NEW.provider_id AND pp.status = 'APPROVED') THEN
        RAISE EXCEPTION 'SUSPENDED_OR_REJECTED_PROVIDERS_CANNOT_PUBLISH_ACTIVE_LISTINGS';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION update_product_rating()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_target uuid;
BEGIN
  IF tg_op = 'DELETE' THEN IF old.target_type = 'PRODUCT' THEN v_target := old.target_id; END IF;
  ELSE IF new.target_type = 'PRODUCT' THEN v_target := new.target_id; END IF;
    IF tg_op = 'UPDATE' AND old.target_type = 'PRODUCT' AND old.target_id IS DISTINCT FROM new.target_id THEN
      UPDATE products p SET rating = coalesce((SELECT avg(rating) FROM reviews r WHERE r.target_type = 'PRODUCT' AND r.target_id = old.target_id), 0),
        review_count = (SELECT count(*) FROM reviews r WHERE r.target_type = 'PRODUCT' AND r.target_id = old.target_id) WHERE p.id = old.target_id;
    END IF;
  END IF;
  IF v_target IS NOT NULL THEN
    UPDATE products p SET rating = coalesce((SELECT avg(rating) FROM reviews r WHERE r.target_type = 'PRODUCT' AND r.target_id = v_target), 0),
      review_count = (SELECT count(*) FROM reviews r WHERE r.target_type = 'PRODUCT' AND r.target_id = v_target) WHERE p.id = v_target;
  END IF;
  RETURN null;
END;
$$;

CREATE OR REPLACE FUNCTION sync_store_listing_count()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = NEW.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = NEW.provider_id;
    RETURN NEW;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = OLD.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = OLD.provider_id;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION sync_store_listing_count_on_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.listing_status IS DISTINCT FROM OLD.listing_status THEN
    UPDATE provider_stores SET listing_count = (SELECT COUNT(*) FROM products WHERE provider_id = NEW.provider_id AND is_active = true AND listing_status = 'ACTIVE') WHERE provider_id = NEW.provider_id;
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================================
-- TRIGGERS (safe to re-create via DO blocks)
-- ============================================================================

-- updated_at triggers
DO $$ BEGIN CREATE TRIGGER trg_profiles_updated BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_updated BEFORE UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_updated BEFORE UPDATE ON products FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_updated BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_ride_requests_updated BEFORE UPDATE ON ride_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallets_updated BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_subscriptions_updated BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_categories_updated BEFORE UPDATE ON categories FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_stores_updated BEFORE UPDATE ON provider_stores FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_gallery_updated BEFORE UPDATE ON provider_gallery FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_methods_updated BEFORE UPDATE ON payment_methods FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_recharge_requests_updated BEFORE UPDATE ON wallet_recharge_requests FOR EACH ROW EXECUTE FUNCTION set_updated_at(); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- Auth triggers
DO $$ BEGIN CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user(); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- Security triggers
DO $$ BEGIN CREATE TRIGGER trg_notifications_security BEFORE INSERT ON notifications FOR EACH ROW EXECUTE FUNCTION prevent_notification_injection(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_auto_approval_request AFTER INSERT ON profiles FOR EACH ROW EXECUTE FUNCTION auto_create_user_approval_request(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_auto_setup AFTER INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION handle_new_provider_profile(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_support_tickets_security BEFORE INSERT OR UPDATE ON support_tickets FOR EACH ROW EXECUTE FUNCTION prevent_support_ticket_status_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_agreements_security BEFORE UPDATE ON payment_agreements FOR EACH ROW EXECUTE FUNCTION prevent_payment_agreement_unaccept(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_vehicles_insert_security BEFORE INSERT ON vehicles FOR EACH ROW EXECUTE FUNCTION prevent_vehicle_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_insert_security BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION prevent_product_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_reviews_insert_security BEFORE INSERT ON reviews FOR EACH ROW EXECUTE FUNCTION prevent_review_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_insert_security BEFORE INSERT ON orders FOR EACH ROW EXECUTE FUNCTION prevent_order_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_ride_requests_insert_security BEFORE INSERT ON ride_requests FOR EACH ROW EXECUTE FUNCTION prevent_ride_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_insert_security BEFORE INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION prevent_provider_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_insert_security BEFORE INSERT ON profiles FOR EACH ROW EXECUTE FUNCTION prevent_profile_insert_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_security BEFORE UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION prevent_provider_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_profiles_security BEFORE UPDATE ON profiles FOR EACH ROW EXECUTE FUNCTION prevent_profile_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_vehicles_security BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION prevent_vehicle_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_payment_proofs_security BEFORE UPDATE ON payment_proofs FOR EACH ROW EXECUTE FUNCTION prevent_payment_proof_self_verification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_orders_security BEFORE UPDATE ON orders FOR EACH ROW EXECUTE FUNCTION prevent_order_self_privilege_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_subscriptions_security BEFORE UPDATE ON subscriptions FOR EACH ROW EXECUTE FUNCTION prevent_subscription_self_modification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_user_roles_security BEFORE INSERT OR UPDATE OR DELETE ON user_roles FOR EACH ROW EXECUTE FUNCTION prevent_role_escalation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallets_security BEFORE UPDATE ON wallets FOR EACH ROW EXECUTE FUNCTION prevent_wallet_direct_balance_edit(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_system_settings_security BEFORE INSERT OR UPDATE OR DELETE ON system_settings FOR EACH ROW EXECUTE FUNCTION prevent_system_settings_self_modification(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_audit_logs_immutable BEFORE DELETE ON audit_logs FOR EACH ROW EXECUTE FUNCTION prevent_audit_log_deletion(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_wallet_transactions_immutable BEFORE UPDATE ON wallet_transactions FOR EACH ROW EXECUTE FUNCTION prevent_wallet_txn_mutation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_approval_history_immutable BEFORE UPDATE OR DELETE ON approval_history FOR EACH ROW EXECUTE FUNCTION prevent_approval_history_mutation(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_listing_status_security BEFORE UPDATE ON products FOR EACH ROW WHEN (NEW.listing_status IS DISTINCT FROM OLD.listing_status) EXECUTE FUNCTION prevent_inactive_provider_publish(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_listing_status_security_insert BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION prevent_inactive_provider_publish_insert(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_reviews_product_rating AFTER INSERT OR UPDATE OR DELETE ON reviews FOR EACH ROW EXECUTE FUNCTION update_product_rating(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_sync_store_count AFTER INSERT OR DELETE ON products FOR EACH ROW EXECUTE FUNCTION sync_store_listing_count(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_products_sync_store_count_status AFTER UPDATE ON products FOR EACH ROW WHEN (NEW.listing_status IS DISTINCT FROM OLD.listing_status) EXECUTE FUNCTION sync_store_listing_count_on_status(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_driver_status AFTER UPDATE ON provider_profiles FOR EACH ROW EXECUTE FUNCTION auto_create_driver_status(); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TRIGGER trg_provider_profiles_driver_status_insert AFTER INSERT ON provider_profiles FOR EACH ROW EXECUTE FUNCTION auto_create_driver_status_insert(); EXCEPTION WHEN duplicate_object THEN null; END $$;

-- ============================================================================
-- SEED DATA (categories from0004 + 0016)
-- ============================================================================

-- Service categories
INSERT INTO categories (name, sector, slug, sort_order) VALUES
  ('Hotels & Lodging', 'SERVICE', 'hotels-lodging', 1),
  ('Food & Restaurants', 'SERVICE', 'food-restaurants', 2),
  ('Retail', 'SERVICE', 'retail', 3),
  ('Health', 'SERVICE', 'health', 4),
  ('Beauty', 'SERVICE', 'beauty', 5),
  ('Home Services', 'SERVICE', 'home-services', 6),
  ('Education', 'SERVICE', 'education', 7),
  ('Professional Services', 'SERVICE', 'professional-services', 8),
  ('Entertainment', 'SERVICE', 'entertainment', 9),
  ('Fitness', 'SERVICE', 'fitness', 10),
  ('Agriculture', 'SERVICE', 'agriculture', 11),
  ('Real Estate', 'SERVICE', 'real-estate', 12)
ON CONFLICT (slug) DO NOTHING;

-- Service subcategories
INSERT INTO categories (parent_id, name, sector, slug, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, sub.sort_order FROM categories p
JOIN (VALUES
  ('hotels-lodging','Hotels','hotels',1),('hotels-lodging','Guesthouses','guesthouses',2),
  ('hotels-lodging','Lodges','lodges',3),('hotels-lodging','Resorts','resorts',4),('hotels-lodging','Rooms','rooms',5),
  ('food-restaurants','Restaurants','restaurants',1),('food-restaurants','Cafes','cafes',2),
  ('food-restaurants','Fast Food','fast-food',3),('food-restaurants','Bakeries','bakeries',4),
  ('food-restaurants','Traditional Food','traditional-food',5),('food-restaurants','Catering','catering',6),
  ('retail','Grocery','grocery',1),('retail','Clothing','clothing',2),('retail','Electronics','electronics',3),
  ('retail','Phones & Accessories','phones-accessories',4),('retail','Furniture','furniture',5),
  ('retail','Cosmetics','cosmetics',6),('retail','General Shops','general-shops',7),
  ('health','Pharmacies','pharmacies',1),('health','Clinics','clinics',2),('health','Laboratories','laboratories',3),
  ('health','Dental','dental',4),('health','Health Services','health-services',5),
  ('beauty','Barbers','barbers',1),('beauty','Hair Salons','hair-salons',2),
  ('beauty','Beauty Salons','beauty-salons',3),('beauty','Spa','spa',4),
  ('home-services','Plumbing','plumbing',1),('home-services','Electrical','electrical',2),
  ('home-services','Cleaning','cleaning',3),('home-services','Construction','construction',4),
  ('home-services','Repair','repair',5),('home-services','Maintenance','maintenance',6),
  ('education','Schools','schools',1),('education','Training Centers','training-centers',2),
  ('education','Tutors','tutors',3),('education','Courses','courses',4),
  ('professional-services','Accounting','accounting',1),('professional-services','Legal','legal',2),
  ('professional-services','Consulting','consulting',3),('professional-services','Printing','printing',4),
  ('professional-services','Photography','photography',5),
  ('entertainment','Events','events',1),('entertainment','Entertainment Centers','entertainment-centers',2),
  ('entertainment','Recreation','recreation',3),
  ('fitness','Gyms','gyms',1),('fitness','Sports','sports',2),('fitness','Fitness Centers','fitness-centers',3),
  ('agriculture','Agricultural Products','agricultural-products',1),('agriculture','Farm Services','farm-services',2),
  ('agriculture','Equipment','equipment',3),
  ('real-estate','Houses','houses',1),('real-estate','Land','land',2),
  ('real-estate','Rentals','rentals',3),('real-estate','Property Services','property-services',4)
) AS sub(parent_slug, name, slug, sort_order) ON p.slug = sub.parent_slug
ON CONFLICT (slug) DO NOTHING;

-- Vehicle categories
INSERT INTO categories (name, sector, slug, sort_order) VALUES
  ('Ride / Taxi', 'VEHICLE', 'ride-taxi', 1),
  ('Delivery Vehicle', 'VEHICLE', 'delivery-vehicle', 2),
  ('Food Delivery', 'VEHICLE', 'food-delivery', 3),
  ('Motorcycle / Bajaj', 'VEHICLE', 'motorcycle-bajaj', 4),
  ('Car Rental', 'VEHICLE', 'car-rental', 5),
  ('Bus', 'VEHICLE', 'bus', 6),
  ('Minibus', 'VEHICLE', 'minibus', 7),
  ('Truck', 'VEHICLE', 'truck', 8),
  ('Freight / Cargo', 'VEHICLE', 'freight-cargo', 9),
  ('Tour & Travel', 'VEHICLE', 'tour-travel', 10),
  ('Airport Transport', 'VEHICLE', 'airport-transport', 11),
  ('Special Transport', 'VEHICLE', 'special-transport', 12),
  ('Ambulance / Emergency Transport', 'VEHICLE', 'ambulance-emergency', 13)
ON CONFLICT (slug) DO NOTHING;

-- Marketplace sector mappings (from0016)
UPDATE categories SET marketplace_sector = 'ACCOMMODATION' WHERE slug = 'hotels-lodging';
UPDATE categories SET marketplace_sector = 'FOOD' WHERE slug = 'food-restaurants';
UPDATE categories SET marketplace_sector = 'RETAIL' WHERE slug = 'retail';
UPDATE categories SET marketplace_sector = 'SERVICES' WHERE slug IN ('health', 'beauty', 'home-services', 'education', 'professional-services', 'entertainment', 'fitness', 'agriculture', 'real-estate');
UPDATE categories SET marketplace_sector = 'TRANSPORT' WHERE sector = 'VEHICLE';

-- Marketplace subcategories (from0016)
INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'FOOD', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
  ('food-restaurants', 'Food Trucks', 'food-trucks', 'Mobile food vendors and street food', 7),
  ('food-restaurants', 'Juice Bars', 'juice-bars', 'Fresh juices, smoothies, and health drinks', 8),
  ('food-restaurants', 'Coffee Shops', 'coffee-shops', 'Coffee, tea, and beverages', 9)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'RETAIL', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
  ('retail', 'Handmade Crafts', 'handmade-crafts', 'Handmade and artisanal products', 8),
  ('retail', 'Books & Stationery', 'books-stationery', 'Books, notebooks, and office supplies', 9),
  ('retail', 'Sports & Outdoors', 'sports-outdoors', 'Sports equipment and outdoor gear', 10),
  ('retail', 'Baby & Kids', 'baby-kids', 'Baby products, toys, and children items', 11),
  ('retail', 'Automotive Parts', 'automotive-parts', 'Car parts, accessories, and supplies', 12),
  ('retail', 'Garden & Home', 'garden-home', 'Garden tools, decor, and home improvement', 13)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'ACCOMMODATION', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
  ('hotels-lodging', 'Vacation Rentals', 'vacation-rentals', 'Short-term vacation property rentals', 6),
  ('hotels-lodging', 'Hostels', 'hostels', 'Budget-friendly shared accommodation', 7),
  ('hotels-lodging', 'Apartments', 'apartments', 'Serviced apartments and furnished units', 8)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'SERVICE', sub.slug, 'SERVICES', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
  ('home-services', 'Moving & Packing', 'moving-packing', 'Relocation and moving services', 7),
  ('home-services', 'Interior Design', 'interior-design', 'Interior decoration and design services', 8),
  ('professional-services', 'IT Services', 'it-services', 'Computer repair, web design, and IT support', 6),
  ('professional-services', 'Translation', 'translation', 'Translation and interpretation services', 7),
  ('professional-services', 'Delivery Services', 'delivery-services', 'Package delivery and courier services', 8),
  ('health', 'Mental Health', 'mental-health', 'Counseling and mental health services', 6),
  ('beauty', 'Tattoo & Piercing', 'tattoo-piercing', 'Tattoo and body piercing studios', 5),
  ('fitness', 'Yoga & Meditation', 'yoga-meditation', 'Yoga classes and meditation sessions', 4),
  ('entertainment', 'Photography Studios', 'photography-studios', 'Professional photography and videography', 4),
  ('education', 'Online Courses', 'online-courses', 'Digital learning and online education platforms', 5)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

INSERT INTO categories (parent_id, name, sector, slug, marketplace_sector, description, sort_order)
SELECT p.id, sub.name, 'VEHICLE', sub.slug, 'TRANSPORT', sub.description, sub.sort_order FROM categories p
JOIN (VALUES
  ('ride-taxi', 'Bike Taxi', 'bike-taxi', 'Motorcycle and bike taxi services', 14),
  ('ride-taxi', 'Shared Rides', 'shared-rides', 'Carpooling and ride-sharing services', 15),
  ('delivery-vehicle', 'Express Delivery', 'express-delivery', 'Same-day and express package delivery', 14),
  ('car-rental', 'Luxury Car Rental', 'luxury-car-rental', 'Premium and luxury vehicle rental', 15),
  ('freight-cargo', 'Moving Trucks', 'moving-trucks', 'Large vehicle rental for moving and logistics', 16),
  ('tour-travel', 'Safari Tours', 'safari-tours', 'Wildlife safari and nature tour packages', 17)
) AS sub(parent_slug, name, slug, description, sort_order) ON p.slug = sub.parent_slug ON CONFLICT (slug) DO NOTHING;

-- Other top-level category
INSERT INTO categories (name, sector, slug, marketplace_sector, description, sort_order)
VALUES ('Other Services', 'SERVICE', 'other-services', 'OTHER', 'Miscellaneous services not classified elsewhere', 50)
ON CONFLICT (slug) DO NOTHING;

-- Marketplace sectors view
CREATE OR REPLACE VIEW marketplace_sectors AS
SELECT marketplace_sector, COUNT(*) FILTER (WHERE parent_id IS NULL) AS top_category_count, COUNT(*) AS total_category_count
FROM categories WHERE is_active = true AND marketplace_sector IS NOT NULL GROUP BY marketplace_sector ORDER BY marketplace_sector;

-- ============================================================================
-- REVOKE/GRANT (from0011)
-- ============================================================================

REVOKE EXECUTE ON FUNCTION deduct_transaction_fee FROM authenticated;
REVOKE EXECUTE ON FUNCTION deduct_subscription_fee FROM authenticated;
REVOKE EXECUTE ON FUNCTION approve_wallet_recharge FROM authenticated;
REVOKE EXECUTE ON FUNCTION reject_wallet_recharge FROM authenticated;
REVOKE EXECUTE ON FUNCTION admin_cash_recharge FROM authenticated;
REVOKE EXECUTE ON FUNCTION admin_wallet_adjustment FROM authenticated;
REVOKE EXECUTE ON FUNCTION approve_provider FROM authenticated;
REVOKE EXECUTE ON FUNCTION reject_provider FROM authenticated;
REVOKE EXECUTE ON FUNCTION request_correction_provider FROM authenticated;
REVOKE EXECUTE ON FUNCTION suspend_provider FROM authenticated;
REVOKE EXECUTE ON FUNCTION unsuspend_provider FROM authenticated;
REVOKE EXECUTE ON FUNCTION transition_order_status FROM authenticated;
REVOKE EXECUTE ON FUNCTION transition_ride_status FROM authenticated;
REVOKE EXECUTE ON FUNCTION claim_ride FROM authenticated;

GRANT EXECUTE ON FUNCTION find_nearby_drivers TO authenticated;
GRANT EXECUTE ON FUNCTION create_ride_request TO authenticated;
GRANT EXECUTE ON FUNCTION update_driver_location TO authenticated;
GRANT EXECUTE ON FUNCTION set_driver_online TO authenticated;
GRANT EXECUTE ON FUNCTION get_setting_numeric TO authenticated;
GRANT EXECUTE ON FUNCTION get_setting_bool TO authenticated;
GRANT EXECUTE ON FUNCTION has_role TO authenticated;
GRANT EXECUTE ON FUNCTION is_admin TO authenticated;
GRANT EXECUTE ON FUNCTION owns_provider_profile TO authenticated;

-- ============================================================================
-- COMPLETION MARKER
-- ============================================================================
COMMENT ON SCHEMA public IS '5BIRR schema — fully applied via 0022_complete_schema.sql';
