-- Behavioural half of the document-review work: perform the actual
-- privilege-escalation attack and require the database to refuse it.
--
-- WHY A SOURCE-TEXT ASSERTION IS NOT ENOUGH HERE
-- ----------------------------------------------
-- assert_document_review_is_admin_only (20260927000030) reads pg_proc.prosrc and
-- can tell that review_user_document() mentions is_admin(). It cannot tell a
-- guard that RUNS from a guard that RETURNS on its first line — which is
-- precisely how 0029/0030/0033/0034 shipped four inert guards that were green
-- in the suite. This test calls the function for real, as a real non-admin, and
-- requires the refusal.
--
-- It also pins the second half of the contract: an administrator's approval
-- must be WRITABLE. A migration that simply removed is_admin() from the
-- function would pass the attack test and leave the feature broken, so both
-- directions are checked in one place.

CREATE OR REPLACE FUNCTION public.assert_document_review_refuses_non_admins()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e602';
  v_admin uuid := '00000000-0000-4000-8000-00000000e603';
  v_doc uuid;
  v_status text;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES
    (v_user,  'doc-review-probe@example.invalid',  now()),
    (v_admin, 'doc-review-admin@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Doc Review Probe', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.user_documents (user_id, document_type, storage_path)
  VALUES (v_user, 'NATIONAL_ID', 'probe/document.jpg')
  RETURNING id INTO v_doc;

  IF v_doc IS NULL THEN
    RAISE EXCEPTION 'could not create the probe document row';
  END IF;

  ------------------------------------------------------------------
  -- 1. The attack: an ordinary user approves their own ID document.
  ------------------------------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);

  IF public.is_admin() THEN
    RAISE EXCEPTION
      'the probe user is unexpectedly an admin, so this test cannot prove anything';
  END IF;

  BEGIN
    PERFORM public.review_user_document(v_doc, 'VERIFIED', NULL);

    SELECT verification_status INTO v_status
    FROM public.user_documents WHERE id = v_doc;

    IF v_status = 'VERIFIED' THEN
      RAISE EXCEPTION
        'a non-admin was able to mark their own document VERIFIED -- the admin check did not fire';
    END IF;
    RAISE EXCEPTION 'a non-admin document review was not refused';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE 'a non-admin %' THEN
        RAISE;
      END IF;
      -- Any other error is the refusal we wanted.
      NULL;
  END;

  ------------------------------------------------------------------
  -- 2. The positive direction: a real administrator CAN approve.
  --    Removing is_admin() would satisfy the test above and break the
  --    feature, so the write must be proven, not assumed.
  ------------------------------------------------------------------
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text,
                                       'role', 'authenticated')::text, true);
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'the admin probe fixture is not recognised as an admin';
  END IF;

  BEGIN
    PERFORM public.review_user_document(v_doc, 'VERIFIED', 'probe approval');
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'an administrator could not verify a document: %', SQLERRM;
  END;

  SELECT verification_status INTO v_status
  FROM public.user_documents WHERE id = v_doc;
  IF v_status IS DISTINCT FROM 'VERIFIED' THEN
    RAISE EXCEPTION
      'review_user_document() reported success but the document reads %', v_status;
  END IF;

  -- 3. And a verified document must leave the provider gate OPEN. Approving
  --    someone's ID closed provider_docs_satisfied() the first time this
  --    lifecycle was written; the admin action that was meant to bless an
  --    account instead locked the provider out of their own business.
  IF NOT public.provider_docs_satisfied(v_user) THEN
    RAISE EXCEPTION
      'provider_docs_satisfied() is false for a user whose document was just VERIFIED -- approving a document must not close the provider gate';
  END IF;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

COMMENT ON FUNCTION public.assert_document_review_refuses_non_admins() IS
  'Attempts to self-verify an identity document as a non-admin and requires '
  'the refusal, then requires a real admin to succeed and the provider gate '
  'to stay open afterwards. Behavioural by necessity: the inert guards this '
  'suite once passed on source text alone all looked correct here.';

GRANT EXECUTE ON FUNCTION public.assert_document_review_refuses_non_admins()
  TO anon, authenticated;
