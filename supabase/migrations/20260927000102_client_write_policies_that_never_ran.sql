-- 20260927000102_client_write_policies_that_never_ran.sql
--
-- Money and document uploads were refused in production, and neither one was
-- caused by the Dart code that performs them.
--
-- WHAT BOTH FAILURES ACTUALLY ARE
-- ==============================
--
--   wallet recharge -- "Sorry, we couldn't submit your recharge. That item
--     could not be found. It may have been removed." That is
--     friendly_error.dart's sentence for a `not found`-class error, and
--     recharge_screen.dart can raise it three ways: a missing provider
--     profile, a missing wallet, or an insert that returns no row. All three
--     render the same sentence, which is why the report said "the item could
--     not be found" about an upload that was never the problem.
--
--   document upload -- refused by storage before any row was written.
--
-- The common cause is not in either screen. It is that the policies both
-- flows depend on were only ever declared in migrations the deploy pipeline
-- marks applied WITHOUT executing.
--
-- WHY THE POLICIES ARE NOT THERE
-- ------------------------------
-- `.github/workflows/deploy-supabase.yml` has a `Baseline migration history`
-- step that runs `supabase migration repair --status applied` for every staged
-- file whose version is below 20260919000000. Its own comment says the step
-- "never executes the files", on the stated assumption that "their effects
-- are already in the live DB (pasted via SQL editor)".
--
-- That assumption has now been falsified twice inside this repo, by this
-- repo's own migrations:
--
--   * 20260927000096 -- `provider-gallery` is declared in 0017 and the bucket
--     did not exist; every gallery upload failed with "Bucket not found". Its
--     section 2 heading reads "0017 created them; it never executed either".
--   * 0033 -- exists "precisely because the buckets 0012 declared were
--     missing".
--
-- So "this policy exists in a migration" and "this policy exists in the
-- database" are different questions, and for the ones below the answer to the
-- second one is no.
--
--   storage.objects, bucket `user-documents`
--     INSERT / SELECT / DELETE are declared only in 0012_storage_policies.sql
--     (version 0012 < the baseline). 0033 declared replacements under the
--     names "user-documents_owner_insert" / "..._owner_or_admin_read", and 0033
--     is also below the baseline. 20260927000042 then ran
--       DROP POLICY IF EXISTS "user-documents_owner_insert" ON storage.objects
--     -- a no-op against a database where it had never existed -- and created
--     only `user_documents_update_own`. Its header comment reasons that
--     "user-documents and payment-proofs keep their 0012 policies". That is
--     the exact assumption being wrong: 0012 never ran.
--
--   storage.objects, bucket `payment-proofs`
--     The same shape. 00042 created UPDATE and DELETE, and left INSERT and
--     SELECT to 0012.
--
--   public.wallets
--     `wallets_owner_read` USING (owns_provider_profile(provider_id) OR
--     is_admin()) is declared in 0009, 0021, 0022 and 0022b -- all below the
--     baseline. The only policy any executed migration creates is
--     `wallets_staff_read` (20260922000010), which is STAFF-scoped. An
--     ordinary provider is therefore evaluated against a policy that only a
--     staff member can satisfy, the select returns zero rows, and
--     `maybeSingle()` yields null.
--
--   public.wallet_recharge_requests
--     `recharge_requests_provider_insert` and `..._read_own` are declared only
--     below the baseline. The only executed-migration policy is
--     `wallet_recharge_requests_staff_read` (20260922000010), also staff-scoped.
--
-- WHY NOTHING CAUGHT IT
-- ---------------------
--   * assert_private_buckets_are_owner_scoped (00042) inspects the policies
--     that EXIST. A bucket with no policies at all passes it vacuously --
--     00096 names this exact hole at its own lines 30-36.
--   * assert_app_buckets_exist (00096) reads storage.buckets, so it checks
--     that a bucket is there and correctly visible. It says nothing about who
--     may write to it.
--   * the connectivity suite drives `assert_document_liveness_is_wired`, which
--     checks `policyname = 'user_documents_insert_own'` -- a policy on the
--     user_documents TABLE. The policy that governs the UPLOAD is a different
--     policy, on storage.objects, and nothing inspected it.
--   * the suite authenticates as anon and, for the write tests, as
--     service_role. Both bypass RLS, so even the policies that do exist are
--     never exercised from the role that is actually refused.
--
-- WHAT THIS MIGRATION DOES
-- ------------------------
-- Restates every policy above, using the exact expressions the live,
-- WORKING `payment_screenshots_*` policies use (00042) -- the shape that has
-- been proven against a real bucket rather than copied from a file that never
-- ran. Idempotent: DROP IF EXISTS then CREATE, in one transaction, which is
-- the pattern 00048 and 00096 use for the same reason.
--
-- No policy is widened. Each restated policy is the one the app's own code
-- requires: the object name's first path segment is the caller's uid, which is
-- what document_upload_service.dart:98, wallet_service.dart and
-- provider_gallery_screen.dart all write.
--
-- RLS enablement is deliberately NOT changed. Whether `wallets` currently has
-- RLS switched on is something only the live database can answer, and turning
-- it on from a migration whose policy set is inferred would be a guess with a
-- balance attached. The new assertion reports the state instead.

