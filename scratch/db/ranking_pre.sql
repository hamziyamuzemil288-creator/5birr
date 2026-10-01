-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Minimal stand-in schema so 0128's ranking lists, the per-category field
-- catalogue and the provider save path can be EXECUTED for real. postgis and
-- uuid-ossp are unavailable in this sandbox, so the primary-key default is
-- aliased to gen_random_uuid(). Everything the migration reads or writes is
-- present; everything it does not touch is omitted on purpose.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS auth;
-- Settable, unlike the fee fixture's always-NULL uid: the whole point of the
-- save-path tests is to become a real provider and write as them.
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE
  AS 'SELECT NULLIF(current_setting(''test.uid'', true), '''')::uuid';

CREATE FUNCTION public.uuid_generate_v4() RETURNS uuid
  LANGUAGE sql VOLATILE AS 'SELECT gen_random_uuid()';

-- is_admin() reads a setting too, so the admin-gated RPCs can be driven.
CREATE FUNCTION public.is_admin() RETURNS boolean LANGUAGE sql STABLE
  AS 'SELECT COALESCE(current_setting(''test.admin'', true), ''false'') = ''true''';

CREATE TYPE public.app_role AS ENUM
  ('USER', 'ADMIN', 'SERVICE_PROVIDER', 'VEHICLE_PROVIDER');
CREATE TYPE public.account_status AS ENUM
  ('PENDING_APPROVAL', 'APPROVED', 'SUSPENDED', 'REJECTED');
CREATE TYPE public.order_status AS ENUM
  ('CREATED', 'ACCEPTED', 'COMPLETED', 'CANCELLED');
CREATE TYPE public.ride_status AS ENUM
  ('REQUESTED', 'CLAIMED', 'STARTED', 'COMPLETED', 'CANCELLED');

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id uuid REFERENCES public.categories(id),
  name text NOT NULL,
  sector text NOT NULL DEFAULT 'SERVICE',
  slug text NOT NULL,
  marketplace_sector text,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0
);

CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  business_name text NOT NULL DEFAULT '',
  provider_type public.app_role,
  status public.account_status NOT NULL DEFAULT 'PENDING_APPROVAL',
  category_id uuid REFERENCES public.categories(id),
  price_range text,
  photo_storage_path text,
  city text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id),
  status public.order_status NOT NULL DEFAULT 'CREATED',
  total_amount numeric(12,2) NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.ride_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  status public.ride_status NOT NULL DEFAULT 'REQUESTED',
  claimed_by_provider_id uuid REFERENCES public.provider_profiles(id),
  fare_estimate numeric(12,2),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL REFERENCES public.provider_profiles(id),
  category_id uuid REFERENCES public.categories(id),
  name text NOT NULL DEFAULT '',
  is_active boolean NOT NULL DEFAULT true,
  sales_count integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ── the data the ordering is judged on ─────────────────────────────────────
-- Three trades with different work volumes, so "most transacted first" is a
-- claim the probe can falsify rather than restate.
INSERT INTO public.categories (id, parent_id, name, sector, slug, marketplace_sector) VALUES
  ('00000000-0000-4000-8000-00000000c001', NULL, 'Hotels & Lodging', 'SERVICE', 'hotels-lodging', 'ACCOMMODATION'),
  ('00000000-0000-4000-8000-00000000c002', '00000000-0000-4000-8000-00000000c001', 'Hostels', 'SERVICE', 'hostels', 'ACCOMMODATION'),
  ('00000000-0000-4000-8000-00000000c003', NULL, 'Health', 'SERVICE', 'health', 'SERVICES'),
  ('00000000-0000-4000-8000-00000000c004', NULL, 'Ride & Taxi', 'VEHICLE', 'ride-taxi', 'TRANSPORT'),
  ('00000000-0000-4000-8000-00000000c005', NULL, 'Retired Trade', 'SERVICE', 'retired-trade', 'RETAIL');

UPDATE public.categories SET is_active = false
 WHERE id = '00000000-0000-4000-8000-00000000c005';

INSERT INTO public.provider_profiles
  (id, user_id, business_name, provider_type, status, category_id, city, created_at) VALUES
  -- Busiest: 3 completed orders only.
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000e1',
   'Busy Diner', 'SERVICE_PROVIDER', 'APPROVED',
   '00000000-0000-4000-8000-00000000c003', 'Addis Ababa', '2026-01-01'),
  -- Second: 2 completed orders + 1 completed ride.
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-0000000000e2',
   'Steady Fleet', 'VEHICLE_PROVIDER', 'APPROVED',
   '00000000-0000-4000-8000-00000000c004', 'Addis Ababa', '2026-01-02'),
  -- Third: nothing completed at all, but it signed up most recently. Under the
  -- OLD ordering (created_at DESC) this one was first; under the new one it is
  -- last, and that inversion is the whole point of the migration.
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000e3',
   'Brand New Inn', 'SERVICE_PROVIDER', 'APPROVED',
   '00000000-0000-4000-8000-00000000c002', 'Addis Ababa', '2026-06-01'),
  -- Not approved: must not appear in ANY ranking.
  ('00000000-0000-4000-8000-0000000000a4', '00000000-0000-4000-8000-0000000000e4',
   'Pending Place', 'SERVICE_PROVIDER', 'PENDING_APPROVAL',
   '00000000-0000-4000-8000-00000000c003', 'Addis Ababa', '2026-05-01');

INSERT INTO public.orders (provider_id, status, total_amount) VALUES
  ('00000000-0000-4000-8000-0000000000a1', 'COMPLETED', 100),
  ('00000000-0000-4000-8000-0000000000a1', 'COMPLETED', 200),
  ('00000000-0000-4000-8000-0000000000a1', 'COMPLETED', 300),
  ('00000000-0000-4000-8000-0000000000a1', 'CANCELLED', 999),
  ('00000000-0000-4000-8000-0000000000a2', 'COMPLETED', 150),
  ('00000000-0000-4000-8000-0000000000a2', 'COMPLETED', 150),
  ('00000000-0000-4000-8000-0000000000a3', 'CANCELLED', 50),
  ('00000000-0000-4000-8000-0000000000a4', 'COMPLETED', 800);

INSERT INTO public.ride_requests (status, claimed_by_provider_id, fare_estimate) VALUES
  ('COMPLETED', '00000000-0000-4000-8000-0000000000a2', 400),
  ('CANCELLED', '00000000-0000-4000-8000-0000000000a2', 700),
  ('COMPLETED', '00000000-0000-4000-8000-0000000000a3', 900);

-- A product sale is a category's other half. 25 sales under Health is what
-- should carry Health above Transport even though Transport has more
-- completed rides.
INSERT INTO public.products (provider_id, category_id, name, sales_count) VALUES
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-00000000c003', 'Checkup', 25),
  ('00000000-0000-4000-8000-0000000000a2', '00000000-0000-4000-8000-00000000c004', 'Airport run', 4),
  ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-00000000c002', 'Bunk bed', 1);
