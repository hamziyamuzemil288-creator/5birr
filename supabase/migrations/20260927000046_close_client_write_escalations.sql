-- Close the client-write escalations, and stop the report crying wolf.
--
-- WHAT THE CORRECTED REPORT SAID
-- ------------------------------
-- 20260927000045 fixed the diagnostic so an INSERT policy is judged on its
-- WITH CHECK clause instead of an empty USING one. The first clean run after
-- that returned four WIDE rows and two of them are real:
--
--   user_roles       · INSERT · Service role can insert roles   CHECK: true
--   email_otp_codes  · INSERT · email_otp_anon_insert           CHECK: true
--
-- The other two are artifacts of the verdict rule itself, which is also fixed
-- at the bottom of this file.
--
-- 1. user_roles — ANY SIGNED-IN USER CAN MAKE THEMSELVES AN ADMIN
-- ---------------------------------------------------------------
-- `Service role can insert roles` was created in 0021 with no TO clause, so it
-- belongs to PUBLIC: it applies to `anon` and `authenticated` exactly as much
-- as it applies to `service_role`. Its rule is WITH CHECK (true). RLS policies
-- OR together, so it does not merely sit beside `user_roles_admin_write`
-- (WITH CHECK (is_admin())) -- it defeats it. Every caller passes.
--
-- The two other layers that should have caught this do not:
--
--   * `authenticated` holds INSERT on user_roles. Supabase's default
--     privileges grant ALL on new public tables; 20260927000041 discovered
--     exactly this on the staff tables. That this table is in the report's
--     candidate list at all is the proof: the list is built from
--     has_table_privilege('authenticated', tablename, 'INSERT').
--
--   * `prevent_role_escalation` does not enforce anything for a client.
--     20260925120000 guards it with `IF current_user = 'authenticated'`, and
--     the trigger function is SECURITY DEFINER, so `current_user` is its
--     OWNER (postgres) on every call. It reads as a role check and is inert.
--     0022's version (`IF NOT is_admin()`) would have refused the client --
--     which is why it was loosened for the signup chain -- and the signup
--     chain is the reason the guard cannot simply be restored: handle_new_user
--     assigns roles while the request is still `anon`.
--
-- So the exploit is one HTTP request with the anon key that ships inside the
-- app bundle: POST /rest/v1/user_roles {"user_id":"<own uid>","role":"ADMIN"}.
-- is_admin() is has_role('ADMIN') against auth.uid(), so the row takes effect
-- immediately and the caller holds every admin policy in the schema: wallets,
-- user_documents, staff, subscriptions, system_settings, products, vehicles,
-- ride_requests, profiles. The account is not an admin of a feature; it is an
-- admin of the database.
--
-- 2. email_otp_codes — THE SIGNUP GATE CAN BE SATISFIED WITHOUT ANY EMAIL
-- ----------------------------------------------------------------------
-- `email_otp_anon_insert` is `TO anon, authenticated WITH CHECK (true)`. The
-- comment that introduced it says anonymous callers must be able to request
-- and verify a signup code, and that is true -- but they do not need a table
-- grant to do either. Both RPCs are SECURITY DEFINER:
--
--   request_email_otp -> EXECUTE is granted to service_role only, and it is
--                        reached through the send-otp Edge Function.
--   verify_email_otp  -> EXECUTE is granted to anon, authenticated, and it
--                        hashes what the caller typed and compares.
--
-- Because the client can write the table directly, it can skip the mailbox
-- entirely: insert (email, sha256_hex('123456')) for your own address, call
-- verify_email_otp('you@example.com','123456'), and the gate passes. Codes are
-- hashed and the select policy is USING (false), so nothing is readable --
-- that is not the defense. Verification is meant to prove control of the
-- mailbox, and a client that can seed its own row never had to prove it.
--
-- 3. order_items — a write path the app does not have
-- ---------------------------------------------------
-- `order_items_user_insert` (WITH CHECK: an order I own) dates from 0002.
-- Nothing in the app writes order_items: orders and their lines are built
-- server-side by create_order_secure(). test/client_write_surface_test.dart
-- scans lib/ and would fail if a `.from('order_items')` write appeared, and it
-- passes, so the path is dead -- while still letting a customer append line
-- items to their own paid order. Same repair: drop it and revoke.
--
-- WHY REVOKING IS THE FIX, AND NOT RESTORING THE TRIGGER
-- -----------------------------------------------------
-- A trigger is enforced only along the paths that go through the table, and
-- the signup chain legitimately needs one of those paths to stay open for a
-- caller who is not an admin. A grant is enforced before RLS and before any
-- trigger, and says the thing that is actually true: this table is written by
-- SECURITY DEFINER functions and by service_role, never by a client. All three
-- writers of these tables (handle_new_user, the role-assignment triggers,
-- request_email_otp, verify_email_otp, create_order_secure) are SECURITY
-- DEFINER, so they run as the owner and keep working.
--
-- The consequence to notice: once these grants are gone the tables leave
-- client_write_surface_report()'s candidate list entirely, because that list
-- is has_table_privilege('authenticated', ..., 'INSERT'). Their absence from
-- the next report is the evidence this migration worked.
--
-- This is the same repair 20260927000041 applied to the five staff tables, for
-- the same reason. The rest of the non-allowlist tables are behind RLS with an
-- admin or owner policy and are not a measured escalation; widening the
-- revocation to all of them is a separate decision, not a silent one.
--
-- WHAT IS *NOT* FIXED HERE
-- ------------------------
-- `prevent_role_escalation` is left as it is, inert, because the correction
-- that would matter -- refusing writes that carry a client JWT -- breaks the
-- anon signup chain that writes the first role row. It is now redundant rather
-- than load-bearing: the grant is what stops the client. If a client-writable
-- path to user_roles is ever reintroduced, that trigger must be replaced
-- first, and the assertion at the bottom of this file will fail until
-- whichever one happened is undone.