-- ===========================================================================
-- 1. storage.objects -- the private buckets whose policies live only in 0012
-- ===========================================================================
-- Expression shape, identical to payment_screenshots_insert (00042:93-99):
--   auth.uid()::text = (string_to_array(name, '/'))[1]
-- `name` is the object name INSIDE the bucket -- the 00042 header is explicit
-- that a path carrying the bucket prefix fails this check -- and the Dart
-- uploaders all write '{auth uid}/{...}'.

-- --------------------------------------------------------------- documents
DROP POLICY IF EXISTS user_documents_insert ON storage.objects;
CREATE POLICY user_documents_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'user-documents'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS user_documents_select_own ON storage.objects;
CREATE POLICY user_documents_select_own ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS user_documents_admin_read ON storage.objects;
CREATE POLICY user_documents_admin_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND public.is_admin()
  );

DROP POLICY IF EXISTS user_documents_delete_own ON storage.objects;
CREATE POLICY user_documents_delete_own ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'user-documents'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

-- ---------------------------------------------------------- payment proofs
DROP POLICY IF EXISTS payment_proofs_insert ON storage.objects;
CREATE POLICY payment_proofs_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'payment-proofs'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_proofs_select_own ON storage.objects;
CREATE POLICY payment_proofs_select_own ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'payment-proofs'
    AND auth.uid()::text = (string_to_array(name, '/'))[1]
  );

DROP POLICY IF EXISTS payment_proofs_admin_read ON storage.objects;
CREATE POLICY payment_proofs_admin_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'payment-proofs'
    AND public.is_admin()
  );

-- payment_proofs_update_own / payment_proofs_delete_own were created by 00042
-- and are deliberately left alone.

-- ===========================================================================
-- 2. public -- the money tables whose owner policies live only in 0009/0022
-- ===========================================================================
-- `public.owns_provider_profile()` rather than an inline subquery over
-- provider_profiles. The helper is SECURITY DEFINER (0011:81-90) and granted
-- to authenticated (0011:49), and it is already what wallets_owner_read used.
-- An inline `IN (SELECT id FROM provider_profiles ...)` would be evaluated
-- under provider_profiles' own RLS, so a future tightening of that table's
-- SELECT policy would silently break the recharge screen again. This cannot.

-- ---------------------------------------------------------------------------
-- 2a. wallets -- the provider reading their own balance
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS wallets_owner_read ON public.wallets;
CREATE POLICY wallets_owner_read ON public.wallets
  FOR SELECT TO authenticated
  USING (public.owns_provider_profile(provider_id) OR public.is_admin());

-- ---------------------------------------------------------------------------
-- 2b. wallet_recharge_requests -- submitting and listing a recharge
-- ---------------------------------------------------------------------------
-- The INSERT is what makes the whole thing work, and it is the half that
-- matters for the reported failure: without it PostgREST refuses the insert
-- outright, and WITH the insert succeeding but the RETURNING representation
-- filtered away by a missing SELECT policy, `.insert().select().single()`
-- raises PGRST116 -- the same sentence the screen was already showing.
DROP POLICY IF EXISTS recharge_requests_provider_insert
  ON public.wallet_recharge_requests;
CREATE POLICY recharge_requests_provider_insert
  ON public.wallet_recharge_requests
  FOR INSERT TO authenticated
  WITH CHECK (public.owns_provider_profile(provider_id));

DROP POLICY IF EXISTS recharge_requests_provider_read_own
  ON public.wallet_recharge_requests;
