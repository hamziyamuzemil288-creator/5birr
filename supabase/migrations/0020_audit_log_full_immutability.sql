-- 5BIRR — Fix audit log full immutability
-- Migration 0020_audit_log_full_immutability.sql
-- Applied: 2026-09-17
--
-- The original prevent_audit_log_deletion() function only fired on DELETE,
-- leaving audit_logs vulnerable to UPDATE. This migration replaces the
-- function to block both UPDATE and DELETE, and recreates the trigger
-- to fire on both events.

-- 1. Replace function to handle both UPDATE and DELETE
CREATE OR REPLACE FUNCTION public.prevent_audit_log_deletion()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN
    RAISE EXCEPTION 'AUDIT_LOGS_CANNOT_BE_MODIFIED';
  ELSIF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'AUDIT_LOGS_CANNOT_BE_DELETED';
  END IF;
  RETURN NULL;
END;
$$;

-- 2. Drop and recreate trigger to fire on both UPDATE and DELETE
DROP TRIGGER IF EXISTS trg_audit_logs_immutable ON audit_logs;
CREATE TRIGGER trg_audit_logs_immutable
  BEFORE UPDATE OR DELETE ON audit_logs
  FOR EACH ROW
  EXECUTE FUNCTION prevent_audit_log_deletion();
