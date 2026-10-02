-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Proves what 0131 claims, by EXECUTING it:
--
--  APR 1  the recipient set is admins + support_chat staff, deduped
--  APR 2  filing a GENERAL appeal reaches the person it names
--  APR 3  ...and every account that can act on it  <- the gap
--  APR 4  an uninvolved account hears nothing
--  APR 5  a retried send with the same key does not double-notify
--  APR 6  DOCUMENT_VERIFICATION can be filed at all
--  APR 7  ...and carries the same evidence rule as GENERAL
--  APR 8  a PASSWORD_RESET case is still relaxed (not over-tightened)
--  APR 9  anon cannot enumerate the recipient set
--  APR 10  the wiring report

\set QUIET on
\set ON_ERROR_STOP off
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS 'SELECT NULLIF(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
\set QUIET off

DO $$
DECLARE
  v_admin    constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_support  constant uuid := '00000000-0000-4000-8000-0000000000b1';
  v_sales    constant uuid := '00000000-0000-4000-8000-0000000000b2';
  v_reporter constant uuid := '00000000-4000-4000-8000-0000000000c1';
  v_named    constant uuid := '00000000-4000-4000-8000-0000000000d1';
  v_stranger constant uuid := '00000000-4000-4000-8000-0000000000e1';
  v_case uuid;
  v_n integer;
  v_applied boolean;
