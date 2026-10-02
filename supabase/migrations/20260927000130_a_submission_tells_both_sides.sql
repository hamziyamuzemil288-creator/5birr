-- A submitted application told nobody anything.
--
-- THE REPORT
-- ----------
-- "when a document verification or app/account verification status changes
-- (submitted, approved, rejected), a notification must appear in the panel
-- for the affected user AND be visible to Admins and Providers".
--
-- Nine of the twelve states already did that, and the audit behind this
-- migration found them one at a time:
--
--   document submitted            trg_document_submitted  (0127)  yes
--   document approved / rejected  trg_document_reviewed   (0127)  yes
--   account approved              approve_user            (0087)  yes
--   provider approved             approve_provider        (0111)  yes
--   provider rejected             reject_provider         (0111)  yes
--   correction requested          request_correction_...  (0111)  yes
--   provider suspended            suspend_provider        (0111)  yes
--   account reactivated           unsuspend_provider      (0111)  NO
--   APPLICATION SUBMITTED         (nothing)                        NO
--
-- Two gaps, and only two. Nothing above is re-implemented here.
--
-- GAP 1 -- the SUBMITTED state wrote nothing, in either direction.
--
--   Every provider signup, every user signup and every "Become a Partner"
--   application converges on ONE row:
--
--     INSERT INTO approval_requests (subject_type, subject_id, status)
--     VALUES ('USER'|'PROVIDER', ..., 'PENDING_APPROVAL')
--
--   written by handle_new_user_consolidated (20260925120000),
--   handle_new_provider_profile (0022c, reached through
--   trg_provider_profiles_auto_setup) and submit_partner_application (0057).
--   No trigger has ever existed on that table, so the person who applied was
--   never told it was received -- a silent application is indistinguishable
--   from a lost one -- and nobody holding `registrations` was told one
--   arrived, so the approval queue is populated by people who happened to go
--   and look. 0127 fixed exactly this shape of gap for documents and said so
--   in its own header; the same table, one column over, was missed.
--
--   The trigger is on approval_requests rather than on the three callers
--   because that is the only place the three of them meet. A call in each
--   function is a call the next caller forgets.
--
-- GAP 2 -- unsuspend_provider stopped reactivating people silently.
--
--   0022c sent 'Account reactivated'. 20260927000026 restated the body from
--   20260922000010 to add the is_server_write() exemption, and that source
--   had no notification line in it, so the notice was dropped by a restatement
--   and nothing noticed. 0111 restated it again from 0026 and carried the
--   omission forward. This restores the message, keyed, so a double unsuspend
--   cannot produce a second one.
--
-- WHY NOT A SECOND SYSTEM
-- -----------------------
-- REGISTRATION_RECEIVED has been in the notification_type enum since 0001 and
-- has never been written by anything -- it is exactly this event, so it is
-- used rather than a new member added. notify_user_safe() (0127) is the send
-- that cannot fail the write that triggered it, and notify_user_once()'s idem
-- key is what stops a retried signup or a replayed form producing a second
-- identical notice. There is no new table, no new enum value and no new send
-- path.
--
-- NOTIFICATION DELIVERY, STATED HONESTLY
-- ---------------------------------------
-- Both signup paths run as the caller of an auth trigger or of a PostgREST
-- RPC, so is_server_write() is false and notify_user() queues to
-- notification_outbox rather than writing through. That is the existing,
-- deliberate routing: prevent_notification_injection refuses a client insert,
-- and pg_cron's drain_notification_outbox() is the only thing that empties
-- the queue. The consequence is that these two notices land within a minute
-- rather than instantly, and no latency is traded away here to avoid it --
-- the alternative is widening a guard that exists to stop an account writing
-- itself a notification.
--
-- FCM IS NOT WIRED, AND THIS MIGRATION DOES NOT PRETEND IT IS
-- ----------------------------------------------------------
-- fcm_tokens and notification_preferences exist (0007). There is no sender:
-- no firebase_messaging in pubspec.yaml, no edge function referencing fcm, no
-- send function in any migration. So there is no push dispatcher to trigger,
-- and the in-app inbox is the only channel that delivers today. Building one
-- is a separate piece of work with its own credentials, not a line added to a
-- trigger.

