-- Role management tools for the Staff Assignment page (true Admin only).
-- Purely additive: extends update_staff backward-compatibly (appended,
-- defaulted params — the pattern migration 20260922000012 established) and
-- adds two is_admin()-gated helpers. No existing table or policy changes.

-- ============================================================
-- 1. update_staff: 8-arg version (adds super-admin + branch control)
-- ============================================================
-- The 6-arg version is replaced (not overloaded) so exactly one definition
-- exists; all existing 6-arg call sites keep working via the new defaults.
DROP FUNCTION IF EXISTS public.update_staff(uuid, text, text[], numeric, boolean, uuid[]);

CREATE OR REPLACE FUNCTION public.update_staff(
  p_staff_id uuid,
  p_name text DEFAULT NULL,
  p_permissions text[] DEFAULT NULL,
  p_sales_target numeric DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_assigned_categories uuid[] DEFAULT NULL,
  p_is_super_admin boolean DEFAULT NULL,
  p_branch text DEFAULT NULL
)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
  v_new_super boolean;
  v_new_branch text;
BEGIN
  IF NOT public.can_manage_staff(p_staff_id, v_admin) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION_TO_MANAGE_STAFF';
  END IF;

  SELECT * INTO v_staff FROM public.staff WHERE id = p_staff_id;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  -- Super-admin changes follow the create_staff rules: one active Super
  -- Admin at most, and supers live in the ADMIN branch. The CEO row itself
  -- is untouchable here (can_manage_staff already blocks it).
  v_new_super := COALESCE(p_is_super_admin, v_staff.is_super_admin);
  v_new_branch := COALESCE(p_branch, v_staff.branch);
  IF v_new_branch NOT IN ('ADMIN','ME') THEN
    RAISE EXCEPTION 'INVALID_STAFF_BRANCH';
  END IF;
  IF v_new_super AND v_new_branch <> 'ADMIN' THEN
    RAISE EXCEPTION 'SUPER_ADMIN_LIVES_IN_ADMIN_BRANCH';
  END IF;
  IF v_new_super AND NOT v_staff.is_super_admin THEN
    IF EXISTS (
      SELECT 1 FROM public.staff
      WHERE is_super_admin AND is_active AND id <> p_staff_id
    ) THEN
      RAISE EXCEPTION 'SUPER_ADMIN_ALREADY_EXISTS';
    END IF;
  END IF;

  UPDATE public.staff SET
    name                = COALESCE(p_name, name),
    permissions         = COALESCE(p_permissions, permissions),
    sales_target        = COALESCE(p_sales_target, sales_target),
    is_active           = COALESCE(p_is_active, is_active),
    assigned_categories = COALESCE(p_assigned_categories, assigned_categories),
    is_super_admin      = v_new_super,
    branch              = CASE WHEN v_new_super THEN 'ADMIN' ELSE v_new_branch END,
    updated_at          = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;

  PERFORM public.log_admin_action(v_admin, 'STAFF_UPDATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('is_active', v_staff.is_active,
                             'is_super_admin', v_staff.is_super_admin,
                             'branch', v_staff.branch,
                             'permissions', to_jsonb(v_staff.permissions),
                             'categories', to_jsonb(v_staff.assigned_categories)));
  RETURN v_staff;
END;
$$;

-- ============================================================
-- 2. admin_set_user_city: true Admin sets/clears a user's saved city
-- ============================================================
-- profiles UPDATE RLS is owner-only by design, so the admin path goes
-- through this SECURITY DEFINER RPC instead of weakening that policy.
CREATE OR REPLACE FUNCTION public.admin_set_user_city(
  p_user_id uuid,
  p_city text DEFAULT NULL  -- NULL clears the saved city
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;
  IF p_city IS NOT NULL AND length(btrim(p_city)) = 0 THEN
    RAISE EXCEPTION 'CITY_CANNOT_BE_EMPTY';
  END IF;

  UPDATE public.profiles
  SET city = CASE WHEN p_city IS NULL THEN NULL ELSE btrim(p_city) END
  WHERE id = p_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND';
  END IF;

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_admin, 'SET_USER_CITY', 'profiles', p_user_id,
          jsonb_build_object('city', p_city));
END;
$$;

-- ============================================================
-- 3. admin_warn_user: issue an in-app warning notification
-- ============================================================
-- In-app delivery only (no SMS/email); the notification appears in the
-- user's notification list. Audited via admin_actions.
CREATE OR REPLACE FUNCTION public.admin_warn_user(
  p_user_id uuid,
  p_title text,
  p_body text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ADMIN_ONLY';
  END IF;
  IF p_title IS NULL OR length(btrim(p_title)) = 0 THEN
    RAISE EXCEPTION 'TITLE_REQUIRED';
  END IF;
  IF p_body IS NULL OR length(btrim(p_body)) = 0 THEN
    RAISE EXCEPTION 'BODY_REQUIRED';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (p_user_id, 'ADMIN_MESSAGE', btrim(p_title), btrim(p_body));

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (v_admin, 'WARN_USER', 'profiles', p_user_id,
          jsonb_build_object('title', btrim(p_title)));
END;
$$;

GRANT EXECUTE ON FUNCTION public.update_staff(uuid, text, text[], numeric, boolean, uuid[], boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_user_city(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_warn_user(uuid, text, text) TO authenticated;
