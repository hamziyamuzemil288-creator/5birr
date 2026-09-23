-- True Admin = CEO from the start (Task 6 correction).
--
-- The owner's account is registered directly in Supabase, outside the app,
-- and holds the true ADMIN app_role. It will never have a staff row, so the
-- staff-row-only is_ceo() meant the true Admin was NOT recognized as the
-- CEO: create_staff's legacy bootstrap arms then threw
-- BOOTSTRAP_FIRST_CEO_OR_SUPER_ADMIN (the in-app "Initialize Role
-- Hierarchy" flow — removed client-side in the same change) and a true
-- Admin could not create any staff row at all.
--
-- Correction, purely additive to callers (signatures unchanged). The
-- ADMIN-role arms are deliberately scoped to accounts WITHOUT any staff row:
-- link_staff_user grants linked staff the ADMIN app_role (the admin-panel
-- gate), so an unscoped role check would silently promote every linked
-- staff member to CEO. The "true Admin" = ADMIN role + no staff row ever.
--   1. is_ceo(): true for a CEO staff row, OR for the external true Admin
--      (ADMIN app_role, no staff row).
--   2. can_manage_staff(): the external true Admin manages every staff row
--      exactly like the CEO (the CEO staff row, if one ever exists, stays
--      self-managed only); linked staff keep their previous reach.
--   3. create_staff(): bootstrap arms REMOVED. CEO/true Admin may create
--      Super Admins and sub-admins; Super Admin may create sub-admins only;
--      nobody else. There is no in-app path that creates a CEO ever again.
--
-- Functionally identical for pre-existing rows: every staff-table CEO/Super
-- Admin keeps exactly their previous reach (can_manage_staff return values
-- are unchanged for staff-row managers; the new true-Admin grants only
-- widen what the external owner account may do — previously blocked with
-- errors).

-- ============================================================
-- 1. is_ceo: a CEO staff row, or the external true Admin
--    (ADMIN app_role AND no staff row — link_staff_user grants
--    linked staff ADMIN too, so the role check must be scoped)
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_ceo(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id AND is_ceo AND is_active
  )
  OR (
    EXISTS (
      SELECT 1 FROM public.user_roles
      WHERE user_id = p_user_id AND role = 'ADMIN'
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.staff WHERE user_id = p_user_id
    )
  );
$$;

-- ============================================================
-- 2. can_manage_staff: the true Admin manages every staff row
--    (same reach the CEO had; signature + prior returns kept)
-- ============================================================
CREATE OR REPLACE FUNCTION public.can_manage_staff(
  p_target_staff_id uuid,
  p_manager uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_manager_is_ceo boolean;
  v_manager_is_super boolean;
  v_manager_branch text;
  v_target_branch text;
  v_target_is_ceo boolean;
  v_target_user uuid;
  v_manager_is_true_admin boolean;
BEGIN
  -- Manager attributes come from the manager's own staff row (may not
  -- exist for the true Admin — that account never needs one); the target's
  -- attributes come from the target row.
  SELECT is_ceo, is_super_admin, branch INTO
    v_manager_is_ceo, v_manager_is_super, v_manager_branch
  FROM public.staff WHERE user_id = p_manager AND is_active;

  -- The external true Admin: ADMIN app_role and no staff row at all (not
  -- even an inactive one). Linked staff hold ADMIN too (the router gate),
  -- so an unscoped check would hand them CEO-level staff management.
  v_manager_is_true_admin := public.is_admin()
    AND NOT EXISTS (
      SELECT 1 FROM public.staff WHERE user_id = p_manager
    );

  IF NOT COALESCE(v_manager_is_ceo, false)
     AND NOT COALESCE(v_manager_is_super, false)
     AND NOT COALESCE(v_manager_is_true_admin, false) THEN
    RETURN false;
  END IF;

  SELECT branch, is_ceo, user_id INTO v_target_branch, v_target_is_ceo, v_target_user
  FROM public.staff WHERE id = p_target_staff_id;
  IF v_target_branch IS NULL THEN
    RETURN false; -- unknown target
  END IF;

  -- The CEO row can only be managed by the CEO (the true Admin IS the CEO;
  -- a staff-row CEO is managed by the CEO only, as before).
  IF COALESCE(v_target_is_ceo, false) THEN
    RETURN COALESCE(v_manager_is_ceo, false)
      OR COALESCE(v_manager_is_true_admin, false);
  END IF;

  -- Nobody manages their own row through this path (self-edits of
  -- permissions would be privilege escalation).
  IF v_target_user = p_manager THEN
    RETURN false;
  END IF;

  RETURN COALESCE(v_manager_is_ceo, false)
      OR COALESCE(v_manager_is_true_admin, false)
      OR COALESCE(v_manager_is_super, false)
      OR v_manager_branch = 'ME';
END;
$$;

-- ============================================================
-- 3. create_staff: bootstrap arms REMOVED
--    CEO / true Admin -> Super Admins + sub-admins
--    Super Admin      -> sub-admins only
--    No in-app path creates a CEO — the identity is external by spec.
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_staff(
  p_name text,
  p_staff_code text,
  p_permissions text[],
  p_sales_target numeric DEFAULT 0,
  p_is_super_admin boolean DEFAULT false,
  p_branch text DEFAULT 'ADMIN',
  p_assigned_categories uuid[] DEFAULT '{}'
)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF p_branch NOT IN ('ADMIN','ME') THEN
    RAISE EXCEPTION 'INVALID_STAFF_BRANCH';
  END IF;
  IF p_is_super_admin AND p_branch <> 'ADMIN' THEN
    RAISE EXCEPTION 'SUPER_ADMIN_LIVES_IN_ADMIN_BRANCH';
  END IF;

  -- ---------------------------------------------------------------
  -- Authorization matrix (no bootstrap paths):
  --   CEO / true Admin -> any non-CEO row (Super Admin or sub-admin)
  --   Super Admin      -> sub-admins only (never a Super Admin)
  --   everyone else    -> denied
  -- ---------------------------------------------------------------
  IF public.is_ceo(v_admin) THEN
    -- Full authority (is_ceo covers both the true ADMIN app_role and a
    -- legacy CEO staff row).
    NULL;
  ELSIF public.is_super_admin(v_admin) THEN
    IF p_is_super_admin THEN
      RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_SUPER_ADMINS';
    END IF;
  ELSE
    RAISE EXCEPTION 'ONLY_CEO_OR_SUPER_ADMIN_CAN_MANAGE_STAFF';
  END IF;

  -- ---------------------------------------------------------------
  -- Insert (never a CEO row — is_ceo is no longer derived from
  -- p_is_super_admin/p_branch here; it exists only on rows linked to the
  -- pre-correction hierarchy, which this path cannot create).
  -- ---------------------------------------------------------------
  INSERT INTO public.staff
    (name, staff_code, permissions, sales_target, is_super_admin, branch, is_ceo, assigned_categories, created_by)
  VALUES
    (p_name, p_staff_code, p_permissions, p_sales_target, p_is_super_admin,
     p_branch, false, p_assigned_categories, v_admin)
  RETURNING * INTO v_staff;

  PERFORM public.log_admin_action(v_admin, 'STAFF_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('staff_code', p_staff_code, 'branch', p_branch,
                             'is_ceo', v_staff.is_ceo,
                             'permissions', to_jsonb(p_permissions),
                             'categories', to_jsonb(p_assigned_categories)));
  RETURN v_staff;
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_ceo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_staff(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_staff(text, text, text[], numeric, boolean, text, uuid[]) TO authenticated;
