-- Retarget the provider guard assertion at the guard's current shape.
--
-- The failure
-- -----------
-- Connectivity CI reported:
--
--   provider status: server may change it, clients may not
--   the self-approval guard exempts server roles only   (failed)
--
-- That is assert_provider_status_guard_is_client_scoped, written in
-- 20260927000015. It does an exact normalised-text match on:
--
--   if new.status is distinct from old.status then
--     raise exception 'status_cannot_be_self_modified'
--
-- 20260927000028 inserted the resubmission exemption inside that comparison,
-- so the guard now reads:
--
--   if new.status is distinct from old.status then
--     if not (old.status = 'REJECTED' and new.status = 'PENDING_APPROVAL') then
--       raise exception 'status_cannot_be_self_modified';
--     end if;
--   end if;
--
-- and the needle no longer appears contiguously. The guard is correct, and
-- strictly better than what the assertion was written to describe: it still
-- refuses self-approval and every other status change, and it additionally
-- permits the one transition 0008 documented and 0019 dropped.
--
-- This is the same failure mode as 20260927000012, where two chain
-- assertions were pinned to source text that no longer matched the function
-- they described. The lesson there was that an exact-text assertion is
-- brittle by construction, and it is worth restating why the brittleness is
-- acceptable here: it fails loudly and immediately when the guard changes
-- shape, and the response is to re-read the guard and restate the intent.
-- That is what this does. A silently-passing assertion is the thing to avoid,
-- and this one never did that -- it was the guard assertion that passed
-- through the 00020 staff-scope revert, which is why 00026 replaced it with
-- a condition-by-condition check rather than a single exact string.
--
-- The new shape checks each condition independently:
--
--   * the server exemption is present;
--   * the resubmission transition is present, so it cannot be dropped again;
--   * the refusal is present, so "allow everything" cannot pass;
--   * the other protected columns are still checked.
--
-- Note what is deliberately NOT asserted: that resubmission is refused. The
-- opposite is now the requirement. profile_repository.resubmitProvider()
-- depends on it, and its comment says so.

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

  -- (1) Server exemption, via the shared discriminator. Branching on
  -- current_user here is what made the 0030/0033/0034 guards inert.
  IF position('is_server_write' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  IF position('current_user' in v_flat) > 0 THEN
    RETURN false;
  END IF;

  -- (2) The resubmission transition must still be allowed. Dropping it again
  -- is what broke rejected providers resubmitting, so it is pinned rather
  -- than left to a comment in the app.
  IF position(
       'old.status = ''rejected'' and new.status = ''pending_approval'''
       in v_flat
     ) = 0 THEN
    RETURN false;
  END IF;

  -- (3) Every other status change must still be refused. Checked on the
  -- raise, not just the comparison, so a guard that compared and then did
  -- nothing would not pass.
  IF position('raise exception' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  IF position('status_cannot_be_self_modified' in v_flat) = 0 THEN
    RETURN false;
  END IF;

  -- (4) The other server-managed columns must remain protected.
  RETURN position('provider_type' in v_flat) > 0
     AND position('owner_national_id' in v_flat) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_provider_status_guard_is_client_scoped() IS
  'True when the provider_profiles guard exempts server writes via '
  'is_server_write(), still refuses status changes other than the documented '
  'REJECTED -> PENDING_APPROVAL resubmission, and still protects provider_type '
  'and owner_national_id.';
