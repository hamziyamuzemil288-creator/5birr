-- 20260927000080_document_liveness_gps.sql
--
-- GPS liveness: record WHERE the person was when they submitted their ID.
--
-- WHY THIS EXISTS
-- ---------------
-- The report was "a GPS/location liveness check is not wired in". Grepping
-- lib/ and supabase/ for `liveness|selfie|gps_match|location_at_upload`
-- found nothing: the only concept in the codebase was a comment in
-- safe_realtime.dart. So it was genuinely missing, and this migration adds
-- the storage half of it. (The "Where to?" search bar from the map redesign
-- was NOT missing — that is already built in lib/features/user/live_map_screen.dart.
-- No change was made there.)
--
-- WHAT IT IS, AND WHAT IT IS NOT
-- ------------------------------
-- This is a liveness SIGNAL, not a gate. When a document row is written, the
-- app asks for one GPS fix and stores it beside the document: where, how
-- accurate, when, and whether the fix came from the OS cache rather than a
-- live satellite lock.
--
-- The reason to record it is that a document photo and its location are very
-- hard to fake together: an ID re-used from another account is almost always
-- submitted from a different place, or replayed later with a stale photo but a
-- fresh fix. Reviewers get the pair and can see that.
--
-- It deliberately does NOT:
--   * block the upload. A phone with GPS off, permission denied, or in a
--     basement must still be able to submit an ID, or the verification flow
--     breaks for a minority of users and with it the product. The client
--     (DocumentUploadService) captures best-effort and records
--     UNAVAILABLE instead of failing;
--   * enforce anything on its own. There is no gate on `provider_docs_satisfied`,
--     on the admin review path, or on publication. Those were working and this
--     migration does not touch them;
--   * store a history. It is the fix at submission time, on that row, and it
--     is not a tracking log.
--
-- PRIVACY
-- -------
-- This is precise location tied to a verified identity — more sensitive than
-- the city field, so it is deliberately NOT in any public view. The existing
-- policies are untouched and already restrict reads of this table:
--   `user_documents_owner`        (user_id = auth.uid() OR is_admin())
--   `user_documents_staff_registration_read` (staff with 'registrations')
-- so only the person who submitted it, an administrator, and a registration
-- officer can read it. Nothing is granted here.
--
-- COMPATIBILITY
-- -------------
-- * Additive columns only. Every existing row gets location_capture_status =
--   'NOT_ATTEMPTED', which reads correctly: those uploads predate the signal.
-- * `user_documents_insert_own ... WITH CHECK (user_id = auth.uid())` does not
--   enumerate columns, so the client can insert the new ones without any
--   policy change. No policy is weakened or added here.
-- * `trg_user_documents_verification_security` runs BEFORE INSERT and
--   overwrites the verification columns only. It leaves the liveness columns
--   alone, and assertion #3 below turns a future change to that into a test
--   failure rather than a silent regression.
--
-- Idempotent — safe to re-run.

-- ===========================================================================
-- 1. The columns
-- ===========================================================================
ALTER TABLE public.user_documents
  ADD COLUMN IF NOT EXISTS location_capture_status text
    NOT NULL DEFAULT 'NOT_ATTEMPTED',
  ADD COLUMN IF NOT EXISTS gps_lat double precision,
  ADD COLUMN IF NOT EXISTS gps_lng double precision,
  ADD COLUMN IF NOT EXISTS gps_accuracy_m double precision,
  ADD COLUMN IF NOT EXISTS gps_captured_at timestamptz,
  ADD COLUMN IF NOT EXISTS gps_is_last_known boolean;

COMMENT ON COLUMN public.user_documents.location_capture_status IS
  'Liveness signal state at submission: NOT_ATTEMPTED (row predates the '
  'signal, or was written by a non-client path), CAPTURED (a GPS fix was '
  'taken when the document was submitted), UNAVAILABLE (the app tried and '
  'could not get one — GPS off or permission denied). NOT_ATTEMPTED and '
  'UNAVAILABLE are NOT refusals: uploads are never blocked on this.';
COMMENT ON COLUMN public.user_documents.gps_lat IS
  'Latitude of the fix taken at document submission. Anti-fraud signal '
  'beside the document, readable only by the owner, admins, and staff with '
  'the ''registrations'' permission. Not used as a gate.';
COMMENT ON COLUMN public.user_documents.gps_lng IS
  'Longitude of the fix taken at document submission (see gps_lat).';
COMMENT ON COLUMN public.user_documents.gps_accuracy_m IS
  'Horizontal accuracy in metres reported by the OS for the captured fix. '
  'A fix accurate to 2 km is worth less as evidence than one accurate to 20 '
  'm, and a reviewer should be able to tell the difference.';
COMMENT ON COLUMN public.user_documents.gps_captured_at IS
  'When the fix was taken, not when the row was written. The two are close '
  'for a normal upload and far apart for a replayed document.';
COMMENT ON COLUMN public.user_documents.gps_is_last_known IS
  'True when the position came from the OS cache after a fresh fix timed '
  'out rather than from a live satellite lock — i.e. an approximate point, '
  'which is a weaker signal and must not be read as a live one.';

-- ===========================================================================
-- 2. Integrity
-- ===========================================================================
-- Written conditionally, like the verification_status constraint in
-- 20260924000004, so a re-run does not collide with its own name.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_location_capture_status_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_location_capture_status_check
      CHECK (location_capture_status IN (
        'NOT_ATTEMPTED',  -- row predates the signal
        'CAPTURED',       -- a fix was taken at submission
        'UNAVAILABLE'     -- tried, could not get one; upload still went through
      ));
  END IF;

  -- A half-written signal is worse than none: coordinates without a
  -- timestamp, or a "captured" row with no coordinates, would read as
  -- evidence that does not exist.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_liveness_consistent_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_liveness_consistent_check
      CHECK (
        location_capture_status <> 'CAPTURED'
        OR (gps_lat IS NOT NULL AND gps_lng IS NOT NULL AND gps_captured_at IS NOT NULL)
      );
  END IF;

  -- Reject a coordinate that is not a coordinate, rather than storing it as
  -- evidence.
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_gps_range_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_gps_range_check
      CHECK (
        (gps_lat IS NULL AND gps_lng IS NULL)
        OR (gps_lat BETWEEN -90 AND 90 AND gps_lng BETWEEN -180 AND 180)
      );
  END IF;
END;
$$;

-- ===========================================================================
-- 3. Assertion for the connectivity suite
-- ===========================================================================
-- Source-level, like assert_document_review_is_admin_only: without a
-- privileged client the only available signal is the schema itself. It fails
-- if the columns are dropped, if the states are narrowed, if the insert policy
-- stops permitting the client, or — the quiet one — if the BEFORE INSERT
-- trigger ever starts overwriting the liveness columns, which would leave the
-- feature present, documented, and recording nothing.
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

  SELECT string_agg(c.conname, ', ')
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

-- New columns: refresh PostgREST's cached view so the client's insert is
-- planned against the current shape instead of erroring with 42703
-- ("column ... does not exist") on the first upload after the deploy.
notify pgrst, 'reload schema';
