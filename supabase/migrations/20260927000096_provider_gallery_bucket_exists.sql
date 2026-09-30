-- 20260927000096 — the provider gallery was built against a bucket nobody created
--
-- THE BUG
-- -------
-- provider_gallery_screen.dart uploads to `provider-gallery` and then records
-- the row through add_gallery_image(). The screen, the RPC and the table all
-- exist. The BUCKET does not.
--
-- `provider-gallery` is created in exactly one place: 0017_marketplace_storage,
-- which also creates the four storage policies it needs. No later migration
-- creates it, and 0017 is in the version range the deploy workflow never
-- executes: the `Baseline migration history` step marks every staged file with a
-- version below 20260919000000 as applied via `migration repair`, and its own
-- comment says the step "never executes the files", because the live database
-- was built by pasting SQL into the editor.
--
-- So the bucket exists only if somebody pasted 0017 by hand. They did not:
-- 0033 exists precisely because the buckets 0012 declared were missing, and it
-- re-created exactly four of them —
--
--   user-documents, product-images, payment-screenshots, payment-proofs
--
-- which is why the product form, the wallet recharge proof and every document
-- upload work while the gallery does not. Those four are also the list 0033
-- documents as "the storage buckets the app writes/reads", so a reader of 0033
-- would reasonably believe the set was complete. It was not: it is a snapshot of
-- what had been pasted by hand at that moment, not a contract the deploy
-- pipeline enforces.
--
-- Confirmed against the live project without a session, through the public
-- object route (an existing public bucket answers NoSuchKey; a bucket that is
-- missing or not public answers NoSuchBucket):
--
--   /storage/v1/object/public/product-images/__probe__.jpg  -> NoSuchKey
--   /storage/v1/object/public/provider-gallery/__probe__.jpg -> NoSuchBucket
--
-- provider-gallery is declared `public = true` in 0017, so had it been created
-- it would have answered NoSuchKey like product-images does.
--
-- WHY NOTHING CAUGHT IT
-- ---------------------
-- Two gaps, and this migration closes both:
--
--   1. No assertion reads storage.buckets. assert_bucket_writes_are_owner_scoped
--      checks the SHAPE of the policies that exist; a bucket with no policies
--      and a bucket that is not there are indistinguishable to it.
--   2. Nothing cross-checked the bucket names in lib/ against the migrations
--      that create them — and "has a creation migration" is not the same test as
--      "has a creation migration the pipeline ever runs". The gallery shipped
--      against a name that had a creation statement, in a file that was marked
--      applied without being executed.
--
-- WHAT CHANGES
-- ------------
--   1. All five buckets the app uses are declared here, in one list, with
--      ON CONFLICT DO UPDATE rather than DO NOTHING. This is the part that makes
--      the set reproducible: after this migration the buckets do not depend on
--      0012, 0017 or 0033 having been pasted, and the four that work today are
--      no-ops. DO UPDATE rather than DO NOTHING because "it is probably already
--      fine" is how the last one shipped broken — a private product-images would
--      make every listing photo 404 for signed-out buyers, and this migration
--      states the intended flags instead of assuming them.
--   2. The four policies `provider-gallery` needs are restated owner-scoped, so
--      they do not depend on 0017 having been pasted either.
--   3. assert_app_buckets_exist() — every bucket the Dart client uses must exist,
--      the two buyers fetch without a session must be public, and the three
--      private ones must not be. It reports what it checked and names what is
--      wrong, instead of returning a bare false.
--
-- vehicle-images is deliberately NOT in the list. It is in the same situation as
-- provider-gallery — 0012 only, therefore absent — but nothing in lib/ reaches
-- it: no upload, no URL, no reader. Creating it would add a bucket with no
-- consumer. When a vehicle-image upload is built, the rule is that the bucket
-- list here, the list in assert_app_buckets_exist() and the names in lib/ move
-- together, and tools/harness/static_checks.py enforces the third leg of that.

