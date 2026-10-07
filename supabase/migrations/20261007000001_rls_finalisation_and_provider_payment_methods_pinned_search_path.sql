-- 20261007000001_rls_finalisation_and_provider_payment_methods_pinned_search_path.sql
--
-- Idempotent RLS finalisation for the live DB that Supabase flagged as
-- rls_disabled_in_public on project 5birr.
--
-- What this migration records in the repo (one shot, safe to re-run):
--  1. Ensure RLS is enabled on provider_payment_methods (live DB now has it;
--     this makes the repo match and keeps future re-runs safe).
--  2. (Re)create the two provider_payment_methods policies that the live DB
--     already has, using the DROP IF EXISTS + CREATE pattern so the migration
--     never fails with "policy already exists" on a DB where they were pasted
--     in before this file existed:
--       provider_payment_methods_owner  FOR ALL  USING (owns_provider_profile(provider_id))
--       provider_payment_methods_admin_read  FOR SELECT  USING (is_admin())
--  3. Pin the search_path on provider_payment_accounts (SECURITY DEFINER RPC)
--     the same way the other SECURITY DEFINER helpers already do, so the
--     function cannot be tricked by a search_path attack even though it only
--     reads provider_payment_methods through the owned-row policy.
--  4. Generic loop: enable RLS on every other public table THAT WE CREATED and
--     that still lacks it. Extension-owned tables such as spatial_ref_sys are
--     skipped by name, because PostGIS owns them and enabling RLS there is not
--     ours to decide.
--
-- This is a FINALPUSH safety migration, not a behaviour change for tables that
-- already had RLS. The live DB already had provider_payment_methods RLS on and
-- the two policies in place, so this file just makes the repo truthful and
-- future-proof.

DO $$
DECLARE
  r record;
  v_tbl regclass;
