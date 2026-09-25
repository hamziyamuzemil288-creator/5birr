-- 0046 — email-format staff usernames, on the SQL side.
--
-- 0045 widened the staff_credentials CHECK constraint, but the constraint is
-- only the last line of defence. This file fixes the LOGIC that still assumed
-- every username was a bare name. Without it, an email username would be
-- rejected with a misleading INVALID_STAFF_USERNAME — or, worse, accepted and
-- then failed the auth.users identity check against an address the Edge
-- Function never created.
--
-- create_staff_gateway used to build the auth email itself as
--   v_username || '@staff-gateway.invalid'
-- and validate the username with the bare-name regex. The Edge Function was
-- changed to derive the email from the username's SHAPE, so this function
-- has to agree exactly.
--
-- The mapping is chosen by shape, which is what makes the change backward
-- compatible and needs no re-key:
--   * bare name (e.g. "aymen")          -> aymen@staff-gateway.invalid
--     Byte-identical to the original, so every staff account created before
--     this migration keeps logging in with no password reset.
--   * email (e.g. "aymen@gmail.com")    -> s_<sha256[0:24]>@staff-gateway.invalid
--     A fixed-shape local part, because a local part may not contain "@".
--
-- There is no lookup table: given a username, each runtime computes the same
-- address with no database round-trip, so staff-login can rebuild the
-- identity from the credentials alone.
--
-- The TypeScript twin is syntheticStaffEmail() in
-- supabase/functions/_shared/staff_identity.ts. The two must agree
-- byte-for-byte; if you change one, change the other, or staff creation
-- will succeed and login will never find the account.

-- ─────────────────────────────────────────────────────────────────────────
-- The one place SQL derives the synthetic email
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.staff_gateway_email(p_username text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN lower(btrim(p_username)) ~ '^[a-z0-9][a-z0-9._-]{2,31}$'
      -- legacy form: identical to the original implementation
      THEN lower(btrim(p_username)) || '@staff-gateway.invalid'
    -- email form: the local part may not contain "@", so hash to a fixed
    -- shape. sha256_hex is the project's existing pure-SQL helper.
    ELSE 's_' || substr(public.sha256_hex(lower(btrim(p_username))), 1, 24)
         || '@staff-gateway.invalid'
  END;
$$;

-- ─────────────────────────────────────────────────────────────────────────
-- create_staff_gateway — accept email usernames, derive the email
-- ─────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.create_staff_gateway(
  p_actor_id uuid,
  p_auth_user_id uuid,
  p_username text,
  p_name text,
  p_staff_code text,
  p_permissions text[],
  p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false,
  p_branch text DEFAULT 'ADMIN',
  p_assigned_categories uuid[] DEFAULT '{}'
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_username text := lower(btrim(p_username));
  v_email text;
  v_staff public.staff;
BEGIN
  IF NOT public.is_ceo(p_actor_id) THEN
    RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_STAFF_GATEWAY';
  END IF;
  -- Same two accepted shapes as the CHECK constraint in 0045 and the
  -- client-side rule: a legacy bare name, or an email address.
  IF v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
     AND v_username !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$' THEN
    RAISE EXCEPTION 'INVALID_STAFF_USERNAME';
  END IF;
  v_email := public.staff_gateway_email(v_username);
  IF p_branch NOT IN ('ADMIN', 'ME') OR (p_is_super_admin AND p_branch <> 'ADMIN') THEN
    RAISE EXCEPTION 'INVALID_STAFF_BRANCH';
  END IF;
  IF p_is_super_admin AND EXISTS (
    SELECT 1 FROM public.staff
    WHERE is_super_admin AND is_active AND user_id <> p_auth_user_id
  ) THEN
    RAISE EXCEPTION 'SUPER_ADMIN_ALREADY_EXISTS';
  END IF;
  IF EXISTS (SELECT 1 FROM public.staff_credentials WHERE lower(username) = v_username) THEN
    RAISE EXCEPTION 'STAFF_USERNAME_TAKEN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = p_auth_user_id AND lower(email) = v_email) THEN
    RAISE EXCEPTION 'STAFF_AUTH_IDENTITY_MISMATCH';
  END IF;

  INSERT INTO public.staff
    (user_id, name, staff_code, permissions, sales_target, is_super_admin,
     branch, is_ceo, assigned_categories, created_by)
  VALUES
    (p_auth_user_id, btrim(p_name), btrim(p_staff_code), p_permissions,
     COALESCE(p_sales_target, 0), p_is_super_admin, p_branch, false,
     COALESCE(p_assigned_categories, '{}'::uuid[]), p_actor_id)
  RETURNING * INTO v_staff;

  INSERT INTO public.staff_credentials (staff_id, user_id, username)
  VALUES (v_staff.id, p_auth_user_id, v_username);

  INSERT INTO public.user_roles (user_id, role)
  VALUES (p_auth_user_id, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  -- The Auth trigger may have created a normal user profile. Gateway accounts
  -- are staff identities, not pending public registrations.
  UPDATE public.profiles
  SET full_name = btrim(p_name), email = v_email,
      status = 'APPROVED', updated_at = now()
  WHERE id = p_auth_user_id;
  DELETE FROM public.approval_requests
  WHERE subject_type = 'USER' AND subject_id = p_auth_user_id
    AND status = 'PENDING_APPROVAL';

  PERFORM public.log_admin_action(
    p_actor_id, 'STAFF_GATEWAY_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('username', v_username,
                             'permissions', to_jsonb(p_permissions))
  );
  RETURN v_staff;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_gateway_email(text) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.staff_gateway_email(text) TO service_role;
