-- Let the server change provider_profiles.status; keep clients from doing so.
--
-- The bug
-- ------
-- provider_profiles has a guard trigger:
--
--   CREATE TRIGGER trg_provider_profiles_security
--     BEFORE UPDATE ON provider_profiles FOR EACH ROW
--     EXECUTE FUNCTION prevent_provider_self_privilege_escalation();
--
-- and that function begins:
--
--   IF NOT is_admin() THEN
--     IF new.status != old.status THEN
--       RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
--
-- is_admin() is has_role('ADMIN'), which is `user_id = auth.uid()`. For a
-- request that is what you want. For anything the SERVER initiates there is
-- no signed-in user at all, so auth.uid() is NULL, is_admin() is false, and
-- the guard fires on the server's own writes:
--
--   * charge_due_subscriptions(), run daily by pg_cron as `postgres`
--   * the subscription-process edge function, which connects as service_role
--
-- Both of those legitimately move provider_profiles.status, and both were
-- being rejected by this trigger.
--
-- The consequences were not subtle:
--
--   1. AUTO-SUSPENSION NEVER WORKED. The suspend branch in
--      charge_due_subscriptions() is not wrapped in a BEGIN/EXCEPTION block,
--      so the raise aborted the entire function. The first provider needing
--      suspension killed the run, and every provider after them in the loop
--      was skipped for that day — not charged, not moved to GRACE, not
--      notified. This is the same "money never reaches the ledger" class as
--      the orphaned scheduler fixed in 20260922000004, one layer further in.
--
--   2. THE REACTIVATION PATH WAS SILENTLY SWALLOWED. The restore added in
--      20260927000006 sits inside a BEGIN/EXCEPTION that increments
--      v_deferred, so the raise was caught rather than aborting — the
--      provider paid, nothing was restored, and the "Account reactivated"
--      notification never fired. A provider could pay their fee forever and
--      stay suspended with no indication of why.
--
-- The fix
-- ------
-- Restrict the guard to CLIENT requests only, discriminated on session_user.
--
-- session_user is the role the request authenticated as and is NOT changed
-- by SECURITY DEFINER — unlike current_user, which inside this trigger is
-- always the function owner and therefore useless for telling a client
-- apart from the server. So:
--
--   PostgREST / app request -> authenticated  -> guarded (as before)
--   pg_cron job             -> postgres       -> allowed
--   edge function           -> service_role   -> allowed
--
-- Every other check in the function — provider_type, subscription_start_date
-- and owner_national_id — is kept, and kept applying to clients exactly as
-- before. Only the "is this the server?" question is new, and only the
-- client branch changes behaviour.
--
-- service_role is trusted here on the same basis every other SECURITY
-- DEFINER function in this schema already relies on: it is only ever
-- obtained by an Edge Function that has already authenticated the caller
-- and checked the role itself (requireUser / requireRole in _shared/client).

CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Server-initiated writes are trusted. A client cannot reach these roles:
  -- the anon/authenticated JWTs map to the `authenticated` role, and
  -- service_role is only ever used by an Edge Function that has already
  -- authorized the caller.
  IF session_user IN ('postgres', 'service_role', 'supabase_admin') THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
  END IF;

  IF new.provider_type IS DISTINCT FROM old.provider_type THEN
    RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
  END IF;

  IF new.subscription_start_date IS DISTINCT FROM old.subscription_start_date THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED';
  END IF;

  IF old.owner_national_id IS NOT NULL
     AND new.owner_national_id IS DISTINCT FROM old.owner_national_id THEN
    RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_provider_self_privilege_escalation() IS
  'Stops a client editing its own provider_profiles.status, provider_type, '
  'subscription_start_date or owner_national_id. Server-initiated writes '
  '(pg_cron as postgres, edge functions as service_role) are exempt, because '
  'is_admin() is false for them and the guard would otherwise block the '
  'subscription scheduler from ever suspending or reactivating anyone.';

-- ── The guard against this regressing ────────────────────────────────────
-- Two things must both hold, and they pull in opposite directions, so both
-- are asserted:
--
--   1. the guard is scoped to clients via session_user — without this the
--      subscription scheduler is broken again, silently;
--   2. the client branch still refuses a status change — without this the
--      fix would have simply removed the protection it was meant to keep.
CREATE OR REPLACE FUNCTION public.assert_provider_status_guard_is_client_scoped()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
BEGIN
  SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'prevent_provider_self_privilege_escalation';

  IF v_flat IS NULL THEN
    RETURN false;
  END IF;

  -- (1) The exemption must key off session_user, not current_user. Inside a
  -- SECURITY DEFINER trigger current_user is the owner, so a guard written
  -- against it would exempt every caller and disable the protection.
  IF position('session_user' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- (2) The client branch must still exist and still refuse. Checked on the
  -- raise, not just the status comparison, so a guard that compared status
  -- but did nothing about it would not pass.
  IF position(
       'if new.status is distinct from old.status then raise exception ''status_cannot_be_self_modified'''
       in v_flat
     ) = 0 THEN
    RETURN false;
  END IF;

  -- The other server-managed columns must remain protected as well.
  RETURN position('provider_type' in v_flat) > 0
     AND position('subscription_start_date' in v_flat) > 0
     AND position('owner_national_id' in v_flat) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_status_guard_is_client_scoped() IS
  'True when the provider_profiles status guard exempts server roles via '
  'session_user while still refusing client status changes.';

GRANT EXECUTE ON FUNCTION public.assert_provider_status_guard_is_client_scoped() TO authenticated;
