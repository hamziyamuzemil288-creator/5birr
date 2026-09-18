-- 5BIRR — Fix order status security trigger for the sanctioned server path
-- Migration 0029_fix_order_status_trigger_server_path.sql
-- Applied: 2026-09-18
--
-- BUG (found while E2E-testing the points feature):
--   prevent_order_self_privilege_escalation() allowed status changes only
--   when is_admin() (a logged-in admin user). But the sanctioned way orders
--   change status is the `order-transition` Edge Function, which runs as
--   the SERVICE ROLE — auth.uid() is NULL there, so is_admin() is false and
--   every server-side transition raised
--   ORDER_STATUS_CHANGE_REQUIRES_SERVER_FUNCTION.
--   Net effect: NO order could ever advance (ACCEPTED -> ... -> COMPLETED)
--   since the hardening pass — and points (Feature 3) could never fire.
--
-- FIX (minimal, intent preserved):
--   Clients (anon/authenticated) are STILL blocked from direct status
--   changes unless they are admins. The trusted server paths — service_role
--   requests (edge functions) and the table owner (postgres, SECURITY
--   DEFINER contexts) — are allowed through.

CREATE OR REPLACE FUNCTION public.prevent_order_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user IN ('postgres', 'service_role') THEN
    -- Trusted server paths: SECURITY DEFINER owners and edge functions.
    RETURN new;
  END IF;
  IF NOT is_admin() THEN
    IF new.status != old.status THEN
      RAISE EXCEPTION 'ORDER_STATUS_CHANGE_REQUIRES_SERVER_FUNCTION';
    END IF;
  END IF;
  RETURN new;
END;
$function$;
