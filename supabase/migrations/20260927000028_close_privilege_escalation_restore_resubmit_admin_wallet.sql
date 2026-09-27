-- Close a live self-approval hole, restore resubmission, and let admins credit wallets.
--
-- Three findings from the full sweep. The first is a privilege escalation
-- that is exploitable by anyone holding the anon key, which ships inside the
-- app bundle.
--
-- 1. prevent_profile_self_privilege_escalation was inert
-- ------------------------------------------------------
-- 0034 gave the profiles guard this exemption:
--
--   IF current_user IN ('postgres', 'service_role') THEN RETURN new; END IF;
--   IF NOT is_admin() THEN
--     IF new.status != old.status THEN
--       RAISE EXCEPTION 'PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED';
--
-- The guard is SECURITY DEFINER, so current_user inside it is the function
-- owner for every caller, not the caller. The first branch is therefore true
-- unconditionally and the function returns immediately. The status check has
-- never run. This is the same defect as 0030's wallet guard, and it was fixed
-- there but never here.
--
-- The RLS policy makes it reachable:
--
--   CREATE POLICY profiles_update_own ON profiles FOR UPDATE
--     USING (id = auth.uid()) WITH CHECK (id = auth.uid());
--
-- That is row-level, not column-level: it lets a user update every column of
-- their own row, status included. So any authenticated user can
--
--   PATCH /rest/v1/profiles?id=eq.<their own uid>  {"status":"APPROVED"}
--
-- and approve their own account, with no admin, no approval request and no
-- audit row. profiles.status is what the login router gates on, so this is
-- self-approval of the whole account.
--
-- Fixed with the same discriminator used across this series. The client check
-- is unchanged in substance: a non-admin still cannot move their own status.
--
-- 2. Provider resubmission was broken (pre-existing, not from tonight)
-- --------------------------------------------------------------
-- 0008_security_hardening_phase2.sql allowed exactly one client status change:
--
--   -- Allow REJECTED -> PENDING_APPROVAL (resubmission after correction)
--   if old.status = 'REJECTED' and new.status = 'PENDING_APPROVAL' then
--     return new;
--   end if;
--
-- with a header saying it exists for "the legitimate REJECTED -> PENDING_APPROVAL
-- transition providers need after correcting their application". 0019 restated
-- the function without it and every version since has omitted it, so a
-- rejected provider cannot resubmit: the call fails with
-- STATUS_CANNOT_BE_SELF_MODIFIED. The app still ships the call --
-- profile_repository.resubmitProvider(), whose comment asserts the guard
-- "explicitly allows this specific transition for non-admin users". That
-- comment describes intent the database no longer implements.
--
-- Restored here, and only that one transition. Self-approval and every other
-- status change stay refused.
--
-- 3. Verified admins could no longer move a wallet balance
-- ------------------------------------------------------
-- 20260927000019 re-enabled prevent_wallet_direct_balance_edit, which had been
-- inert since 0030 for the same current_user reason. But 00019 allowed only
-- is_server_write() past it, and two money RPCs are called straight from the
-- app with the admin's own JWT:
--
--   admin_cash_recharge_screen.dart:54   admin_cash_recharge
--   admin_cash_recharge_screen.dart:97   admin_wallet_adjustment
--
-- Both do UPDATE wallets SET balance = ..., so both have been failing with
-- BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION since 00019 deployed. This is
-- the same missing-admin-case mistake as the notification guard fixed in
-- 00025, one table over: a guard on a table the server also writes has to
-- tell three callers apart -- server, verified privileged client, everyone
-- else -- and 00019 answered only the first two for notifications and only
-- the first for wallets.
--
-- An ordinary user still cannot set a balance. The RPCs keep their own
-- admin_can checks, so this widens nothing that was not already an admin.