CREATE POLICY recharge_requests_provider_read_own
  ON public.wallet_recharge_requests
  FOR SELECT TO authenticated
  USING (public.owns_provider_profile(provider_id));

-- recharge_requests_admin_all (0009:110) is intentionally NOT restated here.
-- It is an admin policy that has never run either, but widening the migration
-- to restore admin access to the recharge queue is a separate change with a
-- separate blast radius, and the admin path already goes through
-- approve_wallet_recharge() / reject_wallet_recharge(), which are SECURITY
-- DEFINER and unaffected by RLS.

-- ===========================================================================
-- 3. The assertion that was missing: a bucket nobody can write to
-- ===========================================================================
-- assert_private_buckets_are_owner_scoped (00042) inspects the policies that
-- exist and is silent when there are none. This one asks the question that
-- actually matters for an upload: is there ANY policy under which this bucket
-- accepts a write, and any under which it answers a read?
CREATE OR REPLACE FUNCTION public.assert_client_buckets_have_write_and_read_policies()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Every bucket the Flutter client writes to or reads from. This is the list
  -- migration 0096 declares as authoritative, plus vehicle_images (0097). It
  -- is spelled out here rather than derived, because a check that derives its
  -- own subject list from the thing it is checking cannot report a missing
  -- bucket.
  v_buckets text[] := ARRAY[
    'user-documents', 'payment-screenshots', 'payment-proofs',
    'product-images', 'provider-gallery', 'vehicle-images'
  ];
  v_bucket text;
  v_write int;
  v_read int;
  v_missing text;
  v_checked int := 0;
  v_report text := '';
