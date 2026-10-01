-- A locked-out person must be able to ask for help, and staff must be able to
-- find the ask.
--
-- WHAT EXISTED
-- ------------
-- The login screen has a working "Forgot Password?" sheet: it calls
-- `resetPasswordForEmail`, and sign-in is `signInWithPassword(email:, password:)`
-- (supabase_service.dart:57), so an emailed link is the correct mechanism and
-- it is already wired. `/update-password` catches the recovery session and
-- calls `updateUser`.
--
-- What does not exist is the case the user named: the person who cannot
-- complete the standard reset. They lost access to the inbox, or the address
-- on the account is wrong, or they signed up with Google and never had a
-- password. Today they have one option, which is to give up.
--
-- `appeal_cases` is the right table to carry it and cannot carry it as written:
--
--   photo_path text NOT NULL
--   phone      text NOT NULL
--
-- A password-reset request has no photo, and by definition may have no usable
-- phone. Both columns are NOT NULL, so the only way to file this case today is
-- to invent a photo, which is precisely the file a reviewer must not have to
-- guess about.
--
-- SO: ADD A CASE TYPE, NOT A PARALLEL TABLE
-- -----------------------------------------
-- A second table would mean a second admin screen, a second queue, a second
-- permission, and a second thing staff forget to check. The user asked for this
-- to be visible in the EXISTING appeals screen, and that is the right call for
-- a second reason as well: an appeals queue that is split by intake channel is
-- worse than one queue, because staff stop checking the smaller one.
--
-- `case_type` is a real column rather than a prefix on `description`, which is
-- what appeal_screen.dart does today for chat escalations ("[Appeal via Help
-- Chat -- tagged: ...]"). A prefix is not filterable, and the moment staff want
-- "show me only the password resets" it stops working.
--
-- WHY THE CHECK IS WRITTEN THE WAY IT IS
-- --------------------------------------
-- Relaxing two NOT NULLs opens the existing path: every current appeal would
-- suddenly be allowed to be fileless and phoneless, and a reviewer looking at an
-- unexplained case with no evidence and no contact detail has nothing to act on.
-- So the constraint moves rather than disappears -- a GENERAL case still has to
-- carry both, exactly as before, and only PASSWORD_RESET may omit them.
--
-- WHY p_email AND p_phone ARE BOTH ASKED FOR
-- -------------------------------------------
-- The function has to be callable by somebody who CANNOT sign in, so it is
-- reachable by `anon`. That makes it an unauthenticated write into a table
-- admins read, and the obvious defence is authentication -- which is exactly
-- what the person in question does not have. So the defence is possession of
-- the registered contact details instead: the pair must match a real account,
-- the response is identical whether or not it did, and nothing is revealed
-- about which addresses exist. One address alone is guessable from a public
-- provider listing; a registered phone number is not.
--
-- The whole function is rate limited on that pair, so it cannot be used to
-- generate a queue of spam cases either.

ALTER TABLE public.appeal_cases
  ADD COLUMN IF NOT EXISTS case_type text NOT NULL DEFAULT 'GENERAL';

-- The contact route, stored. `phone` already existed; there was nowhere to put
-- the address a locked-out person gives, and the whole point of this case type
-- is that they cannot sign in to supply it. Every use of it -- the rate-limit
-- lookup at step 1, the INSERT, the evidence CHECK below, and
-- admin_appeals_screen.dart -- reads this column, so it has to exist before
-- the CHECK that references it, or the push dies with
--
--   ERROR: column "email" does not exist
ALTER TABLE public.appeal_cases
  ADD COLUMN IF NOT EXISTS email text;

-- The two NOT NULLs become relaxable, but not for everyone. Dropping them
-- outright would let an ordinary appeal arrive with no photo and no phone,
-- which is the case a reviewer can do nothing with.
ALTER TABLE public.appeal_cases
  DROP CONSTRAINT IF EXISTS appeal_cases_photo_path_check;
ALTER TABLE public.appeal_cases
  DROP CONSTRAINT IF EXISTS appeal_cases_phone_required;

ALTER TABLE public.appeal_cases
  ALTER COLUMN photo_path DROP NOT NULL,
  ALTER COLUMN phone      DROP NOT NULL;

ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_case_type_known
  CHECK (case_type IN ('GENERAL', 'PASSWORD_RESET'));

