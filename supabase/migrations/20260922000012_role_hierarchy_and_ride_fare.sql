-- ============================================================================
-- Migration 20260922000012_role_hierarchy_and_ride_fare.sql
-- Two features, both STRICTLY ADDITIVE to the existing staff/permission model
-- (20260922000001 + 20260922000010) and the transportation module (0010/0011):
--
-- PART A — Role hierarchy (CEO / Super Admin / Me-Owner / Sub-Admin)
--   CEO controls both branches. ADMIN branch: Super Admin on top.
--   ME branch: the owner ("Me") with categorized Sub-Admins who are jointly
--   controlled by Super Admin AND Me. Sub-Admin power = explicit permission
--   list ∩ assigned categories, enforced server-side in every guarded RPC.
--
-- PART B — Ride fare engine
--   calculate_fare_estimate() reads admin-configurable pricing from
--   system_settings with per-category overrides in categories.metadata,
--   create_ride_request() stamps fare_estimate (column existed, never
--   populated) and enforces the account-approval gate server-side.
--
-- Nothing existing is dropped or narrowed: '{}' scope = unrestricted for
-- staff created before this migration; true ADMIN user_role rows keep full
-- access exactly as admin_can() defined it.
-- ============================================================================

-- ============================================================
-- PART A1. staff table: branch, CEO flag, category scope
-- ============================================================
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS branch text NOT NULL DEFAULT 'ADMIN';
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS is_ceo boolean NOT NULL DEFAULT false;
ALTER TABLE public.staff ADD COLUMN IF NOT EXISTS assigned_categories uuid[] NOT NULL DEFAULT '{}';

DO $$ BEGIN
  ALTER TABLE public.staff ADD CONSTRAINT staff_branch_known CHECK (branch IN ('ADMIN','ME'));
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_table THEN NULL; END $$;

-- Widen the permission vocabulary: sub-admins can also be granted report /
-- expense / audit visibility (the three things the spec calls out).
ALTER TABLE public.staff DROP CONSTRAINT IF EXISTS staff_permissions_known;
DO $$ BEGIN
  ALTER TABLE public.staff ADD CONSTRAINT staff_permissions_known CHECK (
    permissions <@ ARRAY[
      'sales_transactions','registrations','category_management',
      'support_chat','payment_verification','admin_history',
      'view_reports','view_expenses','view_auth_logs'
    ]::text[]
  );
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_table THEN NULL; END $$;

CREATE INDEX IF NOT EXISTS idx_staff_branch ON public.staff(branch, is_active);
CREATE INDEX IF NOT EXISTS idx_staff_categories ON public.staff USING GIN (assigned_categories);

-- Backfill: pre-migration super admins implicitly held every permission
-- (old staff_has_permission ORed in is_super_admin). Under the explicit
-- model they would silently lose access, so seed their list with the full
-- vocabulary — the owner can then trim it like any other row.
UPDATE public.staff
SET permissions = ARRAY[
  'sales_transactions','registrations','category_management',
  'support_chat','payment_verification','admin_history',
  'view_reports','view_expenses','view_auth_logs']
WHERE is_super_admin AND is_active
  AND COALESCE(array_length(permissions, 1), 0) = 0;

-- ============================================================
-- PART A2. Hierarchy helpers (SECURITY DEFINER, read past RLS)
-- ============================================================

-- CEO: top of both branches. One row at most (guarded in create_staff).
CREATE OR REPLACE FUNCTION public.is_ceo(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id AND is_ceo AND is_active
  );
$$;

-- Category scope of a staff member: '{}' = unrestricted (pre-migration rows),
-- otherwise the explicit list of assigned category ids. CEO/Super Admin/
-- ADMIN-role users are always unrestricted.
CREATE OR REPLACE FUNCTION public.staff_category_scope(p_user_id uuid DEFAULT auth.uid())
RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE
    WHEN public.is_admin() OR public.is_ceo(p_user_id) OR public.is_super_admin(p_user_id)
      THEN '{}'::uuid[]
    ELSE COALESCE(
      (SELECT assigned_categories FROM public.staff
        WHERE user_id = p_user_id AND is_active), '{}'::uuid[])
  END;
$$;

