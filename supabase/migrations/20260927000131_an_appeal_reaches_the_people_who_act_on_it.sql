-- A filed appeal reached the person it was filed AGAINST, and nobody who had
-- to act on it.
--
-- THE REPORT
-- ----------
-- "the document verification appeal is not showing at admin front dashboard
-- and in notifications bars but I get it when I go to document verification".
--
-- Two independent causes live here. This migration fixes the one that is a
-- database fact; the other is a Dart bug in the dashboard's count helper and
-- is fixed there, because it is not a schema problem.
--
-- GAP 1 -- filing an appeal notified the wrong half of the story, and none of
-- the right one.
--
--   `fn_notify_appeal_case_filed` (20260927000058) notifies
--   `NEW.respondent_id` -- the person a case is filed AGAINST. That is correct
--   and it is necessary: they are named in it and they deserve to know. But
--   the accounts that can OPEN the queue are not named in a case at all, and
--   none of them was told one arrived. The `appeal_cases` RLS policy
--   (20260923000000:31) is `user_id = auth.uid() OR is_admin() OR
--   staff_has_permission(auth.uid(), 'support_chat')` -- so the set of people
--   who can act on a case is exactly the set this trigger ignored.
--
--   The result is that a queue exists, is counted on the dashboard, and is
--   only found by going to look. 0127 fixed precisely this shape of gap for
--   identity documents and said why in its own header: "a card that nobody is
--   notified about is a card nobody opens."
--
-- GAP 2 -- there was no way to file a document-verification appeal at all.
--
--   `appeal_cases.case_type` (20260927000120:63) admits exactly two values:
--   GENERAL and PASSWORD_RESET. A person whose ID was rejected had nowhere to
--   say so. They could file a GENERAL appeal, which is a spam/report form
--   demanding an evidence photo and a phone number, lands in a queue mixed
--   with disputes about other people, and is filtered out of every document
--   view -- so it works, and it is invisible.
--
--   A third member, DOCUMENT_VERIFICATION, with the same evidence rule as
--   GENERAL: this is a dispute about a decision, not a locked-out account, so
--   it needs a photo and a phone exactly as an appeal always has.
--
-- WHY THE RESPONDENT NOTICE IS NOT REMOVED
-- ---------------------------------------
-- It is restated onto notify_user_safe rather than notify_user, and the
-- difference is load-bearing. Filing an appeal is a DIRECT CLIENT INSERT, so
-- notify_user takes the client branch and appends to notification_outbox. If
-- that append fails for any reason, the trigger RAISES, and a raise inside an
-- AFTER INSERT trigger rolls back the user's appeal -- the queue would refuse
-- a case because the platform could not write a notification about it.
-- notify_user_safe swallows, so the queue's availability never depends on the
-- inbox's. The respondent is still told; they are just not able to stop the
-- case from existing.
--
-- WHY A TRIGGER AND NOT A FUNCTION CALL
-- ------------------------------------
-- `request_password_reset_appeal` (0120) is a SECURITY DEFINER RPC and the
-- ordinary appeal is a direct client INSERT from appeal_screen.dart. Two call
-- sites, and 0058 already found this table once. A trigger is the only place
-- that cannot be forgotten by the next caller.

-- ===========================================================================
-- 1. The case type
-- ===========================================================================
ALTER TABLE public.appeal_cases
  DROP CONSTRAINT IF EXISTS appeal_cases_case_type_known;

ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_case_type_known
  CHECK (case_type IN ('GENERAL', 'PASSWORD_RESET', 'DOCUMENT_VERIFICATION'));

-- The evidence rule. A document appeal is a dispute about a decision made
-- about a person, exactly like a GENERAL appeal, so it carries exactly the
-- same requirement. Only PASSWORD_RESET is relaxed, and only because the
-- person filing it cannot sign in to supply a photo.
ALTER TABLE public.appeal_cases
  DROP CONSTRAINT IF EXISTS appeal_cases_evidence_required;

ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_evidence_required
  CHECK (
    (case_type IN ('GENERAL', 'DOCUMENT_VERIFICATION')
       AND photo_path IS NOT NULL
       AND length(btrim(phone)) > 0)
    OR
    (case_type = 'PASSWORD_RESET'
       AND (NULLIF(btrim(coalesce(email, '')), '') IS NOT NULL
            OR NULLIF(btrim(coalesce(phone, '')), '') IS NOT NULL))
  );

