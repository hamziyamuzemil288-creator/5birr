-- A person can set a BUSINESS photo and still have no way to set their own face.
--
-- WHAT EXISTED
-- ------------
-- `provider-photos` (20260927000106) holds the shop/driver photo on
-- `provider_profiles.photo_storage_path`. That is the business card on the public
-- provider page. It is not the user's own profile picture, and there has never
-- been a way to set one:
--
--   * `lib/features/user/user_profile_screen.dart` contains no image code at all
--     -- no picker, no avatar, no `Image.network`;
--   * `lib/features/user/edit_profile_screen.dart` has no upload either;
--   * no bucket exists for it. The seven live buckets are user-documents,
--     payment-screenshots, payment-proofs, product-images, provider-gallery,
--     vehicle-images, provider-photos. None of them is an avatar bucket.
--
-- So "change my profile picture" is not broken, it is absent: there is no
-- control to press. The column that would hold it does not exist either.
--
-- WHY A NEW BUCKET AND NOT `provider-photos`
-- ------------------------------------------
-- Different lifetimes and different audiences. `provider-photos` is written by
-- providers for the public provider page and is readable by anyone. An avatar
-- is written by EVERY signed-in person, is replaced constantly, and is
-- displayed next to their name wherever they appear -- reviews, chat, order
-- history. Reusing one bucket would put a per-user write path on a bucket whose
-- policies were written and asserted for a different purpose, and the storage
-- policy names would then be lying about what they guard.
--
-- Mirrors 20260927000106 exactly: public bucket, 5MB, jpeg/png/webp only, and
-- the write policies scoped on the first path segment being the caller's uid.
-- That is also why the client path below must start with the caller's own uid --
-- it is the whole authorisation.
--
-- WHY `avatar_storage_path` AND NOT REUSING `profiles.avatar_url`
-- ---------------------------------------------------------------
-- `avatar_url` appears in the schema and is written by the OAuth signup path as
-- a remote URL. This column is a storage path in OUR bucket, signed or public
-- by the same rules as every other image, and it is the one the RLS policy
-- above actually governs. Two columns with two meanings would be one column
-- too many to keep straight, and the remote-URL one cannot be validated by a
-- storage policy at all.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('profile-avatars', 'profile-avatars', true, 5242880,
        ARRAY['image/jpeg', 'image/png', 'image/webp'])
ON CONFLICT (id) DO UPDATE
  SET public             = EXCLUDED.public,
      file_size_limit    = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- The column comes FIRST. The comment used to sit above this block, which is
-- fine on a database that already has the column and fatal on one that does
-- not:
--
--   ERROR: column "avatar_storage_path" of relation "public.profiles" does
--          not exist
--
-- Every other run of this file found the column already present -- because the
-- comment itself was what created it in an earlier draft -- so the order was
-- never exercised against the case it exists for.
DO $$
BEGIN
  IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'profiles'
           AND column_name = 'avatar_storage_path') THEN
    ALTER TABLE public.profiles ADD COLUMN avatar_storage_path text;
  END IF;
END;
$$;

COMMENT ON COLUMN public.profiles.avatar_storage_path IS
  'Path of this user''s own profile picture inside the public profile-avatars '
  'bucket. Written only through that bucket''s storage policies, which scope '
  'the first path segment on auth.uid(). NULL means no picture.';

-- ---------------------------------------------------------------------------
-- The policies
-- ---------------------------------------------------------------------------
-- `string_to_array(name, '/')[1]` is the caller's uid for a path built as
-- `<uid>/avatar/<ts>/<file>`. It is the same expression 20260927000106 uses, and
-- the same reason: it is the only part of the path the client controls that we
-- can tie to an identity, so the client must build the prefix, not the server.
DROP POLICY IF EXISTS profile_avatars_insert ON storage.objects;
CREATE POLICY profile_avatars_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'profile-avatars'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- The bucket is public, so a signed-out customer can render the avatar on a
-- review or a provider page. That is the point: it is a picture of a face next
-- to a name, not a document.
DROP POLICY IF EXISTS profile_avatars_public_read ON storage.objects;
CREATE POLICY profile_avatars_public_read ON storage.objects
  FOR SELECT
  USING (bucket_id = 'profile-avatars');