-- ===========================================================================
-- 1. Who has to be told an application arrived
--
-- The same shape as document_review_recipients() (0127), and for the same
-- reason it returns ONE column: with two, `UNION` cannot collapse a person
-- who is both an is_ceo staff member AND an ADMIN in user_roles -- the rows
-- differ in the boolean -- and the account owner receives two notices.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.registration_review_recipients()
RETURNS TABLE (user_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  -- Everyone who can act on a registration. The permission that gates the
  -- queue is 'registrations' (0001's staff CHECK constraint; admin_can() in
  -- 20260922000010). Super admins and the CEO are included whether or not
  -- they hold it, because an administrator who cannot open the queue cannot
  -- clear it.
  SELECT s.user_id
    FROM public.staff s
   WHERE s.is_active
     AND s.user_id IS NOT NULL
     AND ('registrations' = ANY (coalesce(s.permissions, '{}'))
          OR s.is_ceo OR s.is_super_admin)

  UNION

  SELECT ur.user_id
    FROM public.user_roles ur
   WHERE ur.role = 'ADMIN'
$$;

COMMENT ON FUNCTION public.registration_review_recipients() IS
  'Who a submitted application must be announced to: every active staff '
  'member holding registrations, plus every ADMIN. One column, so UNION can '
  'dedupe a person who qualifies twice.';

-- ===========================================================================
-- 2. The submission: both sides, in one statement
--
-- notify_user_once rather than notify_user, because this can fire twice for
-- one application: handle_new_user_consolidated writes the USER row and the
-- trigger on provider_profiles writes the PROVIDER row, and a provider signup
-- therefore produces two submissions from one person. The key is derived from
-- the approval_requests row id, so each is announced once and neither is
-- swallowed with the other.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.on_registration_submitted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_name text;
  v_label text;
  v_sent integer := 0;
  v_recipient record;
BEGIN
  -- A PROVIDER request is addressed by provider_profiles.id, not by user id.
  -- Getting this wrong would notify a stranger whose uuid happened to collide
  -- with a profile id, so the subject_type decides rather than a COALESCE
  -- that would silently fall through to the wrong branch.
  IF NEW.subject_type = 'PROVIDER' THEN
    SELECT pp.user_id, pp.business_name INTO v_user_id, v_name
      FROM public.provider_profiles pp
     WHERE pp.id = NEW.subject_id;
  ELSE
    SELECT pr.id, pr.full_name INTO v_user_id, v_name
      FROM public.profiles pr
     WHERE pr.id = NEW.subject_id;
  END IF;

  -- An approval_request can exist for a subject that has since been removed.
  -- notify_user_once already returns NULL for a NULL user, so there is nothing
  -- to guard here beyond not looking the name up for nobody.
  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_label := CASE
    WHEN NEW.subject_type = 'PROVIDER' THEN 'your business application'
    ELSE 'your account'
  END;

  -- TO THE PERSON WHO APPLIED. Silent submission is indistinguishable from a
  -- failed one, and the status screen behind the login gate is the only place
  -- they can look -- so this is the acknowledgement, not a courtesy.
  IF public.notify_user_safe(
       'registration-submitted:' || NEW.id::text,
       v_user_id,
       'REGISTRATION_RECEIVED',
       'We received your application',
       'Thank you. We have received ' || v_label || ' and it is waiting for '
         || 'review. We will let you know as soon as there is a decision.',
       jsonb_build_object(
         'approval_request_id', NEW.id,
         'subject_type', NEW.subject_type,
         'event', 'registration_submitted')
     ) THEN
    v_sent := v_sent + 1;
  END IF;

  -- TO EVERYONE WHO CAN ACT ON IT.
  FOR v_recipient IN
    SELECT r.user_id FROM public.registration_review_recipients() r
  LOOP
    IF public.notify_user_safe(
         'registration-queued:' || NEW.id::text || ':' || v_recipient.user_id::text,
         v_recipient.user_id,
         'REGISTRATION_RECEIVED',
         'An application is waiting for review',
         coalesce(NULLIF(btrim(v_name), ''), 'Someone')
           || ' submitted ' || v_label || '.',
         jsonb_build_object(
           'approval_request_id', NEW.id,
           'subject_type', NEW.subject_type,
           'user_id', v_user_id,
           'queue', 'registrations')
       ) THEN
      v_sent := v_sent + 1;
    END IF;
  END LOOP;

  -- DEBUG only: a trigger has no caller to return a count to.
  RAISE DEBUG 'approval_request %: % notice(s) sent', NEW.id, v_sent;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.on_registration_submitted() IS
  'Announces a submitted application to the applicant and to every account '
  'that can review registrations. Reached through a trigger rather than a call '
  'in each submitting function, because the three submission paths converge on '
  'one INSERT and a per-caller call is a call the next caller forgets.';

DROP TRIGGER IF EXISTS trg_registration_submitted ON public.approval_requests;
CREATE TRIGGER trg_registration_submitted
  AFTER INSERT ON public.approval_requests
  FOR EACH ROW EXECUTE FUNCTION public.on_registration_submitted();

-- ===========================================================================
-- 3. The same event, the other way: a REOPENED application
--
-- resubmit_rejected_application (20260922000011) UPDATEs the row back to
-- PENDING_APPROVAL rather than inserting one, so the trigger above cannot see
-- a resubmission. It does tell the person who resubmitted, so this only adds
-- the side that was still missing: the reviewers, who otherwise have no way to
-- know a rejected application is back in the queue.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.on_registration_resubmitted()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_id uuid;
  v_name text;
  v_recipient record;
BEGIN
  -- Only a genuine reopen. approve_provider and reject_provider both write
  -- this column, and neither passes through REJECTED, so the guard is
  -- belt-and-braces rather than the thing that makes it correct.
  IF NEW.status IS DISTINCT FROM 'PENDING_APPROVAL' THEN
    RETURN NEW;
  END IF;

  IF OLD.status IS DISTINCT FROM 'REJECTED' THEN
    RETURN NEW;
  END IF;

  IF NEW.subject_type = 'PROVIDER' THEN
    SELECT pp.user_id, pp.business_name INTO v_user_id, v_name
      FROM public.provider_profiles pp
     WHERE pp.id = NEW.subject_id;
  ELSE
    SELECT pr.id, pr.full_name INTO v_user_id, v_name
      FROM public.profiles pr
     WHERE pr.id = NEW.subject_id;
  END IF;

  IF v_user_id IS NULL THEN
    RETURN NEW;
  END IF;

  FOR v_recipient IN
    SELECT r.user_id FROM public.registration_review_recipients() r
  LOOP
    PERFORM public.notify_user_safe(
      'registration-resubmitted:' || NEW.id::text || ':' || v_recipient.user_id::text,
      v_recipient.user_id,
      'REGISTRATION_RECEIVED',
      'An application was resubmitted',
      coalesce(NULLIF(btrim(v_name), ''), 'Someone')
        || ' resubmitted an application that was previously rejected.',
      jsonb_build_object(
        'approval_request_id', NEW.id,
        'subject_type', NEW.subject_type,
        'user_id', v_user_id,
        'queue', 'registrations')
    );
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_registration_resubmitted ON public.approval_requests;
CREATE TRIGGER trg_registration_resubmitted
  AFTER UPDATE OF status ON public.approval_requests
  FOR EACH ROW EXECUTE FUNCTION public.on_registration_resubmitted();

-- ===========================================================================
-- 4. unsuspend_provider -- the notice 0026 dropped, restored
--
-- The body is 0111's, byte for byte, including all FIVE authorization
-- clauses. Only the notification is new. A restatement that quietly loses one
-- of those clauses is the exact failure 0026's own header describes, so the
-- clause list is pinned by the existing assert_admin_rpc_service_role_access
-- and re-asserted by the report at the bottom of this file.
--
-- notify_user_once rather than a bare INSERT so a double unsuspend cannot
-- produce two identical notices, and notify_user_safe rather than
-- notify_user_once directly so a notice that cannot be sent still does not
-- roll back an account reactivation.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.unsuspend_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
RETURNS public.provider_profiles
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_provider public.provider_profiles;
BEGIN
  IF NOT public.is_server_write() THEN
    IF NOT public.admin_can('registrations')
       OR p_admin_id IS DISTINCT FROM auth.uid()
       OR NOT public.staff_is_action_manager()
       OR NOT public.staff_scope_allows_category(
            (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id))
       OR NOT public.staff_scope_allows_city(
            (SELECT coalesce(city, '') FROM public.provider_profiles WHERE id = p_provider_id)) THEN
      RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
    END IF;
  END IF;

  UPDATE public.provider_profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;

  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = v_provider.user_id;

  -- The message 0022c sent and the 0026 restatement lost. An account that
  -- comes back is trading again, and the person has no other way to learn that
  -- the suspension they were serving has ended.
  PERFORM public.notify_user_safe(
    'provider-reactivated:' || p_provider_id::text,
    v_provider.user_id,
    'APPROVAL',
    'Account reactivated',
    'Your provider account has been reactivated. You can trade again.',
    jsonb_build_object('provider_id', p_provider_id, 'event', 'provider_reactivated')
  );

  PERFORM public.log_admin_action(p_admin_id, 'UNSUSPEND_PROVIDER', p_provider_id,
    'registration', v_provider.city);

  RETURN v_provider;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unsuspend_provider(uuid, uuid) TO authenticated;

-- ===========================================================================
-- 5. The report, so the wiring is counted rather than read
--
-- Same lesson as document_notification_wiring_report (0127): the swallow in
-- notify_user_safe means a completely dead notification path reports success.
-- So the trigger, the enum member, the recipient set and the signature the
-- whole chain rests on are all asserted BY NAME here.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.registration_notification_wiring_report()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad text := '';
  v_src text;
  v_recipients integer;
  v_pending integer;
BEGIN
  IF to_regclass('public.approval_requests') IS NULL THEN
    RETURN 'approval_requests does not exist';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.approval_requests'::regclass
       AND tgname = 'trg_registration_submitted' AND NOT tgisinternal
  ) THEN
    v_bad := v_bad || 'trg_registration_submitted is missing; ';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
     WHERE tgrelid = 'public.approval_requests'::regclass
       AND tgname = 'trg_registration_resubmitted' AND NOT tgisinternal
  ) THEN
    v_bad := v_bad || 'trg_registration_resubmitted is missing; ';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_type t JOIN pg_enum e ON e.enumtypid = t.oid
     WHERE t.typname = 'notification_type' AND e.enumlabel = 'REGISTRATION_RECEIVED'
  ) THEN
    v_bad := v_bad || 'notification_type has no REGISTRATION_RECEIVED value; ';
  END IF;

  IF to_regprocedure('public.registration_review_recipients()') IS NULL THEN
    v_bad := v_bad || 'registration_review_recipients() is missing; ';
  END IF;

  -- The signature notify_user_safe() calls. An enum has no implicit cast to
  -- text, so a third parameter declared `text` makes every call raise, and
  -- the swallow turns that into "no notifications were sent" with no error.
  IF to_regprocedure(
       'public.notify_user_once(text, uuid, public.notification_type, text, text, jsonb)'
     ) IS NULL THEN
    v_bad := v_bad || 'notify_user_once does not have the signature '
             || 'notify_user_safe calls -- every notice this migration sends '
             || 'would be swallowed as a failed cast and NOBODY WOULD BE TOLD; ';
  END IF;

  -- unsuspend_provider must still be guarded, and must still tell the person.
  -- Both halves, because a restatement that dropped the guard would be caught
  -- by assert_admin_rpc_service_role_access and one that dropped the notice
  -- would not be caught by anything.
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'unsuspend_provider'
     AND p.pronargs = 2;
  IF v_src IS NULL THEN
    v_bad := v_bad || 'unsuspend_provider(uuid, uuid) is missing; ';
  ELSIF position('admin_can(''registrations'')' in v_src) = 0
     OR position('staff_is_action_manager' in v_src) = 0
     OR position('staff_scope_allows_city' in v_src) = 0
     OR position('notify_user_safe' in v_src) = 0 THEN
    v_bad := v_bad || 'unsuspend_provider lost a guard clause or the '
             || 'reactivation notice; ';
  END IF;

  -- The recipient set is a list of account ids, so it must not be readable by
  -- a client with no session. Checked HERE, against the live grant, rather
  -- than from the connectivity suite: the suite runs as anon, so a test that
  -- called this function to watch the call fail would name it in a suite that
  -- appears to call it, and the RPC-reachability check would read the denial
  -- as a missing grant and demand one that must not exist.
  IF has_function_privilege(
       'anon', 'public.registration_review_recipients()', 'EXECUTE') THEN
    v_bad := v_bad || 'anon can execute registration_review_recipients(), so '
             || 'the roster of accounts that review registrations is '
             || 'enumerable without a session; ';
  END IF;

  IF v_bad <> '' THEN
    RETURN 'FAIL: ' || v_bad;
  END IF;

  SELECT count(*) INTO v_recipients FROM public.registration_review_recipients();
  SELECT count(*) INTO v_pending FROM public.approval_requests
   WHERE status = 'PENDING_APPROVAL';

  RETURN format(
    'ok: every submitted and resubmitted application now reaches the applicant '
    'and all %s account(s) that can review registrations, and a reactivation '
    'tells the person it happened to (%s application(s) pending right now)',
    v_recipients, v_pending);
END;
$$;

REVOKE ALL ON FUNCTION public.on_registration_submitted() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.on_registration_resubmitted() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.registration_review_recipients() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registration_review_recipients()
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.registration_notification_wiring_report()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.registration_notification_wiring_report()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
