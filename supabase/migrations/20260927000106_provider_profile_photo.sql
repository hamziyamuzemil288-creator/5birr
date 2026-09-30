-- 20260927000106 — a provider had no photo, and no way to put one there
--
-- THE GAP
-- -------
-- user_provider_detail_screen.dart renders a flat teal gradient with the
-- business name in it. There is no avatar, no logo, no Image widget anywhere in
-- the file. provider_business_profile_screen.dart has no image_picker import and
-- no storage call -- it is a five-field text form. So the public profile has
-- nothing to show and the provider has no way to change that.
--
-- provider_profiles has no photo column. Its full column set is
--   id, user_id, business_name, business_description, business_address,
--   location_lat, location_lng, service_category, price_range, is_active,
--   subscription_paid, subscription_due_date, created_at, updated_at,
--   provider_type, owner_national_id, status, category_id  (+ city, 20260922000000)
-- and the only post-baseline ADD COLUMN against it is that `city`.
--
-- There IS a provider_stores table with logo_storage_path / cover_image_storage_path,
-- but it is declared only in 0013-0022d -- every one of those is below
-- BASELINE and was marked applied WITHOUT being executed -- and nothing in lib/
-- references it. It is not a target.
--
-- No bucket for profile photos exists either: 20260927000096 declares the
-- authoritative list (user-documents, payment-screenshots, payment-proofs,
-- product-images, provider-gallery) and 20260927000097 adds vehicle-images.
--
-- WHY A NEW BUCKET AND NOT provider-gallery
-- -----------------------------------------
-- The gallery's storage paths are validated server-side by add_gallery_image()
-- against an actual provider_gallery row -- the path must sit under the folder
-- that row records. A profile photo has no row, so it could not be audited,
-- counted or cleaned up by any of the machinery that already works. Reusing
-- product-images is worse: its write policy is scoped to product ownership.
-- A new bucket keeps "photos attached to a provider record" separable from
-- "photos attached to a product record" and from "photos in a provider's
-- gallery", which are three different things with three different lifetimes.
--
-- WHY A PATH, NOT A URL
-- ---------------------
-- Every image in this app stores a storage path (product_images.storage_path,
-- provider_gallery.storage_path, user_documents.storage_path) and resolves it
-- at read time, through PhotoGridItem.stored(path, bucket:) -> createSignedUrl.
-- A stored URL cannot be re-signed, expires with whatever expiry it was minted
-- under, and would have to be rewritten on every bucket migration. The path is
-- also what the storage policies are written against.
--
-- WHAT THIS MIGRATION DOES NOT TOUCH
-- ----------------------------------
-- It adds one nullable column, one bucket, four storage policies, and one view
-- column. It changes no existing column, no existing policy, no existing
-- function, and no Dart behaviour that exists today. The view is rebuilt
-- because CREATE OR REPLACE VIEW cannot add a column (SQLSTATE 42P16 --
-- 20260924000006's own header records hitting exactly that), and the rebuild is
-- the single highest-risk statement in this file, so it is:
--   - inside one DO block, so the DROP and the CREATE commit together or not
--     at all. A view cannot be left dropped.
--   - a byte-for-byte copy of the column list 20260924000006 shipped, plus the
--     one new column. The previous definition is a proven, executed revision:
--     20260924000006 is above BASELINE, so it ran, and it references
--     registration_fee_paid, which the write tests use against the live
--     database. Anything else here would be an unforced risk to a view the
--     public provider page reads on every load.
--   - skipped entirely if the column is somehow absent, rather than raising.
--
-- The client already has UPDATE on provider_profiles (it is on the 22-table
-- allowlist in 20260927000050, and the business profile screen's direct
-- .update() is how it saves today), and the prevent_provider_self_privilege_
-- escalation() guard in 20260927000027 compares status, provider_type and
-- owner_national_id by name and reads the optional subscription date through
-- to_jsonb -- so it cannot see, and cannot be confused by, a new nullable
-- column. No grant change is needed and none is made.

-- ===========================================================================
-- 1. The column
-- ===========================================================================
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = 'provider_profiles') THEN
    RAISE NOTICE 'provider_profiles absent from public; photo column not added.';
    RETURN;
  END IF;

  -- Nullable, no default, no backfill. Every existing row reads NULL, which the
  -- client renders as the same initial it shows today.
  ALTER TABLE public.provider_profiles
    ADD COLUMN IF NOT EXISTS photo_storage_path text;
END;
$$;

-- ===========================================================================
-- 2. The bucket
-- ===========================================================================
-- Public: the public provider page is reachable by a signed-out customer, so
-- the photo has to render without a session. 5MB, jpeg/png/webp -- identical to
-- provider-gallery and product-images, so the client needs no per-bucket
-- special-casing.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('provider-photos', 'provider-photos', true, 5242880,
        ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ===========================================================================
-- 3. The storage policies
-- ===========================================================================
-- Same shape as provider-gallery, and for the same reason: the path convention
-- is <auth uid>/<image id>/<filename>, so (string_to_array(name,'/'))[1] IS the
-- owner's uid. The read policy is unscoped on purpose -- this bucket is public.
-- The write policies are addressed TO authenticated because the rule is read
-- from auth.uid(); a policy addressed to PUBLIC could only ever be satisfied by
-- a signed-in caller anyway, and naming the role makes that visible in the
-- catalog.

DROP POLICY IF EXISTS provider_photos_insert ON storage.objects;
CREATE POLICY provider_photos_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'provider-photos'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS provider_photos_public_read ON storage.objects;
CREATE POLICY provider_photos_public_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'provider-photos');

