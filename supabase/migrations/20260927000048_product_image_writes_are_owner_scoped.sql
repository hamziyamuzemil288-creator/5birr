-- Any signed-in account could overwrite any provider's listing photo.
--
-- WHAT IS LIVE
-- ------------
-- 0012 created the product-images policies with the documented convention
--
--   path: {provider_user_id}/{product_id}/{filename}
--
-- and `product_images_insert` required `auth.uid() = (string_to_array(name,'/'))[1]`.
--
-- 0033 then DROPPED that policy and recreated it as:
--
--   WITH CHECK (bucket_id = 'product-images')
--
-- with no path check at all. It is in the same DO/WITH CHECK block that the
-- copy-paste in the private buckets came from; 20260927000042 removed the
-- private ones and did not touch this, because the private-bucket bug was a
-- confidentiality problem and this one is not.
--
-- It is an INTEGRITY problem, and it is live: product-images is a PUBLIC
-- bucket, and its SELECT policy is `bucket_id = 'product-images'`. So any
-- authenticated caller -- any customer with the anon key that ships in the app
-- bundle -- could write an object at ANY path in the bucket, including over an
-- existing provider's listing photo, and it would be served to buyers
-- immediately. No read of anyone's private data is involved, which is why it
-- has never been noticed; the marketplace's content is simply writable by
-- everyone who has the app.
--
-- 0012's UPDATE and DELETE policies are still live and DO require the uid, so
-- the two halves of the app disagreed: the INSERT was wide open, and any
-- replace or delete of an object the app had uploaded would have been refused,
-- because the path the app wrote ('product-images/<productId>/...') does not
-- begin with the caller's uid. Nothing in the app deletes a product image yet,
-- so only the open half had a symptom -- or rather, the open half is why
-- nothing failed.
--
-- THE FIX, IN BOTH HALVES
-- -----------------------
-- The path convention and the policy have to move together, which is why this
-- migration is not a one-liner:
--
--   * the Dart upload path becomes `{auth.uid()}/{product_id}/{filename}`,
--     the convention 0012 documented and the one every other bucket already
--     uses (user-documents, payment-proofs and payment-screenshots are all
--     uid-first);
--   * `product_images_insert` requires that first segment to be the caller,
--     so it agrees with the UPDATE and DELETE policies that were never wrong.
--
-- Objects already uploaded keep their old paths and keep working: the app
-- reads `product_images.storage_path` and builds the public URL from it, so a
-- stored path is not re-derived from a convention. Only new writes are
-- affected, and the public read policy is unchanged.
--
-- Product ownership is deliberately NOT added to the policy. It would be easy
-- to require the second segment to name a product the caller owns, and it
-- would buy nothing: a caller can already put anything they like in their own
-- folder, and the listing photo that reaches a buyer is the one with a
-- product_images row, which `product_images_owner_write` already scopes to the
-- product's owner. The invariant worth enforcing here is the one every other
-- bucket enforces -- writes land in your own folder -- and a rule that can
-- only ever refuse a legitimate flow is not a safety improvement.
--
-- AND THE ASSERTION THAT WAS SUPPOSED TO CATCH THIS
-- -------------------------------------------------
-- assert_private_buckets_are_owner_scoped() has been passing the whole time.
-- It reads `qual` -- the USING clause -- and an INSERT policy has NO USING
-- clause: its entire rule is in WITH CHECK. So for exactly the policy that was
-- wrong (`product_images_insert`, an INSERT policy whose WITH CHECK was just
-- `bucket_id = 'product-images'`), `qual` is NULL, `NULL LIKE '%bucket_id%'`
-- is NULL, and the row is not flagged. The assertion could not see an
-- unscoped INSERT policy on any bucket, including the private ones it was
-- written for.
--
-- This is the third time in this audit series that reading one catalog column
-- and assuming it means what it was expected to mean produced a confident
-- wrong answer: 20260927000043 resolved a quoted relation name that does not
-- resolve, 20260927000045 read pg_policies.qual for INSERT policies. Both of
-- those were fixed in the diagnostic; this one is fixed in the assertion, and
-- the lesson is applied at the point where it decides a result rather than
-- only where it prints one.
--
-- The assertion is renamed to assert_bucket_writes_are_owner_scoped() because
-- it now covers a PUBLIC bucket, where the property being protected is
-- integrity rather than confidentiality. A name that says "private" while the
-- check includes a public bucket is the kind of label that stops being read.

-- ===========================================================================
-- 1. The policy: writes land in the caller's own folder
-- ===========================================================================

DROP POLICY IF EXISTS product_images_insert ON storage.objects;
CREATE POLICY product_images_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'product-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- UPDATE and DELETE were never wrong, but they are restated so the three
-- agree on the rule by construction rather than by history. DROP first: a
-- policy cannot be replaced in place without taking a window with no policy at
-- all, and these are recreated in the same transaction as the INSERT above.
DROP POLICY IF EXISTS product_images_update_own ON storage.objects;
CREATE POLICY product_images_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'product-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'product-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS product_images_delete_own ON storage.objects;
CREATE POLICY product_images_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'product-images'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- The public read policy is restated unchanged: buyers must be able to load a
-- listing photo without a session, which is why this bucket is public at all.
DROP POLICY IF EXISTS product_images_public_read ON storage.objects;
CREATE POLICY product_images_public_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'product-images');

-- ===========================================================================
-- 2. The assertion, reading both halves of every policy
-- ===========================================================================

DROP FUNCTION IF EXISTS public.assert_private_buckets_are_owner_scoped();

CREATE OR REPLACE FUNCTION public.assert_bucket_writes_are_owner_scoped()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- The private buckets (confidentiality: a document written outside your own
  -- folder could be read by whoever owns that folder) and the one public
  -- bucket (integrity: a listing photo written outside your own folder
  -- replaces someone else's).
  c_buckets constant text[] := ARRAY[
    'user-documents', 'payment-screenshots', 'payment-proofs', 'product-images'
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
  'Every write policy on user-documents, payment-screenshots, payment-proofs '
  'or product-images must scope the object to the caller''s own folder, and '
  'none may name a path inside a different bucket. Reads BOTH pg_policies '
  'expression columns: an INSERT policy has no USING clause, so a check that '
  'looked only at qual could not see an unscoped insert policy on any bucket '
  '-- which is how a world-writable product-images ended up passing this '
  'assertion. product-images is public, so what it protects there is '
  'integrity rather than confidentiality.';

GRANT EXECUTE ON FUNCTION public.assert_bucket_writes_are_owner_scoped()
  TO anon, authenticated;
