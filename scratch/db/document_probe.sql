-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Proves what 0127 claims: a submitted identity document reaches BOTH the
-- person who sent it and everyone who can review it, a retried upload does not
-- double-notify, and a recorded verdict reaches the person.

\set QUIET on
\set ON_ERROR_STOP off
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS 'SELECT NULLIF(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
\set QUIET off

DO $$
DECLARE
  v_admin  constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_reviewer constant uuid := '00000000-0000-4000-8000-0000000000d1';
  v_stranger constant uuid := '00000000-0000-4000-8000-0000000000e1';
  v_uploader constant uuid := '00000000-4000-4000-8000-0000000000c1';
  v_doc    uuid;
  v_n      integer;
BEGIN
  INSERT INTO auth.users (id, email) VALUES
    (v_admin, 'owner@test'), (v_reviewer, 'rev@test'),
    (v_stranger, 'nobody@test'), (v_uploader, 'user@test')
    ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.staff (user_id, is_ceo, is_active, permissions) VALUES
    (v_admin, true, true, '{}'),
    (v_reviewer, false, true, ARRAY['document_verification']);
  INSERT INTO public.user_roles (user_id, role) VALUES (v_admin, 'ADMIN');

  INSERT INTO public.profiles (id, full_name, city) VALUES
    (v_uploader, 'Selam Bekele', 'addis ababa') ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'DOC recipients -> %: %',
    (SELECT count(*) FROM public.document_review_recipients()),
    (SELECT string_agg(r.user_id::text, ' ' ORDER BY r.user_id)
       FROM public.document_review_recipients() r);

  -- ── A submission ─────────────────────────────────────────────────────
  INSERT INTO public.user_documents (user_id, document_type, storage_path)
  VALUES (v_uploader, 'NATIONAL_ID', 'u1/doc.png')
  RETURNING id INTO v_doc;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE type = 'DOCUMENT_RECEIVED' AND user_id = v_uploader;
  RAISE NOTICE 'DOC 1 submitter notified       -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE type = 'DOCUMENT_RECEIVED' AND user_id = v_reviewer;
  RAISE NOTICE 'DOC 1 reviewer notified        -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE type = 'DOCUMENT_RECEIVED' AND user_id = v_stranger;
  RAISE NOTICE 'DOC 1 uninvolved person        -> % (want 0)', v_n;

  -- ── The retry ────────────────────────────────────────────────────────
  -- The idem key is derived from the ROW id, so the dedupe collapses a retried
  -- write of the SAME document (the upsert path, a replayed edge function, a
  -- double-submitted form) and nothing else. Two genuinely different documents
  -- each notify, which is correct: the reviewer should hear about both.
  --
  -- It is therefore tested by asking notify_user_once to send the same key
  -- twice, not by trying to insert the same primary key twice -- which is not
  -- a scenario the database permits, and which would have been a test that
  -- proved nothing if it had been written to run.
  PERFORM public.notify_user_once(
    'document-submitted:' || v_doc::text, v_uploader, 'DOCUMENT_RECEIVED',
    'duplicate', 'duplicate', '{}'::jsonb);
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE type = 'DOCUMENT_RECEIVED' AND user_id = v_uploader;
  RAISE NOTICE 'DOC 2 same key sent twice     -> % notice(s) to the submitter (want 1)', v_n;

  -- A second, genuinely different document must NOT be swallowed by dedupe.
  INSERT INTO public.user_documents (user_id, document_type, storage_path)
  VALUES (v_uploader, 'PASSPORT', 'u1/passport.png');
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE type = 'DOCUMENT_RECEIVED' AND user_id = v_reviewer;
  RAISE NOTICE 'DOC 2b a SECOND document     -> % reviewer notice(s) (want 2)', v_n;

  -- ── Each verdict, to the person ──────────────────────────────────────
  UPDATE public.user_documents SET verification_status = 'VERIFIED' WHERE id = v_doc;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_uploader AND type = 'APPROVAL';
  RAISE NOTICE 'DOC 3 VERIFIED -> the person   -> % (want 1)', v_n;

  UPDATE public.user_documents SET verification_status = 'REJECTED' WHERE id = v_doc;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_uploader AND type = 'REJECTION';
  RAISE NOTICE 'DOC 4 REJECTED -> the person   -> % (want 1)', v_n;

  UPDATE public.user_documents SET verification_status = 'SUSPECTED_FRAUD' WHERE id = v_doc;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_uploader AND type = 'SECURITY';
  RAISE NOTICE 'DOC 5 SUSPECTED_FRAUD         -> % (want 1)', v_n;

  -- ── A no-op update must not notify ───────────────────────────────────
  SELECT count(*) INTO v_n FROM public.notifications WHERE user_id = v_uploader;
  UPDATE public.user_documents SET storage_path = 'u1/doc2.png' WHERE id = v_doc;
  PERFORM 1;
  SELECT count(*) INTO v_n FROM public.notifications WHERE user_id = v_uploader;
  RAISE NOTICE 'DOC 6 total notices to person -> % (want 5: 2 acks + 3 verdicts)', v_n;

  -- ── A non-reviewer must not get the count ────────────────────────────
  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_stranger::text, false);
    PERFORM public.admin_pending_document_count();
    RAISE NOTICE 'DOC 7 non-reviewer count      -> ok (MUST be ADMIN_ONLY)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'DOC 7 non-reviewer count      -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_reviewer::text, false);
    RAISE NOTICE 'DOC 8 reviewer sees pending  -> % (want 2: both documents)', public.admin_pending_document_count();
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'DOC 8 reviewer sees pending  -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  RAISE NOTICE 'DOC RPT %', public.document_notification_wiring_report();
END;
$$;