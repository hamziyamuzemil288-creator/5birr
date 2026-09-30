-- Gallery reads, and the RPC a Google sign-in needs to finish its profile.
--
-- WHY THIS EXISTS
-- ---------------
-- Two separate defects, found by re-tracing the gallery from the tap rather
-- than from the migration that was supposed to have fixed it.
--
-- 1. THE GALLERY READ PATH WAS NEVER MIGRATED.
--    20260927000055 (provider_gallery_writes.sql) states, in its own header:
--
--      "READS STAY DIRECT -- SELECT was never revoked, and
--       provider_gallery_owner_read / provider_gallery_public_read already
--       scope it."
--
--    Both of those policies are defined in exactly one place: 0014
--    (and the 0021/0022 snapshots). 0014 is below the deploy baseline, so
--    `migration repair` marked it applied WITHOUT executing it. The write
--    side was rebuilt post-baseline as SECURITY DEFINER functions, so it
--    works. The read side was assumed rather than restated, so it does not.
--
--    The failure this produces is the quietest one in the app:
--      * the upload SUCCEEDS (add_gallery_image is SECURITY DEFINER, so it
--        bypasses both the revoked grant from 20260927000050 and any RLS),
--      * the row is written,
--      * the screen's own SELECT returns ZERO rows,
--      * the grid renders its empty state and the provider is told
--        "No photos yet" while their photos sit in the bucket.
--
--    Every previously-reported gallery failure was a WRITE-side or
--    storage-side story. The read side was never examined.
--
-- 2. GOOGLE SIGN-IN LEAVES A PROFILE THE APP CANNOT VERIFY.
--    handle_new_user() populates the profile entirely from
--    raw_user_meta_data:
--
--      full_name  -> COALESCE(metadata->>'full_name', 'New User')
--      phone      -> COALESCE(new.phone, metadata->>'phone')
--      city       -> COALESCE(NULLIF(metadata->>'city',''), default_city())
--      kebele     -> NULLIF(metadata->>'kebele', '')
--      street_road-> NULLIF(metadata->>'street_road', '')
--
--    The password flow passes all five through signUp(data:) -- see
--    AuthNotifier.signUp, whose doc comment says so explicitly. Google
--    supplies none of them, so an OAuth account lands with:
--
--      full_name  = 'New User'   (a placeholder, not a name)
--      phone      = NULL
--      kebele     = NULL
--      street_road= NULL
--      city       = the default city (a real value, so it hides the gap)
--
--    The user_documents INSERT is NOT what breaks: that table needs only
--    user_id, document_type and storage_path, so the upload succeeds. What
--    breaks is verification -- admin_user_management_screen.dart renders
--    `u['phone'] ?? ''` as a blank line and hides the national-ID row
--    entirely when it is null, so the reviewer is handed a document with no
--    identity to check it against. The account is unverifiable, not blocked.
--
--    complete_profile() below is the missing write. profiles is one of the
--    twenty tables the client may write, but its owner UPDATE policy is also
--    0014-only, so a direct client update would be refused for the same
--    baseline reason. Hence a SECURITY DEFINER function, self-scoped, with
--    the validation the signup form does on the client.
--
-- Nothing here loosens a policy. The gallery policies are restated exactly
-- as 0014/0021 defined them, and complete_profile() can only ever write the
-- caller's own row.

-- ===========================================================================
-- 1. What the live database actually has -- reported, not asserted
-- ===========================================================================
-- A reporting function rather than an assertion, deliberately: this one must
-- be able to answer "what was there" as well as "is it right now", so
-- Connectivity CI can print the inventory either way. The assertion below is
-- the one that fails the build.
CREATE OR REPLACE FUNCTION public.gallery_read_surface_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rls boolean;
  v_select int;
  v_all int;
  v_names text;
