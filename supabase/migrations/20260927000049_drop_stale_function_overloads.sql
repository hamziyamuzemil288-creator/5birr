-- A replaced signature that was never dropped is a function no caller can reach.
--
-- WHAT THE ASSERTION FOUND
-- ------------------------
-- 20260927000047's assertion drives update_staff(p_staff_id := ..., p_permissions
-- := ...) as a verified admin. That call came back:
--
--   function public.update_staff(p_staff_id => uuid, p_permissions => text[])
--   is not unique (SQLSTATE 42725)
--   Could not choose a best candidate function.
--
-- Which means the database has more than one update_staff. It does, and this
-- is not a mistake in the assertion: 20260922000001 created
--
--   update_staff(uuid, text, text[], numeric, boolean)
--
-- and a later migration replaced it with a wider signature WITHOUT dropping the
-- old one. 20260923000001 did drop the six-argument version explicitly --
-- `DROP FUNCTION IF EXISTS public.update_staff(uuid, text, text[], numeric,
-- boolean, uuid[])` -- and missed only the five-argument one, so the stale
-- function is still there, still executable, and still a candidate.
--
-- WHY IT MATTERS, GIVEN THE APP STILL WORKS
-- -----------------------------------------
-- PostgREST resolves a call by matching the argument NAMES the caller sent
-- against every candidate that accepts them. A call whose names fit exactly one
-- overload is fine, which is why nothing is visibly broken: every caller in the
-- app happens to send a distinctive name.
--
--   update_staff          the editor sends p_assigned_categories, which the
--                         five-argument version does not have
--   create_staff          all seven names
--   search_products       p_city, which the twelve-argument version lacks
--   create_order_secure   all nine (the order-create Edge Function)
--   match_chunks          kinds, which the three-argument version lacks
--
-- So each of these works by ACCIDENT OF WHICH NAMES THE CALLER HAPPENS TO SEND,
-- and stops working the moment anyone calls it with a smaller subset. That is
-- exactly what the new assertion did: it asked for two arguments, both
-- overloads accepted them, and PostgREST refused to guess. A "Set active"
-- toggle posting {p_staff_id, p_is_active} would have failed the same way, in
-- production, with an error nobody could read.
--
-- THE FIX: THE OLDER SIGNATURE GOES
-- ---------------------------------
-- A replacement means the old one is unreachable by design -- the newer
-- definition is a strict superset, so every call that the old one could serve
-- the new one still serves, with the extra parameters defaulted. Keeping it
-- buys nothing and costs a class of runtime failure.
--
-- The drop is discovered rather than listed. Writing out
--
--   DROP FUNCTION IF EXISTS public.update_staff(uuid, text, text[], numeric, boolean);
--
-- would fix today's instance of the bug and leave the next one to be found by
-- a user, because the failure is created by the RELATIONSHIP between two
-- functions, not by either one. So the migration looks for that relationship:
--
--   two functions in public with the same name, where one's parameter names
--   are a strict subset of the other's AND every shared name has the same
--   type in both
--
-- The type check is what keeps this safe. Without it, f(a text) and
-- f(a int, b int) look like a replacement and are not. With it, the rule
-- describes exactly what happened here and nothing else.
--
-- Extension-owned functions are excluded. `create extension postgis` puts its
-- functions in public with real parameter names, and st_estimatedextent has
-- three overloads whose names nest -- dropping those would break geography for
-- the entire app. pg_depend is what distinguishes a function we wrote from one
-- an extension owns.
--
-- WHAT THIS DOES NOT DO
-- ---------------------
-- It does not touch overloads that are genuinely different functions (different
-- names, or same names with different types). Those are legitimate, and the
-- assertion added below is written to leave them alone.
--
-- FINDING 2: THE ASSERTION'S POLICY HALF WAS TOO STRICT
-- -----------------------------------------------------
-- assert_client_write_surface_is_closed() reported false after 47 and 48, with
-- WIDE count 0. The reason is the other half of it: it demanded that no write
-- policy on user_roles, email_otp_codes or order_items apply to a client role
-- at all. But user_roles still has user_roles_admin_write, WITH CHECK
-- (is_admin()), which is TO public and always was -- and is CORRECT. The
-- escalation 20260927000046 closed was never that policy; it was
-- `Service role can insert roles`, WITH CHECK (true), sitting beside it and
-- ORing past it.
--
-- The invariant is not "no client-reachable policy". It is "no client-reachable
-- policy whose rule does not mention the caller" -- the same test the report
-- makes, which is why the report said WIDE count 0 and this said false: two
-- halves of one assertion disagreeing about what they were checking. A grant
-- with an admin-scoped policy is closed; a WITH CHECK (true) that reappears is
-- exploit-able the moment someone re-grants, and that is what has to fail.