-- ===========================================================================
-- 1. The buckets — the authoritative list
-- ===========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  -- Private. Identity documents: owner + admin only, read through signed URLs.
  ('user-documents', 'user-documents', false, 10485760, -- 10MB
   ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']),
  -- Private. Order payment proofs, read by the buyer who sent them and admins.
  ('payment-proofs', 'payment-proofs', false, 10485760, -- 10MB
   ARRAY['image/jpeg', 'image/png', 'image/webp']),
  -- Private. Wallet recharge screenshots, read by the provider and admins.
  ('payment-screenshots', 'payment-screenshots', false, 5242880, -- 5MB
   ARRAY['image/jpeg', 'image/png', 'image/webp']),
  -- Public. Listing photos, fetched by signed-out buyers.
  ('product-images', 'product-images', true, 5242880, -- 5MB
   ARRAY['image/jpeg', 'image/png', 'image/webp']),
  -- Public. Provider gallery photos, fetched by signed-out buyers. The bucket
  -- this migration exists for.
  ('provider-gallery', 'provider-gallery', true, 5242880, -- 5MB
   ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ===========================================================================
-- 2. The gallery policies (0017 created them; it never executed either)
-- ===========================================================================
-- Dropped and recreated in one transaction, as 20260927000048 does: a policy
-- cannot be replaced in place without taking a window with no policy at all.
-- The write policies carry TO authenticated on purpose — the rule is read from
-- auth.uid(), so a policy addressed to PUBLIC could only ever be satisfied by a
-- signed-in caller anyway; naming the role makes that visible in the catalog.
--
-- The path convention is `{auth.uid()}/{image_id}/{filename}`, which is what
-- provider_gallery_screen.dart writes and what add_gallery_image() re-checks
-- server-side, so the two halves cannot disagree.

DROP POLICY IF EXISTS provider_gallery_insert ON storage.objects;
CREATE POLICY provider_gallery_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'provider-gallery'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS provider_gallery_public_read ON storage.objects;
CREATE POLICY provider_gallery_public_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'provider-gallery');

DROP POLICY IF EXISTS provider_gallery_update_own ON storage.objects;
CREATE POLICY provider_gallery_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'provider-gallery'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'provider-gallery'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS provider_gallery_delete_own ON storage.objects;
CREATE POLICY provider_gallery_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'provider-gallery'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- ===========================================================================
-- 3. The assertion that would have caught this
-- ===========================================================================
-- Returns a diagnostic string rather than a boolean, so a red build names the
-- buckets instead of only asserting that something is wrong: a live run is the
-- only place this can be observed, and a run that says "failed" costs another
-- deploy to learn what it already knew.
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
  -- product-images (product form, product cards, cart, product detail) and
  -- provider-gallery (provider_gallery_screen).
  --
  -- Three flat text[] lists walked by FOREACH with a text loop variable. An
  -- array-typed loop variable is what raised 42804 in the notification
  -- assertions, and migration 95 records the cost of a second dimension;
  -- neither is used here.
  v_buckets text[] := ARRAY[
    'user-documents', 'payment-screenshots', 'payment-proofs',
    'product-images', 'provider-gallery'
  ];
  -- Buyers fetch from these with no session: a listing photo and a gallery
  -- photo both render before anyone signs in.
  v_public text[] := ARRAY['product-images', 'provider-gallery'];
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
  'provider-gallery) must exist, the two that signed-out buyers fetch from must '
  'be public, and the three holding documents or payment proofs must not be. '
  'Reads storage.buckets, which no client role can reach, so it is SECURITY '
  'DEFINER and granted to anon for the connectivity suite. It reports what it '
  'checked and names any bucket that is missing or wrongly visible: '
  'provider-gallery was built, reviewed and shipped against a bucket that only '
  '0017 declares, and 0017 is in the version range the deploy workflow never '
  'executes.';

-- Same three roles as the other assertion grants: anon is the role the
-- connectivity suite calls as, and assert_every_assertion_is_reachable()
-- requires every zero-argument assert_* to be executable by it.
REVOKE ALL ON FUNCTION public.assert_app_buckets_exist()
  FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_app_buckets_exist()
  TO anon, authenticated, service_role;

notify pgrst, 'reload schema';