BEGIN
  SELECT c.relrowsecurity
    INTO v_rls
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'provider_gallery';

  -- A NULL here means the table itself is absent, which is a different
  -- failure from "the table is there and cannot be read". Say which.
  IF v_rls IS NULL THEN
    RETURN 'provider_gallery: ABSENT from public -- the table was never '
           || 'created by a migration the deploy workflow executes '
           || '(0013/0021/0022a are all pre-baseline)';
  END IF;

  SELECT count(*) FILTER (WHERE p.cmd = 'SELECT'),
         count(*) FILTER (WHERE p.cmd = 'ALL'),
         coalesce(string_agg(p.policyname::text, ', ' ORDER BY p.policyname::text), '(none)')
    INTO v_select, v_all, v_names
    FROM pg_policies p
   WHERE p.schemaname = 'public'
     AND p.tablename = 'provider_gallery';

  RETURN 'provider_gallery: present; RLS enabled=' || v_rls::text
         || '; SELECT policies=' || v_select::text
         || '; ALL policies=' || v_all::text
         || '; authenticated SELECT grant='
         || has_table_privilege('authenticated', 'public.provider_gallery', 'SELECT')::text
         || '; policies=[' || v_names || ']';
END;
$$;

COMMENT ON FUNCTION public.gallery_read_surface_report() IS
  'Prints the live RLS and grant inventory for provider_gallery. A report, not '
  'an assertion: it must be able to describe a broken database as well as a '
  'whole one. Reads pg_policies, which no client role can reach, so it is '
  'SECURITY DEFINER and granted to anon.';

-- ===========================================================================
-- 2. The read policies, restated where they will actually run
-- ===========================================================================
-- Taken from 0014 / the 0021 live snapshot, with the inner reference
-- qualified (the 0021 form) rather than left to scope resolution.
--
-- Wrapped in an existence check because this is the one statement in the
-- migration that can fail for a reason unrelated to its own correctness:
-- `DROP POLICY ... ON public.provider_gallery` raises "relation does not
-- exist" if the table was never created by a migration the pipeline ran, and
-- a transaction that aborts takes the rest of this file with it -- the RPC,
-- the report and both assertions. Whether the table is actually there is the
-- question this migration is trying to answer, so it must not be assumed
-- either way. The report above states it, and
-- assert_provider_can_read_their_own_gallery() fails loudly on it.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relname = 'provider_gallery'
  ) THEN
    DROP POLICY IF EXISTS provider_gallery_owner_read ON public.provider_gallery;
    CREATE POLICY provider_gallery_owner_read ON public.provider_gallery
      FOR SELECT
      USING (
        EXISTS (
          SELECT 1
            FROM public.provider_profiles pp
           WHERE pp.id = provider_gallery.provider_id
             AND pp.user_id = auth.uid()
        )
      );

    DROP POLICY IF EXISTS provider_gallery_public_read ON public.provider_gallery;
    CREATE POLICY provider_gallery_public_read ON public.provider_gallery
      FOR SELECT
      USING (
        is_active = true
        AND EXISTS (
          SELECT 1
            FROM public.provider_profiles pp
           WHERE pp.id = provider_gallery.provider_id
             AND pp.status = 'APPROVED'::account_status
        )
      );

    -- RLS is enabled in 0013/0021/0022a, all pre-baseline. Enabling it again
    -- is a no-op where it is already on and the fix where it is not; without
    -- it the owner read policy above is inert and every row is visible to
    -- every caller.
    ALTER TABLE public.provider_gallery ENABLE ROW LEVEL SECURITY;
  ELSE
    RAISE NOTICE
      'provider_gallery is absent from public; read policies not restated. '
      'gallery_read_surface_report() and '
      'assert_provider_can_read_their_own_gallery() will both say so.';
  END IF;
END;
$$;

-- The remaining three (insert/update/delete) are deliberately NOT restated.
-- 20260927000050 revoked client INSERT/UPDATE/DELETE on this table on
-- purpose, and the app writes through add_gallery_image / delete_gallery_image
-- instead. Restating owner write policies here would undo that decision and
-- re-open the surface 0050 closed -- and it would be dead code anyway, since
-- the grant is gone.

-- RLS is enabled in 0013/0021/0022a, all pre-baseline. Enabling it again is
-- a no-op where it is already on and the fix where it is not; without it the
-- owner read policy above is inert and every row is visible to every caller.
-- It is issued inside the existence check above, because naming a table that
-- is not there is an error rather than a no-op.

