-- An admin can actually VERIFY a document — and the user can see the truth.
--
-- THE REPORTED BUG
-- ---------------
-- "The verification page inside profile also default verified txt — it does not
-- identify whether a real document is available and verified by admin or not,
-- it just keeps saying verified."
--
-- Two defects stacked, and neither was in the widget:
--
-- 1. THERE WAS NO "VERIFIED BY ADMIN" STATE TO SHOW. The column's CHECK
--    constraint (20260924000004) allowed exactly three values:
--    MANUAL_REVIEW, AUTO_APPROVED, SUSPECTED_FRAUD. An administrator therefore
--    had no legal value to write when they looked at an ID and approved it —
--    `user_documents_admin_manage` allows admins to UPDATE the row, and the
--    very next thing the database did was reject the update. The admin screen
--    had no Approve/Reject control either. Identity review was not a feature;
--    it was an absent enum value.
--
-- 2. THE CLIENT READ "HAS A DOCUMENT" AS "VERIFIED".
--    ProviderDocGate.checkStatus() returns `satisfied` for ANY accepted
--    document type whose status is not SUSPECTED_FRAUD — so a freshly
--    uploaded, un-reviewed ID read as `satisfied`, and the profile tile
--    rendered its green "Identity verified" / "Verified" chip. A user who had
--    uploaded nothing and a user whose ID an admin had never opened were
--    indistinguishable.
--
-- WHAT THIS MIGRATION CHANGES
-- ---------------------------
--  * Widens user_documents.verification_status to a real lifecycle:
--    PENDING-ISH (MANUAL_REVIEW) -> VERIFIED | REJECTED by an admin, plus the
--    existing AUTO_APPROVED (QR agent) and SUSPECTED_FRAUD (agent flag).
--  * Adds review_user_document(): the ONLY path to VERIFIED/REJECTED,
--    admin-only, audited, and it notifies the user.
--  * Teaches provider_docs_satisfied() about VERIFIED, so approving a
--    document does not silently LOCK the provider out of their own business.
--    The gate stays deliberately generous (a document awaiting review must not
--    block work) — that generosity is a gating decision, and is exactly why it
--    must never be reused as a display status. The client fix for the display
--    side lives in lib/core/services/provider_doc_gate.dart.

-- ===========================================================================
-- 1. The lifecycle
-- ===========================================================================
ALTER TABLE public.user_documents
  DROP CONSTRAINT IF EXISTS user_documents_verification_status_check;

ALTER TABLE public.user_documents
  ADD CONSTRAINT user_documents_verification_status_check
  CHECK (verification_status IN (
    'MANUAL_REVIEW',   -- uploaded, no verdict yet
    'AUTO_APPROVED',   -- QR agent accepted it
    'VERIFIED',        -- an administrator approved it  (new)
    'REJECTED',        -- an administrator refused it    (new)
    'SUSPECTED_FRAUD'  -- the agent flagged it
  ));

COMMENT ON COLUMN public.user_documents.verification_status IS
  'Identity-document lifecycle: MANUAL_REVIEW (no verdict) -> VERIFIED | '
  'REJECTED by an administrator, AUTO_APPROVED by the QR agent, or '
  'SUSPECTED_FRAUD when the agent flags it.';

-- ===========================================================================
-- 2. The admin decision
-- ===========================================================================
-- SECURITY DEFINER is required only so the function can read the row and
-- write the audit entry; the admin check itself is explicit and runs against
-- the CALLER's auth.uid() (auth.uid() reads the request JWT, which a
-- SECURITY DEFINER body still sees — unlike current_user, which is the
-- function owner and the reason the 0029/0030/0033/0034 guards were inert).
CREATE OR REPLACE FUNCTION public.review_user_document(
  p_document_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
)
RETURNS public.user_documents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_doc public.user_documents;
  v_verdict text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'DOCUMENT_REVIEW_IS_ADMIN_ONLY';
  END IF;

  IF p_decision IS NULL OR upper(btrim(p_decision)) NOT IN ('VERIFIED', 'REJECTED') THEN
    RAISE EXCEPTION 'INVALID_DOCUMENT_DECISION';
  END IF;
  v_verdict := upper(btrim(p_decision));

  SELECT * INTO v_doc
  FROM public.user_documents
  WHERE id = p_document_id
  FOR UPDATE;

  IF v_doc.id IS NULL THEN
    RAISE EXCEPTION 'DOCUMENT_NOT_FOUND';
  END IF;

  -- Idempotent: re-approving an already-approved document is a no-op rather
  -- than an error, so a double tap in the admin UI cannot look like a failure.
  IF v_doc.verification_status IS DISTINCT FROM v_verdict THEN
    -- prevent_document_verification_forgery (20260924000004) runs BEFORE
    -- UPDATE and lifts its restriction only for is_admin() or a service-role
    -- caller. This function is reached with the administrator's own JWT, so
    -- that condition holds and the write below is legal. (An earlier version
    -- of the admin UI wrote the column directly and the trigger correctly
    -- refused with DOCUMENT_VERIFICATION_REQUIRES_VERIFIER.)
    UPDATE public.user_documents
    SET verification_status = v_verdict,
        verified_at = now(),
        agent_verdict = CASE
          WHEN p_note IS NULL OR btrim(p_note) = '' THEN agent_verdict
          ELSE COALESCE(agent_verdict, '{}'::jsonb)
               || jsonb_build_object('admin_note', btrim(p_note))
        END
    WHERE id = p_document_id
    RETURNING * INTO v_doc;

    -- Inside the "did it change" branch, unlike the audit line below. A
    -- double tap on Verify is idempotent for the row and must not be a second
    -- identical notification in the user's list; the audit entry still records
    -- both, because an administrator pressing a button twice is itself worth
    -- being able to see.
    --
    -- notifications.type is the notification_type ENUM (0001), not free text:
    -- 'document_review' is not a value, and an insert that failed HERE would
    -- abort the whole transaction — rolling the verdict back and reporting the
    -- approval as failed, which is the worst possible outcome. APPROVAL and
    -- REJECTION already exist and are exactly the right two.
    INSERT INTO public.notifications (user_id, type, title, body)
    VALUES (
      v_doc.user_id,
      CASE WHEN v_verdict = 'VERIFIED'
           THEN 'APPROVAL'::public.notification_type
           ELSE 'REJECTION'::public.notification_type END,
      CASE WHEN v_verdict = 'VERIFIED'
           THEN 'Your ID was verified' ELSE 'Your ID was not accepted' END,
      CASE WHEN v_verdict = 'VERIFIED'
           THEN 'Our team checked your identity document and marked it verified.'
           ELSE 'Our team checked your identity document and could not accept '
                || 'it. Please upload a clear, valid document.'
      END
    );
  END IF;

  PERFORM public.log_admin_action(
    auth.uid(),
    CASE WHEN v_verdict = 'VERIFIED'
         THEN 'DOCUMENT_VERIFIED' ELSE 'DOCUMENT_REJECTED' END,
    v_doc.user_id,
    'document',
    NULL,
    '{}'::text[],
    jsonb_build_object(
      'document_id', p_document_id,
      'document_type', v_doc.document_type,
      'decision', v_verdict
    )
  );

  RETURN v_doc;
