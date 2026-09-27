-- Read with_check too, because that is where an INSERT policy keeps its rule.
--
-- WHAT THE LAST REPORT GOT WRONG
-- -------------------------------
-- The policy detail printed 21 WIDE, and every single one of them was an
-- INSERT. That is the tell:
--
--   pg_policies has TWO expression columns. `qual` is the USING clause and
--   `with_check` is the WITH CHECK clause. An INSERT policy has no USING
--   clause at all -- the rule that decides whether the new row is allowed is
--   entirely in WITH CHECK -- so `qual` comes back empty for every one of
--   them.
--
-- The report read only `qual`, matched the empty string against the scoping
-- patterns, found no caller mentioned, and labelled all 21 WIDE. Policies
-- that are in fact tightly scoped were reported as wide open:
--
--   user_roles_admin_write  WITH CHECK (is_admin())
--   reviews_user_insert     WITH CHECK (user_id = auth.uid() AND exists
--                           (SELECT 1 FROM orders o WHERE ... o.user_id =
--                           auth.uid() AND o.status = 'COMPLETED'))
--
-- Both are correct. Both were about to be treated as findings.
--
-- This is the third bug in this diagnostic and all three are the same shape:
-- reading the catalog and assuming the value means what I expected. The
-- first resolved a quoted name that does not resolve, the second took
-- candidate tables from a catalog view that spans schemas, and this one read
-- the wrong column for the command being described. What the shape has in
-- common is that each was invisible to a passing build, and each was caught
-- only by looking at what the output actually SAID rather than whether it
-- ran. That is the only reason this one is found, and it is why the test
-- prints rather than only asserting.
--
-- THE FIX
-- -------
-- Both columns are returned, so the report shows the real text of a rule
-- instead of an empty string that reads as "no rule". The verdict uses
-- whichever expression the policy actually has:
--
--   USING     for SELECT / UPDATE / DELETE / ALL  (the row being acted on)
--   WITH CHECK for INSERT, and for UPDATE (the row being written)
--
-- Taking the first non-empty of the two is a simplification, and it errs
-- toward calling something scoped when only the other half of the rule is
-- wide. Both are now printed, so a reader can see which half was which, and
-- a policy that scopes USING but not WITH CHECK is visible as such rather
-- than hidden behind a single label.

-- DROP first, and this is not optional. 20260927000044 created this function
-- returning (table_name, cmd, policy_name, qual, verdict). This one returns
-- (table_name, cmd, policy_name, using_expr, check_expr, verdict), and
-- CREATE OR REPLACE REFUSES to change the return type of an existing function:
--
--   ERROR: cannot change return type of existing function (SQLSTATE 42P13)
--
-- Adding a column to a RETURNS TABLE result is a change of return type, not a
-- compatible replacement, so the replacement is rejected however similar it
-- looks. The name and the arguments are unchanged, so the Dart caller needs no
-- edit -- only the definition is rebuilt.
DROP FUNCTION IF EXISTS public.client_write_policy_detail();

CREATE OR REPLACE FUNCTION public.client_write_policy_detail()
RETURNS TABLE (
  table_name text,
  cmd text,
  policy_name text,
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
    SELECT t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
      AND has_table_privilege('authenticated', t.table_name, 'INSERT')
  ),
  writes AS (
    SELECT
      p.tablename,
      p.policyname,
      p.cmd,
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
      -- The rule that actually applies. INSERT is decided by WITH CHECK;
      -- SELECT, UPDATE, DELETE and ALL are decided by USING.
      CASE WHEN w.cmd = 'INSERT' THEN w.check_expr ELSE w.using_expr END AS effective,
      -- An UPDATE has two halves and only one of them is optional, so both must
      -- be present for it to count as scoped. The comparison is <> '' and not
      -- a bare AND: these are text columns, and `text AND text` is
      -- "argument of AND must be type boolean, not type text".
      CASE WHEN w.cmd = 'UPDATE'
           THEN (w.using_expr <> '' AND w.check_expr <> '')
           ELSE true END AS both_halves_scoped
    FROM writes w
  )
  SELECT
    j.tablename,
    j.cmd,
    j.policyname,
    NULLIF(j.using_expr, '') AS using_expr,
    NULLIF(j.check_expr, '') AS check_expr,
    CASE
      WHEN j.effective ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
       AND j.both_halves_scoped
        THEN 'scoped'
      ELSE 'WIDE'
    END
  FROM judged j
  ORDER BY
    (CASE
       WHEN j.effective ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
        AND j.both_halves_scoped
       THEN 1 ELSE 0
     END) ASC,
    j.tablename,
    j.cmd;
$$;

COMMENT ON FUNCTION public.client_write_policy_detail() IS
  'Diagnostic. For every write policy on a client-writable public table: the '
  'table, the command, the policy name, and BOTH pg_policies expression '
  'columns -- using_expr (USING) and check_expr (WITH CHECK) -- labelled '
  'scoped or WIDE. Both columns are returned because an INSERT policy has no '
  'USING clause: its entire rule is in WITH CHECK, and reading only qual '
  'reported 21 tightly scoped policies as wide open. An UPDATE is only scoped '
  'when both its halves are. WIDE means the applicable expression never '
  'mentions the caller, so nothing in it ties the write to a person. It is a '
  'sorting label, not a judgement.';

GRANT EXECUTE ON FUNCTION public.client_write_policy_detail()
  TO anon, authenticated;