COMMENT ON COLUMN public.appeal_cases.case_type IS
  'GENERAL (the original appeal, evidence photo and phone both required), '
  'PASSWORD_RESET (filed by somebody who cannot sign in, so no photo and '
  'possibly no phone, but at least one contact route), or '
  'DOCUMENT_VERIFICATION (a dispute about an identity-document decision; '
  'evidence rules identical to GENERAL, but it is filterable on its own so a '
  'reviewer can work the document queue without wading through disputes '
  'about other people).';

-- The index 0120 built is (case_type, status, created_at DESC), which already
-- serves the new value; recreated only so its definition and this file agree.
CREATE INDEX IF NOT EXISTS idx_appeal_cases_type_status
  ON public.appeal_cases (case_type, status, created_at DESC);

-- ===========================================================================
-- 2. Who has to be told a case arrived
--
-- ONE column, for the reason 0127 gave: with two, `UNION` cannot collapse a
-- person who is both an ADMIN and a support_chat staff member -- the rows
-- differ in the boolean -- and that account receives the notice twice.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.appeal_review_recipients()
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- The same set `appeal_cases`' own SELECT policy admits, and no wider. The
  -- policy is the definition of who can act on a case, so deriving the
  -- recipients from it means the notification cannot drift from the
  -- permission: an account that could not open the queue is never told there
  -- is something in it.
  SELECT s.user_id
    FROM public.staff s
   WHERE s.is_active
     AND s.user_id IS NOT NULL
     AND ('support_chat' = ANY (coalesce(s.permissions, '{}'))
          OR s.is_super_admin OR s.is_ceo)

  UNION

  SELECT ur.user_id
    FROM public.user_roles ur
   WHERE ur.role = 'ADMIN'
$$;

COMMENT ON FUNCTION public.appeal_review_recipients() IS
  'Who must be told an appeal case was filed: every ADMIN and every active '
  'staff member holding support_chat (plus super admins and the CEO). Matches '
  'the appeal_cases SELECT policy exactly, so the notified set and the '
  'permitted set cannot disagree.';

-- ===========================================================================
-- 3. Both sides, in the same trigger
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.fn_notify_appeal_case_filed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_label text;
  v_recipient record;
BEGIN
  -- A case may name no respondent; the reporter knows they filed it, and
  -- notify_user_once already returns NULL for a NULL address, so there is
  -- nothing to pre-check.
  v_label := CASE coalesce(NEW.case_type, 'GENERAL')
    WHEN 'DOCUMENT_VERIFICATION' THEN 'a document verification decision'
    WHEN 'PASSWORD_RESET'          THEN 'a password reset request'
    ELSE 'a support case'
  END;

  -- TO THE PERSON NAMED IN IT. Unchanged in substance, moved onto
  -- notify_user_safe: a raise here would roll back the user's own appeal.
  PERFORM public.notify_user_safe(
    'appeal-filed:' || NEW.id::text || ':respondent',
    NEW.respondent_id,
    'APPEAL_FILED',
    'A case was filed about you',
    'Someone opened a support case that names you. You can read it and reply '
      || 'from your profile.',
    jsonb_build_object('appeal_case_id', NEW.id, 'case_type', NEW.case_type)
  );

  -- TO EVERYONE WHO CAN ACT ON IT. This is the half that was missing: before
  -- this, an appeal arrived in a queue that only an administrator who
  -- happened to open that screen would find.
  FOR v_recipient IN
    SELECT r.user_id FROM public.appeal_review_recipients() r
  LOOP
    PERFORM public.notify_user_safe(
      'appeal-filed:' || NEW.id::text || ':' || v_recipient.user_id::text,
      v_recipient.user_id,
      'APPEAL_FILED',
      'An appeal is waiting for review',
      'Someone filed ' || v_label || '.',
      jsonb_build_object(
        'appeal_case_id', NEW.id,
        'case_type', NEW.case_type,
        'queue', 'appeals')
    );
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_notify_appeal_case_filed() IS
  'Announces a filed appeal to the person it names AND to every account that '
  'can review appeals. Both sends go through notify_user_safe because filing '
  'an appeal is a client write: a raise out of this trigger would roll back '
  'the case the user just filed.';

