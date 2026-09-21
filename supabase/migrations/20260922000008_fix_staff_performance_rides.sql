-- ============================================================
-- Migration 20260922000008_fix_staff_performance_rides.sql
-- Phase 2 connection fix, follow-up to 20260922000001.
--
-- 20260922000001 as merged to main was applied to the live DB
-- (Deploy Supabase #1, 2026-09-21 17:49Z) BEFORE the fix for
-- `staff_performance` rides_count could ride along with it, so the
-- fix ships as this NEW migration (never edit an applied migration).
--
-- BREAK (staff ↔ actions):
--   staff_performance counted rides with r.provider_id, a column that
--   does not exist on ride_requests (real column: claimed_by_provider_id,
--   typed as provider_profiles.id). Every call therefore failed with
--   PGRST204/42703, so the per-staff performance view could not load.
--
-- FIX: restate the function verbatim (same signature, same privilege
-- checks, same SECURITY DEFINER + search_path) with the rides_count
-- subquery corrected to join through provider_profiles, mirroring the
-- orders_count pattern already used in the same function.
--
-- Idempotent: CREATE OR REPLACE on the same signature. The function is
-- SECURITY DEFINER owned by the role running the migration (as created
-- by 20260922000001), so it keeps bypassing RLS for its two authorized
-- counts and nothing else. No table, column, grant or policy touched.
-- ============================================================

CREATE OR REPLACE FUNCTION public.staff_performance(p_staff_id uuid)
RETURNS TABLE(registrations bigint, sales_total numeric, orders_count bigint, rides_count bigint)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin uuid := auth.uid();
  v_is_self boolean;
  v_target_user uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_PERFORMANCE';
  END IF;
  SELECT user_id INTO v_target_user FROM public.staff WHERE id = p_staff_id;
  SELECT (user_id = v_admin) INTO v_is_self FROM public.staff WHERE id = p_staff_id;
  IF NOT (public.is_super_admin(v_admin) OR COALESCE(v_is_self, false)) THEN
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
    (SELECT count(*) FROM public.ride_requests r
      WHERE r.claimed_by_provider_id IN (
        SELECT id FROM public.provider_profiles WHERE user_id = v_target_user)) AS rides_count;
END;
$$;
