-- 5BIRR — Fix wallet balance guard for the sanctioned server path
-- Migration 0030_fix_wallet_balance_trigger_server_path.sql
-- Applied: 2026-09-18
--
-- BUG (same class as migration 0029, found while E2E-testing points):
--   prevent_wallet_direct_balance_edit() allowed balance changes only when
--   is_admin(). But the ONLY sanctioned writer of wallet balances is
--   deduct_transaction_fee() / deduct_subscription_fee(), called from edge
--   functions running as SERVICE ROLE — where is_admin() is false.
--   Net effect: the fee engine itself was blocked; orders could never pass
--   STARTED (BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION).
--
-- FIX (minimal, intent preserved):
--   Clients are STILL blocked from editing balances directly. Trusted
--   server paths (service_role edge functions, SECURITY DEFINER owners)
--   are allowed through.

CREATE OR REPLACE FUNCTION public.prevent_wallet_direct_balance_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user IN ('postgres', 'service_role') THEN
    RETURN new;
  END IF;
  IF NOT is_admin() THEN
    IF new.balance != old.balance THEN
      RAISE EXCEPTION 'BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION';
    END IF;
  END IF;
  RETURN new;
END;
$function$;
