-- ============================================================
-- Migration 20260922000011_rejected_application_resubmission.sql
-- 5BIRR / Aliob — Rejected-application resubmission flow
-- ============================================================
-- Completes the last broken auth-flow leg (the TODOs on
-- rejected_screen.dart): users whose profile.status = 'REJECTED' could
-- only log out. There was no way to correct and resubmit, so every
-- rejected account was a dead end.
--
-- WHY AN RPC: trg_profiles_security ->
-- prevent_profile_self_privilege_escalation() (restated by 0034) blocks
-- ANY client-side profile status change unless is_admin() or the write
-- comes from a trusted server path (postgres / service_role). Flipping
-- REJECTED -> PENDING_APPROVAL must therefore run through a SECURITY
-- DEFINER function — the same sanctioned-server-path pattern as
-- approve_provider / request_correction_provider / approve_user.
--
-- SAFETY (no self-approval is possible):
--   - Only the owner (auth.uid()) may reopen their own application.
--   - Only REJECTED -> PENDING_APPROVAL is allowed (both on profiles and
--     on the matching provider_profiles row for providers).
--   - The approval_requests row is reopened so the admin queue shows the
--     application again; approval_history keeps the original rejection
--     untouched (audit trail intact). The admin's next decision writes
--     the next history row.
--   - The user gets a CORRECTION_REQUIRED notification confirming the
--     resubmission (visible in their notifications inbox).
--
-- Additive and idempotent: no columns, policies, or triggers change.
-- ============================================================

CREATE OR REPLACE FUNCTION public.reopen_rejected_application(
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_profile public.profiles;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND';
  END IF;
  IF v_profile.status <> 'REJECTED' THEN
    -- Anything else (PENDING/ APPROVED) is either already in review or
    -- active — never reopen those.
    RAISE EXCEPTION 'APPLICATION_NOT_REJECTED';
  END IF;

  -- 1. Reopen the login gate: profile back to pending review.
  UPDATE public.profiles
     SET status = 'PENDING_APPROVAL', updated_at = now()
   WHERE id = v_uid;

  -- 2. Reopen the USER approval request (exists for every signup).
  UPDATE public.approval_requests
     SET status = 'PENDING_APPROVAL'
   WHERE subject_type = 'USER'
     AND subject_id = v_uid
     AND status = 'REJECTED';

  -- 3. Providers: mirror the reopen on their provider profile and its
  --    PROVIDER approval request (handle_new_user creates at most one
  --    provider_profiles row per user).
  IF EXISTS (SELECT 1 FROM public.provider_profiles WHERE user_id = v_uid) THEN
    UPDATE public.provider_profiles
       SET status = 'PENDING_APPROVAL', updated_at = now()
     WHERE user_id = v_uid
       AND status = 'REJECTED';

    UPDATE public.approval_requests
       SET status = 'PENDING_APPROVAL'
     WHERE subject_type = 'PROVIDER'
       AND subject_id IN (
             SELECT id FROM public.provider_profiles WHERE user_id = v_uid
           )
       AND status = 'REJECTED';
  END IF;

  -- 4. Confirm to the user (their own inbox; admin sees the reopened
  --    application appear in the approval queue).
  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    v_uid,
    'CORRECTION_REQUIRED',
    'Application resubmitted',
    'You resubmitted your application for review.'
      || COALESCE(' Note to reviewers: ' || left(trim(p_note), 500), '')
  );
END;
$$;

-- Owner-invoked from the rejection screen.
REVOKE EXECUTE ON FUNCTION public.reopen_rejected_application(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.reopen_rejected_application(text) TO authenticated;

NOTIFY pgrst, 'reload schema';