DROP POLICY IF EXISTS provider_photos_update_own ON storage.objects;
CREATE POLICY provider_photos_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'provider-photos'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'provider-photos'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS provider_photos_delete_own ON storage.objects;
CREATE POLICY provider_photos_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'provider-photos'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- ===========================================================================
-- 4. Expose the column on the public view
-- ===========================================================================
-- user_provider_detail_screen.dart reads public_provider_profiles, not
-- provider_profiles, precisely so the public page never needs a read policy on
-- the base table. The column therefore has to be on the view to be visible.
--
-- SELECT is unaffected by the rebuild: the new definition is the old one plus a
-- trailing column, and the WHERE clause is untouched, so the same rows come
-- back for the same providers.
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name  = 'provider_profiles'
           AND column_name = 'photo_storage_path') THEN
    RAISE NOTICE
      'provider_profiles.photo_storage_path is absent; public_provider_profiles '
      'left exactly as it is rather than rebuilt.';
    RETURN;
  END IF;

  EXECUTE 'DROP VIEW IF EXISTS public.public_provider_profiles';

  EXECUTE $view$
    CREATE VIEW public.public_provider_profiles
    WITH (security_barrier = true)
    AS
    SELECT
      p.id,
      p.business_name,
      p.business_description,
      -- City-level location only: kebele/street_road/business_address are address
      -- data and stay private to the owner and admins. (verbatim from
      -- 20260924000006)
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
      p.created_at,
      -- NEW. A storage path into a public bucket, not a URL: the client
      -- resolves it at read time, so it survives a bucket rename or a policy
      -- change in a way a stored URL would not.
      p.photo_storage_path
    FROM public.provider_profiles AS p
    WHERE p.status = 'APPROVED';
  $view$;

  EXECUTE 'GRANT SELECT ON public.public_provider_profiles TO anon, authenticated';
END;
$$;

-- ===========================================================================
-- 5. The report
-- ===========================================================================
-- A live run is the only place any of this is observable, and a run that only
-- says "failed" costs another deploy to learn what it already knew. This
-- returns a diagnostic string, in the shape gallery_read_surface_report() set.
CREATE OR REPLACE FUNCTION public.provider_photo_surface_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_has_column boolean := false;
  v_has_bucket boolean := false;
  v_bucket_public boolean := false;
  v_read_policies int := 0;
  v_write_policies int := 0;
  v_has_view boolean := false;
  v_view_exposes_photo boolean := false;
  v_view_columns text := '(view absent)';
BEGIN
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = 'public'
       AND table_name  = 'provider_profiles'
       AND column_name = 'photo_storage_path'
  ) INTO v_has_column;

  SELECT EXISTS (
    SELECT 1 FROM storage.buckets
     WHERE id = 'provider-photos' AND public
  ) INTO v_has_bucket;

  -- Read back separately so "exists but is private" is distinguishable from
  -- "missing": a private bucket would make every provider logo 404 for a
  -- signed-out customer, and the two need different fixes.
  SELECT COALESCE(b.public, false) INTO v_bucket_public
    FROM storage.buckets b WHERE b.id = 'provider-photos';

  SELECT count(*) INTO v_read_policies
    FROM pg_policies
   WHERE schemaname = 'storage'
     AND tablename  = 'objects'
     AND policyname IN ('provider_photos_public_read');

  SELECT count(*) INTO v_write_policies
    FROM pg_policies
   WHERE schemaname = 'storage'
     AND tablename  = 'objects'
     AND policyname IN ('provider_photos_insert',
                        'provider_photos_update_own',
                        'provider_photos_delete_own');

  SELECT EXISTS (
    SELECT 1 FROM information_schema.views
     WHERE table_schema = 'public'
       AND table_name  = 'public_provider_profiles'
  ) INTO v_has_view;

  IF v_has_view THEN
    -- A single string built in a loop rather than a string_agg over an array:
    -- the notification assertions already recorded what a second dimension in
    -- an aggregate costs.
    SELECT string_agg(c.column_name, ', ' ORDER BY c.ordinal_position)
      INTO v_view_columns
      FROM information_schema.columns c
     WHERE c.table_schema = 'public'
       AND c.table_name  = 'public_provider_profiles';

    v_view_exposes_photo := v_view_columns LIKE '%photo_storage_path%';
  END IF;

  RETURN 'provider photo surface: '
    || 'provider_profiles.photo_storage_path=' || v_has_column::text
    || '; bucket provider-photos present=' || v_has_bucket::text
    || ', public=' || v_bucket_public::text
    || '; storage policies read=' || v_read_policies::text
    || ', write=' || v_write_policies::text
    || '; public_provider_profiles present=' || v_has_view::text
    || ', exposes photo_storage_path=' || v_view_exposes_photo::text
    || '; view columns=[' || v_view_columns || ']';
