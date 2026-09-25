-- 0048 — delete_staff: take the actor explicitly, because auth.uid() is null
-- for every caller that can actually reach it.
--
-- THE BUG THIS FIXES (reproduced live, not theoretical)
-- ----------------------------------------------------
-- 0047's delete_staff identified the caller with `auth.uid()`:
--
--     v_actor uuid := auth.uid();
--     IF NOT public.is_ceo(v_actor) THEN
--       RAISE EXCEPTION 'ONLY_CEO_CAN_DELETE_STAFF';
--
-- That check can never pass. delete_staff is granted to service_role ONLY —
-- verified live: an anon key gets
--   42501 permission denied for function delete_staff
-- — and the only caller is the staff-delete-gateway edge function, which
-- invokes it with the service-role client. A service-role PostgREST request
-- carries no end-user JWT, so auth.uid() is NULL, is_ceo(NULL) is false, and
-- EVERY delete failed with 403 "only_ceo_can_delete_staff" — for the real CEO
-- included. Nobody could delete anyone.
--
-- Why the local harness missed it: the test set request.jwt.claim.sub via
-- set_config, which simulates a user JWT. The real gateway never does that.
-- The test proved the logic but never the call path. This file's test case
-- below drives the actor through the parameter instead, which is how the
-- function is actually reached.
--
-- WHY THIS IS NOT A WEAKENING OF THE CHECK
-- ----------------------------------------
-- The trust model is identical to create_staff_gateway, which has taken
-- p_actor_id explicitly since 0035 for exactly this reason: a function driven
-- by a service-role gateway cannot recover the user from auth.uid().
-- Defence is unchanged and still layered:
--   1. delete_staff is service_role-only — no client can call it at all.
--   2. The edge function re-verifies is_ceo(actor.id) BEFORE calling, where
--      actor.id comes from the caller's own verified JWT.
--   3. This function re-checks is_ceo(p_actor_id) itself, so a future caller
--      that forgets step 2 still cannot escalate.
-- Step 3 is the reason this is not just a trust-the-parameter hole: a
-- non-CEO p_actor_id is still refused, which the test asserts.

DROP FUNCTION IF EXISTS public.delete_staff(uuid);

CREATE OR REPLACE FUNCTION public.delete_staff(
  p_actor_id uuid,
  p_staff_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
  v_auth_user_id uuid;
  v_username text;
BEGIN
  -- NOTE: p_actor_id, not auth.uid(). See the header — auth.uid() is NULL for
  -- the service-role gateway, which is the only thing that can call this.
  IF NOT public.is_ceo(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_CEO_CAN_DELETE_STAFF';
  END IF;

  SELECT * INTO v_staff FROM public.staff WHERE id = p_staff_id;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  -- Guard the CEO row, whoever is asking.
  IF v_staff.is_ceo THEN
    RAISE EXCEPTION 'CANNOT_DELETE_CEO';
  END IF;

  v_auth_user_id := v_staff.user_id;
  SELECT username INTO v_username
  FROM public.staff_credentials WHERE staff_id = p_staff_id;

  -- Drop the app-level ADMIN role the gateway granted, mirroring
  -- revoke_staff, so the person cannot act as an admin afterwards.
  IF v_auth_user_id IS NOT NULL THEN
    DELETE FROM public.user_roles
    WHERE user_id = v_auth_user_id AND role = 'ADMIN';
  END IF;

  DELETE FROM public.staff WHERE id = p_staff_id;

  PERFORM public.log_admin_action(
    p_actor_id, 'STAFF_DELETED', p_staff_id, 'staff', NULL, '{}',
    jsonb_build_object('username', v_username,
                       'auth_user_id', v_auth_user_id,
                       'name', v_staff.name)
  );

  -- The auth_user_id is returned so the Edge Function can remove the GoTrue
  -- account with the service role. The staff row is already gone at this
  -- point, so a failure there leaves an orphan login with no privileges
  -- rather than a live staff row whose account could not be removed.
  RETURN jsonb_build_object(
    'staff_id', p_staff_id,
    'auth_user_id', v_auth_user_id,
    'username', v_username
  );
END;
$$;

REVOKE ALL ON FUNCTION public.delete_staff(uuid, uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_staff(uuid, uuid) TO service_role;