-- The constraint that replaces the two NOT NULLs. A GENERAL appeal must be
-- exactly as complete as it always was; a PASSWORD_RESET appeal must supply at
-- least one way to reach the person, or it is not actionable either.
ALTER TABLE public.appeal_cases
  ADD CONSTRAINT appeal_cases_evidence_required
  CHECK (
    (case_type = 'GENERAL'
       AND photo_path IS NOT NULL
       AND length(btrim(phone)) > 0)
    OR
    (case_type = 'PASSWORD_RESET'
       AND (NULLIF(btrim(coalesce(email, '')), '') IS NOT NULL
            OR NULLIF(btrim(coalesce(phone, '')), '') IS NOT NULL))
  );

CREATE INDEX IF NOT EXISTS idx_appeal_cases_type_status
  ON public.appeal_cases (case_type, status, created_at DESC);

COMMENT ON COLUMN public.appeal_cases.case_type IS
  'GENERAL (the original appeal, evidence photo and phone both required) or '
  'PASSWORD_RESET (filed by somebody who cannot sign in, so no photo and '
  'possibly no phone, but at least one contact route). A real column rather '
  'than a tag inside description, because a prefix cannot be filtered on.';

-- ===========================================================================
-- 1. Filing the request
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.request_password_reset_appeal(
  p_email text,
  p_phone text,
  p_notes text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_phone  text := btrim(coalesce(p_phone, ''));
  v_notes  text := NULLIF(btrim(coalesce(p_notes, '')), '');
  v_user   uuid;
  v_open   int;
  v_case   uuid;
BEGIN
  IF v_email = '' AND v_phone = '' THEN
    RAISE EXCEPTION 'CONTACT_REQUIRED';
  END IF;

  -- Possession of the registered details IS the identity check, because the
  -- person filing this cannot authenticate -- that is the entire premise.
  SELECT u.id INTO v_user
    FROM auth.users u
   WHERE (v_email <> '' AND lower(u.email) = v_email)
      OR (v_phone <> '' AND u.phone = v_phone)
   ORDER BY (lower(coalesce(u.email, '')) = v_email) DESC NULLS LAST
   LIMIT 1;

  -- Same answer either way. Saying "no account matches" to a stranger is an
  -- account-existence oracle, and this function is reachable by anon.
  IF v_user IS NULL THEN
    RETURN 'If those details match an account, a reset request has been sent to our team.';
  END IF;

  -- Rate limited per account, not per session, so this cannot be used to flood
  -- the staff queue. A person who genuinely cannot get in may well try more
  -- than once.
  SELECT count(*) INTO v_open
    FROM public.appeal_cases a
   WHERE a.case_type = 'PASSWORD_RESET'
     AND (a.user_id = v_user
          OR (v_email <> '' AND lower(coalesce(a.email, '')) = v_email)
          OR (v_phone <> '' AND a.phone = v_phone))
     AND a.status = 'OPEN'
     AND a.created_at > now() - interval '24 hours';
  IF v_open >= 3 THEN
    RETURN 'If those details match an account, a reset request has been sent to our team.';
  END IF;

  INSERT INTO public.appeal_cases
    (user_id, case_type, photo_path, description, phone, email)
  VALUES
    (v_user, 'PASSWORD_RESET', NULL,
     coalesce(v_notes,
              'Password reset requested from the sign-in screen. The standard '
              'reset link could not be completed.'),
     NULLIF(v_phone, ''), NULLIF(v_email, ''))
  -- The id of the row just written, not a guess at it afterwards. The audit
  -- line used to read it back with `(SELECT max(id) FROM appeal_cases ...)`,
  -- and PostgreSQL has no `max(uuid)` -- not for uuid, not for any type without
  -- an operator -- so every real caller got
  --
  --   ERROR: function max(uuid) does not exist
  --
  -- from a function that is supposed to be filing an appeal for somebody who
  -- cannot sign in. Nothing about this feature could ever have worked.
  RETURNING id INTO v_case;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_user, 'PASSWORD_RESET_REQUESTED', 'appeal_cases',
          v_case,
          jsonb_build_object('has_email', v_email <> '', 'has_phone', v_phone <> ''));

  RETURN 'If those details match an account, a reset request has been sent to our team.';
END;
$$;

COMMENT ON FUNCTION public.request_password_reset_appeal(text, text, text) IS
  'Files a PASSWORD_RESET appeal on behalf of somebody who cannot sign in. '
  'Callable by anon on purpose -- the premise is that they have no session. '
  'Identity is possession of the registered email AND/OR phone, the answer is '
  'the same whether or not it matched, and the pair is rate limited to three '
  'open cases a day so it cannot be used to flood the staff queue.';

