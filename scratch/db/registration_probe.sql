-- LOCAL FIXTURE -- not a migration, never deployed.
--
-- Proves what 0130 claims, by EXECUTING it:
--
--   REG 1  a submitted application reaches the applicant
--   REG 2  ...and every account that can review registrations
--   REG 3  ...and nobody else
--   REG 4  a retried send with the same key does not double-notify
--   REG 5  a USER submission and a PROVIDER submission from the same person
--          are announced separately, not collapsed into one
--   REG 6  a resubmission (an UPDATE, not an INSERT) reaches the reviewers
--   REG 7  an approval that writes this column notifies nobody extra
--   REG 8  unsuspend_provider still refuses an unpermitted caller
--   REG 9  ...and tells the person when it does reactivate them
--  REG 10  the wiring report

\set QUIET on
\set ON_ERROR_STOP off
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
  LANGUAGE sql STABLE AS 'SELECT NULLIF(current_setting(''request.jwt.claim.sub'', true), '''')::uuid';
\set QUIET off

DO $$
DECLARE
  v_admin     constant uuid := '00000000-0000-4000-8000-0000000000a1';
  v_registrar constant uuid := '00000000-0000-4000-8000-0000000000b1';
  v_otherstaff constant uuid := '00000000-0000-4000-8000-0000000000b2';
  v_applicant constant uuid := '00000000-4000-4000-8000-0000000000c1';
  v_stranger  constant uuid := '00000000-4000-4000-8000-0000000000e1';
  v_req uuid;
  v_prov uuid;
  v_n integer;
BEGIN
  INSERT INTO auth.users (id, email) VALUES
    (v_admin,'owner@test'), (v_registrar,'reg@test'),
    (v_otherstaff,'sales@test'), (v_applicant,'applicant@test'),
    (v_stranger,'nobody@test') ON CONFLICT (id) DO NOTHING;

  -- Three staff: one CEO who is also an ADMIN (qualifies TWICE -- the case
  -- document_review_recipients() got wrong and had to return one column for),
  -- one holding `registrations`, and one holding only `sales_transactions`.
  INSERT INTO public.staff (user_id, is_ceo, is_active, permissions) VALUES
    (v_admin,      true,  true, '{}'),
    (v_registrar,  false, true, ARRAY['registrations']),
    (v_otherstaff, false, true, ARRAY['sales_transactions']);
  INSERT INTO public.user_roles (user_id, role) VALUES (v_admin, 'ADMIN');

  INSERT INTO public.profiles (id, full_name, city) VALUES
    (v_applicant, 'Selam Bekele', 'addis ababa') ON CONFLICT (id) DO NOTHING;

  RAISE NOTICE 'REG recipients -> %: %',
    (SELECT count(*) FROM public.registration_review_recipients()),
    (SELECT string_agg(r.user_id::text, ' ' ORDER BY r.user_id)
       FROM public.registration_review_recipients() r);
  -- want 2: the CEO/ADMIN ONCE, and the registrar. NOT the sales clerk.

  -- ── A user signup ───────────────────────────────────────────────────
  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  VALUES ('USER', v_applicant, 'PENDING_APPROVAL') RETURNING id INTO v_req;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_applicant AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 1 applicant notified          -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_admin AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 2 the CEO/ADMIN notified ONCE  -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_registrar AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 2b the registrar notified     -> % (want 1)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_otherstaff AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 3 staff WITHOUT registrations  -> % (want 0)', v_n;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_stranger AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 3b an uninvolved account      -> % (want 0)', v_n;

  -- ── The retry ───────────────────────────────────────────────────────
  -- The key is derived from the approval_requests row id, so a replayed
  -- signup collapses. Asked as a second send of the same key rather than a
  -- second INSERT of the same primary key, which the database would refuse
  -- and which would prove nothing if it had somehow run.
  PERFORM public.notify_user_once(
    'registration-submitted:' || v_req::text, v_applicant,
    'REGISTRATION_RECEIVED', 'dup', 'dup', '{}'::jsonb);
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_applicant AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 4 the same key sent twice      -> % notice(s) (want 1)', v_n;

  -- ── A provider application from the SAME person ─────────────────────
  -- A provider signup writes the USER row and the trigger on
  -- provider_profiles writes the PROVIDER row, so one person produces two
  -- submissions. Neither may swallow the other.
  INSERT INTO public.provider_profiles (user_id, business_name, city, status)
  VALUES (v_applicant, 'Selam Tailors', 'addis ababa', 'PENDING_APPROVAL')
  RETURNING id INTO v_prov;

  INSERT INTO public.approval_requests (subject_type, subject_id, status)
  VALUES ('PROVIDER', v_prov, 'PENDING_APPROVAL');

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_applicant AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 5 applicant, both submissions -> % notice(s) (want 2)', v_n;

  -- The provider row is addressed by provider_profiles.id, NOT by user id.
  -- Getting that wrong would notify a stranger, so the assertion is on the
  -- body text naming the business.
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_applicant AND body LIKE '%business application%';
  RAISE NOTICE 'REG 5b the PROVIDER half is worded -> % (want 1)', v_n;

  -- ── A resubmission is an UPDATE, not an INSERT ──────────────────────
  -- The registrar holds 2 by now: one for the USER submission and one for the
  -- PROVIDER one. A rejection must add nothing, so the number is UNCHANGED --
  -- which is the assertion, not a count of 0.
  UPDATE public.approval_requests SET status = 'REJECTED' WHERE id = v_req;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_registrar AND type = 'REGISTRATION_RECEIVED';
  RAISE NOTICE 'REG 6a a REJECTION adds nothing    -> % registrar notices (want 2, unchanged)', v_n;

  UPDATE public.approval_requests SET status = 'PENDING_APPROVAL' WHERE id = v_req;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_registrar AND type = 'REGISTRATION_RECEIVED'
     AND title = 'An application was resubmitted';
  RAISE NOTICE 'REG 6b a RESUBMISSION reaches them  -> % (want 1)', v_n;

  -- ── An approval must not fire the resubmit trigger ───────────────────
  UPDATE public.approval_requests SET status = 'APPROVED' WHERE id = v_req;
  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_registrar AND title = 'An application was resubmitted';
  RAISE NOTICE 'REG 7 an APPROVAL fires nothing    -> % (want 1, unchanged)', v_n;

  -- ── unsuspend_provider: guarded, then telling ────────────────────────
  INSERT INTO public.provider_profiles (user_id, business_name, city, status)
  VALUES (v_applicant, 'Selam Tailors', 'addis ababa', 'SUSPENDED')
  ON CONFLICT (id) DO NOTHING;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_stranger::text, false);
    PERFORM public.unsuspend_provider(v_prov, v_stranger);
    RAISE NOTICE 'REG 8 an unpermitted caller       -> ok (MUST BE INSUFFICIENT_PERMISSION)';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'REG 8 an unpermitted caller       -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  BEGIN
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, false);
    PERFORM public.unsuspend_provider(v_prov, v_admin);
    RAISE NOTICE 'REG 9 an admin reactivates        -> ok';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'REG 9 an admin reactivates        -> RAISED % : %', SQLSTATE, SQLERRM;
  END;

  SELECT count(*) INTO v_n FROM public.notifications
   WHERE user_id = v_applicant AND title = 'Account reactivated';
  RAISE NOTICE 'REG 9b the PERSON is told          -> % notice(s) (want 1)', v_n;

  RAISE NOTICE 'REG RPT %', public.registration_notification_wiring_report();
END;
$$;