-- Replacing a picture must not orphan the old object forever, and the same
-- scoping applies: you may only write inside your own folder.
DROP POLICY IF EXISTS profile_avatars_update_own ON storage.objects;
CREATE POLICY profile_avatars_update_own ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'profile-avatars'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  )
  WITH CHECK (
    bucket_id = 'profile-avatars'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS profile_avatars_delete_own ON storage.objects;
CREATE POLICY profile_avatars_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'profile-avatars'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- Index the path we read on every profile load.
CREATE INDEX IF NOT EXISTS idx_profiles_avatar_storage_path
  ON public.profiles (avatar_storage_path)
  WHERE avatar_storage_path IS NOT NULL;

-- ---------------------------------------------------------------------------
-- The write closure
-- ---------------------------------------------------------------------------
-- Nothing to restate here, and that is worth being explicit about.
--
-- `client_write_policy_detail()` (20260927000047) reports every client-writable
-- RLS policy on every public table and judges each one WIDE or scoped; it takes
-- NO column list. `assert_client_write_surface_is_closed()` fails when a policy
-- is WIDE. So adding a column to a table that already carries a scoped UPDATE
-- policy needs no declaration at all -- the new column is covered by the policy
-- that is already there.
--
-- 20260927000106 *did* have to restate a function, and the temptation here is to
-- do the same thing to `client_write_policy_detail()`. Do not: a restatement
-- written from a description rather than from the deployed body replaces a
-- seven-column LANGUAGE sql function with something else, and the write-closure
-- assertion silently stops being the write-closure assertion.

-- ---------------------------------------------------------------------------
-- Do not let it go red later
-- ---------------------------------------------------------------------------
-- The photo surface has been asserted before and the assertion drifted, so this
-- one is stated as the properties rather than as today's values: the bucket
-- exists, it is public, the owner-write policy names both the bucket and the
-- caller's own folder, and the column is where the client says it is.
--
-- The policy checks read `pg_get_expr` rather than trying to walk
-- `pg_node_tree`: `qual` and `with_check` are parse trees, not arrays, and
-- `unnest()` on one is a runtime error inside a function the connectivity suite
-- is about to call.
--
-- They name the columns as `pg_policies` spells them -- `qual`, not `polqual`.
-- `polqual` belongs to the `pg_policy` CATALOG; the VIEW exposes `qual`, and
-- on every version, Supabase's included. Naming the catalog's spelling is how
-- this function got to
--
--   ERROR: column "polqual" does not exist
--
-- which the local PostgreSQL 14 scratch cluster caught before the deploy did.
CREATE OR REPLACE FUNCTION public.assert_profile_avatar_surface()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  -- `pg_policies` is a VIEW whose `qual` and `with_check` columns ARE ALREADY
  -- the deparsed expression text -- the view is defined as
  -- `pg_get_expr(polqual, polrelid) AS qual`. So there is nothing to call
  -- `pg_get_expr` on, and the catalog's own names are not columns here at all:
  --
  --   ERROR: column "polqual" does not exist
  --   ERROR: column "polrelid" does not exist
  --   ERROR: function pg_get_expr(text, regclass) does not exist
  --
  -- COALESCE because an INSERT policy carries its test in `with_check` and
  -- leaves `qual` NULL; reading `qual` alone reports that no insert policy
  -- exists when one plainly does.
  v_bucket  boolean;
  v_public  boolean;
  v_column  boolean;
  v_insert  text;
  v_update  text;
  v_scoped  int;
BEGIN
  SELECT true, b.public INTO v_bucket, v_public
    FROM storage.buckets b WHERE b.id = 'profile-avatars';
  IF NOT COALESCE(v_bucket, false) THEN
    RAISE EXCEPTION 'profile avatar surface: the profile-avatars bucket is missing';
  END IF;
  IF NOT COALESCE(v_public, false) THEN
    RAISE EXCEPTION 'profile avatar surface: profile-avatars is not public, so a '
      'signed-out customer cannot render an avatar next to a review or a provider name';
  END IF;

  SELECT true INTO v_column
    FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'profiles'
     AND column_name = 'avatar_storage_path';
  IF NOT COALESCE(v_column, false) THEN
    RAISE EXCEPTION 'profile avatar surface: profiles.avatar_storage_path is missing';
  END IF;

  SELECT COALESCE(qual, with_check) INTO v_insert
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'profile_avatars_insert';
  IF v_insert IS NULL THEN
    RAISE EXCEPTION 'profile avatar surface: no insert policy exists, so nobody can upload an avatar';
  END IF;
  IF v_insert NOT ILIKE '%auth.uid()%' OR v_insert NOT ILIKE '%profile-avatars%' THEN
    RAISE EXCEPTION 'profile avatar surface: the insert policy no longer ties the write to the '
      'caller''s own folder -- it reads as: %', v_insert;
  END IF;

  SELECT COALESCE(qual, with_check) INTO v_update
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'profile_avatars_update_own';
  IF v_update IS NULL OR v_update NOT ILIKE '%auth.uid()%' THEN
    RAISE EXCEPTION 'profile avatar surface: replacing an avatar is not scoped to the owner';
  END IF;

  -- Every write policy on the bucket must be scoped. A single unscoped one is
  -- enough to let any signed-in account write into anybody else's folder, and
  -- that is the property worth counting rather than the policy count.
  SELECT count(*) INTO v_scoped
    FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname LIKE 'profile_avatars_%'
     AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
     AND COALESCE(qual, with_check) ILIKE '%auth.uid()%';
  IF v_scoped < 3 THEN
    RAISE EXCEPTION 'profile avatar surface: only %s of the three write policies on '
      'profile-avatars are scoped to the caller, so the others let anybody write '
      'into anybody''s folder', v_scoped;
  END IF;

  RETURN 'ok: bucket public, column present, all three write policies owner-scoped';
END;
$$;

REVOKE ALL ON FUNCTION public.assert_profile_avatar_surface() FROM PUBLIC;
-- anon too: the connectivity suite runs as anon, and a diagnostic the reading
-- role cannot call answers PGRST202, which is indistinguishable from a
-- migration that was never applied.
GRANT EXECUTE ON FUNCTION public.assert_profile_avatar_surface()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