BEGIN
  FOREACH v_bucket IN ARRAY v_buckets LOOP
    v_checked := v_checked + 1;

    -- A policy counts for this bucket only if its text actually NAMES the
    -- bucket. pg_policies spans every schema and carries a policy per
    -- (table, command), so an unqualified count would pass on a policy
    -- belonging to a different bucket entirely -- which is the copy-paste
    -- 00042 removed from three policies.
    SELECT count(*) FILTER (WHERE p.cmd IN ('INSERT', 'ALL')),
           count(*) FILTER (WHERE p.cmd IN ('SELECT', 'ALL'))
      INTO v_write, v_read
      FROM pg_policies p
     WHERE p.schemaname = 'storage'
       AND p.tablename = 'objects'
       AND (coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
           LIKE '%' || v_bucket || '%';

    IF v_write = 0 OR v_read = 0 THEN
      RAISE EXCEPTION
        'BUCKET_NOT_WRITABLE: the % bucket has % write policy/policies and % read policy/policies, so %s. A bucket with no INSERT policy fails every upload with "new row violates row-level security policy for table objects", and one with no SELECT policy fails every signed-URL fetch. Both look like a broken screen and neither is.',
        v_bucket, v_write, v_read,
        CASE
          WHEN v_write = 0 AND v_read = 0 THEN 'it can be neither written nor read'
          WHEN v_write = 0 THEN 'every upload to it is refused'
          ELSE 'every read of it is refused'
        END;
    END IF;

    v_report := v_report || v_bucket || ': ' || v_write || 'w/' || v_read || 'r; ';
  END LOOP;

  -- A loop that read no bucket reports success without having looked at
  -- anything, which is how a diagnostic becomes a rubber stamp.
  IF v_checked <> array_length(v_buckets, 1) THEN
    RAISE EXCEPTION
      'BUCKET_POLICY_CHECK_VACUOUS: checked % of % buckets, so a bucket with no policies was never examined',
      v_checked, array_length(v_buckets, 1);
  END IF;

  RETURN 'ok: all ' || v_checked::text
         || ' storage bucket(s) lib/ uses have at least one write policy and '
         || 'one read policy (' || rtrim(v_report) || ')';
END;
$$;

COMMENT ON FUNCTION public.assert_client_buckets_have_write_and_read_policies() IS
  'Every bucket the Flutter client writes to must have at least one INSERT '
  'policy and at least one SELECT policy on storage.objects, counted only '
  'from policies that name that bucket. Exists because '
  'assert_private_buckets_are_owner_scoped() inspects the policies that EXIST '
  'and therefore passes vacuously on a bucket with none -- which is how '
  'user-documents and payment-proofs ended up with an UPDATE policy and '
  'nothing else, while assert_app_buckets_exist() reported every bucket '
  'healthy. Reads pg_policies, which no client role can reach, so it is '
  'SECURITY DEFINER and granted to anon.';

-- ===========================================================================
-- 4. The same question for the two money tables
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_owner_can_read_and_write_their_money()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- table -> the commands an ordinary (non-staff) provider must be able to
  -- perform on their own row. A policy only counts if it names the caller:
  -- `wallets_staff_read` exists on wallets and satisfies nobody but staff,
  -- which is precisely why the recharge screen found no wallet.
  v_needed text[][] := ARRAY[
    ARRAY['wallets', 'SELECT'],
    ARRAY['wallet_recharge_requests', 'INSERT'],
    ARRAY['wallet_recharge_requests', 'SELECT']
  ];
  -- A 2-D array cannot be walked with FOREACH: plpgsql refuses an array-typed
  -- loop variable at RUN time (42804), CREATE FUNCTION does not catch it, so
  -- the function deploys green and then raises on every call. Subscripted
  -- FOR, which the notification assertions (migrations 94/95) already forced.
  v_i int;
  v_row text[];
  v_table text;
  v_cmd text;
  v_found int;
  v_rls boolean;
  v_report text := '';
  v_checked int := 0;
BEGIN
  FOR v_i IN 1 .. array_length(v_needed, 1) LOOP
    v_row := v_needed[v_i];
    v_table := v_row[1];
    v_cmd := v_row[2];
    v_checked := v_checked + 1;

    SELECT c.relrowsecurity INTO v_rls
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname = v_table;
    IF NOT FOUND THEN
      RAISE EXCEPTION
        'MONEY_TABLE_MISSING: public.% does not exist, so the client path that queries it fails', v_table;
    END IF;

    -- Names the caller: auth.uid() or the SECURITY DEFINER ownership helper.
    -- Deliberately NOT is_admin() and NOT a staff permission check -- a
    -- provider is neither, and that is the entire bug.
    SELECT count(*) INTO v_found
      FROM pg_policies p
     WHERE p.schemaname = 'public'
       AND p.tablename = v_table
       AND p.cmd IN (v_cmd, 'ALL')
       AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
           ~ '(auth\.uid|owns_provider_profile)';

    IF v_found = 0 THEN
      RAISE EXCEPTION
        'MONEY_ROUTE_CLOSED: public.% has no % policy that names the caller, so a signed-in provider gets zero rows / a refused write. The wallet and recharge screens read and write exactly this, and the failure surfaces to the user as "That item could not be found" because the client throws its own not-found on an empty result.',
        v_table, v_cmd;
    END IF;

    IF NOT v_rls THEN
      RAISE EXCEPTION
        'MONEY_TABLE_RLS_OFF: row level security is DISABLED on public.%, so any role holding the grant reads every provider''s balance and every provider''s recharge requests. A policy on such a table is decorative.',
        v_table;
    END IF;

    v_report := v_report || v_table || ':' || v_cmd || ' ok; ';
  END LOOP;

  IF v_checked <> array_length(v_needed, 1) THEN
    RAISE EXCEPTION
      'MONEY_POLICY_CHECK_VACUOUS: checked % of % requirements', v_checked, array_length(v_needed, 1);
  END IF;

  RETURN 'ok: a provider can ' || rtrim(v_report)
         || '-- every one is owner-scoped and RLS is on';
END;
$$;

COMMENT ON FUNCTION public.assert_owner_can_read_and_write_their_money() IS
  'Requires a caller-named policy -- one mentioning auth.uid() or '
  'owns_provider_profile() -- for SELECT on wallets and for INSERT and SELECT '
  'on wallet_recharge_requests, and requires RLS to be enabled on both. A '
  'staff-scoped policy does not count: wallets_staff_read and '
  'wallet_recharge_requests_staff_read are the only policies any executed '
  'migration created on these tables, and neither is reachable by a provider, '
  'which is why submitting a recharge reported "That item could not be '
  'found".';

REVOKE ALL ON FUNCTION public.assert_client_buckets_have_write_and_read_policies() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_client_buckets_have_write_and_read_policies() TO anon, authenticated, service_role;

REVOKE ALL ON FUNCTION public.assert_owner_can_read_and_write_their_money() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.assert_owner_can_read_and_write_their_money() TO anon, authenticated, service_role;

-- PostgREST caches policies in its schema cache; without this a fresh policy
-- can be invisible to the very request it is meant to authorise.
notify pgrst, 'reload schema';
