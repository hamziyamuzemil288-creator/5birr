-- 20260927000097 — a vehicle can finally have a photograph
--
-- THE GAP
-- -------
-- vehicles/vehicle_images/storage policies have existed since 0001/0002/0012,
-- and 0096 records the same defect for `vehicle-images` that it fixes for
-- `provider-gallery`: the bucket is declared in 0012 only, and 0012 is below
-- the deploy baseline, so the workflow marks it applied WITHOUT executing it.
-- Nothing in lib/ reached the bucket, so 0096 deliberately left it out -- a
-- bucket with no consumer is not a fix, it is another name nobody checks.
--
-- What lib/ was missing was the consumer. `vehicle_form_screen.dart` had no
-- image picker at all: a vehicle provider could register a vehicle and a plate
-- number but could not show a rider what the vehicle looks like, and
-- `vehicle_images` -- complete with owner RLS -- had zero rows in it and zero
-- references from Dart. This migration and the Dart change that accompanies it
-- are the two halves of the same fix, which is the rule 0096 states: the
-- bucket, the policy and the upload path move together.
--
-- WHY THE WRITE IS A FUNCTION
-- ---------------------------
-- Exactly as for the provider gallery (20260927000055): vehicle_images is not
-- one of the 22 tables the app writes directly, and 20260927000050 revoked the
-- client's INSERT/UPDATE/DELETE on it. Its owner policy is therefore
-- unreachable by a client, which is the intended state -- a grant nobody needs
-- is half of the pair that makes a policy mistake exploitable. The write goes
-- back as SECURITY DEFINER so the invariant "a client may write the 22 tables
-- the app writes, and nothing else" stays literally true, and so the ownership
-- check lives in one place instead of depending on a policy the caller cannot
-- reach. test/client_write_surface_test.dart pins the other half of that pair
-- from the Dart side and would fail the moment a screen wrote the table
-- directly.
--
-- READS STAY DIRECT
-- ------------------
-- SELECT was never revoked and vehicle_images_read already scopes it (approved
-- vehicle, or its owner, or an admin). Reading a vehicle's photos is a plain
-- client read and needs no function.
--
-- THE PATH CONVENTION
-- -------------------
-- `{auth.uid()}/{vehicle_id}/{filename}`, which is what 0012 documents for this
-- bucket and what every other bucket already uses. add_vehicle_image() refuses
-- a path outside the caller's own folder, so the storage policy and the row can
-- never disagree -- the same coupling the gallery has.

-- ===========================================================================
-- 1. The bucket
-- ===========================================================================
-- ON CONFLICT DO UPDATE rather than DO NOTHING, for the reason 0096 gives: "it
-- is probably already fine" is how provider-gallery shipped broken. These are
-- the intended flags, stated rather than assumed. Public because a rider
-- browsing vehicles is very often not signed in yet -- the photo has to render
-- before the account exists.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('vehicle-images', 'vehicle-images', true, 5242880, -- 5MB
   ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ===========================================================================
-- 2. The storage policies (0012 created them; 0012 never executed)
-- ===========================================================================
-- DROP then CREATE in one transaction, as 20260927000048 does: a policy cannot
-- be replaced in place without taking a window with no policy at all. The two
-- write policies carry TO authenticated on purpose -- the rule is read from
-- auth.uid(), so a policy addressed to PUBLIC could only ever be satisfied by a
-- signed-in caller anyway; naming the role makes that visible in the catalog.

DROP POLICY IF EXISTS vehicle_images_insert ON storage.objects;
CREATE POLICY vehicle_images_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'vehicle-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS vehicle_images_public_read ON storage.objects;
CREATE POLICY vehicle_images_public_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'vehicle-images');

