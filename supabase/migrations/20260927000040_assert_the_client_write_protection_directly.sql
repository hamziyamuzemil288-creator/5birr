-- The warnings assertion, proven without SET ROLE.
--
-- 20260927000039 tried to make the direct INSERT fail by assuming the
-- authenticated role first:
--
--   PERFORM set_config('role', 'authenticated', true);
--   ERROR: cannot set parameter "role" within security-definer function
--
-- That restriction is absolute and deliberate. A SECURITY DEFINER function
-- runs with its owner's privileges precisely so that it cannot be
-- downgraded; letting it drop to a lesser role mid-body would hand every
-- definer function a way to act with less authority than it was granted. So
-- no amount of restructuring gets a client role inside one of these.
--
-- WHICH MEANS THE ASSERTION WAS NEVER GOING TO WORK AS WRITTEN
-- -----------------------------------------------------------
-- The direct INSERT in a definer function always runs as the owner. The
-- owner's privileges are not the client's, so that write can never be the
-- thing a client does, no matter what the outcome says. Asserting on it
-- proves nothing either way -- and an assertion that cannot fail is worse
-- than none, because it reports the protection is intact.
--
-- So the protection is asserted where it actually lives. There are exactly
-- two ways a client could write to staff_warnings, and both are now checked:
--
--   1. A table privilege. The table grants SELECT to authenticated and
--      nothing else, so INSERT is denied before RLS is even consulted.
--   2. An RLS policy permitting a write. There is a SELECT policy and no
--      INSERT, UPDATE or DELETE policy.
--
-- has_table_privilege() is used rather than reading information_schema,
-- because it resolves privilege INHERITANCE: a grant to any role
-- authenticated is a member of grants the privilege too, and a catalog scan
-- of role_table_grants would miss that and report the table as safe when it
-- is not. The same reasoning applies to the policy check, which is why both
-- halves are required -- a policy alone cannot grant access without the
-- table privilege, and the privilege alone is enough to deny it. This
-- mirrors the pg_policies check already used by
-- assert_orders_not_client_insertable() in 20260927000014.
--
-- The RPC door is still asserted behaviourally, by calling it: that half was
-- always correct and does not need a role change to be meaningful.


CREATE OR REPLACE FUNCTION public.assert_staff_warnings_are_admin_only()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e601';
  v_staff uuid;
  v_priv text;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'staff-warning-probe@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Warning Probe', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.staff (user_id, name, staff_code, permissions)
  VALUES (v_user, 'Warning Probe', 'WARN-PROBE-1', '{}')
  RETURNING id INTO v_staff;
  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'could not create the probe staff row';
  END IF;

  -- (1) The table itself must not be writable by a client. Checked through
  --     has_table_privilege so an inherited grant counts against us.
  --
  --     Unqualified on purpose. has_table_privilege is a builtin, and
  --     pg_catalog is searched before public unless the search_path names it
  --     later -- so 'public.has_table_privilege(...)' would be "function does
  --     not exist" and the migration would not apply. pg_policies and
  --     pg_policies' schemaname/tablename columns are likewise unqualified.
  FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
    IF has_table_privilege('authenticated', 'public.staff_warnings', v_priv) THEN
      RAISE EXCEPTION
        'authenticated holds % on public.staff_warnings, so a staff member can write a warning row directly',
        v_priv;
    END IF;
  END LOOP;

  -- Same for anon, which is a weaker client but still a client.
  FOREACH v_priv IN ARRAY ARRAY['INSERT', 'UPDATE', 'DELETE'] LOOP
    IF has_table_privilege('anon', 'public.staff_warnings', v_priv) THEN
      RAISE EXCEPTION 'anon holds % on public.staff_warnings', v_priv;
    END IF;
  END LOOP;

  -- (2) And no policy may permit a write. A FOR ALL policy counts: it covers
  --     INSERT, so its absence here is what makes the SELECT policy harmless.
  IF EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'staff_warnings'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  ) THEN
    RAISE EXCEPTION
      'a write policy exists on staff_warnings, so the missing table privilege is not the whole story';
  END IF;

  -- (3) The read policy must still be there, or the above would pass on a
  --     table nobody can read either. Asserted so this test cannot be made
  --     green by deleting the feature.
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'staff_warnings'
      AND cmd = 'SELECT'
  ) THEN
    RAISE EXCEPTION
      'staff_warnings has no SELECT policy, so nobody can see their own warnings';
  END IF;

  -- (4) The RPC door, asserted behaviourally. warn_staff() is what the UI
  --     actually calls, and it re-checks the caller server-side; this half
  --     needs no role change to be a real test.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  IF public.is_ceo() OR public.is_super_admin() THEN
    RAISE EXCEPTION 'the probe user is unexpectedly a manager, so this test cannot prove anything';
  END IF;

  BEGIN
    PERFORM public.warn_staff(v_staff, 'self warning via rpc');
    RAISE EXCEPTION 'warn_staff() accepted a non-manager';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'warn_staff() accepted a non-manager' THEN
        RAISE;
      END IF;
      NULL;
  END;

  -- Nothing may have been written by the attempt above either.
  IF EXISTS (SELECT 1 FROM public.staff_warnings WHERE staff_id = v_staff) THEN
    RAISE EXCEPTION 'warn_staff() wrote a warning row for a non-manager';
  END IF;

  -- Acknowledging a warning that does not exist must fail: the column is
  -- evidence that the person SAW it, and a manager clicking it would make it
  -- worthless.
  BEGIN
    PERFORM public.acknowledge_staff_warning(
      uuid_generate_v4(), 'not mine');
    RAISE EXCEPTION 'acknowledging a warning that does not exist was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'acknowledging a warning that does not exist was accepted' THEN
        RAISE;
      END IF;
      NULL;
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

COMMENT ON FUNCTION public.assert_staff_warnings_are_admin_only() IS
  'Requires staff_warnings to be unwritable by authenticated and anon (checked '
  'with has_table_privilege, so inherited grants count), to have no write '
  'policy and to still have its SELECT policy, and requires warn_staff() to '
  'refuse a non-manager, write no row, and acknowledge_staff_warning() to '
  'refuse a warning that does not exist. A direct INSERT cannot be used here: '
  'PostgreSQL forbids SET ROLE inside a SECURITY DEFINER function, so such a '
  'write would run as the owner and prove nothing.';

GRANT EXECUTE ON FUNCTION public.assert_staff_warnings_are_admin_only()
  TO anon, authenticated;
