-- Reactivating a provider must also put their vehicles back in service.
--
-- The gap
-- -------
-- suspend_provider() does three things, not one:
--
--   UPDATE provider_profiles SET status = 'SUSPENDED'   ...
--   UPDATE public.profiles     SET status = 'SUSPENDED'  ...
--   UPDATE vehicles SET is_available = false
--          WHERE provider_id = p_provider_id AND status = 'APPROVED'
--
-- unsuspend_provider() undoes all three. The revenue-driven reactivation
-- added in 20260927000006 undoes only the first two: it restores
-- provider_profiles.status, and trg_sync_profile_status carries that to
-- profiles.status, but nothing touches vehicles.
--
-- So this sequence leaves a provider permanently unable to work:
--
--   1. admin suspends the provider  -> vehicles.is_available = false
--   2. provider recharges and the monthly fee is collected
--      (20260927000006)              -> account restored, vehicle still off
--
-- claim_ride() requires is_available = true, and find_nearby_drivers()
-- requires v.is_available = true, so a fully approved, unsuspended,
-- fully paid provider whose vehicle is still flagged unavailable simply
-- never appears in search and can never accept a ride. The app gives no
-- indication why: the provider is APPROVED everywhere the UI reads.
--
-- Why the trigger, not another UPDATE
-- ----------------------------------
-- Every path back to APPROVED goes through one UPDATE on
-- provider_profiles.status — the admin RPC, unsuspend_provider, the revenue
-- scheduler and the subscription-process edge function alike. Restoring
-- vehicles inside the trigger means the 20260927000006 revenue path and the
-- edge function are both covered by this one change, with no edit needed at
-- each call site, and a future restore path is covered for free.
--
-- The guard matches the one already used for profiles.status: the vehicle is
-- only returned to service when the provider is coming back from exactly
-- SUSPENDED, and only vehicles the suspension actually touched (those that
-- are themselves APPROVED) are touched at all. A vehicle the provider had
-- manually switched off before being suspended keeps its own state, exactly
-- as it does today under unsuspend_provider.
--
-- The update is deliberately not counted as an approval: approving a
-- brand-new provider (PENDING_APPROVAL -> APPROVED) does not fire this
-- branch, and a provider who set a vehicle unavailable themselves and is
-- later suspended and reactivated still gets it back, which is the existing
-- unsuspend_provider behaviour and not a regression.

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

    -- vehicles.is_available is the third half of a suspension; the account
    -- gate alone does not stop the vehicle being offered to customers.
    UPDATE public.vehicles
       SET is_available = false
     WHERE provider_id = NEW.id
       AND status = 'APPROVED'
       AND is_available = true;

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

    -- Put the vehicles back in service. Without this the provider is
    -- approved, unsuspended and paid up, but their vehicle never appears in
    -- find_nearby_drivers() and claim_ride() refuses it as not eligible.
    UPDATE public.vehicles
       SET is_available = true
     WHERE provider_id = NEW.id
       AND status = 'APPROVED'
       AND is_available = false;

    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_profile_status_from_provider() IS
  'Mirrors provider_profiles SUSPENDED/APPROVED onto profiles.status and '
  'vehicles.is_available so the app router gate, claim_ride() and '
  'unsuspend_provider all agree. Guards the restore so a PENDING_APPROVAL or '
  'REJECTED profile is never flipped to APPROVED.';

-- No backfill, on purpose.
-- --------------------------
-- A vehicle that is unavailable because a suspension was lifted is
-- indistinguishable from one the provider switched off by hand to stop
-- working, and a blanket "approved provider -> vehicle available" UPDATE
-- would put the second kind back on the road. The trigger only fires on a
-- real SUSPENDED -> APPROVED transition, which is exactly the stranded case
-- and cannot over-reach. Any provider already stranded by the bug will be
-- fixed the next time their account is suspended and reactivated, or by an
-- admin unsuspend; until then their vehicle stays off, which is the safe
-- direction to be wrong in.