-- ===========================================================================
-- 2. The job staff need
-- ===========================================================================
INSERT INTO public.staff_jobs (key, label, description, group_name, sort_order)
VALUES
  ('password_reset', 'Password resets',
   'Action a password reset request filed by somebody who cannot sign in.',
   'Support', 36)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.may_reset_password_for(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.is_ceo(p_user_id)
      OR public.is_super_admin(p_user_id)
      OR public.staff_has_permission(p_user_id, 'password_reset')
      OR EXISTS (
           SELECT 1 FROM public.user_roles ur
            WHERE ur.user_id = p_user_id AND ur.role = 'ADMIN'
         );
$$;

-- ===========================================================================
-- 3. Deciding
-- ===========================================================================
-- The row is marked and the decision is written BEFORE the gateway sets the
-- password, for the same reason approve_account_deletion is: a failure after
-- this point leaves a visible, retryable record rather than a request that
-- silently vanished.
--
-- It returns the target user id because that is the one thing the gateway
-- needs and the client must not be able to choose.
CREATE OR REPLACE FUNCTION public.approve_password_reset_appeal(
  p_case_id uuid,
  p_actor_id uuid,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_case  public.appeal_cases;
  v_actor uuid := coalesce(auth.uid(), p_actor_id);
BEGIN
  IF v_actor IS NULL OR NOT public.may_reset_password_for(v_actor) THEN
    RAISE EXCEPTION 'ONLY_PASSWORD_RESET_STAFF_CAN_APPROVE';
  END IF;

  SELECT * INTO v_case
    FROM public.appeal_cases a
   WHERE a.id = p_case_id
   FOR UPDATE;

  IF v_case.id IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND';
  END IF;
  IF v_case.case_type <> 'PASSWORD_RESET' THEN
    -- Guards against this being used as a second, quieter way to take over an
    -- account: an ordinary appeal is resolved by the appeals screen, which does
    -- not set passwords.
    RAISE EXCEPTION 'NOT_A_PASSWORD_RESET_CASE';
  END IF;
  IF v_case.status <> 'OPEN' THEN
    RAISE EXCEPTION 'ALREADY_DECIDED';
  END IF;

  UPDATE public.appeal_cases
     SET status          = 'RESOLVED',
         resolved_by     = v_actor,
         resolved_at     = now(),
         resolution_note = NULLIF(btrim(coalesce(p_note, '')), '')
   WHERE id = p_case_id;

  INSERT INTO public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  VALUES (v_actor, 'PASSWORD_RESET_APPROVED', 'appeal_cases', p_case_id,
          jsonb_build_object('target_user_id', v_case.user_id));

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_actor, 'APPROVE_PASSWORD_RESET', 'appeal_cases', p_case_id,
          jsonb_build_object('target_user_id', v_case.user_id,
                             'note', coalesce(p_note, '')));

  RETURN v_case.user_id;
END;
$$;

COMMENT ON FUNCTION public.approve_password_reset_appeal(uuid, uuid, text) IS
  'Marks a PASSWORD_RESET appeal resolved and records the decision, and '
  'returns WHICH account to reset. The target is derived from the case, never '
  'from a client parameter, so this cannot be pointed at an arbitrary account.';

-- ===========================================================================
-- 4. Revoking what the old password was protecting
-- ===========================================================================
-- The reason a person asks for a reset is that the old password may be known to
-- somebody else. Changing it does NOT end other sessions: every device still
-- holds a refresh token and carries on working, so the account would look
-- secured and would not be.
--
-- This has to be SQL. `auth.admin.signOut(jwt, scope)` takes a JWT, not a user
-- id -- there is no "sign out every session belonging to this account" call in
-- the admin API -- and the gateway has no way to reach `auth.sessions` through
-- PostgREST. So the one place that can, does.
CREATE OR REPLACE FUNCTION public.revoke_user_sessions(p_user_id uuid)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count int;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN 0;
  END IF;
  DELETE FROM auth.sessions WHERE user_id = p_user_id;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

COMMENT ON FUNCTION public.revoke_user_sessions(uuid) IS
  'Ends every other session for an account whose password was just changed. '
  'A password change alone does not do this: a refresh token outlives it. '
  'service_role only, and called by the gateway immediately after the change.';

-- ===========================================================================
-- 5. Grants
-- ===========================================================================
REVOKE ALL ON FUNCTION public.request_password_reset_appeal(text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_password_reset_appeal(uuid, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.may_reset_password_for(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_user_sessions(uuid) FROM PUBLIC, anon, authenticated;

-- anon on the request function is the point: see the note on it.
GRANT EXECUTE ON FUNCTION public.request_password_reset_appeal(text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.approve_password_reset_appeal(uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.may_reset_password_for(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revoke_user_sessions(uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