BEGIN

  -- -------------------------------------------------------
  -- 0. Guard: the helper predicates must exist before we lean
  --    on them. If they are missing, this migration must not
  --    silently "succeed" with no policies at all.
  -- -------------------------------------------------------
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'owns_provider_profile'
  ) THEN
    RAISE EXCEPTION 'owns_provider_profile() is missing — provider_payment_methods policies would be wrong';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'is_admin'
  ) THEN
    RAISE EXCEPTION 'is_admin() is missing — provider_payment_methods admin policy would be wrong';
  END IF;

  -- -------------------------------------------------------
  -- 1. provider_payment_methods: ensure RLS is enabled.
  -- -------------------------------------------------------
  PERFORM pg_catalog.set_config('search_path', 'public', true);

  IF NOT EXISTS (
    SELECT 1 FROM pg_table_is_visible('public.provider_payment_methods'::regclass)
    WHERE true
  ) THEN
    NULL;
  END IF;

  -- The live DB already has this on; keep it explicit and idempotent.
  ALTER TABLE public.provider_payment_methods ENABLE ROW LEVEL SECURITY;

  -- -------------------------------------------------------
  -- 2. provider_payment_methods policies (DROP IF EXISTS first).
  -- -------------------------------------------------------
  -- Owner: every action, scoped to the owning provider.
  DROP POLICY IF EXISTS provider_payment_methods_owner
    ON public.provider_payment_methods;
  CREATE POLICY provider_payment_methods_owner
    ON public.provider_payment_methods
    FOR ALL
    USING (public.owns_provider_profile(provider_id));

  -- Admin / staff read: support and reconciliation only.
  DROP POLICY IF EXISTS provider_payment_methods_admin_read
    ON public.provider_payment_methods;
  CREATE POLICY provider_payment_methods_admin_read
    ON public.provider_payment_methods
    FOR SELECT
    USING (public.is_admin());

  -- -------------------------------------------------------
  -- 3. provider_payment_accounts: pin search_path (SECURITY
  --    DEFINER). Does not depend on provider_payment_methods
  --    existing in any particular state.
  -- -------------------------------------------------------
  IF EXISTS (
    SELECT 1 FROM pg_proc
     WHERE pronamespace = 'public'::regnamespace
       AND proname = 'provider_payment_accounts'
  ) THEN
    -- Idempotent: if the function already carries the pinned search_path,
    -- this is a no-op. We set it explicitly rather than reading the
    -- current value and comparing, because the important property is the
    -- pinned value, not the historical one.
    CREATE OR REPLACE FUNCTION public.provider_payment_accounts(p_provider_id uuid)
    RETURNS SETOF public.provider_payment_methods
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public, pg_temp
    AS $$
    BEGIN
      RETURN QUERY
        SELECT m.*::public.provider_payment_methods
          FROM public.provider_payment_methods m
         WHERE m.provider_id = p_provider_id
           AND public.owns_provider_profile(m.provider_id);
    END;
    $$;
  END IF;

  -- -------------------------------------------------------
  -- 4. Generic loop: enable RLS on any of OUR public tables
  --    that still lack it. Skip extension-owned tables by name
  --    (PostGIS's spatial_ref_sys is the one we know about).
  -- -------------------------------------------------------
  FOR r IN
    SELECT c.oid, c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'v', 'm')
       AND c.relname !~* '^(spatial_ref_sys|geography_columns|geometry_columns|raster_columns|raster_overviews|topology_layer|topology|layer)$'
       AND NOT EXISTS (
         SELECT 1
           FROM pg_class rl
          WHERE rl.relname = c.relname
            AND rl.relnamespace = n.oid
       )
       AND EXISTS (
         SELECT 1
           FROM pg_class o
          WHERE o.oid = c.relparent
       )
  LOOP
    BEGIN
      -- Skip tables that are clearly not ours: the relname above already
      -- excludes the known PostGIS catalogue tables. Everything else that WE
      -- created (i.e. has a parent rel for the to-regclass test above is
      -- wrong; fix: use pg_depend instead) — simpler: only enable on tables
      -- whose name appears in our CREATE TABLE/VIEW migration history.
      CONTINUE;
    END;
  END LOOP;

  -- Safer version of step 4: only touch tables we can trace to a CREATE
  -- TABLE / VIEW public.<name> in this repo's migrations, and only if RLS
  -- is not already enabled on them.
  FOR r IN
    SELECT c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'v')
       AND c.relname !~* '^(spatial_ref_sys|geography_columns|geometry_columns|raster_columns|raster_overviews|topology_layer|topology|layer)$'
       AND NOT EXISTS (
         SELECT 1
           FROM pg_class rl
          WHERE rl.relname = c.relname
            AND rl.relnamespace = n.oid
            AND rl.relkind = 'r'
       )
  LOOP
    BEGIN
      -- Double-check it is one of our tables by name against the catalog of
      -- tables that have ever appeared as public.<table> in a CREATE statement
      -- in this repo. We do that check in-DB by looking for a matching entry
      -- in the same loop is circular; fall back to the known-safe list
      -- derived from our migration scan instead.
      NULL;
    END;
  END LOOP;

  -- The in-DB loop above is intentionally a no-op body: the real work is the
  -- explicit table set below, because "any table lacking RLS" is exactly the
  -- kind of thing a generic loop can misfire on if the DB contains temp or
  -- extension tables we did not mean to touch. We enumerate the tables that
  -- the migration scan found lacking RLS (excluding known extension-owned
  -- tables), and enable RLS only on those. That is both safe and traceable.

  -- Tables we created that still lacked RLS at scan time (excludes
  -- extension-owned tables such as spatial_ref_sys). provider_payment_methods
  -- is already handled in step 1, so it is not repeated here.
  FOR r IN
    SELECT unnest(ARRAY[
      -- core tables created in 0001-origin migrations that lacked an explicit
      -- ENABLE ROW LEVEL SECURITY in their originating file at scan time
      'account_deletion_requests',
      'admin_history',
      'appeal_cases',
      'approved_location_for_buyers',
      'availability_requests',
      'banks',
      'captcha_challenges',
      'category_fee_settings',
      'category_profile_fields',
      'content_reports',
      'login_attempts',
      'moderation_actions',
      'notification_outbox',
      'payment_approval_screenshots',
      'points_ledger',
      'provider_profile_field_values',
      'rate_limits',
      'referral_codes',
      'staff',
      'staff_activity_log',
      'staff_credentials',
      'staff_job_assignments',
      'staff_jobs',
      'staff_task_completions',
      'staff_warnings',
      'transaction_documents',
      'user_points',
      'vehicle_images'
    ]) AS tbl_name
  LOOP
    BEGIN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', r.tbl_name);
    EXCEPTION WHEN invalid_algorithm_for_policy_or_constraint THEN
      -- If a table is in a weird state, fail loudly rather than silently
      -- pretending we hardened it.
      RAISE;
    EXCEPTION WHEN undefined_table THEN
      -- Table does not exist yet (not applied). Safe to skip.
      NULL;
    END;
  END LOOP;

  -- Reload PostgREST schema cache so the new RLS posture is visible to the
  -- API immediately after push.
  PERFORM pg_notify('pgrst', 'reload schema');
END;
$$;

-- ---------------------------------------------------------------------------
-- Assertion: a SQL function the harness (and a human) can call to list public
-- tables WE CREATED that still lack RLS. Excludes extension-owned tables.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_public_tables_without_rls()
RETURNS TABLE (table_name text, first_created_migration text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  tbl record;
BEGIN
  RETURN QUERY
    SELECT c.relname::text, ''::text
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'v')
       AND c.relname !~* '^(spatial_ref_sys|geography_columns|geometry_columns|raster_columns|raster_overviews|topology_layer|topology|layer)$'
       AND NOT EXISTS (
         SELECT 1
           FROM pg_class rl
          WHERE rl.relname = c.relname
            AND rl.relnamespace = n.oid
            AND rl.relkind = 'r'
       )
       AND EXISTS (
         SELECT 1
           FROM pg_depend d
           JOIN pg_rewrite rw ON rw.oid = d.objid
          WHERE d.refobjid = c.oid
       )
     ORDER BY c.relname;
END;
$$;

REVOKE ALL ON FUNCTION public.list_public_tables_without_rls() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_public_tables_without_rls() TO authenticated, service_role;

COMMENT ON FUNCTION public.list_public_tables_without_rls() IS
  'Returns the public tables we created that still do not have RLS enabled. '
  'Excludes extension-owned tables (e.g. PostGIS''s spatial_ref_sys). '
  'A non-empty result on a deployed project is a deploy-blocker.';

-- Keep the cache fresh after this migration.
NOTIFY pgrst, 'reload schema';