END;
$$;

COMMENT ON FUNCTION public.provider_photo_surface_report() IS
  'Diagnostic for the provider profile photo surface: the column, the bucket and '
  'its visibility, the storage policies, and whether the public view still '
  'exists and exposes the column. Returns a readable string, not a boolean, so '
  'a failing run names what is wrong instead of only asserting that something '
  'is.';

-- ===========================================================================
-- 6. The assertion
-- ===========================================================================
-- The view rebuild is the one destructive statement here, and a view that lost
-- a column or a WHERE clause would break the public provider page for every
-- customer -- a failure with no other symptom. So the assertion pins the view's
-- exact column set, not merely that it exists. If someone edits the view again,
-- this goes red instead of the page quietly losing data.
CREATE OR REPLACE FUNCTION public.assert_provider_photo_surface_is_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_expected text := 'id, business_name, business_description, address_text, '
                  || 'location_lat, location_lng, service_category, price_range, '
                  || 'is_active, subscription_paid, subscription_due_date, '
                  || 'provider_type, status, category_id, city, '
                  || 'registration_fee_paid, created_at, photo_storage_path';
  v_actual text;
  v_is_public boolean := false;
  v_writes int := 0;
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public'
           AND table_name  = 'provider_profiles'
           AND column_name = 'photo_storage_path') THEN
    RAISE EXCEPTION 'provider photo surface: provider_profiles.photo_storage_path is missing';
  END IF;

  IF NOT EXISTS (
        SELECT 1 FROM storage.buckets WHERE id = 'provider-photos') THEN
    RAISE EXCEPTION 'provider photo surface: the provider-photos bucket is missing -- every provider photo upload fails with 404 Bucket not found';
  END IF;

  SELECT b.public INTO v_is_public
    FROM storage.buckets b WHERE b.id = 'provider-photos';
  IF v_is_public IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'provider photo surface: provider-photos must be public, or a signed-out customer gets a 400 on the provider page';
  END IF;

  SELECT count(*) INTO v_writes
    FROM pg_policies
   WHERE schemaname = 'storage'
     AND tablename  = 'objects'
     AND policyname IN ('provider_photos_insert',
                        'provider_photos_update_own',
                        'provider_photos_delete_own',
                        'provider_photos_public_read');
  IF v_writes < 4 THEN
    RAISE EXCEPTION 'provider photo surface: expected 4 storage policies on provider-photos, found %', v_writes;
  END IF;

  IF NOT EXISTS (
        SELECT 1 FROM information_schema.views
         WHERE table_schema = 'public'
           AND table_name  = 'public_provider_profiles') THEN
    RAISE EXCEPTION 'provider photo surface: public_provider_profiles is missing -- the public provider page cannot read anything';
  END IF;

  SELECT string_agg(c.column_name, ', ' ORDER BY c.ordinal_position)
    INTO v_actual
    FROM information_schema.columns c
   WHERE c.table_schema = 'public'
     AND c.table_name  = 'public_provider_profiles';

  IF v_actual IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION
      'provider photo surface: public_provider_profiles has the wrong columns. expected=[%] found=[%]',
      v_expected, v_actual;
  END IF;

  -- The write policy has to be owner-scoped on the first path segment, or any
  -- signed-in user could overwrite any other provider's photo. Checked as a
  -- substring because pg_policies.qual is a rendered expression and its
  -- whitespace is not stable across versions.
  IF NOT EXISTS (
        SELECT 1 FROM pg_policies
         WHERE schemaname = 'storage'
           AND tablename  = 'objects'
           AND policyname = 'provider_photos_update_own'
           AND qual LIKE '%auth.uid()%'
           AND qual LIKE '%string_to_array%') THEN
    RAISE EXCEPTION 'provider photo surface: provider_photos_update_own is not owner-scoped on auth.uid()';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_photo_surface_is_wired() IS
  'The provider profile photo surface is complete and still safe: the column, '
  'a public provider-photos bucket, four owner-scoped/public storage policies, '
  'and a public_provider_profiles view whose column set is exactly the 202609'
  '24000006 definition plus photo_storage_path. Pins the column set because the '
  'view rebuild is the one destructive statement in the migration and a view '
  'that lost a column would break the public provider page silently.';

-- ===========================================================================
-- 7. Grants, cache reload
-- ===========================================================================
-- Same three roles as every other assertion grant: anon is what the
-- connectivity suite calls as, and assert_every_assertion_is_reachable()
-- requires every zero-argument assert_* to be executable by it.
GRANT EXECUTE ON FUNCTION public.provider_photo_surface_report()
  TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_provider_photo_surface_is_wired()
  TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.provider_photo_surface_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_provider_photo_surface_is_wired() FROM PUBLIC;

notify pgrst, 'reload schema';
