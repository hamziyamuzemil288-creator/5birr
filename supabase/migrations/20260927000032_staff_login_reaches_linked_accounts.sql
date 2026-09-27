-- A linked staff member could never log in — the gateway had no username to
-- find.
--
-- THE REPORTED BUG
-- ---------------
-- "After I create the staff in the admin interface and try to login with the
-- credentials created there, the login interface does not accept the
-- credentials — it says invalid login or username."
--
-- WHAT WAS ACTUALLY BROKEN
-- ------------------------
-- staff-login looks the typed identifier up in `staff_credentials` and signs
-- in against the auth address stored on that row. Two paths produce a staff
-- row WITHOUT a staff_credentials row, so the lookup returns nothing and every
-- attempt is refused with the same opaque 401:
--
--   1. link_staff_user() attached an existing auth.users row to a staff row
--      and stopped there. The admin screen's success message for it reads
--      "$email can now sign in as staff" — a promise the code could not keep.
--   2. create_staff (the non-CEO create path) inserts a staff row and no login
--      at all, which is correct — only the CEO may mint gateway credentials —
--      but the screen gave the operator no way to know that.
--
-- The second half of the lockout lived in staff-login itself, which rebuilt the
-- auth address from the username instead of reading the one on the auth row.
-- That made any linked account unreachable even once a username existed,
-- because the person's real auth email is not a @staff-gateway.invalid
-- synthetic address. staff-login now reads auth.users; see that file.
--
-- THIS MIGRATION
-- --------------
--   * Backfills a gateway username for every staff row that has an auth user
--     and no credential row yet, so staff linked BEFORE this fix can log in
--     with the email they already sign in with — no re-key, no password reset.
--   * link_staff_user() now maintains that row, so the gap cannot reopen.
--   * Adds staff_gateway_username(), the one place the answer is computed.
--   * Asserts all three.

-- ===========================================================================
-- 1. The one place a linked staff member's gateway username is computed
-- ===========================================================================
-- The auth email, lowercased, or NULL when there is nothing address-shaped to
-- use. NULL is meaningful: it makes the caller skip the row instead of writing
-- a username nobody could ever type.
--
-- Note this deliberately does NOT exclude the synthetic @staff-gateway.invalid
-- addresses. It does not need to: every gateway-created account already has a
-- staff_credentials row written by create_staff_gateway, and both the backfill
-- and link_staff_user only fill a MISSING row. Excluding them would add a rule
-- with no caller and a second place for the two paths to disagree.
CREATE OR REPLACE FUNCTION public.staff_gateway_username(p_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_email IS NULL THEN NULL
    WHEN lower(btrim(p_email)) ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]{2,}$'
      THEN lower(btrim(p_email))
    ELSE NULL
  END;
$$;

-- ===========================================================================
-- 2. Backfill: every linked staff member gets a username
-- ===========================================================================
-- auth.users is read as the migration owner, which is the only role that can:
-- this runs on a migration connection with no JWT, so RLS is not involved and
-- there is no caller to grant anything to.
--
-- ON CONFLICT DO NOTHING because the unique index is on lower(username): two
-- staff rows linked to the same address (which link_staff_user forbids, but a
-- pre-existing row could predate that check) must not abort the migration and
-- leave the rest un-backfilled.
INSERT INTO public.staff_credentials (staff_id, user_id, username)
SELECT s.id,
       s.user_id,
       public.staff_gateway_username(u.email)
FROM public.staff s
JOIN auth.users u ON u.id = s.user_id
WHERE s.user_id IS NOT NULL
  AND public.staff_gateway_username(u.email) IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.staff_credentials c WHERE c.staff_id = s.id
  )
ON CONFLICT DO NOTHING;

-- ===========================================================================
-- 3. link_staff_user() maintains the credential row
-- ===========================================================================
-- Restated with the same signature, guards and returns; the only addition is
-- the credential row, so the operator's promise becomes true. Copied from
-- 20260922000012 rather than retyped.
CREATE OR REPLACE FUNCTION public.link_staff_user(
  p_staff_id uuid,
  p_email text
)
RETURNS public.staff
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
  v_user_id uuid;
  v_email text;
  v_username text;
  v_existing_user_id uuid;
