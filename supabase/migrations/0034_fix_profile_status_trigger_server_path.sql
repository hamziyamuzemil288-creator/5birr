-- 5BIRR — Fix profile status guard for the sanctioned server path
-- Migration 0034_fix_profile_status_trigger_server_path.sql
--
-- BUG (same class as 0029/0030/0033, found while E2E-testing provider
-- approval after 20260919000002):
--   approve_provider() (restated by 20260919000002) now also does
--     UPDATE profiles SET status = 'APPROVED' WHERE id = v_provider.user_id
--   to close the login gate. But trg_profiles_security ->
--   prevent_profile_self_privilege_escalation() blocks ANY status change
--   unless is_admin(). The SECURITY DEFINER RPC runs as service_role/
--   postgres — is_admin() is false there — so every approval attempted
--   after the 20260919000002 deploy failed with
--   PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED (unsanitized -> generic 400 in
--   the provider-approval Edge Function).
--   Identical pattern already fixed for orders (0029), wallets (0030),
--   provider_profiles + notifications (0033).
--
-- FIX (minimal, intent preserved):
--   Clients are STILL blocked from editing profile status directly.
--   Trusted server paths (service_role edge functions, SECURITY DEFINER
--   owners) are allowed through.

CREATE OR REPLACE FUNCTION public.prevent_profile_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user IN ('postgres', 'service_role') THEN
    -- Trusted server paths: SECURITY DEFINER RPCs (approve_provider,
    -- reject_provider, request_correction_provider, suspend/unsuspend,
    -- approve_user/reject_user) and edge functions. Clients are still
    -- restricted below.
    RETURN new;
  END IF;
  IF NOT is_admin() THEN
    IF new.status != old.status THEN
      RAISE EXCEPTION 'PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED';
    END IF;
  END IF;
  RETURN new;
END;
$function$;

-- The trigger itself (trg_profiles_security -> BEFORE UPDATE ON profiles)
-- is unchanged; only the function body is restated. No DDL on tables, no
-- policy changes, no data writes. Idempotent.
