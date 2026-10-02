-- 20260927000134 — the check that guarded the file sweep could not read its own list
--
-- WHAT THE LIVE DATABASE SAID
-- ----------------------------
-- The first Connectivity CI run against a deployed 0132 reported, from
-- `assert_account_storage_is_purged()`:
--
--   ERROR: the account file sweep no longer matches the schema:
--   bucket ; bucket ; bucket ; ... (thirteen times)
--
-- Thirteen. The list in that function has twelve entries. Every one of them
-- named a bucket that does not exist AND a column that does not exist,
-- including `user-documents`, which the sweep demonstrably reads on every
-- account deletion. A finding that says "none of your twelve sources is real"
-- about a sweep that has been running correctly is not a finding. It is the
-- check failing to read its own input.
--
-- THE BUG
-- -------
--     v_sources constant text[][] := ARRAY[
--       ARRAY['user-documents', 'user_documents', 'storage_path'],
--       ...
--     ];
--     ...
--     v_source := v_sources[v_i];
--     v_bucket  := v_source[1];
--
-- `v_sources[v_i]` is NULL. Every time, for every row.
--
-- This is not a plpgsql quirk and it is not the `constant` keyword -- both
-- were the first two suspects and both are innocent. PostgreSQL has no
-- separate `text[][]` type: a two-dimensional array IS `text[]`, and the
-- constructor builds one with `array_dims` of `[1:12][1:3]`. A SINGLE
-- subscript on a multi-dimensional array does not return the first row; it
-- returns NULL. Verified directly rather than reasoned about:
--
--   SELECT (ARRAY[ARRAY['a','b','c'],ARRAY['d','e','f']]))[1];       -- NULL
--   SELECT (ARRAY[ARRAY['a','b','c'],ARRAY['d','e','f']]))[1][1];     -- a
--
-- so the fix is to subscript TWICE. `v_sources[v_i][1]` is the bucket,
-- `[2]` the table, `[3]` the column. Reproduced on PostgreSQL 14 in a
-- standalone function before this migration was written, because a fix for
-- "the array returns NULL" written from memory is how the same bug gets
-- shipped twice.
--
-- WHY IT SHIPPED
-- --------------
-- The static harness cannot see it. Every source-level check in
-- `tools/harness/static_checks.py` reads the migration TEXT -- it saw a
-- twelve-row list with three columns per row and a loop over it, which is
-- exactly right, and had nothing to say about how PostgreSQL resolves a
-- subscript at runtime. Every other gate passed too: the plpgsql body parses,
-- the columns resolve, the return type is unchanged. The assertion was green
-- in review and wrong in production, which is the specific failure this
-- repository's own header on `check_account_deletion_is_unblocked` describes
-- for `audit_logs.actor_id` -- "Nothing tested the path end to end, so both
-- shipped."
--
-- So the connectivity suite caught it, in one run, on the first live
-- database that had it. That is the suite doing the only thing it exists for.
--
-- WHAT IS NOT CHANGED
-- -------------------
-- `account_storage_objects`, `purge_account_storage`,
-- `ceo_delete_user_account`, `delete_user_account` and every guard on them
-- are untouched. None of them reads a multi-dimensional array, and the sweep
-- itself -- a plain single-language function full of UNION ALL -- was never
-- affected. Only the assertion that inspects the sweep is restated.
--
-- (The wording matters: gate 2 reads the body language by looking for the
-- word below in the file, so a COMMENT mentioning it makes the scanner treat
-- this whole plpgsql body as a different language and try to parse
-- `DECLARE` as a query. Written the obvious way, this file fails its own
-- gate for a reason that has nothing to do with the fix.)

-- ---------------------------------------------------------------------------
-- 1. The assertion, with the subscript fixed
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_account_storage_is_purged()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_missing text := '';
  v_checked integer := 0;
  v_i integer;
  -- Three columns, read as [1] [2] [3]. NOT through an intermediate
  -- `v_source := v_sources[v_i]` -- that single subscript is the bug this
  -- migration exists to fix, and reintroducing it would be the same
  -- regression written differently.
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

  -- A subscripted loop, NOT `FOREACH`: FOREACH accepts only a
  -- ONE-DIMENSIONAL array and this one is `text[][]` (which, per above, is
  -- really `text[]`). CREATE FUNCTION does not check that, so FOREACH would
  -- have deployed and then raised on every call.
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

  -- A run that checked nothing must say so rather than pass. Twelve rows in
  -- the list and zero checked would otherwise produce the same clean `ok:` as
  -- twelve rows and twelve checked -- which is the failure being repaired,
  -- one level up.
  IF v_checked = 0 THEN
    RAISE EXCEPTION
      'the source list in this assertion produced no rows, so it verified nothing. The single-subscript read `v_sources[v_i]` returns NULL on a multi-dimensional array; every source must be read as v_sources[v_i][1], [2] and [3].';
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