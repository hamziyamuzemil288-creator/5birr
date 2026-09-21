-- ============================================================
-- Migration 20260922000000_multi_city_support.sql
-- Phase 1: multi-city support
-- ============================================================
-- STRICTLY ADDITIVE:
--   - New nullable `city text` column on profiles (user's saved city),
--     products / provider_profiles / vehicles (listings), categories
--     (catalog scoping), orders / ride_requests (transaction scoping).
--   - No existing column is modified or dropped. No existing row changes
--     except the backfill below (setting the new column's default).
--   - Existing clients that SELECT * keep working; inserts without city
--     keep working (column is nullable).
--
-- BACKFILL: every existing row gets 'Addis Ababa' so pre-migration data
-- remains visible under the app's default city.
--
-- HELPER: current_city() resolves the signed-in user's saved city with a
-- safe fallback, for use in RLS-safe view filters and app queries.
-- ============================================================

-- 1. Columns (idempotent; DO block avoids error spam on re-run)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'profiles'       AND column_name = 'city') THEN
    ALTER TABLE public.profiles       ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'products'       AND column_name = 'city') THEN
    ALTER TABLE public.products       ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'provider_profiles' AND column_name = 'city') THEN
    ALTER TABLE public.provider_profiles ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'vehicles'       AND column_name = 'city') THEN
    ALTER TABLE public.vehicles       ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'categories'     AND column_name = 'city') THEN
    ALTER TABLE public.categories     ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'orders'         AND column_name = 'city') THEN
    ALTER TABLE public.orders         ADD COLUMN city text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'ride_requests'  AND column_name = 'city') THEN
    ALTER TABLE public.ride_requests  ADD COLUMN city text;
  END IF;
END $$;

-- 2. Backfill (idempotent: touches only rows where city is still null)
UPDATE public.profiles        SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.products        SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.provider_profiles SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.vehicles        SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.categories      SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.orders          SET city = 'Addis Ababa' WHERE city IS NULL;
UPDATE public.ride_requests   SET city = 'Addis Ababa' WHERE city IS NULL;

-- 3. Default city constant + current-city helper ( SECURITY DEFINER so
--    RLS policies / views can call it without reading profiles directly).
CREATE OR REPLACE FUNCTION public.default_city()
RETURNS text
LANGUAGE sql
STABLE
AS $$ SELECT 'Addis Ababa'::text $$;

CREATE OR REPLACE FUNCTION public.current_city()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid;
  v_city text;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RETURN public.default_city();
  END IF;
  SELECT city INTO v_city FROM public.profiles WHERE id = v_uid;
  RETURN COALESCE(v_city, public.default_city());
EXCEPTION WHEN OTHERS THEN
  RETURN public.default_city();
END;
$$;

-- ============================================================
-- 4. handle_new_user() — restated to accept the signup city from
--    metadata. Logic is otherwise byte-for-byte the contract from
--    0025 (profile + USER role + approval request + provider row).
--    The app sends 'city' in signUp(data: ...) metadata; users who
--    signed up before this change are unaffected (backfill above).
-- ============================================================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- 1. Create the profile with the complete signup data (skip if the row
  --    already exists). status is always PENDING_APPROVAL.
  INSERT INTO public.profiles (id, full_name, phone, email, national_id, status, city)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data ->> 'full_name', 'New User'),
    COALESCE(new.phone, new.raw_user_meta_data ->> 'phone'),
    new.email,
    new.raw_user_meta_data ->> 'national_id',
    'PENDING_APPROVAL'::account_status,
    COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city())
  )
  ON CONFLICT (id) DO NOTHING;

  -- 2. Assign the USER role (skip if already present).
  INSERT INTO public.user_roles (user_id, role)
  VALUES (new.id, 'USER'::app_role)
  ON CONFLICT (user_id, role) DO NOTHING;

  -- 3. Create an approval request so admins can review this user.
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  SELECT 'USER', new.id, 'PENDING_APPROVAL'::account_status
  WHERE NOT EXISTS (
    SELECT 1 FROM public.approval_requests
    WHERE subject_type = 'USER' AND subject_id = new.id
  );

  -- 4. Provider signups: create the provider profile from metadata.
  --    trg_provider_profiles_auto_setup then assigns the provider role and
  --    opens the provider approval request, exactly as a client-side
  --    insert would have.
  IF COALESCE(new.raw_user_meta_data ->> 'provider_type', '') <> '' THEN
    INSERT INTO public.provider_profiles
      (user_id, provider_type, business_name, owner_national_id, status, city)
    SELECT
      new.id,
      (new.raw_user_meta_data ->> 'provider_type')::app_role,
      COALESCE(
        new.raw_user_meta_data ->> 'business_name',
        new.raw_user_meta_data ->> 'full_name',
        'New Provider'
      ),
      new.raw_user_meta_data ->> 'national_id',
      'PENDING_APPROVAL'::account_status,
      COALESCE(NULLIF(new.raw_user_meta_data ->> 'city', ''), public.default_city())
    WHERE NOT EXISTS (
      SELECT 1 FROM public.provider_profiles WHERE user_id = new.id
    );
  END IF;

  RETURN new;
END;
$$;

-- ============================================================
-- 5. Category helper: categories visible for a given city. Global
--    categories (city IS NULL after future inserts) are always shown,
--    so a city filter can never empty the catalog.
--    One shared query (Phase 4.6): p_category_id NULL = all.
-- ============================================================
CREATE OR REPLACE FUNCTION public.visible_categories_for_city(
  p_city text,
  p_category_id uuid DEFAULT NULL
)
RETURNS SETOF public.categories
LANGUAGE sql
STABLE
AS $$
  SELECT c.*
  FROM public.categories c
  WHERE c.is_active
    AND (c.city IS NULL OR c.city = p_city)
    AND (p_category_id IS NULL OR c.id = p_category_id OR c.parent_id = p_category_id)
  ORDER BY c.sort_order, c.name;
$$;

-- ============================================================
-- 6. Grant execute on the new helpers to authenticated clients.
-- ============================================================
GRANT EXECUTE ON FUNCTION public.current_city() TO authenticated;
GRANT EXECUTE ON FUNCTION public.default_city() TO authenticated;
GRANT EXECUTE ON FUNCTION public.visible_categories_for_city(text, uuid) TO authenticated;
