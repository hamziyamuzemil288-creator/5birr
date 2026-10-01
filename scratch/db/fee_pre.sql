-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Minimal stand-in schema so the per-category fee WRITE path can be executed
-- for real. postgis and uuid-ossp are unavailable in this sandbox, so geometry
-- and uuid defaults are replaced by plain types. Everything the save function
-- touches is present; everything it does not touch is omitted on purpose.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- `auth.uid()` is parsed when is_ceo() is created, so the schema and the table
-- it reads have to exist first. Ordering, not content, is what is at issue.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS 'SELECT NULL::uuid';
CREATE TABLE auth.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb DEFAULT '{}'::jsonb
);

-- uuid-ossp is not installed here; the migrations default their primary keys
-- with uuid_generate_v4(), so the same value is produced under a local name.
CREATE FUNCTION public.uuid_generate_v4() RETURNS uuid
  LANGUAGE sql VOLATILE AS 'SELECT gen_random_uuid()';

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY,
  full_name text,
  city text,
  phone text,
  status text DEFAULT 'ACTIVE'
);

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  sector text NOT NULL DEFAULT 'OTHER',
  is_active boolean NOT NULL DEFAULT true,
  -- added by 20260922000012; 0107 reads its legacy price keys
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  city text
);

CREATE TABLE public.system_settings (
  key text PRIMARY KEY,
  value jsonb NOT NULL DEFAULT '{}'::jsonb,
  description text,
  updated_at timestamptz DEFAULT now(),
  updated_by uuid
);

-- The two tables is_ceo() reads, copied from 20260923000003 so the fixture
-- resolves the SAME authority question the live database does.
CREATE TABLE public.staff (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  is_ceo boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.user_roles (
  user_id uuid NOT NULL,
  role text NOT NULL,
  PRIMARY KEY (user_id, role)
);

-- Verbatim from 20260923000003_true_admin_as_ceo.sql, because the whole
-- question under test is "who is allowed to set a price".
CREATE FUNCTION public.is_ceo(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id AND is_ceo AND is_active
  )
  OR (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = p_user_id AND role = 'ADMIN'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.staff WHERE user_id = p_user_id
    )
  );
$$;

CREATE FUNCTION public.is_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT public.is_ceo(); $$;

-- Composite return types 0062 declares on unrelated functions. PostgreSQL
-- resolves a `RETURNS public.x` at CREATE time even though the body that uses
-- it is never called here, so the names have to exist. Empty on purpose.
CREATE TABLE public.ride_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid, city text
);
CREATE TABLE public.wallet_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE TABLE public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid, type text, title text, body text, is_read boolean DEFAULT false
);
CREATE TABLE public.wallets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  balance numeric(12,2) NOT NULL DEFAULT 0
);
CREATE TABLE public.provider_profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid,
  business_name text NOT NULL DEFAULT '',
  category_id uuid,
  city text,
  status text DEFAULT 'PENDING'
);

-- Verbatim from 20260927000055, which is what the provider-side functions
-- gate on: "is this provider profile mine", NOT "is it approved".
CREATE FUNCTION public.owns_provider_profile(p_provider_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.provider_profiles pp
     WHERE pp.id = p_provider_id AND pp.user_id = auth.uid());
$$;


-- Verbatim from 0003_functions.sql. The fee resolvers fall back to these when
-- a category has no override, so the fallback chain is part of the test.
CREATE FUNCTION public.get_setting_numeric(p_key text)
RETURNS numeric LANGUAGE sql STABLE
AS $$ SELECT (value #>> '{}')::numeric FROM public.system_settings WHERE key = p_key; $$;

CREATE FUNCTION public.get_setting_bool(p_key text)
RETURNS boolean LANGUAGE sql STABLE
AS $$ SELECT (value #>> '{}')::boolean FROM public.system_settings WHERE key = p_key; $$;

CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  event_type text NOT NULL,
  entity_type text,
  entity_id uuid,
  metadata jsonb DEFAULT '{}'::jsonb,
  created_at timestamptz DEFAULT now()
);

-- 0062 drops and recreates this trigger; the name has to exist first or the
-- DROP TRIGGER fails on a fixture that never had it.
CREATE FUNCTION public.system_settings_security() RETURNS trigger
  LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END; $$;
CREATE TRIGGER trg_system_settings_security BEFORE UPDATE ON public.system_settings
  FOR EACH ROW EXECUTE FUNCTION public.system_settings_security();

-- ── What 0126 needs beyond the fee path ─────────────────────────────────
-- moderation_actions, the three image tables the gallery unions over, and
-- notify_user(). notify_user is STUBBED, not copied: the probe only needs the
-- signature to resolve and an id back, and copying the real body would drag in
-- notification_outbox, pg_cron and the drain trigger for no additional
-- coverage. Everything else is the real shape.
CREATE TABLE public.moderation_actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action_type text NOT NULL,
  severity text NOT NULL DEFAULT 'MODERATE',
  reason text NOT NULL,
  target_user_id uuid,
  target_provider_id uuid,
  object_bucket text,
  object_path text,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  actioned_by uuid,
  actioned_by_name text NOT NULL DEFAULT '',
  report_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.provider_gallery (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL,
  storage_path text NOT NULL,
  caption text,
  display_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL,
  category_id uuid,
  name text NOT NULL,
  listing_status text NOT NULL DEFAULT 'ACTIVE',
  city text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL,
  storage_path text NOT NULL,
  sort_order integer DEFAULT 0
);

CREATE TABLE public.vehicles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_id uuid NOT NULL,
  city text,
  is_active boolean,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.vehicle_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vehicle_id uuid NOT NULL,
  storage_path text NOT NULL
);

-- STUB, same signature and same return type. See the note above.
CREATE FUNCTION public.notify_user(
  p_user_id uuid, p_type text, p_title text, p_body text, p_data jsonb DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $$
  SELECT CASE WHEN p_user_id IS NULL THEN NULL ELSE gen_random_uuid() END;
$$;

INSERT INTO public.categories (name, sector) VALUES
  ('Bajaj', 'RIDE'),
  ('Truck', 'RIDE'),
  ('Beauty Salon', 'SERVICE'),
  ('Laptop Sale', 'PRODUCT');