END;
$$;

REVOKE ALL ON FUNCTION public.review_user_document(uuid, text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.review_user_document(uuid, text, text)
  TO authenticated;

-- ===========================================================================
-- 3. Approving a document must not lock the provider out
-- ===========================================================================
-- provider_docs_satisfied() is the server-side re-check on protected writes
-- (listing upload, claim_ride). It accepts MANUAL_REVIEW and AUTO_APPROVED.
-- Without VERIFIED in that list, the act of approving someone's ID would flip
-- their gate from open to shut — an admin action that breaks the account it
-- was meant to bless. REJECTED and SUSPECTED_FRAUD stay out on purpose.
CREATE OR REPLACE FUNCTION public.provider_docs_satisfied(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.user_documents d
    WHERE d.user_id = p_user_id
      AND d.document_type IN (
        'NATIONAL_ID', 'DRIVING_LICENSE', 'DRIVING_LICENSE_ID', 'PASSPORT'
      )
      AND COALESCE(d.verification_status, 'MANUAL_REVIEW') IN (
        'MANUAL_REVIEW', 'AUTO_APPROVED', 'VERIFIED'
      )
  );
$$;

GRANT EXECUTE ON FUNCTION public.provider_docs_satisfied(uuid) TO authenticated;

-- ===========================================================================
-- 4. Assertion: the review path is admin-only and the gate is not inverted
-- ===========================================================================
-- Source-level, because that is the only signal available without a
-- privileged client. The behavioural half is assert_document_review_is_admin_only
-- in the connectivity suite, which actually calls the function as a
-- non-admin and requires the refusal.
CREATE OR REPLACE FUNCTION public.assert_document_review_is_admin_only()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_flat text;
  v_gate text;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
  INTO v_flat
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'review_user_document'
    AND p.pronargs = 3;
  IF v_flat IS NULL THEN
    RETURN false;
  END IF;

  -- Admin-only, checked against the caller.
  IF position('is_admin()' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  IF position('document_review_is_admin_only' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- Both decisions must be reachable, and nothing else.
  IF position('not in (''verified'', ''rejected'')' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  IF position('invalid_document_decision' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- It must actually write the column. A function that validated the decision
  -- and returned without updating would pass every check above.
  IF position('set verification_status = v_verdict' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- current_user is the function owner inside a SECURITY DEFINER body, so a
  -- guard written on it is inert (0029/0030/0033/0034 all shipped that bug).
  IF position('current_user' in v_flat) > 0 THEN
    RETURN false;
  END IF;

  -- The gate must accept the new terminal state, or approving a document
  -- closes the very gate it was meant to open.
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
  INTO v_gate
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'provider_docs_satisfied'
    AND p.pronargs = 1;
  IF v_gate IS NULL THEN
    RETURN false;
  END IF;
  RETURN position(
           '''manual_review'', ''auto_approved'', ''verified''' in v_gate
         ) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_document_review_is_admin_only() IS
  'True when review_user_document() is admin-only, accepts only '
  'VERIFIED/REJECTED, really writes verification_status, and '
  'provider_docs_satisfied() still counts a VERIFIED document.';

GRANT EXECUTE ON FUNCTION public.assert_document_review_is_admin_only()
  TO anon, authenticated;