-- ===========================================================================
-- 3. The assertion that would have caught it
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_provider_can_read_their_own_gallery()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_rls boolean;
  v_select int;
BEGIN
  SELECT c.relrowsecurity
    INTO v_rls
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public'
     AND c.relname = 'provider_gallery';

  IF v_rls IS NULL THEN
    RAISE EXCEPTION
      'GALLERY_TABLE_MISSING: public.provider_gallery does not exist. The gallery screen reads it directly, so the screen cannot work and no policy can be the reason.';
  END IF;

  IF NOT v_rls THEN
    RAISE EXCEPTION
      'GALLERY_RLS_OFF: row level security is disabled on provider_gallery, so the owner read policy is inert and every gallery row is readable by any signed-in caller. Enable it.';
  END IF;

  SELECT count(*) INTO v_select
    FROM pg_policies p
   WHERE p.schemaname = 'public'
     AND p.tablename = 'provider_gallery'
     AND p.cmd IN ('SELECT', 'ALL');

  -- An empty list is the exact state this migration was written for, so the
  -- check cannot pass vacuously: zero IS the failure, not the success.
  IF v_select = 0 THEN
    RAISE EXCEPTION
      'GALLERY_UNREADABLE: provider_gallery has no SELECT policy, so the screen''s own query returns zero rows and a provider sees "No photos yet" after an upload that succeeded. The writes are SECURITY DEFINER and bypass RLS, which is why this presented as an upload problem rather than a read one.';
  END IF;

  IF NOT has_table_privilege('authenticated', 'public.provider_gallery', 'SELECT') THEN
    RAISE EXCEPTION
      'GALLERY_NO_SELECT_GRANT: the policies are correct but the authenticated role cannot SELECT the table, so PostgREST refuses the read regardless of RLS.';
  END IF;

  RETURN 'ok: a provider can read their own gallery (RLS on, '
         || v_select::text || ' SELECT/ALL policy/policies, authenticated holds SELECT)';
END;
$$;

COMMENT ON FUNCTION public.assert_provider_can_read_their_own_gallery() IS
  'Fails when a provider cannot read their own gallery rows. Exists because '
  'assert_client_buckets_have_write_and_read_policies() inspects '
  'storage.objects and says nothing about the TABLE the rows live in -- the '
  'gap that let a working upload path sit behind a read that returns nothing.';

-- ===========================================================================
-- 4. complete_profile -- the write a Google account is missing
-- ===========================================================================
-- Self-scoped by construction: the target row is auth.uid(), never a
-- parameter, so there is no id for a caller to point at somebody else.
CREATE OR REPLACE FUNCTION public.complete_profile(
  p_full_name text,
  p_phone text,
  p_city text,
  p_kebele text,
  p_street_road text
)
RETURNS public.profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.profiles;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  -- The same rules the signup form enforces, enforced here as well: a client
  -- validation is a courtesy, and this row is what an admin verifies against.
  IF p_full_name IS NULL OR btrim(p_full_name) = '' THEN
    RAISE EXCEPTION 'FULL_NAME_REQUIRED';
  END IF;
  IF length(btrim(p_full_name)) < 2 THEN
    RAISE EXCEPTION 'FULL_NAME_TOO_SHORT';
  END IF;
  IF p_phone IS NULL OR btrim(p_phone) = '' THEN
    RAISE EXCEPTION 'PHONE_REQUIRED';
  END IF;
  IF p_kebele IS NULL OR btrim(p_kebele) = '' THEN
    RAISE EXCEPTION 'KEBELE_REQUIRED';
  END IF;
  IF p_street_road IS NULL OR btrim(p_street_road) = '' THEN
    RAISE EXCEPTION 'STREET_ROAD_REQUIRED';
  END IF;

  UPDATE public.profiles
     SET full_name   = btrim(p_full_name),
         phone       = btrim(p_phone),
         city        = coalesce(NULLIF(btrim(coalesce(p_city, '')), ''), city),
         kebele      = btrim(p_kebele),
         street_road = btrim(p_street_road),
         updated_at  = now()
   WHERE id = auth.uid()
   RETURNING * INTO v_row;

  -- ON CONFLICT DO NOTHING in the trigger means an OAuth account can exist in
  -- auth.users with no profile row at all. Creating it here is the only thing
  -- that makes the rest of the app work for that account.
  IF v_row.id IS NULL THEN
    INSERT INTO public.profiles (id, full_name, phone, email, status, city, kebele, street_road)
    VALUES (
      auth.uid(),
      btrim(p_full_name),
      btrim(p_phone),
      (SELECT a.email FROM auth.users a WHERE a.id = auth.uid()),
      'PENDING_APPROVAL'::account_status,
      coalesce(NULLIF(btrim(coalesce(p_city, '')), ''), public.default_city()),
      btrim(p_kebele),
      btrim(p_street_road)
    )
    ON CONFLICT (id) DO UPDATE
      SET full_name   = excluded.full_name,
          phone       = excluded.phone,
          kebele      = excluded.kebele,
          street_road = excluded.street_road,
          updated_at  = now()
      RETURNING * INTO v_row;
  END IF;

  RETURN v_row;