-- ===========================================================================
-- 1. The relationship, as a query
-- ===========================================================================
-- Both the repair and the assertion read this, so the thing that drops the
-- stale overload and the thing that fails when one reappears cannot drift.
CREATE OR REPLACE FUNCTION public.stale_function_overloads()
RETURNS TABLE (
  fn text,
  stale_args text,
  kept_args text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH ours AS (
    SELECT p.oid, p.proname, p.proargnames, p.proargtypes
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proargnames IS NOT NULL
      -- Extension members and extension dependencies. PostGIS defines real
      -- parameter names in public and its overloads nest, so this is not
      -- hypothetical tidiness.
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid AND d.deptype IN ('e', 'x')
      )
  )
  SELECT
    f.proname,
    pg_get_function_identity_arguments(f.oid),
    pg_get_function_identity_arguments(g.oid)
  FROM ours f
  JOIN ours g
    ON g.proname = f.proname
   AND coalesce(array_length(g.proargnames, 1), 0) > coalesce(array_length(f.proargnames, 1), 0)
   -- Every name the smaller one takes, the larger one takes too...
   AND f.proargnames <@ g.proargnames
   -- ...with the same type. Without this, f(a text) looks like a replacement
   -- for f(a int, b int), and it is not.
   AND NOT EXISTS (
     SELECT 1
     FROM generate_subscripts(f.proargnames, 1) AS i
     WHERE format_type(f.proargtypes[i - 1], NULL)
           IS DISTINCT FROM
           format_type(g.proargtypes[array_position(g.proargnames, f.proargnames[i]) - 1], NULL)
   );
$$;

COMMENT ON FUNCTION public.stale_function_overloads() IS
  'Pairs of public functions with the same name where one''s parameter names '
  'are a strict subset of the other''s with matching types: a signature that '
  'was replaced without dropping the old function. Every call whose argument '
  'names fit both fails with 42725 "is not unique", and whether a given caller '
  'is affected depends only on which optional parameters it happens to send. '
  'Excludes extension-owned functions, whose nesting overloads are legitimate.';

-- ===========================================================================
-- 2. Drop them
-- ===========================================================================
-- NOTICE per drop, so the deploy log says exactly what changed. A silent
-- cleanup of function signatures is not something to discover later.
DO $$
DECLARE
  s record;
  v_dropped int := 0;
BEGIN
  FOR s IN SELECT * FROM public.stale_function_overloads() LOOP
    -- No '%' followed by anything but a known specifier in these strings:
    -- RAISE and format() both read '%' plus the next character as a conversion
    -- and raise 'unrecognized conversion type' on one they do not know, so a
    -- parenthesised argument list has to be spelled out rather than written
    -- with a bare % around it.
    RAISE NOTICE 'dropping stale overload of %s: %s -- superseded by %s',
      s.fn, s.stale_args, s.kept_args;
    EXECUTE format('DROP FUNCTION public.%I(%s)', s.fn, s.stale_args);
    v_dropped := v_dropped + 1;
  END LOOP;
  RAISE NOTICE 'stale overloads dropped: %', v_dropped;
END $$;

-- PostgREST caches the function signatures it will resolve against. Without
-- this the caller keeps getting 42725 from the cache after the fix.
NOTIFY pgrst, 'reload schema';

