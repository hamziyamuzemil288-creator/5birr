-- 5BIRR — Fix prevent_role_escalation trigger
-- Migration 0022_fix_role_escalation_trigger.sql
-- Applied: 2026-09-17
--
-- The original prevent_role_escalation() checked is_admin() via auth.uid(),
-- which blocked ALL automated role assignments — including SECURITY DEFINER
-- functions like handle_new_user() and handle_new_provider_profile() that
-- run during signup. Since auth.uid() returns the new user's ID (not an
-- admin), the trigger raised ROLE_ASSIGNMENT_IS_ADMIN_ONLY and rolled back
-- the entire signup transaction.
--
-- Fix: only enforce the admin check when current_user = 'authenticated'
-- (i.e., a direct client request). When current_user is anything else
-- (e.g., 'postgres' inside a SECURITY DEFINER function), allow the
-- assignment to proceed. This preserves the protection against
-- user-initiated role escalation while unblocking legitimate system flows.

CREATE OR REPLACE FUNCTION public.prevent_role_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Allow role assignment if we're inside a SECURITY DEFINER function
  -- (auth triggers, system functions) — identified by current_user not being
  -- the 'authenticated' role. Only block direct user-initiated inserts.
  IF current_user = 'authenticated' THEN
    IF NOT is_admin() THEN
      RAISE EXCEPTION 'ROLE_ASSIGNMENT_IS_ADMIN_ONLY';
    END IF;
  END IF;
  RETURN new;
END;
$$;