BEGIN
  IF NOT public.can_manage_staff(p_staff_id, auth.uid()) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION_TO_MANAGE_STAFF';
  END IF;

  SELECT id INTO v_user_id FROM auth.users
  WHERE lower(email) = lower(trim(p_email))
  LIMIT 1;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'NO_USER_WITH_THAT_EMAIL';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.staff WHERE user_id = v_user_id AND id <> p_staff_id
  ) THEN
    RAISE EXCEPTION 'USER_ALREADY_LINKED_TO_STAFF';
  END IF;

  SELECT email INTO v_email FROM auth.users WHERE id = v_user_id;
  v_username := public.staff_gateway_username(v_email);

  -- A username already held by a DIFFERENT account is a real conflict and must
  -- be refused, not silently skipped: the admin screen promises this address
  -- can sign in, and an ON CONFLICT DO NOTHING here would leave that promise
  -- false with no error anywhere.
  IF v_username IS NOT NULL THEN
    SELECT user_id INTO v_existing_user_id
    FROM public.staff_credentials
    WHERE lower(username) = v_username;
    IF v_existing_user_id IS NOT NULL AND v_existing_user_id <> v_user_id THEN
      RAISE EXCEPTION 'STAFF_USERNAME_TAKEN';
    END IF;
  END IF;

  UPDATE public.staff SET user_id = v_user_id, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  -- The fix: without this the linked person has a staff row, an auth account
  -- and no username, so staff-login's lookup misses and the account is
  -- unreachable for good.
  IF v_username IS NOT NULL THEN
    INSERT INTO public.staff_credentials (staff_id, user_id, username)
    VALUES (v_staff.id, v_user_id, v_username)
    ON CONFLICT (staff_id) DO UPDATE
      SET username = EXCLUDED.username, updated_at = now();
  END IF;

  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_user_id, 'ADMIN')
  ON CONFLICT (user_id, role) DO NOTHING;

  PERFORM public.log_admin_action(auth.uid(), 'STAFF_USER_LINKED', v_staff.id, 'staff', NULL,
    '{}', jsonb_build_object('linked_user', v_user_id));

  RETURN v_staff;
END;
$$;

GRANT EXECUTE ON FUNCTION public.link_staff_user(uuid, text) TO authenticated;

-- ===========================================================================
-- 4. Assertion
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_staff_link_gets_a_login()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_flat text;
  v_missing bigint;
  v_helper text;
BEGIN
  -- (1) No staff row with an auth user may be left without a username. This is
  --     the backfill's own contract, checked against live data rather than
  --     against the INSERT text: a re-run of link_staff_user, a staff UPDATE,
  --     or a restored dump could reopen the gap and every assertion that only
  --     reads pg_proc would stay green.
  SELECT count(*) INTO v_missing
  FROM public.staff s
  JOIN auth.users u ON u.id = s.user_id
  WHERE public.staff_gateway_username(u.email) IS NOT NULL
    AND NOT EXISTS (
      SELECT 1 FROM public.staff_credentials c WHERE c.staff_id = s.id
    );
  IF v_missing > 0 THEN
    RETURN false;
  END IF;

  -- (2) link_staff_user must write the row. Checked on the INSERT, not on a
  --     comment: the function previously did the linking and stopped, which is
  --     the whole bug.
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
  INTO v_flat
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'link_staff_user'
    AND p.pronargs = 2;
  IF v_flat IS NULL THEN
    RETURN false;
  END IF;
  IF position('insert into public.staff_credentials' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  -- A collision must be refused rather than swallowed, or the admin screen
  -- goes on promising a login that silently does not exist.
  IF position('staff_username_taken' in v_flat) = 0 THEN
    RETURN false;
  END IF;
  -- current_user is the function owner inside SECURITY DEFINER, so a guard
  -- written on it is inert (0029/0030/0033/0034 shipped that bug four times).
  IF position('current_user' in v_flat) > 0 THEN
    RETURN false;
  END IF;

  -- (3) The username must come from the auth address, not a re-derivation.
  SELECT regexp_replace(lower(p.prosrc), '\s+', ' ', 'g')
  INTO v_helper
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'staff_gateway_username'
    AND p.pronargs = 1;
  IF v_helper IS NULL THEN
    RETURN false;
  END IF;

  RETURN position('lower(btrim(p_email))' in v_helper) > 0;
END;
$$;

COMMENT ON FUNCTION public.assert_staff_link_gets_a_login() IS
  'True when every staff row with an auth user has a gateway username, '
  'link_staff_user() creates it and refuses collisions, and the username is '
  'the real auth address rather than a re-derived synthetic one.';

GRANT EXECUTE ON FUNCTION public.assert_staff_link_gets_a_login()
  TO anon, authenticated;
