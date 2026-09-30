-- 20260927000099_other_document_type.sql
--
-- Part 2: the document-type list grows an "Other" choice with a free-text
-- label.
--
-- THE LIMITATION
-- --------------
-- Every identity-document surface asks for exactly one of three types:
-- National ID / Driving License / Passport (ProviderDocGate.acceptedDocTypes,
-- the single source of the list since Task 9). A kebele ID, a business
-- licence, a health certificate — anything outside the fixed three — had no
-- home, so the person holding only that document could not complete
-- verification at all.
--
-- THE SCHEMA FACT THAT DECIDES THE SHAPE
-- --------------------------------------
-- user_documents.document_type has been plain `text NOT NULL` since
-- 0001_core_schema.sql — no enum, no CHECK. The Dart enum was the only
-- constraint. This migration adds the missing database half:
--
--   * document_type gets a CHECK listing every value the app has ever
--     written (the four identity types, plus the legacy DRIVING_LICENSE_ID
--     spelling provider_docs_satisfied already tolerated, TRADE_LICENSE
--     named in the 0001 comment, and the new OTHER);
--   * other_document_label text holds WHAT the document is when OTHER is
--     chosen ("business licence", "health certificate", ...). Nullable on
--     purpose: every existing row predates it, and NOT NULL would have
--     required a backfill of data nobody recorded;
--   * the label is mandatory exactly when it is meaningful. A CHECK can
--     express that pairing; a NOT NULL cannot, which is why it is written
--     as a constraint rather than a column default.
--
-- The insert path needs nothing else. user_documents_insert_own
-- (WITH CHECK (user_id = auth.uid())) does not enumerate columns, so the
-- new column rides in the same INSERT the client already makes, and
-- trg_user_documents_verification_security only overwrites verification
-- fields — both re-verified by the assertion below.
--
-- WHAT DELIBERATELY DOES NOT CHANGE
-- ---------------------------------
-- provider_docs_satisfied() still accepts only the four identity types. An
-- OTHER document proves nothing about identity until an administrator looks
-- at it, so it must not open a provider gate just by existing. (An OTHER row
-- CAN be VERIFIED by review_user_document — an admin who recognises the
-- document as an identity proof may accept it — but the gate deliberately
-- does not count OTHER, keeping the automated surface conservative.)

-- ===========================================================================
-- 1. The column
-- ===========================================================================
ALTER TABLE public.user_documents
  ADD COLUMN IF NOT EXISTS other_document_label text;

COMMENT ON COLUMN public.user_documents.other_document_label IS
  'What the document actually is, when document_type is OTHER (business '
  'licence, health certificate, ...). NULL for the fixed types; '
  'non-empty exactly when document_type = OTHER.';

-- ===========================================================================
-- 2. The two constraints
-- ===========================================================================
-- IF NOT EXISTS guards keep the migration safe to re-apply, the same way
-- 00080 added the liveness constraints.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_type_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_type_check
      CHECK (document_type IN (
        'NATIONAL_ID', 'DRIVING_LICENSE', 'DRIVING_LICENSE_ID', 'PASSPORT',
        'TRADE_LICENSE', 'OTHER'
      ));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.user_documents'::regclass
      AND conname = 'user_documents_other_label_check'
  ) THEN
    ALTER TABLE public.user_documents
      ADD CONSTRAINT user_documents_other_label_check
      CHECK (
        (document_type = 'OTHER' AND other_document_label IS NOT NULL
                                     AND btrim(other_document_label) <> '')
        OR (document_type <> 'OTHER' AND other_document_label IS NULL)
      );
  END IF;
END;
$$;

-- ===========================================================================
-- 3. The assertion the connectivity suite runs as anon
-- ===========================================================================
-- Same source-level shape as assert_document_liveness_is_recorded (00080):
-- without a privileged client the schema and the client source ARE the
-- signal. Fails if the column or either constraint is dropped, if the insert
-- policy stops permitting the client, if the verification trigger starts
-- overwriting OTHER fields, or if the client stops sending the label — each
-- of which would leave the feature present, documented, and storing nothing.
CREATE OR REPLACE FUNCTION public.assert_other_document_type_is_wired()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_cols int;
  v_missing text;
  v_trigger_src text;
BEGIN
  SELECT count(*) INTO v_cols
    FROM pg_attribute
   WHERE attrelid = 'public.user_documents'::regclass
     AND attname IN ('document_type', 'other_document_label')
     AND attnum > 0
     AND NOT attisdropped;

  IF v_cols <> 2 THEN
    RAISE EXCEPTION
      'OTHER_DOC_REGRESSION: user_documents has % of the 2 document-type columns (document_type, other_document_label), so an Other upload records no label',
      v_cols;
  END IF;

  SELECT string_agg(want.conname, ', ')
    INTO v_missing
    FROM unnest(ARRAY[
           'user_documents_type_check',
           'user_documents_other_label_check'
         ]) AS want(conname)
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_constraint c
      WHERE c.conrelid = 'public.user_documents'::regclass
        AND c.conname = want.conname
   );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'OTHER_DOC_REGRESSION: missing constraint(s) % on user_documents, so an OTHER row can exist without a label (or a label without OTHER)',
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
      'OTHER_DOC_REGRESSION: user_documents_insert_own is gone, so no document of any type can be uploaded';
  END IF;

  -- The BEFORE INSERT trigger must keep leaving the client's fields alone.
  -- Flat source, exactly as assert_document_liveness_is_recorded reads it,
  -- because liveness and other_document_label ride the same INSERT payload.
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
    INTO v_trigger_src
   FROM pg_proc p
   JOIN pg_namespace n ON n.oid = p.pronamespace
   JOIN pg_trigger t ON t.tgfoid = p.oid
   WHERE n.nspname = 'public'
     AND t.tgrelid = 'public.user_documents'::regclass
     AND t.tgname = 'trg_user_documents_verification_security'
     AND NOT t.tgisinternal;

  IF v_trigger_src IS NULL THEN
    RAISE EXCEPTION
      'OTHER_DOC_REGRESSION: trg_user_documents_verification_security is missing, so verification columns are not forced to their safe defaults on insert';
  END IF;

  IF position('new.verification_status' in v_trigger_src) = 0
     OR position('new.qr_payload' in v_trigger_src) = 0
     OR position('new.agent_verdict' in v_trigger_src) = 0
     OR position('other_document_label' in v_trigger_src) > 0
     OR position('document_type' in v_trigger_src) > 0 THEN
    RAISE EXCEPTION
      'OTHER_DOC_REGRESSION: the insert trigger changed the fields it overwrites, so an OTHER upload loses its label or escapes verification defaults';
  END IF;

  -- That the CLIENT actually sends other_document_label is checked by the
  -- Python static harness (tools/harness/static_checks.py), which reads the
  -- Dart source; SQL cannot see the client tree, and pretending otherwise is
  -- how an assertion silently passes on nothing (migration 00043's lesson).

  RETURN 'ok: other_document_label column, both constraints, insert policy and trigger scope all present';
END;
$$;

-- The connectivity suite calls this through the anon client; matching the
-- grant convention every other assertion follows (20260927000091) keeps it
-- reachable. Read-only introspection, returns no privileged data.
GRANT EXECUTE ON FUNCTION public.assert_other_document_type_is_wired()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