-- Can the caller act on things belonging to [p_category]? NULL category =
-- uncategorized rows stay visible to every permitted staff member.
CREATE OR REPLACE FUNCTION public.staff_scope_allows_category(
  p_category uuid,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.is_admin()
      OR public.is_ceo(p_user_id)
      OR public.is_super_admin(p_user_id)
      OR p_category IS NULL
      OR public.staff_category_scope(p_user_id) = '{}'::uuid[]
      OR p_category = ANY (public.staff_category_scope(p_user_id));
$$;

-- Permission resolution: the CEO row always passes; everyone else —
-- INCLUDING the super admin — holds exactly the permissions explicitly
-- assigned by the owner (spec: super-admin access is configurable, not
-- automatic). True ADMIN-role users pass via admin_can()/is_admin(), which
-- OR this in everywhere it is used.
CREATE OR REPLACE FUNCTION public.staff_has_permission(
  p_user_id uuid DEFAULT auth.uid(),
  -- A param after one with a default must also have one (42P13); the NULL
  -- guard in the body fails closed, so an omitted permission never grants.
  p_permission text DEFAULT NULL
)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT p_permission IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.staff
    WHERE user_id = p_user_id
      AND is_active
      AND (is_ceo OR p_permission = ANY (permissions))
  );
$$;

-- Joint control matrix: who may manage (edit/revoke) a given staff row.
--   CEO                 -> every row, both branches
--   Super Admin (ADMIN) -> every row except the CEO's and their own
--   Me/Owner    (ME)    -> every row except the CEO's and their own
--   Sub-Admins          -> nobody
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
BEGIN
  -- Manager attributes come from the manager's own staff row; the target's
  -- attributes (including user_id) come from the target row. Mixing them in
  -- one SELECT made the self-edit check below compare p_manager with
  -- itself, blocking every legitimate manager.
  SELECT is_ceo, is_super_admin, branch INTO
    v_manager_is_ceo, v_manager_is_super, v_manager_branch
  FROM public.staff WHERE user_id = p_manager AND is_active;

  IF NOT COALESCE(v_manager_is_ceo, false)
     AND NOT COALESCE(v_manager_is_super, false)
     AND NOT public.is_admin() THEN
    RETURN false;
  END IF;

  SELECT branch, is_ceo, user_id INTO v_target_branch, v_target_is_ceo, v_target_user
  FROM public.staff WHERE id = p_target_staff_id;
  IF v_target_branch IS NULL THEN
    RETURN false; -- unknown target
  END IF;

  -- The CEO row can only be managed by the CEO themselves.
  IF COALESCE(v_target_is_ceo, false) THEN
    RETURN COALESCE(v_manager_is_ceo, false);
  END IF;

  -- Nobody manages their own row through this path (self-edits of
  -- permissions would be privilege escalation).
  IF v_target_user = p_manager THEN
    RETURN false;
  END IF;

  RETURN COALESCE(v_manager_is_ceo, false)
      OR COALESCE(v_manager_is_super, false)
      OR v_manager_branch = 'ME';
END;
$$;