BEGIN
  -- Pre-flight. Without this the whole DO block dies on its first reference
  -- to a function 0131 creates, and the --without-fix run reports only
  -- "does not exist" instead of the behaviour that is actually missing. A
  -- falsification should show the gap, not just that a name is absent.
  v_applied := to_regprocedure('public.appeal_review_recipients()') IS NOT NULL;
  RAISE NOTICE 'APR 0 migration 0131 applied   -> % (%s)',
    v_applied,
    CASE WHEN v_applied THEN 'expectations below should hold'
         ELSE 'everything below is the PRE-0131 behaviour' END;
  INSERT INTO auth.users (id, email) VALUES
    (v_admin,'owner@test'), (v_support,'support@test'),
    (v_sales,'sales@test'), (v_reporter,'reporter@test'),
    (v_named,'named@test'), (v_stranger,'nobody@test')
    ON CONFLICT (id) DO NOTHING;

  -- The CEO who is ALSO an ADMIN: qualifies twice, and must be told once.
  -- That is the two-column UNION trap 0127 documented.
  INSERT INTO public.staff (user_id, is_ceo, is_active, permissions) VALUES
    (v_admin,   true,  true, '{}'),
    (v_support, false, true, ARRAY['support_chat']),
    (v_sales,   false, true, ARRAY['sales_transactions']);
  INSERT INTO public.user_roles (user_id, role) VALUES (v_admin, 'ADMIN');

  IF v_applied THEN
    RAISE NOTICE 'APR recipients -> %: %',
      (SELECT count(*) FROM public.appeal_review_recipients()),
      (SELECT string_agg(r.user_id::text, ' ' ORDER BY r.user_id)
         FROM public.appeal_review_recipients() r);
    -- want 2: the CEO/ADMIN ONCE, and support_chat. NOT the sales clerk.
  END IF;

  -- ── A GENERAL appeal naming somebody ─────────────────────────────────
  INSERT INTO public.appeal_cases
    (user_id, respondent_id, photo_path, description, phone, case_type)
  VALUES (v_reporter, v_named, 'r/appeal1.jpg', 'scammed', '0912345678', 'GENERAL')
  RETURNING id INTO v_case;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_named AND type = 'APPEAL_FILED';
  RAISE NOTICE 'APR 2 the person NAMED is told     -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_admin AND type = 'APPEAL_FILED'
     AND title = 'An appeal is waiting for review';
  RAISE NOTICE 'APR 3 the CEO/ADMIN is told ONCE   -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_support AND type = 'APPEAL_FILED'
     AND title = 'An appeal is waiting for review';
  RAISE NOTICE 'APR 3b support_chat staff told     -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_sales AND type = 'APPEAL_FILED';
  RAISE NOTICE 'APR 4 staff WITHOUT support_chat  -> % (want 0)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_stranger AND type = 'APPEAL_FILED';
  RAISE NOTICE 'APR 4b an uninvolved account      -> % (want 0)', v_n;

  -- The reviewer notice must be the REVIEW one, not a second copy of the
  -- respondent's "a case was filed ABOUT YOU" wording.
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_admin AND type = 'APPEAL_FILED';
  RAISE NOTICE 'APR 3c total notices to that admin -> % (want 1, the review one)', v_n;

  -- ── The retry ────────────────────────────────────────────────────────
  PERFORM public.notify_user_safe(
    'appeal-filed:' || v_case::text || ':' || v_admin::text, v_admin,
    'APPEAL_FILED', 'dup', 'dup', '{}'::jsonb);
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_admin AND type = 'APPEAL_FILED';
  RAISE NOTICE 'APR 5 the same key sent twice      -> % notice(s) (want 1)', v_n;

  -- ── A DOCUMENT_VERIFICATION appeal ───────────────────────────────────
  BEGIN
    INSERT INTO public.appeal_cases
      (user_id, photo_path, description, phone, case_type)
    VALUES (v_reporter, 'r/id.jpg', 'my ID was rejected', '0912345678',
            'DOCUMENT_VERIFICATION');
    RAISE NOTICE 'APR 6 DOCUMENT_VERIFICATION files -> ok';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'APR 6 DOCUMENT_VERIFICATION files -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_support AND type = 'APPEAL_FILED'
     AND body LIKE '%document verification decision%';
  RAISE NOTICE 'APR 6b reviewers told it is a doc -> % (want 1)', v_n;

  -- The evidence rule must match GENERAL, not be accidentally relaxed.
  BEGIN
    INSERT INTO public.appeal_cases
      (user_id, photo_path, description, phone, case_type)
    VALUES (v_reporter, NULL, 'no photo', '0912345678', 'DOCUMENT_VERIFICATION');
    RAISE NOTICE 'APR 7 a document appeal with NO photo -> ACCEPTED (WRONG)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'APR 7 a document appeal with NO photo -> refused (% : %)',
      SQLSTATE, SQLERRM;
  END;

  -- ...and not be over-tightened either: a photo and a phone must be enough.
  BEGIN
    INSERT INTO public.appeal_cases
      (user_id, photo_path, description, phone, case_type)
    VALUES (v_reporter, 'r/id2.jpg', 'still rejected', '0912345678',
            'DOCUMENT_VERIFICATION');
    RAISE NOTICE 'APR 7b photo + phone accepted       -> ok';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'APR 7b photo + phone accepted       -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── PASSWORD_RESET must stay relaxed ─────────────────────────────────
  BEGIN
    INSERT INTO public.appeal_cases
      (user_id, photo_path, description, phone, email, case_type)
    VALUES (v_reporter, NULL, 'locked out', '', 'a@b.co', 'PASSWORD_RESET');
    RAISE NOTICE 'APR 8 password reset still relaxed -> ok';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'APR 8 password reset still relaxed -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  -- ── anon must not be able to read the roster ─────────────────────────
  IF v_applied THEN
    BEGIN
      SET LOCAL ROLE anon;
      PERFORM * FROM public.appeal_review_recipients();
      RAISE NOTICE 'APR 9 anon reads the roster        -> ALLOWED (WRONG)';
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'APR 9 anon reads the roster        -> refused (% : %)', SQLSTATE, SQLERRM;
    END;

    RAISE NOTICE 'APR RPT %', public.appeal_notification_wiring_report();
  ELSE
    RAISE NOTICE 'APR 9/10 report and roster check   -> SKIPPED (0131 not applied)';
  END IF;
END;
$$;