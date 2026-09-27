-- Keep public.profiles.status in step with public.provider_profiles.status.
--
-- Why
-- ---
-- `profiles.status` and `provider_profiles.status` are two columns meaning
-- related but different things, and the code paths that move them are not
-- symmetric.
--
-- Suspend (admin) sets BOTH:
--
--   UPDATE provider_profiles SET status = 'SUSPENDED' ...
--   UPDATE public.profiles     SET status = 'SUSPENDED' ...
--
-- Suspend (revenue scheduler, on an unpaid subscription fee) sets only the
-- provider row:
--
--   update subscriptions      set status = 'SUSPENDED' ...
--   update provider_profiles  set status = 'SUSPENDED', updated_at = now()
--
-- Unsuspend restores only the provider row:
--
--   UPDATE provider_profiles SET status = 'APPROVED' ...
--
-- Two consequences, one of them a lockout:
--
--   1. unsuspend_provider() never restores profiles.status, so an
--      admin-suspended account stays profiles.status = 'SUSPENDED'
--      permanently. The app router gates on profiles.status, so the user is
--      refused their own account forever with no self-service way out. The
--      admin sees "APPROVED" in the provider table and believes it worked.
--
--   2. A provider suspended by the revenue scheduler — the common case, and
--      entirely the account holder's own doing — never gets profiles.status
--      set, so the router does not gate them at all.
--
-- Before the /suspended screen, (1) was invisible: the router ignored
-- SUSPENDED, so the mismatch cost nothing. Gating on it turned a latent
-- inconsistency into a hard lockout, which is why this lands in the same
-- change rather than after it.
--
-- The fix
-- -------
-- One trigger on provider_profiles.status, so every existing path is covered
-- at once — the admin RPC, unsuspend_provider, the revenue scheduler and the
-- subscription-process edge function all go through the same UPDATE.
--
-- Only two transitions are mirrored, and the restore is guarded, because
-- profiles.status also carries PENDING_APPROVAL and REJECTED, which are
-- account-approval states with no provider equivalent. Restoring
-- APPROVED only when the current value is exactly SUSPENDED means a REJECTED
-- applicant cannot be flipped to APPROVED by an unrelated provider update.

CREATE OR REPLACE FUNCTION public.sync_profile_status_from_provider()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- Suspended provider -> suspended account.
  IF NEW.status = 'SUSPENDED' AND OLD.status IS DISTINCT FROM 'SUSPENDED' THEN
    UPDATE public.profiles
       SET status = 'SUSPENDED'
     WHERE id = NEW.user_id
       AND status IS DISTINCT FROM 'SUSPENDED';
    RETURN NEW;
  END IF;

  -- Reactivated provider -> restore the account, but ONLY from SUSPENDED.
  -- A PENDING_APPROVAL or REJECTED profile is mid-approval and must not be
  -- rescued by a provider-status write.
  IF NEW.status = 'APPROVED' AND OLD.status IS DISTINCT FROM 'APPROVED' THEN
    UPDATE public.profiles
       SET status = 'APPROVED'
     WHERE id = NEW.user_id
       AND status = 'SUSPENDED';
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_profile_status_from_provider() IS
  'Mirrors provider_profiles SUSPENDED/APPROVED onto profiles.status so the '
  'app router gate and unsuspend_provider agree. Guards the restore so a '
  'PENDING_APPROVAL or REJECTED profile is never flipped to APPROVED.';

DROP TRIGGER IF EXISTS trg_sync_profile_status ON public.provider_profiles;
CREATE TRIGGER trg_sync_profile_status
  AFTER UPDATE OF status ON public.provider_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_profile_status_from_provider();

-- ── Backfill any drift already present ──────────────────────────────────
-- Providers suspended through the admin path whose profile was never
-- restored, and providers suspended by the scheduler whose profile was
-- never set. Both are currently unreachable by the user for no visible
-- reason; this makes the state self-consistent.

-- SUSPENDED provider whose profile still says APPROVED.
UPDATE public.profiles p
   SET status = 'SUSPENDED'
  FROM public.provider_profiles pp
 WHERE pp.user_id = p.id
   AND pp.status = 'SUSPENDED'
   AND p.status = 'APPROVED';

-- Suspended profile whose provider row has since been reactivated, i.e. an
-- unsuspend that only half-landed.
UPDATE public.profiles p
   SET status = 'APPROVED'
  FROM public.provider_profiles pp
 WHERE pp.user_id = p.id
   AND pp.status = 'APPROVED'
   AND p.status = 'SUSPENDED';