DROP POLICY IF EXISTS vehicle_images_update_own ON storage.objects;
CREATE POLICY vehicle_images_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'vehicle-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'vehicle-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS vehicle_images_delete_own ON storage.objects;
CREATE POLICY vehicle_images_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'vehicle-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- ===========================================================================
-- 3. The table, stated here too
-- ===========================================================================
-- It exists live -- 0021 is a snapshot taken FROM the live database and lists
-- it -- but its only creation statements are in 0001 and 0022, both below the
-- baseline and therefore both marked applied without being executed. A
-- deployment that lost the table would take the feature down with an error
-- nobody could place, so the shape is restated here as the reproducible
-- definition of record. IF NOT EXISTS, so this is a no-op wherever 0001 was
-- pasted by hand.
CREATE TABLE IF NOT EXISTS public.vehicle_images (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  vehicle_id uuid NOT NULL REFERENCES public.vehicles(id) ON DELETE CASCADE,
  storage_path text NOT NULL,
  sort_order integer DEFAULT 0
);

ALTER TABLE public.vehicle_images ENABLE ROW LEVEL SECURITY;

-- Restated owner-scoped, matching what 0002 and 0022b intended. Clients cannot
-- reach the write policy (the grant is revoked below); it is kept because it is
-- the table's documented intent and because the write-surface report reads the
-- policy catalog rather than assuming an empty policy list means "safe".
DROP POLICY IF EXISTS vehicle_images_owner_write ON public.vehicle_images;
CREATE POLICY vehicle_images_owner_write ON public.vehicle_images
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM public.vehicles v
       WHERE v.id = vehicle_id
         AND public.owns_provider_profile(v.provider_id)
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.vehicles v
       WHERE v.id = vehicle_id
         AND public.owns_provider_profile(v.provider_id)
    )
  );

-- A photo of a vehicle that is still pending review is visible to its owner and
-- to admins only; once the vehicle is APPROVED the same row is public, which is
-- what makes the bucket's public read policy useful rather than a leak.
DROP POLICY IF EXISTS vehicle_images_read ON public.vehicle_images;
CREATE POLICY vehicle_images_read ON public.vehicle_images
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.vehicles v
       WHERE v.id = vehicle_id
         AND (
           v.status = 'APPROVED'
           OR public.owns_provider_profile(v.provider_id)
           OR public.is_admin()
         )
    )
  );

-- Stated, not assumed: the app writes this table only through the two functions
-- below. 20260927000050 already revoked these, so on a deployment that ran it
-- this changes nothing, and on one that did not it closes the hole.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.vehicle_images FROM anon, authenticated;

-- ===========================================================================
-- 4. Add a photo
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.add_vehicle_image(
  p_vehicle_id uuid,
  p_storage_path text,
  p_sort_order integer DEFAULT NULL
)
RETURNS public.vehicle_images
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_image public.vehicle_images;
  v_provider uuid;
  v_next integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  -- Ownership is decided by the VEHICLE's provider, not by anything the caller
  -- passed in: p_vehicle_id is the only vehicle identifier in the signature, so
  -- there is no second value that could disagree with it.
  SELECT v.provider_id INTO v_provider
    FROM public.vehicles v
   WHERE v.id = p_vehicle_id;
  IF v_provider IS NULL THEN
    RAISE EXCEPTION 'VEHICLE_NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_provider) THEN
    RAISE EXCEPTION 'NOT_YOUR_VEHICLE';
  END IF;

  IF p_storage_path IS NULL OR btrim(p_storage_path) = '' THEN
    RAISE EXCEPTION 'STORAGE_PATH_REQUIRED';
  END IF;

  -- The storage policies on `vehicle-images` scope every write to
  -- auth.uid()::text = (string_to_array(name, '/'))[1], so an object uploaded
  -- outside the caller's own folder is unviewable and undeletable even though
  -- the upload succeeded. Refusing the row here means the two halves can never
  -- disagree: a vehicle_images row always points at an object its owner can
  -- manage.
  IF (string_to_array(btrim(p_storage_path), '/'))[1] IS DISTINCT FROM auth.uid()::text THEN
    RAISE EXCEPTION 'STORAGE_PATH_NOT_OWNED';
  END IF;

  -- Append to the end when the caller does not say where it goes.
  v_next := coalesce(p_sort_order, (
    SELECT coalesce(max(i.sort_order), -1) + 1
      FROM public.vehicle_images i
     WHERE i.vehicle_id = p_vehicle_id));

  INSERT INTO public.vehicle_images (vehicle_id, storage_path, sort_order)
  VALUES (p_vehicle_id, btrim(p_storage_path), v_next)
  RETURNING * INTO v_image;

  RETURN v_image;