-- The trigger itself is unchanged -- 0058 already owns the INSERT fire. Only
-- the function behind it is restated, so there is still exactly one trigger
-- per event and no second one to keep in step.
DROP TRIGGER IF EXISTS trg_appeal_cases_notify_filed ON public.appeal_cases;
CREATE TRIGGER trg_appeal_cases_notify_filed
  AFTER INSERT ON public.appeal_cases
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_notify_appeal_case_filed();

-- ===========================================================================
-- 4. The report
--
-- The swallow in notify_user_safe means a completely dead notification path
-- reports success, so the trigger, the enum value, the constraint, the
-- recipient set and the signature the whole chain rests on are all asserted
-- BY NAME here rather than left to be read.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.appeal_notification_wiring_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text := '';
  v_recipients integer;
  v_open integer;
BEGIN
  IF to_regclass('public.appeal_cases') IS NULL THEN
    RETURN 'appeal_cases does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.appeal_cases'::regclass
       AND tgname = 'trg_appeal_cases_notify_filed' AND NOT tgisinternal
  ) THEN
    v_bad := v_bad || 'trg_appeal_cases_notify_filed is missing; ';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.appeal_cases'::regclass
       AND conname = 'appeal_cases_case_type_known'
  ) THEN
    v_bad := v_bad || 'appeal_cases_case_type_known is missing; ';
  ELSIF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = 'public.appeal_cases'::regclass
       AND c.conname = 'appeal_cases_case_type_known'
       -- pg_get_constraintdef, NOT c.consrc: consrc was removed in
       -- PostgreSQL 12 and the live database is newer than that, so reading
       -- it raises `column "consrc" does not exist` and takes the whole
       -- report down -- which is the function that would have told us.
       AND pg_get_constraintdef(c.oid) LIKE '%DOCUMENT_VERIFICATION%'
  ) THEN
    v_bad := v_bad || 'the case_type CHECK does not admit '
             || 'DOCUMENT_VERIFICATION, so a document appeal cannot be filed; ';
  END IF;

  IF to_regprocedure('public.appeal_review_recipients()') IS NULL THEN
    v_bad := v_bad || 'appeal_review_recipients() is missing; ';
  END IF;

  -- The recipient set is a list of account ids. It must not be enumerable by
  -- a client with no session; the trigger is SECURITY DEFINER and needs no
  -- caller privilege.
  IF has_function_privilege(
       'anon', 'public.appeal_review_recipients()', 'EXECUTE') THEN
    v_bad := v_bad || 'anon can execute appeal_review_recipients(), so the '
             || 'roster of accounts that review appeals is enumerable without '
             || 'a session; ';
  END IF;

  -- The signature notify_user_safe calls. An enum has no implicit cast to
  -- text, so a third parameter declared `text` makes every call raise -- and
  -- the swallow turns that into "nobody was told", with no error anywhere.
  IF to_regprocedure(
       'public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)'
     ) IS NULL THEN
    v_bad := v_bad || 'notify_user_once does not have the signature '
             || 'notify_user_safe calls -- every notice this migration sends '
             || 'would be swallowed as a failed cast and NOBODY WOULD BE TOLD; ';
  END IF;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad;
  END IF;

  SELECT count(*) INTO v_recipients FROM public.appeal_review_recipients();
  SELECT count(*) INTO v_open FROM public.appeal_cases WHERE status = 'OPEN';

  RETURN format(
    'ok: a filed appeal now reaches the person it names and all %s account(s) '
    'that can review appeals, DOCUMENT_VERIFICATION can be filed, and the '
    'evidence rule for it matches an ordinary appeal (%s case(s) open now)',
    v_recipients, v_open);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_notify_appeal_case_filed() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.appeal_review_recipients() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.appeal_review_recipients()
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.appeal_notification_wiring_report()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.appeal_notification_wiring_report()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
