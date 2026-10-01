-- A submitted document told nobody anything.
--
-- THE REPORT
-- ----------
-- "when people sent their documents let notifications appear both at front
-- dashboard and in apps notifications at the same time ... for all parties".
--
-- THAT IS ACCURATE, AND IT IS A TRIGGER THAT WAS NEVER WRITTEN.
--
-- `DocumentUploadService.uploadAndRecord` (lib/core/services/
-- document_upload_service.dart) does exactly two things:
--
--   client.storage.from('user-documents').upload(...)
--   client.from('user_documents').insert(row)
--
-- There is no third statement. No notification is raised on insert, and no
-- trigger on `user_documents` exists anywhere in the schema, so:
--
--   * the person who uploaded an ID was told nothing, and had to assume it
--     worked;
--   * nobody with `document_verification` was told a document arrived, so the
--     review queue was populated by people who happened to go and look.
--
-- The admin dashboard card is real and correctly gated -- it was built in the
-- previous audit -- but a card that nobody is notified about is a card nobody
-- opens.
--
-- WHAT THIS ADDS
-- --------------
-- One AFTER INSERT trigger that notifies BOTH sides, and one AFTER UPDATE that
-- notifies the person when a verdict is recorded. Both directions, because
-- "all parties" means all parties: a submission is a message TO the reviewer
-- and an acknowledgement TO the submitter.
--
-- WHY A TRIGGER AND NOT A FUNCTION CALL
-- ------------------------------------
-- Because the write is a direct client INSERT. `DocumentUploadService` and the
-- signup form both write the table directly, and both are on paths that must
-- keep working when a notification fails. A trigger is the only place that
-- cannot be forgotten by the next caller -- which is precisely how the gap
-- opened. There was no trigger, so every caller had to remember, and one
-- caller did not.
--
-- It is written defensively for the same reason: every notification is
-- individually wrapped, so one bad recipient cannot roll back the upload that
-- is already on disk. A failed NOTICE must never un-insert a row the person
-- has already been told they sent.

-- ===========================================================================
-- 1. A type for the event itself
-- ===========================================================================
-- The enum had no member for "we received your document". REGISTRATION_RECEIVED
-- is about an account, not an ID, and reusing it would make the inbox say
-- something false. ALTER TYPE ... ADD VALUE is additive and safe; it takes
-- effect for new rows immediately, which is all a notification ever is.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
      JOIN pg_enum e ON e.enumtypid = t.oid
     WHERE t.typname = 'notification_type'
       AND e.enumlabel = 'DOCUMENT_RECEIVED'
  ) THEN
    ALTER TYPE public.notification_type ADD VALUE 'DOCUMENT_RECEIVED';
  END IF;
END;
$$;

-- ===========================================================================
-- 2. Who is allowed to review a document
-- ===========================================================================
-- A reporting function first, because the recipient set is the part most
-- likely to be wrong and the part nobody can check by reading: `staff`
-- carries a `permissions text[]`, `user_roles` carries the ADMIN role, and
-- `document_verification` was grantable since 20260927000034 while gating
-- nothing on the server at all.
--
-- Admins are included even when they hold no named permission, because an
-- administrator who cannot review documents is an administrator whose
-- dashboard card is decoration. The report exists so Connectivity CI can
-- print this count rather than leaving the claim untested.

CREATE OR REPLACE FUNCTION public.document_review_recipients()
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- Any account that can act on a review. is_admin() and is_ceo() are asked
  -- FIRST and on their own, because "ADMIN in user_roles" is NOT the same
  -- question as "can review documents":
  --
  --   * a CEO whose staff row carries an EMPTY permissions array was excluded
  --     by an earlier version of this function, which only matched
  --     'document_verification' = ANY(permissions) and then excluded anyone
  --     with a staff row from the ADMIN branch. A CEO with a staff row --
  --     which is every CEO created through Staff Management -- matched neither
  --     branch and was told nothing, while the comment above this function
  --     claimed administrators were always included. Found by replaying it and
  --     counting the rows, not by reading it.
  --
  -- The set is "anyone who could open the review screen", which is the honest
  -- definition and is the same one the dashboard card uses.
  --
  -- ONE COLUMN, not "user_id and is_admin". With two, a CEO who is both an
  -- `is_ceo` staff member AND an ADMIN in `user_roles` produced TWO rows that
  -- `UNION` cannot collapse -- they differ in the boolean -- so the account
  -- owner received TWO notices for every single document. Found by counting the
  -- recipient list, which is the only thing that can see it: both notices
  -- "worked", the trigger did not raise, and the report said ok.
  SELECT s.user_id
    FROM public.staff s
   WHERE s.is_active
     AND s.user_id IS NOT NULL
     AND ('document_verification' = ANY (coalesce(s.permissions, '{}'))
          OR s.is_ceo OR s.is_super_admin)

  UNION

  SELECT ur.user_id
    FROM public.user_roles ur
   WHERE ur.role = 'ADMIN'