GRANT EXECUTE ON FUNCTION public.is_ceo(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_category_scope(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_scope_allows_category(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_manage_staff(uuid, uuid) TO authenticated;

-- May the caller perform staff-gated ADMIN ACTIONS (approve/reject/suspend
-- providers, wallet adjustments)? Privileged rows only: true ADMIN-role
-- users, the CEO, and the Super Admin. Categorized sub-admins are read/
-- verify only (spec: reports + verification within their categories).
CREATE OR REPLACE FUNCTION public.staff_is_action_manager()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT public.is_admin()
      OR public.is_ceo()
      OR public.is_super_admin();
$$;

-- What can the signed-in principal do in the admin area? Used by the
-- Flutter dashboard to show only permitted sections. '*' = everything
-- (true ADMIN-role users and the CEO). The super admin gets their explicit
-- list, same as any sub-admin.
CREATE OR REPLACE FUNCTION public.my_admin_permissions()
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT CASE
    WHEN public.is_admin() OR public.is_ceo()
      THEN ARRAY['*']::text[]
    WHEN EXISTS (SELECT 1 FROM public.staff WHERE user_id = auth.uid() AND is_active)
      THEN COALESCE((SELECT permissions FROM public.staff
                      WHERE user_id = auth.uid() AND is_active), '{}'::text[])
    ELSE ARRAY[]::text[]
  END;
$$;

GRANT EXECUTE ON FUNCTION public.my_admin_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_is_action_manager() TO authenticated;

-- ============================================================
-- PART A3. Staff management RPCs — hierarchy-aware, signatures
--          backward compatible (new params appended with defaults
--          so existing calls keep working).
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
  v_no_ceo boolean;
  v_no_super boolean;
  v_acting_super boolean := public.is_super_admin(v_admin);
BEGIN
  IF p_branch NOT IN ('ADMIN','ME') THEN
    RAISE EXCEPTION 'INVALID_STAFF_BRANCH';
  END IF;
  IF p_is_super_admin AND p_branch <> 'ADMIN' THEN
    RAISE EXCEPTION 'SUPER_ADMIN_LIVES_IN_ADMIN_BRANCH';
  END IF;

  SELECT NOT EXISTS (SELECT 1 FROM public.staff WHERE is_ceo AND is_active) INTO v_no_ceo;
  SELECT NOT EXISTS (SELECT 1 FROM public.staff WHERE is_super_admin AND is_active) INTO v_no_super;

  -- ---------------------------------------------------------------
  -- Authorization matrix
  -- ---------------------------------------------------------------
  IF NOT public.is_ceo(v_admin) THEN
    IF p_is_super_admin AND p_branch = 'ME' THEN
      -- CEO-claim bootstrap: the first ADMIN creates their own ME-branch
      -- owner row. One-time only — requires no CEO to exist yet.
      IF NOT public.is_admin() OR NOT v_no_ceo THEN
        RAISE EXCEPTION 'ONLY_FIRST_ADMIN_CAN_BOOTSTRAP_CEO';
      END IF;
    ELSIF v_acting_super THEN
      -- Super Admin creates sub-admins in either branch; never CEOs,
      -- never another super admin.
      IF p_is_super_admin THEN
        RAISE EXCEPTION 'ONLY_CEO_CAN_CREATE_SUPER_ADMINS';
      END IF;
    ELSIF public.is_admin() AND v_no_ceo AND v_no_super THEN
      -- Legacy bootstrap (pre-hierarchy installs): the first ADMIN may
      -- seed the ADMIN branch by creating the first super admin row.
      IF NOT p_is_super_admin THEN
        RAISE EXCEPTION 'BOOTSTRAP_FIRST_CEO_OR_SUPER_ADMIN';
      END IF;
    ELSE
      RAISE EXCEPTION 'ONLY_CEO_OR_SUPER_ADMIN_CAN_MANAGE_STAFF';
    END IF;
  END IF;

  -- ---------------------------------------------------------------
  -- Insert
  -- ---------------------------------------------------------------
  INSERT INTO public.staff
    (name, staff_code, permissions, sales_target, is_super_admin, branch, is_ceo, assigned_categories, created_by)
  VALUES
    (p_name, p_staff_code, p_permissions, p_sales_target, p_is_super_admin,
     p_branch, p_is_super_admin AND p_branch = 'ME', p_assigned_categories, v_admin)
  RETURNING * INTO v_staff;

  -- ---------------------------------------------------------------
  -- Bootstrap self-linking (auth-user attachment happens here for the
  -- top rows only; all other staff users are linked by an admin directly
  -- on the staff row, as before this migration)
  -- ---------------------------------------------------------------
  IF p_is_super_admin AND p_branch = 'ME' AND v_no_ceo THEN
    IF EXISTS (SELECT 1 FROM public.staff WHERE user_id = v_admin AND id <> v_staff.id) THEN
      -- Pre-hierarchy install: the acting admin already has a staff row
      -- (legacy super admin). staff.user_id is UNIQUE, so instead of a
      -- second link, promote THEIR existing row to CEO.
      UPDATE public.staff
        SET is_ceo = true, is_super_admin = true, branch = 'ME', is_active = true,
            updated_at = now()
        WHERE user_id = v_admin
        RETURNING * INTO v_staff;
      DELETE FROM public.staff WHERE id = (SELECT id FROM public.staff
        WHERE user_id IS NULL AND staff_code = p_staff_code LIMIT 1);
    ELSE
      -- The first CEO claims their own auth user (one-time).
      UPDATE public.staff SET user_id = v_admin WHERE id = v_staff.id;
      v_staff.user_id := v_admin;
    END IF;
  ELSIF p_is_super_admin AND v_staff.user_id IS NULL AND v_no_super AND v_no_ceo
        AND NOT public.is_ceo(v_admin) THEN
    -- Legacy path: the first (ADMIN-branch) super admin self-links and
    -- keeps is_ceo = false, exactly as the pre-hierarchy code did.
    UPDATE public.staff SET user_id = v_admin WHERE id = v_staff.id;
    v_staff.user_id := v_admin;
  END IF;

  PERFORM public.log_admin_action(v_admin, 'STAFF_CREATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('staff_code', p_staff_code, 'branch', p_branch,
                             'is_ceo', v_staff.is_ceo,
                             'permissions', to_jsonb(p_permissions),
                             'categories', to_jsonb(p_assigned_categories)));
  RETURN v_staff;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_staff(
  p_staff_id uuid,
  p_name text DEFAULT NULL,
  p_permissions text[] DEFAULT NULL,
  p_sales_target numeric DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_assigned_categories uuid[] DEFAULT NULL
)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF NOT public.can_manage_staff(p_staff_id, v_admin) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION_TO_MANAGE_STAFF';
  END IF;

  UPDATE public.staff SET
    name                = COALESCE(p_name, name),
    permissions         = COALESCE(p_permissions, permissions),
    sales_target        = COALESCE(p_sales_target, sales_target),
    is_active           = COALESCE(p_is_active, is_active),
    assigned_categories = COALESCE(p_assigned_categories, assigned_categories),
    updated_at          = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  PERFORM public.log_admin_action(v_admin, 'STAFF_UPDATED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('is_active', v_staff.is_active,
                             'permissions', to_jsonb(v_staff.permissions),
                             'categories', to_jsonb(v_staff.assigned_categories)));
  RETURN v_staff;
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_staff(p_staff_id uuid)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_staff public.staff;
BEGIN
  IF NOT public.can_manage_staff(p_staff_id, v_admin) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION_TO_MANAGE_STAFF';
  END IF;

  UPDATE public.staff SET is_active = false, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  UPDATE public.user_roles SET role = 'USER'
  WHERE user_id = v_staff.user_id AND role = 'ADMIN';

  PERFORM public.log_admin_action(v_admin, 'STAFF_REVOKED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('branch', v_staff.branch));
  RETURN v_staff;
END;
$$;

-- Attach a staff record to a real account by email. Without this, only the
-- bootstrap rows are usable — sub-admins could never sign in with their
-- permissions. The linked user gains the app-level ADMIN role (the router
-- gate); revoke_staff removes it again. One staff row per user.
CREATE OR REPLACE FUNCTION public.link_staff_user(
  p_staff_id uuid,
  p_email text
)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
  v_user_id uuid;
BEGIN
  IF NOT public.can_manage_staff(p_staff_id, auth.uid()) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION_TO_MANAGE_STAFF';
  END IF;

  SELECT id INTO v_user_id FROM auth.users
    WHERE lower(email) = lower(trim(p_email))
    LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NO_USER_WITH_THAT_EMAIL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.staff WHERE user_id = v_user_id AND id <> p_staff_id
  ) THEN
    RAISE EXCEPTION 'USER_ALREADY_LINKED_TO_STAFF';
  END IF;

  UPDATE public.staff SET user_id = v_user_id, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_user_id, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  PERFORM public.log_admin_action(auth.uid(), 'STAFF_USER_LINKED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('linked_user', v_user_id));
  RETURN v_staff;
END;
$$;

GRANT EXECUTE ON FUNCTION public.link_staff_user(uuid, text) TO authenticated;

-- Performance view: self, super admin, or CEO may read a row.
CREATE OR REPLACE FUNCTION public.staff_performance(p_staff_id uuid)
RETURNS TABLE(registrations bigint, sales_total numeric, orders_count bigint, rides_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_target_user uuid;
  v_is_self boolean;
BEGIN
  IF NOT public.is_admin() AND NOT public.is_ceo() AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_PERFORMANCE';
  END IF;
  SELECT user_id INTO v_target_user FROM public.staff WHERE id = p_staff_id;
  SELECT (user_id = v_admin) INTO v_is_self FROM public.staff WHERE id = p_staff_id;
  IF NOT (public.is_ceo() OR public.is_super_admin() OR COALESCE(v_is_self, false)) THEN
    RAISE EXCEPTION 'ONLY_SUPER_ADMIN_CAN_VIEW_OTHER_STAFF_PERFORMANCE';
  END IF;

  RETURN QUERY
  SELECT
    (SELECT count(*) FROM public.approval_history h
      WHERE h.performed_by = v_target_user AND h.action = 'APPROVE') AS registrations,
    (SELECT COALESCE(sum(o.total_amount), 0) FROM public.orders o
      WHERE o.provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)
        AND o.status IN ('APPROVED','STARTED','COMPLETED')) AS sales_total,
    (SELECT count(*) FROM public.orders o
      WHERE o.provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)) AS orders_count,
    -- ride_requests has no provider_id column (20260922000008): rides are
    -- attributed via claimed_by_provider_id -> provider_profiles.id.
    (SELECT count(*) FROM public.ride_requests r
      WHERE r.claimed_by_provider_id IN (
        SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)) AS rides_count;
END;
$$;

-- ============================================================
-- PART A4. Category scoping on the guarded action RPCs.
--          Bodies restated verbatim from 20260922000010 with ONLY the
--          guard line extended by staff_scope_allows_category(target).
-- ============================================================

create or replace function public.approve_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider public.provider_profiles;
BEGIN
  IF NOT public.admin_can('registrations')
     OR p_admin_id IS DISTINCT FROM auth.uid()
     OR NOT public.staff_is_action_manager()
     OR NOT public.staff_scope_allows_category(
          (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  IF auth.uid() = (SELECT user_id FROM public.provider_profiles WHERE id = p_provider_id) THEN
    RAISE EXCEPTION 'CANNOT_APPROVE_OWN_ACCOUNT';
  END IF;

  UPDATE public.provider_profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = p_provider_id
    RETURNING * INTO v_provider;

  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles
    SET status = 'APPROVED', updated_at = now()
    WHERE id = v_provider.user_id;

  UPDATE public.approval_requests
    SET status = 'APPROVED'
    WHERE subject_type = 'PROVIDER'
      AND subject_id = p_provider_id
      AND status = 'PENDING_APPROVAL';

  INSERT INTO public.wallets (provider_id, balance)
  VALUES (p_provider_id, 0)
  ON CONFLICT (provider_id) DO NOTHING;

  INSERT INTO public.subscriptions (provider_id, status, next_due_date)
  VALUES (p_provider_id, 'ACTIVE', now() + interval '1 month')
  ON CONFLICT (provider_id) DO NOTHING;

  INSERT INTO public.approval_history (subject_type, subject_id, action, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'APPROVE', p_admin_id);

  INSERT INTO public.notifications (user_id, type, title, body)
  VALUES (
    v_provider.user_id,
    'APPROVAL',
    'Application approved',
    'Your provider account is now active.'
  );

  INSERT INTO public.admin_actions (admin_id, action, target_type, target_id)
  VALUES (p_admin_id, 'APPROVE_PROVIDER', 'provider_profiles', p_provider_id);

  PERFORM public.log_admin_action(p_admin_id, 'APPROVE_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('provider_user', v_provider.user_id));

  RETURN v_provider;
END;
$$;

create or replace function public.reject_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.admin_can('registrations')
     OR p_admin_id IS DISTINCT FROM auth.uid()
     OR NOT public.staff_is_action_manager()
     OR NOT public.staff_scope_allows_category(
          (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now()
  WHERE id = p_provider_id
  RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'REJECTED', updated_at = now()
  WHERE id = v_provider.user_id;

  UPDATE public.approval_requests
    SET status = 'REJECTED'
    WHERE subject_type = 'PROVIDER'
      AND subject_id = p_provider_id
      AND status = 'PENDING_APPROVAL';

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'REJECT', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
  SELECT user_id, 'REJECTION', 'Application rejected', p_reason
  FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'REJECT_PROVIDER', 'provider_profiles', p_provider_id,
          jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'REJECT_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

create or replace function public.request_correction_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.admin_can('registrations')
     OR p_admin_id IS DISTINCT FROM auth.uid()
     OR NOT public.staff_is_action_manager()
     OR NOT public.staff_scope_allows_category(
          (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE provider_profiles SET status = 'REJECTED', updated_at = now()
  WHERE id = p_provider_id
  RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'REJECTED', updated_at = now()
  WHERE id = v_provider.user_id;

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'REQUEST_CORRECTION', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
  SELECT user_id, 'CORRECTION_REQUIRED', 'Correction requested', 'Please update your submission: ' || p_reason
  FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'REQUEST_CORRECTION', 'provider_profiles', p_provider_id,
          jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'REQUEST_CORRECTION_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

create or replace function public.suspend_provider(
  p_provider_id uuid,
  p_admin_id uuid,
  p_reason text default null
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.admin_can('registrations')
     OR p_admin_id IS DISTINCT FROM auth.uid()
     OR NOT public.staff_is_action_manager()
     OR NOT public.staff_scope_allows_category(
          (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE provider_profiles SET status = 'SUSPENDED', updated_at = now()
  WHERE id = p_provider_id
  RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'SUSPENDED', updated_at = now()
  WHERE id = v_provider.user_id;

  UPDATE vehicles SET is_available = false WHERE provider_id = p_provider_id AND status = 'APPROVED';

  INSERT INTO approval_history (subject_type, subject_id, action, reason, performed_by)
  VALUES ('PROVIDER', p_provider_id, 'SUSPEND', p_reason, p_admin_id);

  INSERT INTO notifications (user_id, type, title, body)
  SELECT user_id, 'PROVIDER_INACTIVE', 'Account suspended', coalesce(p_reason, 'Your provider account has been suspended.')
  FROM provider_profiles WHERE id = p_provider_id;

  INSERT INTO admin_actions (admin_id, action, target_type, target_id, details)
  VALUES (p_admin_id, 'SUSPEND_PROVIDER', 'provider_profiles', p_provider_id,
          jsonb_build_object('reason', p_reason));

  PERFORM public.log_admin_action(p_admin_id, 'SUSPEND_PROVIDER', p_provider_id,
    'registration', v_provider.city,
    '{}', jsonb_build_object('reason', p_reason));

  RETURN v_provider;
END;
$$;

create or replace function public.unsuspend_provider(
  p_provider_id uuid,
  p_admin_id uuid
)
returns public.provider_profiles
language plpgsql
security definer
set search_path = public
as $$
DECLARE
  v_provider provider_profiles;
BEGIN
  IF NOT public.admin_can('registrations')
     OR p_admin_id IS DISTINCT FROM auth.uid()
     OR NOT public.staff_is_action_manager()
     OR NOT public.staff_scope_allows_category(
          (SELECT category_id FROM public.provider_profiles WHERE id = p_provider_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  UPDATE provider_profiles SET status = 'APPROVED', updated_at = now()
  WHERE id = p_provider_id
  RETURNING * INTO v_provider;
  IF v_provider.id IS NULL THEN
    RAISE EXCEPTION 'PROVIDER_NOT_FOUND';
  END IF;

  UPDATE public.profiles SET status = 'APPROVED', updated_at = now()
  WHERE id = v_provider.user_id;

  PERFORM public.log_admin_action(p_admin_id, 'UNSUSPEND_PROVIDER', p_provider_id,
    'registration', v_provider.city);

  RETURN v_provider;
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_payment_proof(
  p_proof_id uuid,
  p_decision text,
  p_note text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_txn uuid;
BEGIN
  IF NOT public.admin_can('payment_verification')
     OR NOT public.staff_scope_allows_category(
          (SELECT pp.category_id
             FROM public.payment_proofs proof
             JOIN public.orders o ON o.id = proof.order_id
             JOIN public.provider_profiles pp ON pp.id = o.provider_id
            WHERE proof.id = p_proof_id)) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;
  IF p_decision NOT IN ('VERIFIED','REJECTED') THEN
    RAISE EXCEPTION 'INVALID_VERIFICATION_DECISION';
  END IF;

  SELECT order_id, transaction_id INTO v_order.id, v_txn
  FROM public.payment_proofs WHERE id = p_proof_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'PROOF_NOT_FOUND';
  END IF;

  UPDATE public.payment_proofs
  SET verification_status = p_decision, verified_by = auth.uid(), verified_at = now()
  WHERE id = p_proof_id;

  SELECT * INTO v_order FROM public.orders WHERE id = v_order.id;

  IF p_decision = 'VERIFIED' AND v_order.status = 'PAYMENT_VERIFICATION' THEN
    UPDATE public.orders SET status = 'APPROVED', updated_at = now() WHERE id = v_order.id;
    INSERT INTO order_status_history (order_id, from_status, to_status, changed_by)
    VALUES (v_order.id, 'PAYMENT_VERIFICATION', 'APPROVED', auth.uid())
    ON CONFLICT DO NOTHING;
  END IF;

  INSERT INTO notifications (user_id, type, title, body)
  VALUES (
    v_order.user_id,
    CASE WHEN p_decision = 'VERIFIED' THEN 'APPROVAL'::notification_type ELSE 'REJECTION'::notification_type END,
    CASE WHEN p_decision = 'VERIFIED' THEN 'Payment verified' ELSE 'Payment rejected' END,
    COALESCE(p_note, CASE WHEN p_decision = 'VERIFIED'
      THEN 'Your payment has been verified. The provider contact details are now available.'
      ELSE 'Your payment proof could not be verified. Please re-upload.' END)
  );

  PERFORM public.log_admin_action(auth.uid(),
    'PAYMENT_PROOF_' || p_decision, v_order.id, 'transaction', v_order.city,
    '{}', jsonb_build_object('proof_id', p_proof_id, 'note', p_note));
END;
$$;

-- ============================================================
-- PART A5. Scoped read policies so categorized sub-admins see exactly
--          their slice (additive; admins unaffected).
-- ============================================================

-- Provider directory scoped by category (replaces the unscoped 0010 policy).
DROP POLICY IF EXISTS provider_profiles_staff_registration_read ON public.provider_profiles;
DO $$ BEGIN
  CREATE POLICY provider_profiles_staff_registration_read ON public.provider_profiles FOR SELECT
    USING (
      status = 'APPROVED' OR user_id = auth.uid() OR public.is_admin()
      OR (
        public.staff_has_permission(auth.uid(), 'registrations')
        AND public.staff_scope_allows_category(category_id)
      )
      OR (
        public.staff_has_permission(auth.uid(), 'payment_verification')
        AND public.staff_scope_allows_category(category_id)
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Reports visibility: 'view_reports' staff see orders / rides / products
-- within their categories.
DO $$ BEGIN
  CREATE POLICY orders_staff_reports_read ON public.orders FOR SELECT
    USING (
      public.is_admin()
      OR (
        public.staff_has_permission(auth.uid(), 'view_reports')
        AND public.staff_scope_allows_category(
              (SELECT pp.category_id FROM public.provider_profiles pp
                WHERE pp.id = orders.provider_id))
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY ride_requests_staff_reports_read ON public.ride_requests FOR SELECT
    USING (
      public.is_admin()
      OR user_id = auth.uid()
      OR claimed_by_provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = auth.uid())
      OR (
        public.staff_has_permission(auth.uid(), 'view_reports')
        AND public.staff_scope_allows_category(vehicle_category_id)
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
  CREATE POLICY products_staff_reports_read ON public.products FOR SELECT
    USING (
      public.is_admin()
      OR provider_id IN (SELECT id FROM public.provider_profiles WHERE user_id = auth.uid())
      OR (
        public.staff_has_permission(auth.uid(), 'view_reports')
        AND public.staff_scope_allows_category(category_id)
      )
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Expenses: super admin / CEO / 'view_expenses' staff.
DO $$ BEGIN
  CREATE POLICY admin_expenses_staff_read ON public.admin_expenses FOR SELECT
    USING (
      public.is_admin()
      OR public.staff_has_permission(auth.uid(), 'view_expenses')
    );
EXCEPTION WHEN duplicate_object THEN NULL; WHEN undefined_table THEN NULL; END $$;

-- Audit trail: 'view_auth_logs' staff (in addition to 'admin_history').
DROP POLICY IF EXISTS admin_history_staff_read ON public.admin_history;
DO $$ BEGIN
  CREATE POLICY admin_history_staff_read ON public.admin_history FOR SELECT
    USING (
      public.is_admin()
      OR public.staff_has_permission(auth.uid(), 'admin_history')
      OR public.staff_has_permission(auth.uid(), 'view_auth_logs')
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ============================================================
-- PART B. Ride fare engine
-- ============================================================

-- Admin-configurable defaults (per-category overrides live in
-- categories.metadata as {"base_fare":..,"per_km":..,"minimum_fare":..}).
-- SETTINGS GUARD BYPASS (same session-local pattern as 0038): the settings
-- trigger calls is_admin() -> auth.uid(), which is NULL on a migration
-- connection (no JWT), so the guard would fire for the owner itself. Disable
-- the trigger for this transaction only; app-level writes stay guarded.
BEGIN;
ALTER TABLE public.system_settings DISABLE TRIGGER trg_system_settings_security;

INSERT INTO system_settings (key, value, description) VALUES
  ('ride_base_fare', '50', 'Ride: base fare in ETB applied to every trip'),
  ('ride_per_km', '20', 'Ride: charge per kilometer in ETB'),
  ('ride_minimum_fare', '80', 'Ride: minimum fare in ETB')
ON CONFLICT (key) DO NOTHING;

ALTER TABLE public.system_settings ENABLE TRIGGER trg_system_settings_security;
COMMIT;

ALTER TABLE public.categories ADD COLUMN IF NOT EXISTS metadata jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE OR REPLACE FUNCTION public.calculate_fare_estimate(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid DEFAULT NULL
)
RETURNS numeric(12,2)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_distance_km numeric;
  v_base numeric;
  v_per_km numeric;
  v_min numeric;
  v_meta jsonb;
  v_estimate numeric;
BEGIN
  v_distance_km := round(
    (st_distance(
      st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_dest_lng, p_dest_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  v_base    := COALESCE(get_setting_numeric('ride_base_fare'), 50);
  v_per_km  := COALESCE(get_setting_numeric('ride_per_km'), 20);
  v_min     := COALESCE(get_setting_numeric('ride_minimum_fare'), 80);

  -- Per-category overrides win over the global settings.
  IF p_vehicle_category_id IS NOT NULL THEN
    SELECT metadata INTO v_meta FROM public.categories WHERE id = p_vehicle_category_id;
    v_base   := COALESCE((v_meta ->> 'base_fare')::numeric, v_base);
    v_per_km := COALESCE((v_meta ->> 'per_km')::numeric, v_per_km);
    v_min    := COALESCE((v_meta ->> 'minimum_fare')::numeric, v_min);
  END IF;

  v_estimate := GREATEST(v_min, v_base + v_per_km * v_distance_km);
  RETURN round(v_estimate, 2);
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate(double precision, double precision, double precision, double precision, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_fare_estimate(double precision, double precision, double precision, double precision) TO authenticated;

-- create_ride_request restated (same name/signature/posture as 0011):
-- + fare stamping from calculate_fare_estimate
-- + server-side account-approval gate (profiles.status must be APPROVED)
-- The insert, status history write, and parameter contract are unchanged.
CREATE OR REPLACE FUNCTION public.create_ride_request(
  p_user_id uuid,
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_destination_lat double precision,
  p_destination_lng double precision,
  p_pickup_text text default null,
  p_destination_text text default null,
  p_vehicle_category_id uuid default null
) RETURNS ride_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride ride_requests;
  v_status text;
BEGIN
  IF p_user_id != auth.uid() THEN
    RAISE EXCEPTION 'CANNOT_CREATE_RIDE_FOR_ANOTHER_USER';
  END IF;

  -- Approval gate: only APPROVED accounts can summon drivers. The login
  -- router already sends pending/rejected users to their screens; this is
  -- the server-side backstop (admins bypass by design).
  SELECT status::text INTO v_status FROM public.profiles WHERE id = p_user_id;
  IF v_status IS NULL THEN
    RAISE EXCEPTION 'PROFILE_NOT_FOUND';
  END IF;
  IF v_status NOT IN ('APPROVED') THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_APPROVED_YET';
  END IF;

  INSERT INTO ride_requests (
    user_id, pickup_location, destination_location,
    pickup_text, destination_text, vehicle_category_id,
    fare_estimate, status
  ) VALUES (
    p_user_id,
    st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
    st_setsrid(st_makepoint(p_destination_lng, p_destination_lat), 4326)::geography,
    p_pickup_text, p_destination_text, p_vehicle_category_id,
    calculate_fare_estimate(p_pickup_lat, p_pickup_lng, p_destination_lat, p_destination_lng, p_vehicle_category_id),
    'REQUESTED'
  ) RETURNING * INTO v_ride;

  INSERT INTO ride_status_history (ride_request_id, from_status, to_status, changed_by)
  VALUES (v_ride.id, null, 'REQUESTED', p_user_id);

  RETURN v_ride;
END;
$$;

-- ============================================================
-- Grants for restated functions (idempotent)
-- ============================================================
GRANT EXECUTE ON FUNCTION public.create_staff(text, text, text[], numeric, boolean, text, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_staff(uuid, text, text[], numeric, boolean, uuid[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.revoke_staff(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_performance(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_provider(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_provider(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_correction_provider(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.suspend_provider(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.unsuspend_provider(uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.verify_payment_proof(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_ride_request(uuid, double precision, double precision, double precision, double precision, text, text, uuid) TO authenticated;
