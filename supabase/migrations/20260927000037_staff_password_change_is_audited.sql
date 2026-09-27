-- A staff member changing their own password leaves a record.
--
-- THE GAP THIS CLOSES
-- -------------------
-- Self-service password change has existed since the gateway shipped, and it
-- is the one act of real consequence a staff member can take on their own
-- account: it is how a leaked CEO-issued password gets replaced. It also left
-- NO trace anywhere.
--
-- That is the same defect class migration 20260927000035 was written to end.
-- A password change is an 'access' event — staff_activity_log already has a
-- kind for exactly this — and the fact that the column existed and nothing
-- wrote to it is worse than never having had it.
--
-- WHY THE FUNCTION HAD TO BE RESTATED, NOT JUST CALLED
-- ----------------------------------------------------
-- log_staff_activity() took the actor from auth.uid(). That is right for a
-- call made by the person themselves, and NULL for every other caller:
--
--   * An Edge Function uses the service_role key, which carries no JWT, so
--     auth.uid() is NULL. The activity row would be written with a NULL actor
--     — "somebody changed this password" with no record of who, on an audit
--     table whose entire purpose is answering that.
--   * Hardcoding the actor could not be fixed on the caller's side either,
--     because the function had no parameter to pass one through.
--
-- So p_actor_id is added and the 4-argument call sites keep working unchanged
-- (it defaults to NULL, which still means "the caller"). One function, not
-- two: a second variant is a second place for the rule to live, which is how
-- the 20260927000029-34 drift happened in the first place.
--
-- The 4-argument overload is DROPPED so there is exactly one definition. Left
-- in place it would be a second function with subtly different actor
-- semantics, and the next reader would not know which one is live.
--
-- The detail carries NO password, old or new. A log that records the secret it
-- exists to protect is a plaintext store with extra steps.

-- ===========================================================================
-- 1. log_staff_activity, restated
-- ===========================================================================
DROP FUNCTION IF EXISTS public.log_staff_activity(uuid, text, jsonb, text);