END;
$$;

-- ===========================================================================
-- 5. Delete a photo
-- ===========================================================================
-- The row goes; the stored object is left alone on purpose, exactly as
-- delete_gallery_image() does. Storage deletes are irreversible and the bucket
-- is PUBLIC-read, so a path some other screen still points at is better left on
-- disk than silently broken. The vehicle_images row is what the app shows, and
-- it is what "remove this photo" means.
CREATE OR REPLACE FUNCTION public.delete_vehicle_image(p_image_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  SELECT v.provider_id INTO v_provider
    FROM public.vehicle_images i
    JOIN public.vehicles v ON v.id = i.vehicle_id
   WHERE i.id = p_image_id;

  IF v_provider IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;

  IF NOT public.owns_provider_profile(v_provider) THEN
    RAISE EXCEPTION 'NOT_YOUR_IMAGE';
  END IF;

  DELETE FROM public.vehicle_images i WHERE i.id = p_image_id;
  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.add_vehicle_image(uuid, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_vehicle_image(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.add_vehicle_image(uuid, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_vehicle_image(uuid) TO authenticated;

-- ===========================================================================
-- 6. assert_bucket_writes_are_owner_scoped covers the two new buckets
-- ===========================================================================
-- The assertion from 20260927000048 hard-codes four buckets and therefore could
-- not see a write policy on `provider-gallery` or `vehicle-images` at all. Both
-- are public, so what it protects there is integrity -- a photo written outside
-- your own folder replaces someone else's -- and both now carry owner-scoped
-- policies that reference auth.uid(). The body below is the 48 body with two
-- entries added to c_buckets and nothing else changed; every condition, the
-- admin-helper allowance, the "no policy may name another bucket's path" second
-- half and the exception text are carried across verbatim. Only c_buckets
-- changed: two entries added, so all six client buckets the app uses are now
-- covered by both this assertion and assert_app_buckets_exist() below.
CREATE OR REPLACE FUNCTION public.assert_bucket_writes_are_owner_scoped()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- The private buckets (confidentiality: a document written outside your own
  -- folder could be read by whoever owns that folder) and the three public
  -- ones (integrity: a listing, gallery or vehicle photo written outside your
  -- own folder replaces someone else's).
  c_buckets constant text[] := ARRAY[
    'user-documents', 'payment-screenshots', 'payment-proofs',
    'product-images', 'provider-gallery', 'vehicle-images'
  ];
  v_offender text;
  v_policy text;
BEGIN
  FOREACH v_offender IN ARRAY c_buckets LOOP
    -- The applied rule is BOTH expression columns, because which column holds
    -- it depends on the command: USING decides a row being read or matched,
    -- WITH CHECK decides a row being written, and an INSERT policy has no
    -- USING clause at all. Reading only qual is what let an unscoped
    -- product_images_insert pass this check for as long as it existed.
    FOR v_policy IN
      SELECT p.policyname
      FROM pg_policies p
      WHERE p.schemaname = 'storage'
        AND p.tablename = 'objects'
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
              LIKE '%' || v_offender || '%'
        -- An identity helper has to appear. auth.uid() covers every owner
        -- rule; the admin helpers are accepted because a policy only an admin
        -- can satisfy is not a client writing outside its own folder, and
        -- refusing to recognise them would fail the build over a policy that
        -- is stricter than this check. The shape that must fail is the one
        -- that actually shipped: a WITH CHECK that names nothing but the
        -- bucket.
        AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
              !~ '(auth\.uid|is_admin|is_ceo|is_super_admin|has_role)'
    LOOP
      RAISE EXCEPTION
        'the storage write policy % on bucket % is not scoped to the caller''s own folder, so it can write outside its own path',
        v_policy, v_offender;
    END LOOP;
  END LOOP;

  -- And no policy guarding one of these buckets may also name a path inside a
  -- DIFFERENT bucket. This is the exact shape of the copy-paste 0033 left in
  -- the private buckets, so it is asserted separately from the owner check
  -- above: the removed policies DID reference auth.uid(), so that check would
  -- have waved them through. It is the stray disjunct that was actually wrong,
  -- because it let a client write outside its own folder.
  --
  -- Scoped to policies that mention BOTH a guarded bucket and a product-images
  -- PATH. The legitimate product-images policies name only product-images, so
  -- they are not caught -- an earlier version of this check matched on the
  -- bare bucket name and flagged them, which would have failed the build over
  -- a policy that was never wrong.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND lower(coalesce(qual, '') || ' ' || coalesce(with_check, ''))
            LIKE '%product-images/%'
      AND lower(coalesce(qual, '') || ' ' || coalesce(with_check, ''))
            ~ '(user-documents|payment-screenshots|payment-proofs)'
  ) THEN
    RAISE EXCEPTION
      'a storage write policy for a private bucket also allows a product-images path, which is the copy-paste 20260927000042 removed';
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_bucket_writes_are_owner_scoped() IS
  'Every write policy on user-documents, payment-screenshots, payment-proofs, '
  'product-images, provider-gallery or vehicle-images must scope the object to '
  'the caller''s own folder, and none may name a path inside a different '
  'bucket. Reads BOTH pg_policies expression columns: an INSERT policy has no '
  'USING clause, so a check that looked only at qual could not see an unscoped '
  'insert policy on any bucket -- which is how a world-writable product-images '
  'ended up passing this assertion. The last three buckets are public, so what '
  'the check protects there is integrity rather than confidentiality.';

GRANT EXECUTE ON FUNCTION public.assert_bucket_writes_are_owner_scoped()
  TO anon, authenticated;

-- ===========================================================================
-- 7. assert_app_buckets_exist sees the sixth bucket
-- ===========================================================================
-- The list must move with the bucket, or the assertion reports success about a
-- bucket it never looked at -- which is the failure mode this whole series is
-- about. Same body as 0096, with vehicle-images added to v_buckets and to
-- v_public, and the wording changed from "two"/"three" to the array lengths so
-- a future addition cannot leave a stale number in the message.
CREATE OR REPLACE FUNCTION public.assert_app_buckets_exist()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Every bucket reached from lib/ through storage.from('<bucket>') or the
  -- `_bucket` constant that holds the same string: user-documents
  -- (document_upload_service, appeal screens), payment-screenshots
  -- (wallet_service, admin payment verification, CEO dashboard),
  -- payment-proofs (checkout, order detail, admin order payments),
  -- product-images (product form, product cards, cart, product detail),
  -- provider-gallery (provider_gallery_screen) and vehicle-images
  -- (vehicle_form_screen).
  --
  -- Three flat text[] lists walked by FOREACH with a text loop variable. An
  -- array-typed loop variable is what raised 42804 in the notification
  -- assertions, and migration 95 records the cost of a second dimension;
  -- neither is used here.
  v_buckets text[] := ARRAY[
    'user-documents', 'payment-screenshots', 'payment-proofs',
    'product-images', 'provider-gallery', 'vehicle-images'
  ];
  -- Buyers fetch from these with no session: a listing photo, a gallery photo
  -- and a vehicle photo all render before anyone signs in.
  v_public text[] := ARRAY[
    'product-images', 'provider-gallery', 'vehicle-images'
  ];
  -- And these must stay private. A mistakenly-public identity document bucket
  -- would serve passports to anyone who knows a path, which is worse than the
  -- opposite mistake and is checked for the same reason.
  v_private text[] := ARRAY[
    'user-documents', 'payment-proofs', 'payment-screenshots'
  ];
  v_bucket text;
  v_checked int := 0;
  v_missing text := '';
  v_wrong_visibility text := '';
BEGIN
  FOREACH v_bucket IN ARRAY v_buckets LOOP
    v_checked := v_checked + 1;

    IF NOT EXISTS (SELECT 1 FROM storage.buckets b WHERE b.id = v_bucket) THEN
      v_missing := v_missing || v_bucket || ', ';
      CONTINUE;
    END IF;

    IF v_bucket = ANY (v_public)
       AND NOT EXISTS (
         SELECT 1 FROM storage.buckets b WHERE b.id = v_bucket AND b.public
       ) THEN
      v_wrong_visibility :=
        v_wrong_visibility || v_bucket || ' (must be public), ';
    END IF;

    IF v_bucket = ANY (v_private)
       AND EXISTS (
         SELECT 1 FROM storage.buckets b WHERE b.id = v_bucket AND b.public
       ) THEN
      v_wrong_visibility :=
        v_wrong_visibility || v_bucket || ' (must be private), ';
    END IF;
  END LOOP;

  -- A check that examined nothing must never report success. This is the rule
  -- migration 95 states as applying to every assertion here, and the counter is
  -- how it is honoured.
  IF v_checked = 0 THEN
    RETURN 'FAIL: no bucket was checked at all, so this assertion is reporting '
           || 'success without having looked at anything';
  END IF;

  IF v_missing <> '' THEN
    RETURN 'FAIL: the Flutter client writes to bucket(s) that do not exist: '
           || rtrim(v_missing, ', ')
           || '. Every upload aimed at one of them fails with "Bucket not '
           || 'found" (404) and the user sees only the generic upload error. '
           || 'provider-gallery shipped exactly this way: 0017 creates it, and '
           || '0017 is in the version range the deploy workflow marks applied '
           || 'WITHOUT executing it.';
  END IF;

  IF v_wrong_visibility <> '' THEN
    RETURN 'FAIL: bucket visibility does not match what the app expects: '
           || rtrim(v_wrong_visibility, ', ')
           || '. A public bucket that should be private leaks documents; a '
           || 'private bucket that should be public 404s for every signed-out '
           || 'buyer while looking correct to the provider who uploaded it';
  END IF;

  RETURN 'ok: all ' || v_checked::text || ' bucket(s) the Flutter client uses '
         || 'exist (' || array_to_string(v_buckets, ', ') || '); '
         || array_length(v_public, 1)::text || ' public ('
         || array_to_string(v_public, ', ') || ') and '
         || array_length(v_private, 1)::text || ' private ('
         || array_to_string(v_private, ', ') || '), as the app expects';
END;
$$;

COMMENT ON FUNCTION public.assert_app_buckets_exist() IS
  'Every storage bucket the Flutter client writes to or builds a URL from '
  '(user-documents, payment-screenshots, payment-proofs, product-images, '
  'provider-gallery, vehicle-images) must exist, the three that signed-out '
  'buyers fetch from must be public, and the three holding documents or payment '
  'proofs must not be. Reads storage.buckets, which no client role can reach, '
  'so it is SECURITY DEFINER and granted to anon for the connectivity suite. It '
  'reports what it checked and names any bucket that is missing or wrongly '
  'visible: provider-gallery was built, reviewed and shipped against a bucket '
  'that only 0017 declares, and 0017 is in the version range the deploy '
  'workflow never executes.';

REVOKE ALL ON FUNCTION public.assert_app_buckets_exist()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_app_buckets_exist()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