CREATE OR REPLACE FUNCTION public.prevent_profile_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF NOT public.is_admin() THEN
    IF new.status IS DISTINCT FROM old.status THEN
      RAISE EXCEPTION 'PROFILE_STATUS_CANNOT_BE_SELF_MODIFIED';
    END IF;
  END IF;

  RETURN new;
END;
$$;

COMMENT ON FUNCTION public.prevent_profile_self_privilege_escalation() IS
  'Stops a non-admin changing their own profiles.status. This guard was inert '
  'from 0034 until now: it exempted current_user inside a SECURITY DEFINER '
  'trigger, where current_user is the owner for every caller, so any user '
  'could PATCH their own profile to status=APPROVED.';

CREATE OR REPLACE FUNCTION public.prevent_wallet_direct_balance_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  -- A verified admin may credit and debit directly. admin_cash_recharge and
  -- admin_wallet_adjustment run as the admin's own JWT from the admin screen
  -- and both update wallets.balance.
  IF public.is_admin() THEN
    RETURN new;
  END IF;

  IF new.balance IS DISTINCT FROM old.balance THEN
    RAISE EXCEPTION 'BALANCE_MODIFICATION_REQUIRES_SECURE_FUNCTION';
  END IF;

  RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.prevent_provider_self_privilege_escalation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF public.is_server_write() THEN
    RETURN new;
  END IF;

  IF new.status IS DISTINCT FROM old.status THEN
    -- Resubmission after correcting a rejected application. Allowed since
    -- 0008 and dropped by 0019, which left profile_repository.resubmitProvider
    -- failing for every rejected provider. This one transition only:
    -- self-approval and every other change still raise below.
    IF NOT (old.status = 'REJECTED' AND new.status = 'PENDING_APPROVAL') THEN
      RAISE EXCEPTION 'STATUS_CANNOT_BE_SELF_MODIFIED';
    END IF;
  END IF;

  IF new.provider_type IS DISTINCT FROM old.provider_type THEN
    RAISE EXCEPTION 'PROVIDER_TYPE_CANNOT_BE_MODIFIED';
  END IF;

  -- Read through JSONB rather than naming the column. A GENERATED column
  -- cannot be written directly, so this only fires when registration_date
  -- changes; and if the column is absent in a given schema, a missing JSONB
  -- key is NULL instead of a runtime error, which is what 0033 was guarding
  -- against when it dropped the direct comparison.
  IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name  = 'provider_profiles'
          AND column_name = 'subscription_start_date'
     )
     AND (to_jsonb(new) ->> 'subscription_start_date')
         IS DISTINCT FROM (to_jsonb(old) ->> 'subscription_start_date') THEN
    RAISE EXCEPTION 'SUBSCRIPTION_DATES_ARE_SERVER_MANAGED';
  END IF;

  IF old.owner_national_id IS NOT NULL
     AND new.owner_national_id IS DISTINCT FROM old.owner_national_id THEN
    RAISE EXCEPTION 'NATIONAL_ID_CANNOT_BE_CHANGED';
  END IF;

  RETURN new;
END;
$$;

-- ---------------------------------------------------------------------------
-- Assertions
--
-- The inert-profile-guard bug is the reason this file needs more than prose.
-- Every assertion in this suite reads pg_proc.prosrc, and the inert guard had
-- all the right strings in it -- current_user, is_admin, the raise. A source
-- check cannot tell a guard that runs from a guard that returns immediately.
-- So these two are pinned structurally, and assert_profile_status_guard_raises
-- is behavioural: it drives a real UPDATE through the trigger and requires the
-- refusal, which no amount of correct-looking source can fake.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_client_guards_are_server_safe()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_flat text;
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'prevent_provider_self_privilege_escalation',
    'prevent_order_insert_privilege_escalation',
    'prevent_order_self_privilege_escalation',
    'prevent_notification_injection',
    'prevent_subscription_self_modification',
    'prevent_wallet_direct_balance_edit',
    'prevent_wallet_txn_mutation',
    'prevent_profile_self_privilege_escalation'
  ] LOOP
    SELECT regexp_replace(lower(p.prosrc), E'\\s+', ' ', 'g') INTO v_flat
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_name;

    IF v_flat IS NULL THEN
      RETURN false;
    END IF;

    -- Must route through the shared discriminator. A guard that still branches
    -- on current_user is inert inside a SECURITY DEFINER trigger, which is
    -- exactly how the profile guard stayed disabled for so long.
    IF position('is_server_write' in v_flat) = 0 THEN
      RETURN false;
    END IF;
    IF position('current_user' in v_flat) > 0 THEN
      RETURN false;
    END IF;

    -- ...and must still refuse a client.
    IF position('raise exception' in v_flat) = 0 THEN
      RETURN false;
    END IF;
  END LOOP;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_client_guards_are_server_safe() IS
  'True when all eight client-write guards exempt server writes via '
  'is_server_write(), branch on nothing that is inert inside a SECURITY '
  'DEFINER trigger, and still refuse client writes.';

