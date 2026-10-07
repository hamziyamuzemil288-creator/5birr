-- =============================================================================
-- 20261007000012 — Revoke write privileges on banks from authenticated
--
-- ROOT CAUSE: The banks table has GRANT ALL ON public.banks TO service_role.
-- In Supabase, the 'authenticated' role is a member of 'service_role', so it
-- inherits the GRANT ALL privileges — including INSERT, UPDATE, DELETE.
--
-- The connectivity test reports 'banks' as an unexpected writable table because
-- has_table_privilege('authenticated', 'banks', 'INSERT') returns TRUE.
--
-- The policy banks_admin_all is FOR ALL TO authenticated USING (is_admin()),
-- which is correct: only admins should write to banks. But the GRANT ALL from
-- service_role bypasses the policy check.
--
-- FIX: Revoke INSERT, UPDATE, DELETE, TRUNCATE from authenticated, leaving only
-- SELECT (which is already granted). This ensures only admins can write to banks.
-- =============================================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON public.banks FROM authenticated;

-- PostgREST caches table privileges for its schema cache; without this a
-- revoked grant can still be served from the cache.
NOTIFY pgrst, 'reload schema';

-- Assertion: banks should not be writable by authenticated
CREATE OR REPLACE FUNCTION public.assert_banks_not_writable_by_authenticated()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF has_table_privilege('authenticated', 'public.banks', 'INSERT')
     OR has_table_privilege('authenticated', 'public.banks', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.banks', 'DELETE')
     OR has_table_privilege('authenticated', 'public.banks', 'TRUNCATE') THEN
    RAISE WARNING 'BANKS_STILL_WRITABLE: authenticated has write privileges on banks';
    RETURN false;
  END IF;
  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_banks_not_writable_by_authenticated() IS
  'Asserts that authenticated role cannot write to banks table. Fails if INSERT, UPDATE, DELETE or TRUNCATE privileges are still granted.';

grant execute on function public.assert_banks_not_writable_by_authenticated() to anon, authenticated;
