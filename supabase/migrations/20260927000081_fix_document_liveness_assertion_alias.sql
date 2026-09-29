-- 20260927000081_fix_document_liveness_assertion_alias.sql
--
-- Fixes the assertion shipped in 00080. The feature itself is fine — the
-- columns, the constraints and the client write are all in place and applied.
-- The ASSERTION could not run:
--
--   PostgrestException: missing FROM-clause entry for table "c"  (42P01)
--
-- Cause: the constraint sweep selected `c.conname` in the OUTER query, where
-- `c` does not exist. `c` is only defined inside the NOT EXISTS subquery; the
-- outer FROM is `unnest(...) AS want(conname)`. So the function raised before
-- it could check anything, and the connectivity suite saw a null — the same
-- uninformative null that migration 66 documented, which is why that test now
-- prints the error instead of guessing.
--
-- The fix is `want.conname`: name the constraint being asked about from the
-- side that has it in scope. The checks themselves are unchanged, so this
-- migration changes no behaviour on a database that was already correct — it
-- only makes the test able to say so.
--
-- Corrected in a new file rather than by editing 00080: that one is already
-- in the migration history, so an edit to it would never be applied again.
--
-- Applied by hand, not through Deploy Supabase: GitHub Actions was refusing to
-- schedule any run ("recent account payments have failed or your spending
-- limit needs to be increased"), so this was pasted into the Supabase SQL
-- editor. That means `supabase db push` will still see 00081 as pending and
-- apply it once Actions works again — which is harmless, because this file is
-- a CREATE OR REPLACE of the same signature plus a GRANT and a NOTIFY. Do not
-- delete it on the assumption that it has "already run".

CREATE OR REPLACE FUNCTION public.assert_document_liveness_is_recorded()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_cols int;
  v_trigger_src text;
  v_missing text;
BEGIN
  SELECT count(*) INTO v_cols
    FROM pg_attribute
   WHERE attrelid = 'public.user_documents'::regclass
     AND attname IN (
       'location_capture_status', 'gps_lat', 'gps_lng',
       'gps_accuracy_m', 'gps_captured_at', 'gps_is_last_known'
     )
     AND attnum > 0
     AND NOT attisdropped;

  IF v_cols <> 6 THEN
    RAISE EXCEPTION
      'LIVENESS_REGRESSION: user_documents has % of the 6 liveness columns, so a document submission records no location',
      v_cols;
  END IF;

  -- `want.conname` and not `c.conname`: the constraint lives in the subquery,
  -- the name being looked for lives in the outer FROM.
  SELECT string_agg(want.conname, ', ')
    INTO v_missing
    FROM unnest(ARRAY[
           'user_documents_location_capture_status_check',
           'user_documents_liveness_consistent_check',
           'user_documents_gps_range_check'
         ]) AS want(conname)
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.user_documents'::regclass
        AND c.conname = want.conname
   );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'LIVENESS_REGRESSION: missing integrity constraint(s) % on user_documents, so a row can claim a captured fix with no coordinates',
      v_missing;
  END IF;

  -- The client must still be able to write the row at all.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'user_documents'
      AND policyname = 'user_documents_insert_own'
  ) THEN
    RAISE EXCEPTION
      'LIVENESS_REGRESSION: user_documents_insert_own is gone, so no client can upload a document at all';
  END IF;

  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
    INTO v_trigger_src
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'prevent_document_verification_forgery';

  IF v_trigger_src IS NULL THEN
    RAISE EXCEPTION
      'LIVENESS_REGRESSION: prevent_document_verification_forgery() is missing; the document insert path changed and needs re-checking';
  END IF;

  IF position('location_capture_status' in v_trigger_src) > 0
     OR position('gps_lat' in v_trigger_src) > 0
     OR position('gps_captured_at' in v_trigger_src) > 0 THEN
    RAISE EXCEPTION
      'LIVENESS_REGRESSION: prevent_document_verification_forgery() now touches the liveness columns, so every upload records the trigger''s value instead of the device''s fix';
  END IF;

  RETURN 'document liveness OK: 6 columns present, integrity constraints in place, insert policy intact, BEFORE INSERT trigger does not overwrite the signal';
END;
$$;

COMMENT ON FUNCTION public.assert_document_liveness_is_recorded() IS
  'True when a document submission records the device location at the moment '
  'of upload and the BEFORE INSERT trigger does not overwrite it.';

GRANT EXECUTE ON FUNCTION public.assert_document_liveness_is_recorded()
  TO anon, authenticated;

-- Same signature as 00080, so PostgREST's cache does not need to relearn it,
-- but sent anyway: a CREATE OR REPLACE that leaves the cache cold is how
-- migration 66 lost three deploy cycles.
notify pgrst, 'reload schema';