CREATE OR REPLACE FUNCTION public.log_staff_activity(
  p_staff_id uuid,
  p_action text,
  p_detail jsonb DEFAULT '{}'::jsonb,
  p_kind text DEFAULT 'work',
  p_actor_id uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := COALESCE(p_actor_id, auth.uid());
  v_actor_name text;
BEGIN
  SELECT COALESCE(full_name, '(staff)') INTO v_actor_name
  FROM public.profiles WHERE id = v_actor;

  INSERT INTO public.staff_activity_log
    (staff_id, actor_id, actor_name, kind, action, detail)
  VALUES
    (p_staff_id, v_actor, v_actor_name, p_kind, p_action,
     COALESCE(p_detail, '{}'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION public.log_staff_activity(uuid, text, jsonb, text, uuid)
  FROM public, anon;
-- service_role is what the Edge Functions authenticate as. Without this the
-- GRANT-less function (PUBLIC execute was just revoked) is unreachable and the
-- audit write fails at runtime rather than at deploy — the worst time to find
-- out, because the password still changes and only the record is missing.
GRANT EXECUTE ON FUNCTION public.log_staff_activity(uuid, text, jsonb, text, uuid)
  TO authenticated, service_role;

-- ===========================================================================
-- 2. What a password change writes
-- ===========================================================================
-- A small helper so the Edge Function does not invent the action name inline,
-- and so the shape of the record is defined in one place.
CREATE OR REPLACE FUNCTION public.log_staff_password_change(
  p_staff_id uuid,
  p_actor_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- plpgsql, deliberately, not LANGUAGE sql. A SQL-language body is fully
  -- parsed and name-resolved at CREATE time, so this function could only be
  -- created after log_staff_activity and staff_activity_log both existed —
  -- turning a migration-ordering mistake into a hard deploy failure instead
  -- of a runtime one. plpgsql resolves names on first execution, which is the
  -- same reason 20260927000034's validate_staff_jobs() is plpgsql.
  PERFORM public.log_staff_activity(
    p_staff_id,
    'PASSWORD_CHANGED',
    -- What changed, and by whom. Never the value.
    jsonb_build_object(
      'self_service', p_actor_id IS NOT NULL,
      'other_sessions_revoked', true
    ),
    'access',
    p_actor_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.log_staff_password_change(uuid, uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.log_staff_password_change(uuid, uuid)
  TO authenticated, service_role;

-- ===========================================================================
-- 3. Assertion
-- ===========================================================================
-- The bug being guarded is narrow and specific: a caller that passes its own
-- actor (the Edge Function case) must get that actor recorded. Reverting the
-- COALESCE, or dropping the parameter, makes the row write successfully with a
-- NULL actor — which no read-only check can see, because the row is there and
-- looks fine. Only asserting the actor value catches it.
CREATE OR REPLACE FUNCTION public.assert_staff_password_changes_are_audited()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e609';
  v_actor uuid := '00000000-0000-4000-8000-00000000e610';
  v_staff uuid;
  v_actor_id uuid;
  v_action text;
  v_kind text;
  v_detail jsonb;
  v_staff_id uuid;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'pw-change-probe@example.invalid', now()),
         (v_actor, 'pw-change-actor@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Password Probe', 'APPROVED'),
         (v_actor, 'Password Actor', 'APPROVED')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.staff (user_id, name, staff_code, permissions)
  VALUES (v_user, 'Password Probe', 'PW-CHANGE-1', '{}')
  RETURNING id INTO v_staff;
  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'could not create the probe staff row';
  END IF;

  -- (1) A caller that supplies its own actor has THAT actor recorded, not
  --     NULL. This is the Edge Function case: service_role carries no JWT, so
  --     auth.uid() is NULL and the unguarded version silently writes an audit
  --     row that cannot answer "who changed this password".
  PERFORM public.log_staff_password_change(v_staff, v_actor);
  SELECT actor_id, action, kind, detail, staff_id
    INTO v_actor_id, v_action, v_kind, v_detail, v_staff_id
  FROM public.staff_activity_log
  WHERE staff_id = v_staff AND action = 'PASSWORD_CHANGED'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION
      'a password change was logged with no actor, so the record cannot say who changed it';
  END IF;
  IF v_actor_id <> v_actor THEN
    RAISE EXCEPTION 'the wrong actor was recorded: %', v_actor_id;
  END IF;
  IF v_kind <> 'access' THEN
    RAISE EXCEPTION 'a password change was not recorded as an access event: %', v_kind;
  END IF;
  IF v_staff_id <> v_staff THEN
    RAISE EXCEPTION 'the password change was recorded against the wrong staff row';
  END IF;
  -- The record must not become a plaintext store of the secret it exists to
  -- protect. Anything password-shaped in the detail is a leak.
  IF v_detail::text ~* 'pass(word|_hash)?\s*[:=]' THEN
    RAISE EXCEPTION 'the activity detail appears to contain a password';
  END IF;

  -- (2) A self-service change is identified as such, because "the person
  --     changed their own" and "an administrator reset it" are different
  --     events and the CEO has to be able to tell them apart later.
  IF NOT COALESCE((v_detail ->> 'self_service')::boolean, false) THEN
    RAISE EXCEPTION 'a self-service password change was not marked self_service';
  END IF;

  -- (3) The 4-argument call still works and still means "the caller". A
  --     dropped default here would break every existing call site at runtime,
  --     which is the regression this restatement could plausibly introduce.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  PERFORM public.log_staff_activity(v_staff, 'WORK_DONE', '{"task":"probe"}'::jsonb);
  SELECT actor_id INTO v_actor_id
  FROM public.staff_activity_log
  WHERE staff_id = v_staff AND action = 'WORK_DONE'
  ORDER BY created_at DESC LIMIT 1;
  IF v_actor_id IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION
      'the 4-argument form no longer records the calling user (got %)',
      v_actor_id;
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

COMMENT ON FUNCTION public.assert_staff_password_changes_are_audited() IS
  'Requires a self-service password change to be recorded in '
  'staff_activity_log against the ACTUAL actor rather than a NULL one, as an '
  '"access" event, carrying no password, and requires the 4-argument form of '
  'log_staff_activity() to keep meaning "the caller".';

GRANT EXECUTE ON FUNCTION public.assert_staff_password_changes_are_audited()
  TO anon, authenticated;
