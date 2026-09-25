-- 0047 — permanent staff deletion (CEO only).
--
-- revoke_staff is reversible and deliberately keeps the Auth account: the
-- login function already refuses an inactive staff row. What it does NOT do
-- is release the person — the auth account survives, the username stays
-- reserved forever, and the account can still authenticate even though it can
-- no longer reach any staff privilege.
--
-- The CEO needs a genuine "remove this person entirely", so this adds
-- delete_staff: the staff row, everything cascading off it, and (via the
-- Edge Function) the GoTrue account.
--
-- Deliberately NOT gated on can_manage_staff(). Deleting is irreversible and
-- can strip permissions a sub-admin holds over the target, so it is not
-- delegated: only the CEO can call it. The CEO's own row is refused outright
-- — including when the CEO is the caller — because a single mis-tap would
-- otherwise leave nobody able to manage staff at all.
--
-- Every FK onto public.staff already cascades (staff_credentials,
-- staff_tasks, referral_codes) or nulls (referral attribution), so deleting
-- the staff row removes the dependent rows.
--
-- This function does NOT delete auth.users. That needs the service role,
-- which must never be reachable from a client, so the Edge Function
-- staff-delete-gateway does it using the auth_user_id returned here. The
-- ordering is deliberate: the staff row goes first, so a failure in the auth
-- step leaves an orphan login with no privileges, never a live staff row
-- whose account could not be removed.

CREATE OR REPLACE FUNCTION public.delete_staff(p_staff_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
  v_auth_user_id uuid;
  v_username text;
BEGIN
  IF NOT public.is_ceo(v_actor) THEN
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
    v_actor, 'STAFF_DELETED', p_staff_id, 'staff', NULL, '{}',
    jsonb_build_object('username', v_username,
                       'auth_user_id', v_auth_user_id,
                       'name', v_staff.name)
  );

  RETURN jsonb_build_object(
    'staff_id', p_staff_id,
    'auth_user_id', v_auth_user_id,
    'username', v_username
  );
END;
$$;

-- service_role only: the Edge Function acts with it, and it is the only role
-- that can touch auth.users. Never exposed to a client.
REVOKE ALL ON FUNCTION public.delete_staff(uuid) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_staff(uuid) TO service_role;