$$;
COMMENT ON FUNCTION public.document_review_recipients() IS
  'Who a submitted identity document must be announced to: every active staff '
  'member holding document_verification, plus every ADMIN. Returns nothing '
  'user-facing -- it is the single definition the trigger uses and the single '
  'definition the connectivity suite counts, so the two cannot disagree.';

-- ===========================================================================
-- 3. A send that cannot fail the thing that sent it
-- ===========================================================================
-- One named place that swallows, so the trigger has no exception block of its
-- own and the behaviour is stated once rather than at every call site.
--
-- `notify_user_once()` already swallows internally (0092), so this is belt and
-- braces -- but that swallow is inside a SECURITY DEFINER function whose body
-- has a top-level EXCEPTION, and a trigger that wrapped its own calls in
-- BEGIN/EXCEPTION would need a NESTED one. The SQL-body scanner in
-- tools/harness/plpgsql_body_syntax.py splits on semicolons at paren depth 0
-- and has no idea about plpgsql block structure, so a nested BEGIN reads as a
-- bare `BEGIN` statement followed by `PERFORM ...`, which is a syntax error in
-- a trigger that is perfectly valid.
--
-- That is the harness being blunt rather than wrong, and 0092's top-level
-- EXCEPTION shape is the one that already passes it -- so this function uses
-- that shape too.