-- ============================================================
-- 1. user_roles: stop clients writing roles
-- ============================================================

DROP POLICY IF EXISTS "Service role can insert roles" ON public.user_roles;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.user_roles FROM anon, authenticated;

-- ============================================================
-- 2. email_otp_codes: the RPCs write it, the clients do not
-- ============================================================

DROP POLICY IF EXISTS email_otp_anon_insert ON public.email_otp_codes;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.email_otp_codes FROM anon, authenticated;

-- ============================================================
-- 3. order_items: the dead client write path
-- ============================================================

DROP POLICY IF EXISTS order_items_user_insert ON public.order_items;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.order_items FROM anon, authenticated;

-- ============================================================
-- 4. Two artifacts in the report's own verdict rule
-- ============================================================
--
-- Both are false findings produced by the judge, not by the schema, and both
-- would have been "fixed" by loosening something that is correct.
--
-- (a) A missing WITH CHECK is not a wide rule. Postgres uses the USING
--     expression as the check for the rows an UPDATE writes when WITH CHECK is
--     omitted. 20260927000045 required both halves to be non-empty, so
--     `Users can update own profile`, USING (auth.uid() = id), was reported
--     WIDE. The write half of that policy IS the caller.
--     Ditto user_roles_admin_update, USING (is_admin()).
--
-- (b) A policy is only interesting if a client can reach it. The candidate
--     tables are chosen by the grant, but a policy may be scoped `TO
--     service_role`, which bypasses RLS anyway. Without the roles, the
--     WITH CHECK (true) that WAS the hole and a WITH CHECK (true) on a
--     service_role row read identically: `CHECK: true`. Printing `roles`
--     separates them, and a policy no client role holds is labelled
--     client-unreachable rather than scoped, so neither word claims anything
--     untrue.
--
-- An INSERT policy is still judged on WITH CHECK alone. It has no USING
-- clause, and that is the whole reason this function was rewritten once
-- already.
DROP FUNCTION IF EXISTS public.client_write_policy_detail();

