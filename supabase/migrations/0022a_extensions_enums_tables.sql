-- PART 1 of 4: Extensions, Enums, Tables
-- Paste into Supabase SQL Editor and run first.
-- EVERY statement is wrapped so no single error rolls back the batch.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

DO $$ BEGIN CREATE TYPE app_role AS ENUM ('USER','VEHICLE_PROVIDER','SERVICE_PROVIDER','ADMIN'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE account_status AS ENUM ('PENDING_APPROVAL','APPROVED','REJECTED','SUSPENDED','INACTIVE'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE approval_action AS ENUM ('APPROVE','REJECT','REQUEST_CORRECTION','SUSPEND','DELETE'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE ride_status AS ENUM ('REQUESTED','CLAIMED','DRIVER_ARRIVING','STARTED','COMPLETED','CANCELLED'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE order_status AS ENUM ('CREATED','PENDING_PROVIDER','ACCEPTED','PAYMENT_PENDING','PAYMENT_VERIFICATION','APPROVED','STARTED','COMPLETED','CANCELLED','DISPUTED','REFUNDED','REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE wallet_txn_type AS ENUM ('TRANSACTION_FEE','SUBSCRIPTION_FEE','DEPOSIT','WITHDRAWAL','ADJUSTMENT','REFUND'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE wallet_txn_status AS ENUM ('PENDING','COMPLETED','FAILED','REVERSED'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE notification_type AS ENUM ('REGISTRATION_RECEIVED','APPROVAL','REJECTION','CORRECTION_REQUIRED','ADMIN_MESSAGE','ORDER_RECEIVED','ORDER_ACCEPTED','ORDER_REJECTED','RIDE_REQUEST','RIDE_CLAIMED','RIDE_TAKEN','RIDE_STARTED','RIDE_COMPLETED','PAYMENT_REMINDER','PAYMENT_PROOF_REQUIRED','WALLET_LOW','WALLET_EMPTY','SUBSCRIPTION_DUE','PROVIDER_INACTIVE','TRANSACTION_FEE_DEDUCTED','SECURITY'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE listing_type AS ENUM ('PRODUCT','FOOD','SERVICE','ROOM','OTHER'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE listing_status AS ENUM ('ACTIVE','DRAFT','SOLD_OUT','ARCHIVED'); EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN CREATE TYPE recharge_status AS ENUM ('PENDING','APPROVED','REJECTED'); EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN ALTER TYPE wallet_txn_type ADD VALUE IF NOT EXISTS 'RECHARGE' BEFORE 'WITHDRAWAL'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE wallet_txn_type ADD VALUE IF NOT EXISTS 'ADMIN_CASH' BEFORE 'ADJUSTMENT'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'DRIVER_EN_ROUTE' AFTER 'DRIVER_ARRIVING'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'ARRIVED' AFTER 'DRIVER_EN_ROUTE'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'TRIP_STARTED' AFTER 'ARRIVED'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.NewRequest' AFTER 'RIDE_TAKEN'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Claimed' AFTER 'RIDE.NewRequest'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Cancelled' AFTER 'RIDE.Claimed'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.DriverArriving' AFTER 'RIDE.Cancelled'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Arrived' AFTER 'RIDE.DriverArriving'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.TripStarted' AFTER 'RIDE.Arrived'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.TripCompleted' AFTER 'RIDE.TripStarted'; EXCEPTION WHEN duplicate_object THEN null; END $$;
DO $$ BEGIN ALTER TYPE notification_type ADD VALUE IF NOT EXISTS 'RIDE.Rated' AFTER 'RIDE.TripCompleted'; EXCEPTION WHEN duplicate_object THEN null; END $$;

INSERT INTO system_settings (key, value, description) VALUES
('subscription_grace_period_days','3','Days after due date before restriction'),
('low_wallet_threshold','15','Balance below this triggers low-wallet warning'),
('minimum_wallet_balance','0','Floor for wallet balance'),
('allow_negative_wallet','false','Whether wallet can go negative'),
('default_ride_search_radius_km','5','Default radius for nearby ride/provider search'),
('payment_proof_required','true','Whether payment proof is required before protected stage')
ON CONFLICT (key) DO NOTHING;

-- ========== TABLES (dependency order: no FK references a table created later) ==========

CREATE TABLE IF NOT EXISTS user_documents (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, document_type text NOT NULL, storage_path text NOT NULL, uploaded_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_user_documents_user ON user_documents(user_id);

CREATE TABLE IF NOT EXISTS approval_requests (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), subject_type text NOT NULL, subject_id uuid NOT NULL, status account_status NOT NULL DEFAULT 'PENDING_APPROVAL', created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS approval_history (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), approval_request_id uuid REFERENCES approval_requests(id) ON DELETE SET NULL, subject_type text NOT NULL, subject_id uuid NOT NULL, action approval_action NOT NULL, reason text, performed_by uuid REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_approval_history_subject ON approval_history(subject_type, subject_id);

CREATE TABLE IF NOT EXISTS categories (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), parent_id uuid REFERENCES categories(id) ON DELETE CASCADE, name text NOT NULL, sector text NOT NULL CHECK (sector IN ('SERVICE','VEHICLE')), slug text NOT NULL UNIQUE, icon text, is_active boolean NOT NULL DEFAULT true, sort_order int DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), description text, image_url text, marketplace_sector text CHECK (marketplace_sector IN ('FOOD','RETAIL','ACCOMMODATION','SERVICES','TRANSPORT','OTHER')), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_categories_parent ON categories(parent_id);
CREATE INDEX IF NOT EXISTS idx_categories_sector ON categories(sector);
CREATE INDEX IF NOT EXISTS idx_categories_marketplace_sector ON categories(marketplace_sector) WHERE marketplace_sector IS NOT NULL;

-- Now that categories exists, add category_id to provider_profiles
DO $$ BEGIN ALTER TABLE provider_profiles ADD COLUMN IF NOT EXISTS category_id uuid; EXCEPTION WHEN duplicate_column THEN null; END $$;
DO $$ BEGIN ALTER TABLE provider_profiles ADD CONSTRAINT fk_provider_category FOREIGN KEY (category_id) REFERENCES categories(id); EXCEPTION WHEN duplicate_object THEN null; END $$;

CREATE TABLE IF NOT EXISTS vehicles (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE, category_id uuid REFERENCES categories(id), brand text, model text, plate_number text NOT NULL, color text, capacity int, current_location geography(Point,4326), is_available boolean NOT NULL DEFAULT true, status account_status NOT NULL DEFAULT 'PENDING_APPROVAL', rating numeric DEFAULT 0, rating_count int DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (plate_number));
CREATE INDEX IF NOT EXISTS idx_vehicles_provider ON vehicles(provider_id);
CREATE INDEX IF NOT EXISTS idx_vehicles_location ON vehicles USING gist(current_location);
CREATE INDEX IF NOT EXISTS idx_vehicles_available ON vehicles(is_available) WHERE is_available = true;

CREATE TABLE IF NOT EXISTS vehicle_images (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), vehicle_id uuid NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE, storage_path text NOT NULL, sort_order int DEFAULT 0);

CREATE TABLE IF NOT EXISTS products (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE, category_id uuid REFERENCES categories(id), name text NOT NULL, description text, price numeric(12,2) NOT NULL DEFAULT 0, currency text NOT NULL DEFAULT 'ETB', quantity int, is_available boolean NOT NULL DEFAULT true, is_active boolean NOT NULL DEFAULT true, location geography(Point,4326), rating numeric DEFAULT 0, review_count int DEFAULT 0, sales_count int DEFAULT 0, search_vector tsvector GENERATED ALWAYS AS (setweight(to_tsvector('simple', coalesce(name,'')), 'A') || setweight(to_tsvector('simple', coalesce(description,'')), 'B')) STORED, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), listing_type listing_type NOT NULL DEFAULT 'PRODUCT', stock_quantity int, low_stock_threshold int DEFAULT 5, listing_status listing_status NOT NULL DEFAULT 'ACTIVE', metadata jsonb);
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

CREATE TABLE IF NOT EXISTS product_images (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE, storage_path text NOT NULL, sort_order int DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_product_images_product ON product_images(product_id);

CREATE TABLE IF NOT EXISTS orders (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id), provider_id uuid NOT NULL REFERENCES provider_profiles(id), status order_status NOT NULL DEFAULT 'CREATED', total_amount numeric(12,2) NOT NULL DEFAULT 0, currency text NOT NULL DEFAULT 'ETB', requires_payment_proof boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_orders_user ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_provider ON orders(provider_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

CREATE TABLE IF NOT EXISTS order_items (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE, product_id uuid REFERENCES products(id), quantity int NOT NULL DEFAULT 1, unit_price numeric(12,2) NOT NULL, subtotal numeric(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);

CREATE TABLE IF NOT EXISTS order_status_history (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE, from_status order_status, to_status order_status NOT NULL, changed_by uuid REFERENCES auth.users(id), note text, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_order_status_history_order ON order_status_history(order_id);

CREATE TABLE IF NOT EXISTS payment_agreements (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE, user_id uuid NOT NULL REFERENCES auth.users(id), accepted boolean NOT NULL DEFAULT false, accepted_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (order_id));

CREATE TABLE IF NOT EXISTS payment_proofs (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE, transaction_id uuid, storage_path text NOT NULL, verification_status text NOT NULL DEFAULT 'PENDING' CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED')), verified_by uuid REFERENCES auth.users(id), verified_at timestamptz, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_payment_proofs_order ON payment_proofs(order_id);

CREATE TABLE IF NOT EXISTS ride_requests (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id), pickup_location geography(Point,4326) NOT NULL, destination_location geography(Point,4326) NOT NULL, pickup_text text, destination_text text, vehicle_category_id uuid REFERENCES categories(id), status ride_status NOT NULL DEFAULT 'REQUESTED', claimed_by_provider_id uuid REFERENCES provider_profiles(id), claimed_vehicle_id uuid REFERENCES vehicles(id), claimed_at timestamptz, fare_estimate numeric(12,2), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_ride_requests_status ON ride_requests(status);
CREATE INDEX IF NOT EXISTS idx_ride_requests_pickup ON ride_requests USING gist(pickup_location);
CREATE INDEX IF NOT EXISTS idx_ride_requests_provider ON ride_requests(claimed_by_provider_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ride_single_claim ON ride_requests(id) WHERE status = 'CLAIMED';
CREATE INDEX IF NOT EXISTS idx_ride_requests_user_status ON ride_requests(user_id, status);
CREATE INDEX IF NOT EXISTS idx_ride_requests_provider_status ON ride_requests(claimed_by_provider_id, status);

CREATE TABLE IF NOT EXISTS ride_status_history (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), ride_request_id uuid NOT NULL REFERENCES ride_requests(id) ON DELETE CASCADE, from_status ride_status, to_status ride_status NOT NULL, changed_by uuid REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS wallets (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE, balance numeric(12,2) NOT NULL DEFAULT 0, status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','RESTRICTED')), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS wallet_transactions (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE CASCADE, provider_id uuid NOT NULL REFERENCES provider_profiles(id), order_id uuid REFERENCES orders(id), ride_request_id uuid REFERENCES ride_requests(id), transaction_type wallet_txn_type NOT NULL, gross_amount numeric(12,2) NOT NULL DEFAULT 0, platform_fee numeric(12,2) NOT NULL DEFAULT 0, net_amount numeric(12,2) NOT NULL DEFAULT 0, balance_after numeric(12,2) NOT NULL, status wallet_txn_status NOT NULL DEFAULT 'COMPLETED', idempotency_key text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_wallet_txn_wallet ON wallet_transactions(wallet_id);
CREATE INDEX IF NOT EXISTS idx_wallet_txn_provider ON wallet_transactions(provider_id);

CREATE TABLE IF NOT EXISTS subscriptions (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE, status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','DUE','GRACE','SUSPENDED')), next_due_date timestamptz NOT NULL, last_charged_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS reviews (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id), target_type text NOT NULL CHECK (target_type IN ('PRODUCT','PROVIDER','VEHICLE')), target_id uuid NOT NULL, order_id uuid REFERENCES orders(id), rating int NOT NULL CHECK (rating BETWEEN 1 AND 5), comment text, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (user_id, target_type, target_id, order_id));
CREATE INDEX IF NOT EXISTS idx_reviews_target ON reviews(target_type, target_id);

CREATE TABLE IF NOT EXISTS favorites (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, target_type text NOT NULL CHECK (target_type IN ('PRODUCT','PROVIDER','VEHICLE')), target_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (user_id, target_type, target_id));

CREATE TABLE IF NOT EXISTS notifications (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, type notification_type NOT NULL, title text NOT NULL, body text, data jsonb, is_read boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, is_read);

CREATE TABLE IF NOT EXISTS notification_preferences (user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, push_enabled boolean NOT NULL DEFAULT true, in_app_enabled boolean NOT NULL DEFAULT true);

CREATE TABLE IF NOT EXISTS admin_actions (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), admin_id uuid NOT NULL REFERENCES auth.users(id), action text NOT NULL, target_type text, target_id uuid, details jsonb, created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS support_tickets (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id), subject text NOT NULL, status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','IN_PROGRESS','RESOLVED','CLOSED')), created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS appeals (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id), related_type text NOT NULL, related_id uuid NOT NULL, reason text NOT NULL, status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','DENIED')), reviewed_by uuid REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now());

CREATE TABLE IF NOT EXISTS audit_logs (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), actor_id uuid REFERENCES auth.users(id), event_type text NOT NULL, entity_type text, entity_id uuid, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_audit_logs_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_actor ON audit_logs(actor_id);

CREATE TABLE IF NOT EXISTS cart_items (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, product_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE, quantity int NOT NULL CHECK (quantity > 0), added_at timestamptz NOT NULL DEFAULT now(), UNIQUE (user_id, product_id));

CREATE TABLE IF NOT EXISTS fcm_tokens (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE, token text NOT NULL, device_type text NOT NULL DEFAULT 'android' CHECK (device_type IN ('android','ios','web')), is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE (user_id, token));
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_user ON fcm_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_fcm_tokens_active ON fcm_tokens(is_active) WHERE is_active = true;

CREATE TABLE IF NOT EXISTS n8n_events (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), event_type text NOT NULL, entity_type text NOT NULL, entity_id uuid, payload jsonb, status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','SENT','FAILED','RETRYING')), attempts int NOT NULL DEFAULT 0, last_error text, created_at timestamptz NOT NULL DEFAULT now(), processed_at timestamptz);
CREATE INDEX IF NOT EXISTS idx_n8n_events_status ON n8n_events(status);
CREATE INDEX IF NOT EXISTS idx_n8n_events_type ON n8n_events(event_type, entity_type);
CREATE INDEX IF NOT EXISTS idx_n8n_events_entity ON n8n_events(entity_type, entity_id);

CREATE TABLE IF NOT EXISTS payment_methods (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), name text NOT NULL, account_name text, account_number text, instructions text, logo_storage_path text, is_active boolean NOT NULL DEFAULT true, sort_order int NOT NULL DEFAULT 0, created_by uuid REFERENCES auth.users(id), created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_payment_methods_active ON payment_methods(is_active) WHERE is_active = true;

CREATE TABLE IF NOT EXISTS wallet_recharge_requests (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE, wallet_id uuid NOT NULL REFERENCES wallets(id) ON DELETE CASCADE, payment_method_id uuid REFERENCES payment_methods(id), amount numeric(12,2) NOT NULL CHECK (amount > 0), currency text NOT NULL DEFAULT 'ETB', payment_reference text, screenshot_storage_path text, status recharge_status NOT NULL DEFAULT 'PENDING', rejection_reason text, approved_by uuid REFERENCES auth.users(id), approved_at timestamptz, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_recharge_requests_provider ON wallet_recharge_requests(provider_id);
CREATE INDEX IF NOT EXISTS idx_recharge_requests_status ON wallet_recharge_requests(status);
CREATE INDEX IF NOT EXISTS idx_recharge_requests_wallet ON wallet_recharge_requests(wallet_id);

CREATE TABLE IF NOT EXISTS admin_wallet_actions (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), admin_id uuid NOT NULL REFERENCES auth.users(id), provider_id uuid NOT NULL REFERENCES provider_profiles(id), wallet_id uuid NOT NULL REFERENCES wallets(id), action_type text NOT NULL CHECK (action_type IN ('CASH_RECHARGE','ADJUSTMENT_CREDIT','ADJUSTMENT_DEBIT')), amount numeric(12,2) NOT NULL CHECK (amount > 0), reason text NOT NULL, balance_before numeric(12,2) NOT NULL, balance_after numeric(12,2) NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_admin_wallet_actions_admin ON admin_wallet_actions(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_wallet_actions_provider ON admin_wallet_actions(provider_id);

CREATE TABLE IF NOT EXISTS driver_status (provider_id uuid PRIMARY KEY REFERENCES provider_profiles(id) ON DELETE CASCADE, is_online boolean NOT NULL DEFAULT false, current_location geography(Point,4326), last_location_update timestamptz, current_ride_id uuid REFERENCES ride_requests(id), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_driver_status_online ON driver_status(is_online) WHERE is_online = true;
CREATE INDEX IF NOT EXISTS idx_driver_status_location ON driver_status USING gist(current_location);
CREATE INDEX IF NOT EXISTS idx_driver_status_provider ON driver_status(provider_id);

CREATE TABLE IF NOT EXISTS ride_ratings (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), ride_request_id uuid NOT NULL REFERENCES ride_requests(id) ON DELETE CASCADE, rater_id uuid NOT NULL REFERENCES auth.users(id), ratee_provider_id uuid REFERENCES provider_profiles(id), rating int NOT NULL CHECK (rating BETWEEN 1 AND 5), comment text, created_at timestamptz NOT NULL DEFAULT now(), UNIQUE (ride_request_id, rater_id));
CREATE INDEX IF NOT EXISTS idx_ride_ratings_ride ON ride_ratings(ride_request_id);
CREATE INDEX IF NOT EXISTS idx_ride_ratings_provider ON ride_ratings(ratee_provider_id);

CREATE TABLE IF NOT EXISTS provider_stores (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL UNIQUE REFERENCES provider_profiles(id) ON DELETE CASCADE, business_name text NOT NULL, description text, category_id uuid REFERENCES categories(id), location geography(Point,4326), address_text text, contact_phone text, contact_email text, website_url text, logo_storage_path text, cover_image_storage_path text, rating numeric(3,2) NOT NULL DEFAULT 0 CHECK (rating >= 0 AND rating <= 5), review_count int NOT NULL DEFAULT 0, listing_count int NOT NULL DEFAULT 0, is_active boolean NOT NULL DEFAULT true, metadata jsonb, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_provider_stores_provider ON provider_stores(provider_id);
CREATE INDEX IF NOT EXISTS idx_provider_stores_category ON provider_stores(category_id);
CREATE INDEX IF NOT EXISTS idx_provider_stores_active ON provider_stores(is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_provider_stores_location ON provider_stores USING gist(location);
CREATE INDEX IF NOT EXISTS idx_provider_stores_rating ON provider_stores(rating DESC);
CREATE INDEX IF NOT EXISTS idx_provider_stores_sector_active ON provider_stores(is_active) WHERE is_active = true;

CREATE TABLE IF NOT EXISTS listing_images (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), listing_id uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE, storage_path text NOT NULL, alt_text text, is_primary boolean NOT NULL DEFAULT false, sort_order int NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_listing_images_listing ON listing_images(listing_id);
CREATE INDEX IF NOT EXISTS idx_listing_images_primary ON listing_images(listing_id) WHERE is_primary = true;
CREATE INDEX IF NOT EXISTS idx_listing_images_sort ON listing_images(listing_id, sort_order);

CREATE TABLE IF NOT EXISTS provider_gallery (id uuid PRIMARY KEY DEFAULT uuid_generate_v4(), provider_id uuid NOT NULL REFERENCES provider_profiles(id) ON DELETE CASCADE, storage_path text NOT NULL, caption text, display_order int NOT NULL DEFAULT 0, is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS idx_provider_gallery_provider ON provider_gallery(provider_id);
CREATE INDEX IF NOT EXISTS idx_provider_gallery_active ON provider_gallery(provider_id, is_active) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_provider_gallery_order ON provider_gallery(provider_id, display_order);

-- Additional indexes on pre-existing tables
CREATE INDEX IF NOT EXISTS idx_provider_profiles_business_name_trgm ON provider_profiles USING gin(business_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_provider_profiles_business_name ON provider_profiles(business_name);

-- ========== ENABLE RLS (wrapped in DO blocks for safety) ==========
DO $$ BEGIN ALTER TABLE profiles ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE user_documents ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE provider_profiles ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE approval_requests ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE approval_history ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE categories ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE vehicle_images ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE products ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE product_images ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE orders ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE order_items ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE order_status_history ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE payment_agreements ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE payment_proofs ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE ride_requests ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE ride_status_history ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE wallets ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE reviews ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE favorites ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE notifications ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE notification_preferences ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE admin_actions ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE support_tickets ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE appeals ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE system_settings ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE cart_items ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE fcm_tokens ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE n8n_events ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE wallet_recharge_requests ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE admin_wallet_actions ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE driver_status ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE ride_ratings ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE provider_stores ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE listing_images ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
DO $$ BEGIN ALTER TABLE provider_gallery ENABLE ROW LEVEL SECURITY; EXCEPTION WHEN undefined_table THEN null; END $$;