GRANT EXECUTE ON FUNCTION public.assert_client_guards_are_server_safe() TO authenticated;

-- ---------------------------------------------------------------------------
-- The exploit itself, as a test.
--
-- assert_client_guards_are_server_safe can only read prosrc. The inert profile
-- guard had every right-looking string in it -- current_user, is_admin, the
-- raise -- and still approved any user who asked. No source check can tell a
-- guard that runs from a guard that returns on its first line.
--
-- So this performs the attack instead. It acts as a freshly signed-up
-- non-admin, exactly as an attacker would, and requires the database to
-- refuse the status change. Against the inert guard this returns false,
-- because the UPDATE succeeds. There is no way to pass it without the guard
-- actually firing.
--
-- It also checks the opposite direction: a non-status column must still be
-- writable, so the fix cannot be "block every update to profiles" -- which
-- would break CityService and the profile editor.
--
-- Rolls back via the usual sentinel; the fixture ids are fixed and inert.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_profile_self_approval_is_refused()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e601';
  v_status text;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'self-approval-probe@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;

  -- PENDING_APPROVAL, which is what the insert guard requires of a client.
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Self Approval Probe', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  -- Act as that user. Non-admin, which is the whole point.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

  IF public.is_admin() THEN
    RAISE EXCEPTION 'the probe user is unexpectedly an admin, so this test cannot prove anything';
  END IF;

  -- The attack: approve your own account.
  BEGIN
    UPDATE public.profiles SET status = 'APPROVED' WHERE id = v_user;

    SELECT status::text INTO v_status FROM public.profiles WHERE id = v_user;
    IF v_status = 'APPROVED' THEN
      RAISE EXCEPTION 'a non-admin was able to set their own profile status to APPROVED -- the guard did not fire';
    END IF;

    -- The UPDATE was rolled back by the subtransaction, which is itself a
    -- failure: it means the row changed before the guard stopped it.
    RAISE EXCEPTION 'a non-admin UPDATE of profiles.status was not refused';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a non-admin was able to set their own profile status to APPROVED -- the guard did not fire'
         OR SQLERRM = 'a non-admin UPDATE of profiles.status was not refused' THEN
        RAISE;
      END IF;
      -- Any other error is the refusal we wanted.
      NULL;
  END;

  -- The guard must not be a blanket block: a non-privileged column still has
  -- to be writable, or CityService and the profile editor break.
  BEGIN
    UPDATE public.profiles SET city = 'Addis Ababa' WHERE id = v_user;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'a non-admin could not update profiles.city: %', SQLERRM;
  END;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

COMMENT ON FUNCTION public.assert_profile_self_approval_is_refused() IS
  'Performs the self-approval attack as a non-admin and requires the database '
  'to refuse it, then requires an ordinary column still to be writable. '
  'Behavioural by necessity: the inert guard this replaces passed every '
  'source-text check in the suite.';

GRANT EXECUTE ON FUNCTION public.assert_profile_self_approval_is_refused() TO anon, authenticated;