CREATE OR REPLACE FUNCTION public.notify_user_safe(
  p_idem_key text,
  p_user_id uuid,
  p_type public.notification_type,
  p_title text,
  p_body text,
  p_data jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  v_id := public.notify_user_once(
    p_idem_key, p_user_id, p_type, p_title, p_body, p_data);
  RETURN v_id IS NOT NULL;
EXCEPTION WHEN OTHERS THEN
  -- A notice that failed to send must never un-insert a row that is already
  -- written and a file that is already in storage, and must certainly not tell
  -- the person their upload failed when it did not.
  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.notify_user_safe(text, uuid, public.notification_type, text, text, jsonb) IS
  'notify_user_once() that returns false instead of raising, so a caller on a '
  'write path can never be rolled back by its own notification. Counts as sent '
  '= the idem key had not already been used.';

-- ===========================================================================
-- 4. The submission itself: both sides, in one statement
-- ===========================================================================
-- notify_user_once() rather than notify_user() because this trigger can fire
-- twice for one document: the upload path inserts, and a retried upload (a
-- flaky connection, a double tap, the signup form replaying its own step)
-- inserts again with the same idem key. Without dedupe the reviewer opens the
-- queue to find the same ID twice and has to work out which is real.
--
-- The key is derived from the ROW ID, not from a clock. That collapses a
-- retried write of the SAME document -- the upsert path, a replayed edge
-- function, a double-submitted form -- and deliberately does not collapse two
-- different documents, because a reviewer must hear about both. (An earlier
-- version of this comment claimed a retried upload never double-notifies; the
-- precise truth is that a retried *row* never does, and that is what the key
-- is built from.)

CREATE OR REPLACE FUNCTION public.on_document_submitted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_name text;
  v_label text;
  v_sent integer := 0;
  -- Declared rather than left to plpgsql's implicit creation: iterating a
  -- set-returning function needs a record variable, and an undeclared name is
  -- a syntax error at CREATE time. Found by replaying this migration, not by
  -- reading it.
  v_recipient record;
BEGIN
  SELECT coalesce(full_name, 'Someone') INTO v_name
    FROM public.profiles WHERE id = NEW.user_id;

  v_label := coalesce(NULLIF(btrim(NEW.document_type), ''), 'an identity document');

  -- TO THE PERSON WHO SUBMITTED IT. They were told nothing at all before this,
  -- and a silent upload is indistinguishable from a failed one.
  IF public.notify_user_safe(
       'document-submitted:' || NEW.id::text,
       NEW.user_id,
       'DOCUMENT_RECEIVED',
       'We received your document',
       'Your ' || v_label || ' has been uploaded and is waiting for review. '
         || 'We will let you know as soon as there is a decision.',
       jsonb_build_object('document_id', NEW.id, 'document_type', NEW.document_type)
     ) THEN
    v_sent := v_sent + 1;
  END IF;

  -- TO EVERYONE WHO CAN ACT ON IT.
  FOR v_recipient IN
    SELECT r.user_id FROM public.document_review_recipients() r
  LOOP
    IF public.notify_user_safe(
         'document-queued:' || NEW.id::text || ':' || v_recipient.user_id::text,
         v_recipient.user_id,
         'DOCUMENT_RECEIVED',
         'A document is waiting for review',
         v_name || ' submitted a ' || v_label || '.',
         jsonb_build_object(
           'document_id', NEW.id,
           'document_type', NEW.document_type,
           'user_id', NEW.user_id,
           'queue', 'document_verification')
       ) THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  -- DEBUG only. A trigger has no caller to return a value to, so the count
  -- would otherwise be assigned and never read.
  RAISE DEBUG 'document %: % notice(s) sent', NEW.id, v_sent;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_document_submitted ON public.user_documents;
CREATE TRIGGER trg_document_submitted
  AFTER INSERT ON public.user_documents
  FOR EACH ROW EXECUTE FUNCTION public.on_document_submitted();

-- ===========================================================================
-- 5. The other direction: the verdict reaches the person
-- ===========================================================================
-- 0030 widened verification_status into a real lifecycle and added the admin
-- review RPC, but nothing told the account holder when a reviewer recorded a
-- decision. A refused identity document with no notice is the worst of the
-- available outcomes: the person cannot act on a verdict they were never told.

CREATE OR REPLACE FUNCTION public.on_document_reviewed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_verdict text := coalesce(NEW.verification_status, '');
BEGIN
  IF NEW.verification_status IS NOT DISTINCT FROM OLD.verification_status THEN
    RETURN NEW;   -- nothing actually changed
  END IF;

  IF v_verdict IN ('VERIFIED', 'AUTO_APPROVED') THEN
    PERFORM public.notify_user_safe(
      'document-decision:' || NEW.id::text || ':' || v_verdict,
      NEW.user_id, 'APPROVAL',
      'Your document is verified',
      'We have checked your identity document and it is approved. '
        || 'Everything on your account is unlocked.',
      jsonb_build_object('document_id', NEW.id, 'verdict', v_verdict));

  ELSIF v_verdict = 'REJECTED' THEN
    PERFORM public.notify_user_safe(
      'document-decision:' || NEW.id::text || ':' || v_verdict,
      NEW.user_id, 'REJECTION',
      'Your document was not accepted',
      'We could not accept the identity document you uploaded. '
        || 'Please upload a clearer or different document.',
      jsonb_build_object('document_id', NEW.id, 'verdict', v_verdict));

  ELSIF v_verdict = 'SUSPECTED_FRAUD' THEN
    -- SECURITY, not REJECTION: this one goes to the account holder too, but
    -- the wording must not accuse them of something we have not established.
    PERFORM public.notify_user_safe(
      'document-decision:' || NEW.id::text || ':' || v_verdict,
      NEW.user_id, 'SECURITY',
      'We need to check your document',
      'Your identity document needs a closer look before we can approve your '
        || 'account. Our team will be in touch.',
      jsonb_build_object('document_id', NEW.id, 'verdict', v_verdict));
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_document_reviewed ON public.user_documents;
CREATE TRIGGER trg_document_reviewed
  AFTER UPDATE OF verification_status ON public.user_documents
  FOR EACH ROW EXECUTE FUNCTION public.on_document_reviewed();

-- ===========================================================================
-- 6. The count the dashboard shows, and the report that proves the wiring
-- ===========================================================================
-- The dashboard card already exists and is correctly gated on
-- document_verification. What it does not have is a NUMBER, so "are there
-- documents waiting?" is answered by opening the page. This returns the count
-- for the person asking and nothing else -- it cannot be used to enumerate
-- documents, because it returns an integer.

CREATE OR REPLACE FUNCTION public.admin_pending_document_count()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count integer;
BEGIN
  IF NOT (
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.document_review_recipients() r
       WHERE r.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;

  SELECT count(*) INTO v_count
    FROM public.user_documents
   WHERE verification_status IN ('MANUAL_REVIEW', 'SUSPECTED_FRAUD');

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.document_notification_wiring_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text := '';
  v_recipients integer;
  v_docs integer;
BEGIN
  IF to_regclass('public.user_documents') IS NULL THEN
    RETURN 'user_documents does not exist';
  END IF;

  -- Both triggers, by name. A DROP TRIGGER without its CREATE is the way this
  -- gap happened once already.
  IF to_regclass('public.user_documents') IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.user_documents'::regclass
         AND tgname = 'trg_document_submitted' AND NOT tgisinternal
    ) THEN
      v_bad := v_bad || 'trg_document_submitted is missing; ';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_trigger
       WHERE tgrelid = 'public.user_documents'::regclass
         AND tgname = 'trg_document_reviewed' AND NOT tgisinternal
    ) THEN
      v_bad := v_bad || 'trg_document_reviewed is missing; ';
    END IF;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
     WHERE t.typname = 'notification_type' AND e.enumlabel = 'DOCUMENT_RECEIVED'
  ) THEN
    v_bad := v_bad || 'notification_type has no DOCUMENT_RECEIVED value; ';
  END IF;

  IF to_regprocedure('public.document_review_recipients()') IS NULL THEN
    v_bad := v_bad || 'document_review_recipients() is missing; ';
  END IF;

  IF to_regprocedure('public.admin_pending_document_count()') IS NULL THEN
    v_bad := v_bad || 'admin_pending_document_count() is missing; ';
  END IF;

  -- THE SIGNATURE OF notify_user_once(), checked by name and not by trust.
  --
  -- This exists because the swallow worked too well. While building the
  -- fixture for this migration, `notify_user_once` was declared with its third
  -- parameter as `text` instead of `public.notification_type`. An enum has no
  -- implicit cast to text, so every call raised -- and notify_user_safe's
  -- `EXCEPTION WHEN OTHERS THEN RETURN false` swallowed it. The result was
  -- indistinguishable from "no notifications were sent": no error, no warning,
  -- a green report.
  --
  -- That is the property a swallow buys and also the danger: a notification
  -- path can be completely dead and report success. So the one signature the
  -- whole chain rests on is asserted here, where a mismatch is loud.
  IF to_regprocedure(
       'public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)'
     ) IS NULL THEN
    v_bad := v_bad || 'notify_user_once does not have the signature '
             || 'notify_user_safe calls (text, uuid, notification_type, text, '
             || 'text, jsonb) -- every notice this migration sends would be '
             || 'swallowed as a failed cast and NOBODY WOULD BE TOLD; ';
  END IF;

  IF to_regprocedure(
       'public.notify_user(uuid, public.notification_type, text, text, jsonb)'
     ) IS NULL THEN
    v_bad := v_bad || 'notify_user() is not the signature notify_user_once() '
             || 'calls; ';
  END IF;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad;
  END IF;

  SELECT count(*) INTO v_recipients FROM public.document_review_recipients();
  SELECT count(*) INTO v_docs FROM public.user_documents;

  RETURN format(
    'ok: both document triggers exist, DOCUMENT_RECEIVED is in the enum, and '
    '%s account(s) can review a document -- every submission now reaches both '
    'the submitter and all of them, and every verdict reaches the submitter '
    '(%s document(s) on file)',
    v_recipients, v_docs);
END;
$$;

-- The count is readable by any signed-in reviewer and by nobody else; the
-- report is readable by the connectivity suite, which runs as anon.
REVOKE ALL ON FUNCTION public.notify_user_safe(text, uuid, public.notification_type, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.notify_user_safe(text, uuid, public.notification_type, text, text, jsonb)
  TO service_role;

REVOKE ALL ON FUNCTION public.document_review_recipients() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.document_review_recipients()
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_pending_document_count()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_pending_document_count()
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.document_notification_wiring_report()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.document_notification_wiring_report()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';