-- ===========================================================================
-- 3. The fence
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_no_stale_function_overloads()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_offenders text;
BEGIN
  SELECT string_agg(format('%s: %s superseded by %s', s.fn, s.stale_args, s.kept_args), ' | ' ORDER BY s.fn)
    INTO v_offenders
    FROM public.stale_function_overloads() s;

  IF v_offenders IS NOT NULL THEN
    RAISE WARNING 'STALE FUNCTION OVERLOADS: %', v_offenders;
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_no_stale_function_overloads() IS
  'Fails while any public function has a superseded overload beside it -- same '
  'name, parameter names a strict subset with matching types. Such a pair makes '
  'every call whose argument names fit both fail with 42725 "is not unique", '
  'and which callers are affected depends only on which optional parameters '
  'they send, so it is not visible to a reviewer or to a compiler.';
GRANT EXECUTE ON FUNCTION public.assert_no_stale_function_overloads()
  TO anon, authenticated;

-- ===========================================================================
-- 4. The write-surface assertion, checking what it meant to check
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.assert_client_write_surface_is_closed()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_tables constant text[] := ARRAY['user_roles', 'email_otp_codes', 'order_items'];
  v_privs  constant text[] := ARRAY['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'];
  v_table  text;
  v_priv   text;
  v_policy text;
  v_wide   text;
  v_problems text[] := ARRAY[]::text[];
BEGIN
  FOREACH v_table IN ARRAY v_tables LOOP
    FOREACH v_priv IN ARRAY v_privs LOOP
      -- Unqualified table name on purpose. has_table_privilege looks in
      -- pg_catalog first, and a format('public.%I', ...) name does not resolve
      -- there -- the mistake that made the first write-surface report print
      -- `relation "public.objects" does not exist` while staying green.
      IF has_table_privilege('anon', v_table, v_priv)
         OR has_table_privilege('authenticated', v_table, v_priv) THEN
        v_problems := v_problems || format(
          '%s: %s is still granted to a client role', v_table, v_priv);
      END IF;
    END LOOP;

    -- A policy the caller can reach is only a finding when its rule never
    -- mentions anyone. user_roles_admin_write -- TO public, WITH CHECK
    -- (is_admin()) -- is correct and must not fail this; a WITH CHECK (true)
    -- beside it is the escalation 46 closed and must. Both expression columns
    -- are read, because an INSERT policy keeps its whole rule in WITH CHECK.
    FOR v_policy IN
      SELECT format('%s (%s)', p.policyname, p.cmd)
      FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = v_table
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        AND p.roles::text[] && ARRAY['public', 'anon', 'authenticated']
        AND lower(coalesce(p.qual, '') || ' ' || coalesce(p.with_check, ''))
              !~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
    LOOP
      v_problems := v_problems || format(
        '%s: policy %s applies to a client role and never names a caller', v_table, v_policy);
    END LOOP;
  END LOOP;

  SELECT string_agg(format('%s (%s)', d.table_name, d.cmd), ', ' ORDER BY d.table_name)
    INTO v_wide
    FROM public.client_write_policy_detail() d
   WHERE d.verdict = 'WIDE';

  IF v_wide IS NOT NULL THEN
    v_problems := v_problems || format('client-reachable WIDE write policies: %s', v_wide);
  END IF;

  IF array_length(v_problems, 1) > 0 THEN
    RAISE WARNING 'CLIENT_WRITE_SURFACE_IS_OPEN: %', array_to_string(v_problems, ' | ');
    RETURN false;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_client_write_surface_is_closed() IS
  'Fails while a client role holds INSERT/UPDATE/DELETE/TRUNCATE on '
  'user_roles, email_otp_codes or order_items, while a client-reachable write '
  'policy on those three never names a caller (a WITH CHECK (true) beside an '
  'admin-scoped policy is what makes a re-grant exploitable), or while any '
  'client-reachable write policy in the schema is WIDE. An admin-scoped policy '
  'that a client can technically reach is not a finding and is not reported as '
  'one -- the grant is what closes the table.';
