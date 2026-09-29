-- 20260927000083_staff_jobs_rls.sql
--
-- Close an inconsistent exposure on the staff-job catalogue.
--
-- WHAT WAS WRONG
-- --------------
-- `staff_jobs` is the catalogue of assignable jobs (payment_verification,
-- registrations, sales_transactions, …). It was created by migration 34 with
-- NO `ENABLE ROW LEVEL SECURITY` and no policies, so it sat on the table with
-- the default Supabase grants: any holder of the anon key could read it
-- through PostgREST, while the function that was written to expose it
-- deliberately is the opposite:
--
--     REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon;
--     GRANT EXECUTE ... TO authenticated;
--
-- So the catalogue was published to the public through the table and
-- withheld from the public through the RPC. The RPC exists for a reason —
-- it is a SECURITY DEFINER reader the product chose — and the table defeats
-- it. This is the same shape as the migration-40 finding recorded in the
-- deploy workflow next to user-admin: an endpoint the client calls that
-- nothing ever deploys.
--
-- The client's own reader is a plain authenticated SELECT
-- (`StaffGatewayService.jobCatalogue`, used by the CEO's staff editor), so
-- the fix keeps that working rather than forcing every caller through an
-- RPC.
--
-- WHAT THIS DOES NOT CHANGE
-- -------------------------
--  * Every write already goes through `set_staff_jobs()` / `create_staff_job()`,
--    both SECURITY DEFINER, and the table owner bypasses RLS — so the seed,
--    the catalogue validator trigger and the CEO's edits are unaffected.
--  * `assert_staff_jobs_are_creatable()` is SECURITY DEFINER and reads the
--    table as the owner, so the connectivity suite keeps working when it
--    calls it as anon.
--  * No existing policy, function or row is modified. This is additive and
--    idempotent.

-- ===========================================================================
-- 1. RLS
-- ===========================================================================
ALTER TABLE public.staff_jobs ENABLE ROW LEVEL SECURITY;

-- Read-only for a signed-in account: the catalogue is a list of job names,
-- and the CEO's editor is the only thing that needs it. No INSERT/UPDATE/
-- DELETE policy is added, so a client cannot add or rename a job even if the
-- row-level grant were ever widened.
DROP POLICY IF EXISTS staff_jobs_authenticated_read ON public.staff_jobs;
CREATE POLICY staff_jobs_authenticated_read ON public.staff_jobs
  FOR SELECT
  TO authenticated
  USING (true);

-- Defence in depth: RLS already denies anon every row, but the table grant
-- itself is what PostgREST advertises, and an explicit REVOSE means an anon
-- key gets a permission error rather than an empty set.
REVOKE ALL ON public.staff_jobs FROM anon;

-- ===========================================================================
-- 2. The client read must still work, and anon must really be shut out
-- ===========================================================================
-- The policy above is the fix; this is the proof, because "RLS is enabled" is
-- not the same claim as "anon cannot read it" and only one of them has ever
-- been false here in a way nobody noticed.
CREATE OR REPLACE FUNCTION public.assert_staff_jobs_are_session_only()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  v_rls boolean;
  v_read_policies int;
BEGIN
  SELECT c.relrowsecurity INTO v_rls
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'staff_jobs';

  IF NOT coalesce(v_rls, false) THEN
    RAISE EXCEPTION
      'STAFF_JOBS_EXPOSED: public.staff_jobs has RLS disabled, so the anon key can read the whole job catalogue directly — which is exactly what list_staff_jobs() is revoked from anon to prevent';
  END IF;

  SELECT count(*) INTO v_read_policies
    FROM pg_policies
   WHERE schemaname = 'public'
     AND tablename = 'staff_jobs'
     AND cmd = 'SELECT';

  IF v_read_policies = 0 THEN
    RAISE EXCEPTION
      'STAFF_JOBS_UNREADABLE: RLS is on but no SELECT policy exists, so the CEO''s staff editor cannot load the job catalogue and every staff member sees an empty checklist';
  END IF;

  -- RLS with a USING(true) SELECT policy still lets anon through if anon
  -- holds the table privilege and the policy has no role restriction, so the
  -- grant is checked directly rather than inferred from the policy.
  IF has_table_privilege('anon', 'public.staff_jobs', 'SELECT') THEN
    RAISE EXCEPTION
      'STAFF_JOBS_EXPOSED: anon still holds SELECT on public.staff_jobs';
  END IF;

  RETURN 'staff_jobs OK: RLS enabled, ' || v_read_policies
         || ' read policy/policies, anon holds no SELECT';
END;
$$;

COMMENT ON FUNCTION public.assert_staff_jobs_are_session_only() IS
  'True when the staff-job catalogue is readable by a signed-in account and '
  'not by the anon key — the table and list_staff_jobs() must agree.';

GRANT EXECUTE ON FUNCTION public.assert_staff_jobs_are_session_only()
  TO anon, authenticated;

notify pgrst, 'reload schema';
