-- 20260927000136 — the file sweep check could not see the buckets
--
-- WHAT THE LIVE DATABASE SAID
-- ----------------------------
-- With 0134 deployed the assertion stopped claiming that every bucket was
-- missing and started saying something else:
--
--   ERROR: the source list in this assertion produced no rows, so it verified
--   nothing. The single-subscript read `v_sources[v_i]` returns NULL on a
--   multi-dimensional array; ...
--
-- The array is fixed. This is the SECOND defect in the same function, and it
-- is why 0134's zero-rows guard fired rather than the check passing.
--
-- THE BUG
-- -------
-- `assert_account_storage_is_purged()` reads:
--
--     IF NOT EXISTS (SELECT 1 FROM storage.buckets b WHERE b.id = v_sources[v_i][1])
--
-- and it was created as a plain `LANGUAGE plpgsql` function -- NOT
-- SECURITY DEFINER. The connectivity suite calls it with the ANON key.
-- `storage.buckets` has row-level security, and anon is not a member of any
-- policy that reads it, so the SELECT inside `NOT EXISTS` returns ZERO ROWS.
--
-- `NOT EXISTS` over zero rows is TRUE. So every one of the twelve sources
-- looked like a missing bucket, every iteration hit its `CONTINUE`, and the
-- run checked nothing.
--
-- Which means this function could never have passed on a real Supabase
-- project, at any point in its life. 0132 and 0134 both lacked the
-- attribute; the array bug simply fired first and hid it.
--
-- WHY IT WAS INVISIBLE HERE TOO
-- -----------------------------
-- Every other assertion in this repository that reads `storage.buckets` is
-- `SECURITY DEFINER SET search_path = public, pg_temp`:
--
--   20260927000096 assert_app_buckets_exist()          SECURITY DEFINER
--   20260927000097 assert_vehicle_images_bucket_exists() SECURITY DEFINER
--   20260927000106 assert_provider_photo_surface()      SECURITY DEFINER
--   20260927000119 assert_profile_avatar_bucket_exists() SECURITY DEFINER
--
-- and the harness's `check_client_rpcs_are_executable` enforces reachability
-- but says nothing about RLS visibility to the caller. The convention was
-- followed everywhere except here, and nothing recorded the exception.
--
-- THE FIX
-- -------
-- `SECURITY DEFINER SET search_path = public, pg_temp`, matching the four
-- functions above. SECURITY DEFINER makes the body run as the owner, which is
-- the role that can read the catalog tables these reports are built on; the
-- `SET search_path` is the other half of that convention and is copied from
-- them rather than invented.
--
-- This is safe to do. The function returns a string, mutates nothing, and
-- the only thing it exposes is whether a bucket and a column exist -- a fact
-- every assertion in this repository already publishes to `authenticated`
-- and `anon` by design, and one that tells a caller nothing they could not
-- learn from the client itself.
--
-- THE GUARD IS REWORDED, NOT REMOVED
-- -----------------------------------
-- 0134 added "if nothing was checked, say so". That guard did exactly its
-- job here -- without it this function would have reported a clean `ok:`
-- while having verified nothing at all, which is worse than failing. But its
-- message blamed the array subscript, which was fixed and is no longer the
-- cause. A guard that names the wrong cause sends the next person to the
-- wrong file, so it now states the fact -- nothing was verified -- and names
-- the most likely reason without asserting it as the only one.
--
-- `assert_app_buckets_exist` exists and is granted to the same anon role. If
-- you want to know whether these buckets are really there, that is the
-- function to ask.

-- ---------------------------------------------------------------------------
-- The assertion, with the visibility attribute 0132 and 0134 both lacked.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_account_storage_is_purged()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text := '';
  v_checked integer := 0;
  v_i integer;
  -- Three columns, read as [1] [2] [3]. NOT through an intermediate
  -- `v_source := v_sources[v_i]` -- that single subscript returns NULL on a
  -- multi-dimensional array (0134) and is the regression this shape avoids.
  v_sources constant text[][] := ARRAY[
    ARRAY['user-documents',                'user_documents',        'storage_path'],
    ARRAY['user-documents',                'appeal_cases',          'photo_path'],
    ARRAY['user-documents',                'appeal_cases',          'response_photo_path'],
    ARRAY['profile-avatars',               'profiles',              'avatar_storage_path'],
    ARRAY['provider-photos',               'provider_profiles',     'photo_storage_path'],
    ARRAY['product-images',                'product_images',        'storage_path'],
    ARRAY['product-images',                'listing_images',        'storage_path'],
    ARRAY['provider-gallery',              'provider_gallery',      'storage_path'],
    ARRAY['vehicle-images',                'vehicle_images',        'storage_path'],
    ARRAY['provider-gallery',              'provider_stores',       'logo_storage_path'],
    ARRAY['provider-gallery',              'provider_stores',       'cover_image_storage_path'],
    ARRAY['payment-screenshots',           'wallet_recharge_requests', 'screenshot_storage_path']
  ];
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

  FOR v_i IN 1 .. coalesce(array_length(v_sources, 1), 0) LOOP
    IF NOT EXISTS (
         SELECT 1 FROM storage.buckets b
          WHERE b.id = v_sources[v_i][1]) THEN
      v_missing := v_missing || format('bucket %s; ', v_sources[v_i][1]);
      CONTINUE;
    END IF;

    IF NOT EXISTS (
         SELECT 1 FROM information_schema.columns c
          WHERE c.table_schema = 'public'
            AND c.table_name  = v_sources[v_i][2]
            AND c.column_name = v_sources[v_i][3]) THEN
      v_missing := v_missing
                || format('%s.%s; ', v_sources[v_i][2], v_sources[v_i][3]);
    END IF;

    v_checked := v_checked + 1;
  END LOOP;

  -- A run that verified nothing must not report success. It did not: without
  -- this the function returned `ok:` having checked none of its twelve
  -- sources, which is a green answer about nothing.
  --
  -- If it fires, the likely cause is that this function cannot SEE
  -- `storage.buckets` -- the table has row-level security, and a caller that
  -- is not SECURITY DEFINER reads zero rows from it, so every `NOT EXISTS`
  -- is vacuously true and every source looks missing. The other possibility
  -- is that the list itself is unreadable, which is what 0134 found. Both
  -- produce a run that checked nothing; which one happened is answerable by
  -- asking `assert_app_buckets_exist()`, which reads the same table through
  -- a function that IS SECURITY DEFINER.
  IF v_checked = 0 THEN
    RAISE EXCEPTION
      'this assertion verified nothing: none of its %s sources could be checked. The most likely cause is that it cannot read storage.buckets under row-level security, which a non-SECURITY DEFINER function cannot do -- compare assert_app_buckets_exist(), which reads the same table. The other cause is an unreadable source list, which is what 20260927000134 was about.',
      coalesce(array_length(v_sources, 1), 0);
  END IF;

  IF v_missing <> '' THEN
    RAISE EXCEPTION
      'the account file sweep no longer matches the schema: %s. Each of these is read by account_storage_objects() at plan time, so a missing one would stop this migration from being applied or re-applied.', v_missing;
  END IF;

  RETURN format(
    'ok: %s sources verified, every bucket present, purge_account_storage is service_role only, and both functions exist', v_checked);
END;
$$;

-- The guards 0132 wrote, restated so this file is the whole truth about them.
REVOKE ALL ON FUNCTION public.assert_account_storage_is_purged()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_account_storage_is_purged()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';