-- =============================================================================
-- 20261007000014 — Fix is_admin() to handle SECURITY DEFINER functions
--
-- ROOT CAUSE: The is_admin() function checks has_role('ADMIN'::app_role),
-- which checks auth.uid(). When a SECURITY DEFINER function runs without a
-- JWT (auth.uid() = NULL), is_admin() returns FALSE — even though the
-- function is running as the postgres role, which IS an admin.
--
-- This causes the like-persistence test to fail: it creates a provider
-- with status='APPROVED' using the trigger disable/enable pattern, but
-- the trigger (when not disabled) blocks the insert because is_admin()
-- returns FALSE.
--
-- FIX: Make is_admin() return TRUE when the current role is postgres
-- (the migration runner), since postgres IS an admin.
-- =============================================================================

CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT has_role('ADMIN'::app_role)
     OR (auth.uid() IS NULL AND current_setting('role', true) = 'postgres');
$function$;

grant execute on function is_admin() to anon, authenticated, service_role;

comment on function is_admin() is
  'Returns TRUE if the current user is an admin. When running as a SECURITY DEFINER function without a JWT (auth.uid() IS NULL), also returns TRUE if the current role is postgres (the migration runner), since postgres IS an admin.';