END;
$$;

COMMENT ON FUNCTION public.complete_profile(text, text, text, text, text) IS
  'Writes the profile fields an OAuth sign-up never supplies (phone, kebele, '
  'street_road, real full_name). Self-scoped: the row is auth.uid() and there '
  'is no id parameter. SECURITY DEFINER because profiles owner UPDATE is 0014 '
  'only, and the client write surface 0050 closed leaves no grant to rely on.';

REVOKE ALL ON FUNCTION public.complete_profile(text, text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.complete_profile(text, text, text, text, text) TO authenticated;

-- ===========================================================================
-- 5. The assertion for the profile gap
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_profile_completion_is_wired()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_args text;
  v_dollar text;
BEGIN
  -- The signature, not the name: a same-named function with different
  -- parameters would satisfy a name-only needle and the client would still
  -- get "function does not exist" at runtime.
  SELECT p.proargnames::text INTO v_args
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'complete_profile';

  IF v_args IS NULL THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_MISSING: public.complete_profile does not exist, so an OAuth account can never fill in the phone and address the verification step needs.';
  END IF;

  IF v_args <> 'full_name,phone,city,kebele,street_road' THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_SIGNATURE: public.complete_profile takes (%), not (full_name,phone,city,kebele,street_road). The client calls it with those five names; a rename here is a runtime failure for every OAuth sign-in.',
      v_args;
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.complete_profile(text,text,text,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_NOT_GRANTED: the authenticated role cannot EXECUTE complete_profile, so the "Complete your profile" screen is unreachable.';
  END IF;

  -- The trap this function must not walk into: it may only ever write the
  -- caller's own row. A body that names a second table in an UPDATE or
  -- INSERT is the shape that would let one account edit another's identity.
  SELECT p.prosrc INTO v_dollar
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'complete_profile'
     AND p.pronargs = 5;

  IF v_dollar IS NULL THEN
    RAISE EXCEPTION 'PROFILE_COMPLETION_MALFORMED: the 5-argument complete_profile is not defined.';
  END IF;

  IF v_dollar !~ '(?i)UPDATE\s+public\.profiles' THEN
    RAISE EXCEPTION
      'PROFILE_COMPLETION_MALFORMED: complete_profile no longer updates public.profiles.';
  END IF;

  RETURN 'ok: complete_profile(text,text,text,text,text) exists, is executable '
         || 'by authenticated, and updates the caller''s own profiles row';
END;
$$;

COMMENT ON FUNCTION public.assert_profile_completion_is_wired() IS
  'The SQL half of the OAuth profile-completion gap: the RPC exists, with the '
  'signature the client calls, and is executable by authenticated. Without it '
  'a Google account stays phone-less and the admin who must verify it has '
  'nothing to check.';

-- ===========================================================================
-- 6. Grants, cache reload
-- ===========================================================================
GRANT EXECUTE ON FUNCTION public.gallery_read_surface_report() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_provider_can_read_their_own_gallery() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.assert_profile_completion_is_wired() TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.gallery_read_surface_report() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_provider_can_read_their_own_gallery() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.assert_profile_completion_is_wired() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
