-- 20260927000132 — the uploaded files go too
--
-- WHAT IS MISSING
-- ----------------
-- Deleting an account works. Migration 0054 ends in
--
--   DELETE FROM auth.users WHERE id = p_target_user_id
--
-- and that single statement takes thirty-six tables with it: the profile,
-- the provider profile, every product, product image, listing image, gallery
-- photo, vehicle photo, store record, the cart, the favourites, the likes,
-- the documents, the appeals, the wallet and its ledger. 0118 then detached
-- the twenty record tables that must survive, and the harness proves nothing
-- still blocks the delete.
--
-- Every one of those rows is a POINTER to a file. Not one of them takes the
-- file with it.
--
-- `grep -rn "storage.from" supabase/functions/` returns nothing, and the only
-- `remove(` in lib/ is a provider swapping their own header photo. So after an
-- account is closed:
--
--   * the identity document, business licence and driving licence scans stay in
--     the `user-documents` bucket, reachable by path;
--   * the evidence photo attached to every appeal the person filed, and every
--     appeal they answered, stays in that same bucket;
--   * the avatar, the shop photo, the gallery, the vehicle photos, the
--     marketplace listing photos stay;
--   * the wallet recharge screenshot stays.
--
-- The rows that named those files are gone, so nothing in the app can find
-- them again -- which is exactly why this is invisible rather than obviously
-- broken. They are unreachable but not removed, they still occupy the project's
-- storage quota, and `docs/delete-account.html` tells a user reading it that
-- their uploaded identity and driving documents are deleted with the account.
-- That sentence is currently false for the file itself.
--
-- WHY NOT A TRIGGER ON auth.users
-- -------------------------------
-- A trigger would be the only thing that cannot be forgotten, and it is not
-- available: creating one on `auth.users` needs ownership of GoTrue's table,
-- which a migration connection does not have, and a migration that names
-- `auth.users` in DDL has already cost two deploy runs in this repository
-- (0118's header). So the sweep is an explicit call, made from all three
-- delete paths before the cascade runs -- and the harness below proves there
-- are three and that each one makes it.
--
-- WHY THE COLLECTOR RUNS FIRST
-- -----------------------------
-- After `DELETE FROM auth.users` there is nothing left to read: the rows that
-- held the paths are gone, and their files are orphans with no index. So
-- `account_storage_objects()` has to be called while the rows still exist,
-- and `purge_account_storage()` deletes inside that same window.
--
-- WHY THE PAYMENT SCREENSHOTS ARE CONDITIONAL
-- -------------------------------------------
-- `payment_proofs` and the customer-side `wallet_recharge_requests` rows are
-- RECORD rows: they are kept by 0118 with the person detached, because they
-- are the evidence for a transaction that still exists. Deleting their files
-- would leave a live accounting record pointing at a missing image. They are
-- therefore NOT in this sweep.
--
-- A provider's `wallet_recharge_requests` rows are the other case: those hang
-- off `wallets` and `provider_profiles` with ON DELETE CASCADE, so they DO go
-- with the account, and their screenshots go with them. The collector decides
-- per row rather than per bucket, which is the only rule that is true in both
-- cases -- and it is the rule the owner picked: a blob goes when its row goes.
--
-- WHY `DELETE FROM storage.objects` IS ENOUGH
-- -------------------------------------------
-- Because it is already the mechanism this project ships. Migration 0122's
-- `admin_moderate_image` removes a single reported image with exactly this
-- statement, and the storage trigger behind it removes the underlying object.
-- Reusing a proven statement beats introducing a second way to delete a file.

-- ===========================================================================
-- 1. What the account owns, as (bucket, path) pairs
-- ===========================================================================
-- SECURITY DEFINER because the caller is a service-role connection reading
-- rows whose RLS nobody in that path is a member of, and STABLE because it
-- reads nothing it does not read twice.
--
-- Every column below is read at PLAN time, so a missing one would abort the
-- whole push rather than skip: they are named here with the migration that
-- added each one, and `assert_account_storage_is_purged()` checks them in the
-- live catalog so a later rename is a loud failure rather than a silent one.
--
-- `nullif(btrim(path), '') IS NOT NULL` is not decoration. A single empty
-- string would otherwise be handed to the DELETE as `name = ''`; the sweep
-- would then remove whatever object happens to sit at the root of a bucket.
CREATE OR REPLACE FUNCTION public.account_storage_objects(p_user_id uuid)
RETURNS TABLE(bucket_id text, object_name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH prov AS (
    SELECT pp.id
      FROM public.provider_profiles pp
     WHERE pp.user_id = p_user_id
  )
  -- Identity / business / driving documents (0001, 0021, 0022). The same
  -- bucket the appeal evidence lives in, and the same folder convention.
  SELECT 'user-documents'::text, u.storage_path
    FROM public.user_documents u
   WHERE u.user_id = p_user_id
     AND nullif(btrim(u.storage_path), '') IS NOT NULL
  UNION ALL
  -- The photo a person attached when they filed an appeal (appeal_cases,
  -- 20260923000000).
  SELECT 'user-documents', a.photo_path
    FROM public.appeal_cases a
   WHERE a.user_id = p_user_id
     AND nullif(btrim(a.photo_path), '') IS NOT NULL
  UNION ALL
  -- The photo they attached answering an appeal filed against them. That
  -- column arrived in 20260927000051, long before this migration.
  SELECT 'user-documents', a.response_photo_path
    FROM public.appeal_cases a
   WHERE a.respondent_id = p_user_id
     AND nullif(btrim(a.response_photo_path), '') IS NOT NULL
  UNION ALL
  -- The user's own picture (20260927000119).
  SELECT 'profile-avatars', pr.avatar_storage_path
    FROM public.profiles pr
   WHERE pr.id = p_user_id
     AND nullif(btrim(pr.avatar_storage_path), '') IS NOT NULL
  UNION ALL
  -- The shop / driver header photo (20260927000106).
  SELECT 'provider-photos', pp.photo_storage_path
    FROM public.provider_profiles pp
   WHERE pp.id IN (SELECT id FROM prov)
     AND nullif(btrim(pp.photo_storage_path), '') IS NOT NULL
  UNION ALL
  -- Marketplace listing photos (0001, 0021, 0022).
  SELECT 'product-images', pi.storage_path
    FROM public.product_images pi
   WHERE pi.product_id IN (
           SELECT p.id FROM public.products p
            WHERE p.provider_id IN (SELECT id FROM prov))
     AND nullif(btrim(pi.storage_path), '') IS NOT NULL
  UNION ALL
  -- The second image table the marketplace search reads (0013). Same bucket,
  -- same products, and a delete that matches no row in a bucket costs one
  -- index lookup -- which is why both are swept rather than one being guessed.
  SELECT 'product-images', li.storage_path
    FROM public.listing_images li
   WHERE li.listing_id IN (
           SELECT p.id FROM public.products p
            WHERE p.provider_id IN (SELECT id FROM prov))
     AND nullif(btrim(li.storage_path), '') IS NOT NULL
  UNION ALL
  -- The business / driver gallery (0013).
  SELECT 'provider-gallery', g.storage_path
    FROM public.provider_gallery g
   WHERE g.provider_id IN (SELECT id FROM prov)
     AND nullif(btrim(g.storage_path), '') IS NOT NULL
  UNION ALL
  -- Vehicle photos (20260927000097).
  SELECT 'vehicle-images', vi.storage_path
    FROM public.vehicle_images vi
   WHERE vi.vehicle_id IN (
           SELECT v.id FROM public.vehicles v
            WHERE v.provider_id IN (SELECT id FROM prov))
     AND nullif(btrim(vi.storage_path), '') IS NOT NULL
  UNION ALL
  -- Store logo and cover (0013). No client writes these columns today, and no
  -- migration ever recorded which bucket they were meant to live in, so both
  -- buckets this project uses for provider imagery are tried. Every upload in
  -- this project is `<uid>/...`, so the two names cannot collide across them.
  SELECT b.bucket, img.path
    FROM public.provider_stores s
    CROSS JOIN LATERAL unnest(
           ARRAY[s.logo_storage_path, s.cover_image_storage_path]) AS img(path)
    CROSS JOIN LATERAL (VALUES ('provider-gallery'), ('product-images'))
           AS b(bucket)
   WHERE s.provider_id IN (SELECT id FROM prov)
     AND nullif(btrim(img.path), '') IS NOT NULL
  UNION ALL
  -- The recharge screenshot -- ONLY for the rows that are about to be
  -- deleted. A provider's recharges hang off `wallets` and
  -- `provider_profiles` with ON DELETE CASCADE, so they go; a customer has no
  -- wallet, their recharge rows are kept by 0118, and so is the proof.
  SELECT 'payment-screenshots', r.screenshot_storage_path
    FROM public.wallet_recharge_requests r
   WHERE (
           r.provider_id IN (SELECT id FROM prov)
        OR r.wallet_id IN (
             SELECT w.id FROM public.wallets w
              WHERE w.provider_id IN (SELECT id FROM prov)))
     AND nullif(btrim(r.screenshot_storage_path), '') IS NOT NULL
$$;

COMMENT ON FUNCTION public.account_storage_objects(uuid) IS
  'The (bucket, path) pairs an account owns, read from the rows that still '
  'exist. A blob goes when its row goes: provider content, documents, appeal '
  'evidence, avatar, and a recharge proof only when that recharge row is '
  'itself deleted with the wallet. Retained records keep their files.';

-- ===========================================================================
-- 2. Remove them
-- ===========================================================================
-- service_role only. This function deletes files, and the one thing that must
-- not happen is a client role being able to call it on somebody else's id --
-- which is exactly what `check_client_rpcs_are_executable` guards.
CREATE OR REPLACE FUNCTION public.purge_account_storage(p_user_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec record;
  v_hit integer := 0;
  v_removed integer := 0;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN 0;
  END IF;

  -- A database without the storage schema has nothing to clean. 0122 guards
  -- the same way, and skipping is the correct answer rather than an error:
  -- the account must still be deletable where storage is absent.
  IF to_regclass('storage.objects') IS NULL THEN
    RETURN 0;
  END IF;

  FOR v_rec IN
    SELECT o.bucket_id, o.object_name
      FROM public.account_storage_objects(p_user_id) o
  LOOP
    DELETE FROM storage.objects
     WHERE bucket_id = v_rec.bucket_id
       AND name = v_rec.object_name;
    GET DIAGNOSTICS v_hit = ROW_COUNT;
    v_removed := v_removed + v_hit;
  END LOOP;

  RETURN v_removed;
END;
$$;

REVOKE ALL ON FUNCTION public.account_storage_objects(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.account_storage_objects(uuid)
  TO service_role;

REVOKE ALL ON FUNCTION public.purge_account_storage(uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_account_storage(uuid)
  TO service_role;

-- ===========================================================================
-- 3. The CEO path, which reaches the cascade through a wrapper
-- ===========================================================================
-- `ceo_delete_user_account` never touches a table itself -- it records the
-- reason and then CALLS `delete_user_account`, which is the one statement that
-- does the work. The sweep goes in between, while the rows still exist, and
-- the count is folded into the returned object so the CEO screen can say how
-- many files went with the account.
--
-- No `auth.users` is named anywhere in this file, and none is needed: the
-- wrapper passes the id it was given.
CREATE OR REPLACE FUNCTION public.ceo_delete_user_account(
  p_target_user_id uuid,
  p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_name text;
  v_storage integer;
  v_result jsonb;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF NOT public.is_ceo_authority() THEN
    RAISE EXCEPTION 'CEO_DELETE_IS_CEO_ONLY';
  END IF;

  IF p_target_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  IF p_target_user_id = v_actor THEN
    RAISE EXCEPTION 'CANNOT_DELETE_SELF';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 10 THEN
    RAISE EXCEPTION 'REASON_REQUIRED';
  END IF;

  SELECT full_name INTO v_name FROM public.profiles WHERE id = p_target_user_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'USER_NOT_FOUND';
  END IF;

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor,
          'CEO_DELETE_ACCOUNT',
          'auth_users',
          p_target_user_id,
          jsonb_build_object('reason', btrim(p_reason),
                             'full_name', v_name));

  -- Before the cascade. Every path is still reachable from a row at this
  -- point; one statement later, none of them is.
  v_storage := public.purge_account_storage(p_target_user_id);

  v_result := public.delete_user_account(v_actor, p_target_user_id);

  RETURN coalesce(v_result, '{}'::jsonb)
         || jsonb_build_object('storage_objects_removed', v_storage);
END;
$$;

REVOKE ALL ON FUNCTION public.ceo_delete_user_account(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ceo_delete_user_account(uuid, text)
  TO authenticated;

-- ===========================================================================
-- 4. The assertion
-- ===========================================================================
-- Proves, in the live catalog, the three things a later migration could break
-- without anybody noticing:
--
--   1. both functions exist, and `purge_account_storage` is reachable by
--      service_role and by NOBODY else -- a client that could call it could
--      delete another person's identity documents;
--   2. every bucket the collector names actually exists in `storage.buckets`,
--      so a typo cannot leave a whole class of files behind;
--   3. every column the collector reads exists, because a column that had
--      gone would have aborted this migration at plan time -- and a migration
--      that cannot be re-applied is a deploy that cannot be rolled forward.
--
-- It also returns the count of verified sources so a green run says how much
-- it actually looked at.
CREATE OR REPLACE FUNCTION public.assert_account_storage_is_purged()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_bucket text;
  v_table text;
  v_column text;
  v_missing text := '';
  v_checked integer := 0;
  v_i integer;
  v_sources constant text[][] := ARRAY[
    ARRAY['user-documents',             'user_documents',        'storage_path'],
    ARRAY['user-documents',             'appeal_cases',          'photo_path'],
    ARRAY['user-documents',             'appeal_cases',          'response_photo_path'],
    ARRAY['profile-avatars',            'profiles',              'avatar_storage_path'],
    ARRAY['provider-photos',            'provider_profiles',     'photo_storage_path'],
    ARRAY['product-images',             'product_images',        'storage_path'],
    ARRAY['product-images',             'listing_images',        'storage_path'],
    ARRAY['provider-gallery',           'provider_gallery',      'storage_path'],
    ARRAY['vehicle-images',            'vehicle_images',        'storage_path'],
    ARRAY['provider-gallery',           'provider_stores',       'logo_storage_path'],
    ARRAY['provider-gallery',           'provider_stores',       'cover_image_storage_path'],
    ARRAY['payment-screenshots',        'wallet_recharge_requests', 'screenshot_storage_path']
  ];
  v_source text[];
BEGIN
  IF to_regprocedure('public.account_storage_objects(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'account_storage_objects(uuid) is missing: nothing collects the files an account owns, so every uploaded photo, document and appeal evidence survives the deletion';
  END IF;

  IF to_regprocedure('public.purge_account_storage(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'purge_account_storage(uuid) is missing: the files are collected but nothing removes them';
  END IF;

  IF has_function_privilege('anon', 'public.purge_account_storage(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION
      'anon can execute purge_account_storage: a signed-out client could delete another account''s identity documents';
  END IF;

  IF has_function_privilege('authenticated', 'public.purge_account_storage(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION
      'authenticated can execute purge_account_storage: any signed-in user could delete another account''s identity documents';
  END IF;

  IF NOT has_function_privilege('service_role', 'public.purge_account_storage(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION
      'service_role cannot execute purge_account_storage: the gateways that delete accounts would silently skip the file sweep';
  END IF;

  -- A subscripted loop, NOT `FOREACH`. FOREACH only accepts a
  -- ONE-DIMENSIONAL array, and this one is `text[][]`: CREATE FUNCTION does
  -- not check that, so the assertion would have deployed and then raised 42804
  -- on every single call -- a check that is green in review and dead in
  -- production. Found by tools/harness, which is exactly what it is for.
  FOR v_i IN 1 .. coalesce(array_length(v_sources, 1), 0) LOOP
    v_source := v_sources[v_i];
    v_bucket := v_source[1];
    v_table  := v_source[2];
    v_column := v_source[3];
    v_checked := v_checked + 1;

    IF NOT EXISTS (SELECT 1 FROM storage.buckets b WHERE b.id = v_bucket) THEN
      v_missing := v_missing || format('bucket %s; ', v_bucket);
      CONTINUE;
    END IF;

    IF NOT EXISTS (
         SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name = v_table
            AND c.column_name = v_column) THEN
      v_missing := v_missing || format('%s.%s; ', v_table, v_column);
    END IF;
  END LOOP;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'the account file sweep no longer matches the schema: %s. Each of these is read by account_storage_objects() at plan time, so a missing one would stop this migration from being applied or re-applied.', v_missing;
  END IF;

  RETURN format(
    'ok: %s sources verified, every bucket present, purge_account_storage is service_role only, and both functions exist', v_checked);
END;
$$;

REVOKE ALL ON FUNCTION public.assert_account_storage_is_purged()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_account_storage_is_purged()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';