CREATE OR REPLACE FUNCTION public.client_write_policy_detail()
RETURNS TABLE (
  table_name text,
  cmd text,
  policy_name text,
  roles text,
  using_expr text,
  check_expr text,
  verdict text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH public_tables AS (
    -- Base tables in public that a client can INSERT into at all. `anon` is
    -- checked as well as `authenticated`: a table an unauthenticated caller
    -- can write is not less of a finding than one a signed-in caller can.
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND (has_table_privilege('authenticated', t.table_name, 'INSERT')
           OR has_table_privilege('anon', t.table_name, 'INSERT'))
  ),
  writes AS (
    SELECT
      p.tablename,
      p.policyname,
      p.cmd,
      p.roles::text[] AS roles,
      lower(regexp_replace(replace(coalesce(p.qual, ''), 'public.', ''), '\s+', '', 'g'))      AS using_expr,
      lower(regexp_replace(replace(coalesce(p.with_check, ''), 'public.', ''), '\s+', '', 'g')) AS check_expr
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      AND p.tablename IN (SELECT table_name FROM public_tables)
  ),
  judged AS (
    SELECT
      w.*,
      -- The rule that decides the row being read or matched.
      CASE WHEN w.cmd = 'INSERT' THEN w.check_expr ELSE w.using_expr END AS effective,
      -- The rule that decides the row being WRITTEN, and for an UPDATE that is
      -- WITH CHECK -- which Postgres takes from USING when the policy omits it.
      CASE WHEN w.cmd = 'INSERT' THEN w.check_expr
           ELSE coalesce(nullif(w.check_expr, ''), w.using_expr) END AS effective_check,
      (w.roles && ARRAY['public', 'anon', 'authenticated']) AS client_reachable
    FROM writes w
  )
  SELECT
    j.tablename,
    j.cmd,
    j.policyname,
    array_to_string(j.roles, ','),
    NULLIF(j.using_expr, ''),
    NULLIF(j.check_expr, ''),
    CASE
      WHEN NOT j.client_reachable THEN 'client-unreachable'
      WHEN j.effective ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
       AND j.effective_check ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
        THEN 'scoped'
      ELSE 'WIDE'
    END
  FROM judged j
  ORDER BY
    (CASE
       WHEN j.client_reachable
        AND NOT (j.effective ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
                 AND j.effective_check ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)')
       THEN 0 ELSE 1 END) ASC,
    j.tablename,
    j.cmd;
$$;

COMMENT ON FUNCTION public.client_write_policy_detail() IS
  'Diagnostic. For every write policy on a client-writable public table: the '
  'table, the command, the policy name, the roles it applies to, and BOTH '
  'pg_policies expression columns -- using_expr (USING) and check_expr (WITH '
  'CHECK) -- labelled scoped, WIDE, or client-unreachable. An INSERT policy is '
  'judged on WITH CHECK alone: it has no USING clause, and reading only qual '
  'reported 21 tightly scoped policies as wide open. A missing WITH CHECK is '
  'judged as USING, which is what Postgres does for a written row. WIDE means '
  'the applicable expression never mentions the caller, so nothing in it ties '
  'the write to a person. It is a sorting label, not a judgement.';

GRANT EXECUTE ON FUNCTION public.client_write_policy_detail()
  TO anon, authenticated;

-- ============================================================
-- 5. The fence
-- ============================================================
--
-- One assertion, of two halves, and it is deliberately a catalog check rather
-- than a behavioural one -- the one place in this suite where that is the
-- right instrument instead of a shortcut. Everywhere else the recurring
-- failure has been a guard that mentions its condition and never evaluates it,
-- which only a behavioural test can see. Here the question is a CAPABILITY:
-- either `authenticated` holds INSERT on user_roles or it does not. There is no
-- body to be inert.
--
-- Both halves are required, because either alone is insufficient: a grant with
-- no policy still fails in RLS, and a permissive WITH CHECK (true) policy on a
-- table with no grant is unreachable. Removing one of them while the other says
-- "clients may write here" is not a partial fix, it is a different bug.
--
-- The second half is the report above, promoted to a contract now that the
-- four rows it printed have been read and triaged: two were fixed here and two
-- were artifacts of the judge. Until this migration the report was print-only
-- on purpose, because failing the build on a count nobody had read would turn
-- the pipeline red for a reason nobody could act on. That reason is gone, so a
-- WIDE row that is client-reachable is now a failure.
CREATE OR REPLACE FUNCTION public.assert_client_write_surface_is_closed()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  -- Every table here was measured live, not guessed from the migration files.
  -- user_roles and email_otp_codes are the two escalations; order_items is the
  -- dead path that only creates risk.
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

    FOR v_policy IN
      SELECT format('%s (%s)', p.policyname, p.cmd)
      FROM pg_policies p
      WHERE p.schemaname = 'public'
        AND p.tablename = v_table
        AND p.cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
        -- A policy with no TO clause lists as {public}. Roles are name[], so
        -- the array is cast to text[] before the overlap test rather than
        -- relying on an operator that may not exist for name[] && text[].
        AND p.roles::text[] && ARRAY['public', 'anon', 'authenticated']
    LOOP
      v_problems := v_problems || format(
        '%s: policy %s still applies to a client role', v_table, v_policy);
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
  'user_roles, email_otp_codes or order_items, while a write policy on those '
  'three still applies to public/anon/authenticated, or while any '
  'client-reachable write policy has an expression that never mentions the '
  'caller. This is a capability check rather than a behavioural one because a '
  'capability is a catalog fact -- there is no function body to be inert. The '
  'WIDE half reuses client_write_policy_detail(), so the report and the '
  'contract can never disagree.';

GRANT EXECUTE ON FUNCTION public.assert_client_write_surface_is_closed()
  TO anon, authenticated;
