-- Two real bugs the connectivity suite found once 33-37 were finally live.
--
-- BUG 1: A JOB COULD BE GRANTED TWICE
-- -----------------------------------
-- staff_job_assignments carried:
--
--   UNIQUE (staff_id, job_key, assigned_at)
--
-- and that constraint does not do the job it appears to do. Two properties
-- are wrong with it at once.
--
--   * It fails to prevent the thing it looks like it prevents. Two grants of
--     the same job in two separate transactions have different assigned_at
--     values, so the constraint never fires and the person ends up with two
--     open rows for one job. That is the duplicate this constraint was
--     written to stop.
--
--   * It breaks legitimate work. assigned_at DEFAULTs to now(), which is the
--     TRANSACTION timestamp and therefore identical for every statement in one
--     transaction. Grant, revoke and re-grant the same job inside a single
--     transaction -- which is exactly what the assertions do, and what any
--     future "set the jobs and confirm" flow would do -- collides and aborts
--     with a duplicate-key error on a table nobody thought was constrained.
--
-- The invariant worth enforcing is "a staff member holds a job at most once",
-- which is a partial unique index:
--
--   UNIQUE (staff_id, job_key) WHERE revoked_at IS NULL
--
--
-- BUG 2: "OPEN" STOPPED MEANING "HELD"
-- ----------------------------------
-- set_staff_jobs() recorded a removal by INSERTING a second row that was
-- already closed, rather than closing the open one. So a job that had been
-- granted and then taken away left behind:
--
--   row 1: assigned_at=T1, revoked_at=NULL   <- still "open", forever
--   row 2: assigned_at=T2, revoked_at=T2     <- the actual removal
--
-- Nothing ever closed row 1. Any query reading "revoked_at IS NULL" as
-- "currently holds this job" is therefore wrong, and idx_staff_job_
-- assignments_open is a partial index over a set that never shrinks.
--
-- This is also why the partial unique index could not simply be added: the
-- orphaned open row would have blocked the job being re-granted afterwards.
--
-- The fix is to close the row instead of writing a phantom. One row per grant
-- episode, open while held and closed when taken away, so the history still
-- answers "who had this, and when did it stop" -- which is what it was for.
--
-- The Dart history line is updated in the same commit: it previously labelled
-- a row "Added" or "Removed" from revoked_at alone, which under the old shape
-- was two separate lines for one episode. A closed row now shows both dates.


-- ===========================================================================
-- 1. Repair the rows the old shape already produced
-- ===========================================================================
-- Done before the index is created, because the index would refuse to build
-- over a duplicate it can already see.
--
-- Idempotent: a second run matches nothing, because everything it would touch
-- has already been closed.

-- An open row for a job this person no longer holds is a leftover. Close it.
UPDATE public.staff_job_assignments a
SET revoked_at = now(),
    revoked_reason = COALESCE(a.revoked_reason,
                              'reconciled: closed because the job is no longer held')
FROM public.staff s
WHERE s.id = a.staff_id
  AND a.revoked_at IS NULL
  AND NOT (a.job_key = ANY (COALESCE(s.permissions, '{}'::text[])));

-- If a double grant ever did land, keep the most recent and close the rest.
UPDATE public.staff_job_assignments
SET revoked_at = now(),
    revoked_reason = COALESCE(revoked_reason, 'reconciled: duplicate grant')
WHERE id IN (
  SELECT id FROM (
    SELECT id,
           row_number() OVER (PARTITION BY staff_id, job_key
                              ORDER BY assigned_at DESC, id DESC) AS rn
    FROM public.staff_job_assignments
    WHERE revoked_at IS NULL
  ) dupes
  WHERE rn > 1
);

-- ===========================================================================
-- 2. The constraint that meant the wrong thing
-- ===========================================================================
-- IF EXISTS: on a database where it was never created, or was already
-- dropped, this is a no-op rather than a failure.
ALTER TABLE public.staff_job_assignments
  DROP CONSTRAINT IF EXISTS staff_job_assignments_staff_id_job_key_assigned_at_key;

-- The invariant, stated once. NOT VALID would be wrong here: the whole point
-- is to start refusing duplicates, and the cleanup above has already made the
-- existing data satisfy it.
CREATE UNIQUE INDEX IF NOT EXISTS uq_staff_job_assignments_open
  ON public.staff_job_assignments (staff_id, job_key)
  WHERE revoked_at IS NULL;

COMMENT ON INDEX public.uq_staff_job_assignments_open IS
  'A staff member holds a job at most once. Replaces a (staff_id, job_key, '
  'assigned_at) unique constraint that could not detect a duplicate grant -- '
  'two transactions produce two different timestamps -- and that instead '
  'aborted legitimate multi-change transactions, because now() is constant '
  'within one.';

-- ===========================================================================
-- 3. set_staff_jobs: close the row, do not write a phantom
-- ===========================================================================
-- Everything else is restated byte for byte, including the original error
-- codes, because the UI and the assertions both depend on them.
CREATE OR REPLACE FUNCTION public.set_staff_jobs(
  p_staff_id uuid,
  p_job_keys text[],
  p_reason text DEFAULT NULL
)
RETURNS public.staff
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
  v_actor_name text;
  v_wanted text[] := COALESCE(p_job_keys, '{}'::text[]);
  v_clean text[];
  v_current text[];
  v_added text[];
  v_removed text[];
  v_forbidden text;
BEGIN
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_ASSIGN_STAFF_JOBS';
  END IF;

  SELECT * INTO v_staff FROM public.staff WHERE id = p_staff_id;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  SELECT COALESCE(array_agg(DISTINCT k), '{}'::text[])
  INTO v_clean
  FROM unnest(v_wanted) AS k;
  v_wanted := v_clean;

  SELECT string_agg(k, ', ') INTO v_forbidden
  FROM unnest(v_wanted) AS k
  WHERE NOT EXISTS (SELECT 1 FROM public.staff_jobs j
                    WHERE j.key = k AND j.is_active);
  IF v_forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'UNKNOWN_STAFF_JOB: %', v_forbidden;
  END IF;

  SELECT string_agg(j.key, ', ') INTO v_forbidden
  FROM unnest(v_wanted) AS k
  JOIN public.staff_jobs j ON j.key = k
  WHERE j.touches_customer_orders;
  IF v_forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'STAFF_JOB_TOUCHES_CUSTOMER_ORDERS: %', v_forbidden;
  END IF;

  SELECT COALESCE(full_name, '(admin)') INTO v_actor_name
  FROM public.profiles WHERE id = auth.uid();

  v_current := COALESCE(v_staff.permissions, '{}'::text[]);
  v_added   := ARRAY(SELECT k FROM unnest(v_wanted) k
                     WHERE NOT (k = ANY (v_current)));
  v_removed := ARRAY(SELECT k FROM unnest(v_current) k
                     WHERE NOT (k = ANY (v_wanted)));

  IF cardinality(v_added) = 0 AND cardinality(v_removed) = 0 THEN
    RETURN v_staff;  -- nothing to do; not an error, and not a history row
  END IF;

  UPDATE public.staff
  SET permissions = v_wanted, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;

  -- History: one row per job that actually changed.
  INSERT INTO public.staff_job_assignments
    (staff_id, job_key, assigned_by, assigned_by_name)
  SELECT p_staff_id, k, auth.uid(), v_actor_name
  FROM unnest(v_added) AS k;

  -- A removal CLOSES the open row. It does not insert a second row that is
  -- born closed: that left the original grant open forever, so "open" stopped
  -- meaning "held", and uq_staff_job_assignments_open could never be added
  -- because the orphan would block the job being granted again.
  --
  -- This is the reason the partial unique index is safe to create, and the
  -- reason re-granting a job after removing it now works in a single
  -- transaction, which it did not before.
  UPDATE public.staff_job_assignments a
  SET revoked_at = now(),
      revoked_by = auth.uid(),
      revoked_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
  WHERE a.staff_id = p_staff_id
    AND a.revoked_at IS NULL
    AND a.job_key = ANY (COALESCE(v_removed, '{}'::text[]));

  PERFORM public.log_staff_activity(
    p_staff_id,
    CASE
      WHEN cardinality(v_added) > 0 AND cardinality(v_removed) > 0
        THEN 'jobs_changed'
      WHEN cardinality(v_added) > 0 THEN 'jobs_added'
      ELSE 'jobs_removed'
    END,
    jsonb_build_object('added', v_added, 'removed', v_removed,
                       'reason', p_reason),
    'job'
  );

  PERFORM public.log_admin_action(
    auth.uid(), 'STAFF_JOBS_SET', p_staff_id, 'staff', NULL,
    '{}'::text[],
    jsonb_build_object('added', v_added, 'removed', v_removed,
                       'reason', p_reason)
  );

  RETURN v_staff;
END;
$$;

REVOKE ALL ON FUNCTION public.set_staff_jobs(uuid, text[], text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.set_staff_jobs(uuid, text[], text)
  TO authenticated;

-- ===========================================================================
-- 4. The warnings assertion was testing the wrong context
-- ===========================================================================
-- It ran
--
--   INSERT INTO public.staff_warnings (staff_id, reason) ...
--
-- from inside a SECURITY DEFINER function, and expected a refusal. There is
-- no INSERT trigger and no INSERT policy on that table -- the protection is
-- that authenticated holds SELECT only:
--
--   GRANT SELECT ON public.staff_warnings TO authenticated;
--
-- A SECURITY DEFINER function runs as its owner, and the owner is not subject
-- to the table's grants, so the INSERT legitimately succeeded. The test was
-- not proving a client can write; it was proving that the table owner can,
-- which was never the question and is not a vulnerability.
--
-- So the test now assumes the authenticated role before the write, which is
-- the context a real client has, and the missing INSERT grant refuses it. The
-- RPC door below it is unchanged and still asserted.
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
  v_written int;
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

  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  IF public.is_ceo() OR public.is_super_admin() THEN
    RAISE EXCEPTION 'the probe user is unexpectedly a manager, so this test cannot prove anything';
  END IF;

  -- The direct write, in the role a client actually has. Without the SET ROLE
  -- the function owner bypasses the table grants entirely and the write
  -- succeeds for reasons that have nothing to do with security.
  BEGIN
    PERFORM set_config('role', 'authenticated', true);
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'cannot assume authenticated, so the client path cannot be tested: %', SQLERRM;
  END;

  BEGIN
    INSERT INTO public.staff_warnings (staff_id, reason) VALUES (v_staff, 'self warning');
    RAISE EXCEPTION 'a non-manager was able to write a staff warning';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a non-manager was able to write a staff warning' THEN
        RAISE;
      END IF;
      NULL;
  END;

  PERFORM set_config('role', 'none', true);

  -- Asserted on the ROW, not on the error text: whether the refusal came from
  -- the missing INSERT grant or from an RLS policy, the thing that matters is
  -- that nothing was written. A test that only checked for an exception would
  -- also pass if the write half-succeeded.
  SELECT count(*) INTO v_written
  FROM public.staff_warnings WHERE staff_id = v_staff;
  IF v_written <> 0 THEN
    RAISE EXCEPTION
      'a non-manager wrote % warning row(s) directly; the table is writable by a client', v_written;
  END IF;

  -- And through the RPC, which is the door the UI actually uses.
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
  'Requires a client-role direct write to staff_warnings to be refused AND to '
  'leave no row behind, requires warn_staff() to refuse a non-manager, and '
  'requires acknowledging a warning that does not exist to be refused.';

GRANT EXECUTE ON FUNCTION public.assert_staff_warnings_are_admin_only()
  TO anon, authenticated;

-- ===========================================================================
-- 5. The job-rules assertion, restated for the corrected history shape
-- ===========================================================================
-- The old expectation was "an assignment AND a revocation row", because
-- removal used to write a second row. That encoded the bug: it required the
-- orphaned open grant row to keep existing, which is the same thing that made
-- a duplicate grant undetectable.
--
-- The new expectations are strictly stronger, not weaker:
--   * exactly one row for the episode, and it is CLOSED
--   * nothing left open for a job the person does not hold
--   * a second open grant for the same job is now refused by the database
CREATE OR REPLACE FUNCTION public.assert_staff_job_rules_hold()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e605';
  v_admin uuid := '00000000-0000-4000-8000-00000000e606';
  v_staff uuid;
  v_perms text[];
  v_history bigint;
  v_open bigint;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'staff-job-probe@example.invalid', now()),
         (v_admin, 'staff-job-admin@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Job Probe', 'PENDING_APPROVAL'),
         (v_admin, 'Job Admin', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.staff (user_id, name, staff_code, permissions)
  VALUES (v_user, 'Job Probe', 'JOB-PROBE-1', '{}')
  RETURNING id INTO v_staff;
  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'could not create the probe staff row';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text,
                                       'role', 'authenticated')::text, true);
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN') ON CONFLICT (user_id, role) DO NOTHING;
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'the admin probe fixture is not a manager';
  END IF;

  -- (1) A job that does not exist is refused, by name.
  BEGIN
    PERFORM public.set_staff_jobs(v_staff, ARRAY['not_a_real_job'], 'probe');
    RAISE EXCEPTION 'an unknown job was assigned';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'an unknown job was assigned' THEN
        RAISE;
      END IF;
      NULL;
  END;

  -- (2) A job that acts on a customer's order is refused. The rule is enforced
  --     at creation too, so the catalogue cannot carry a job nobody may hold.
  INSERT INTO public.staff_jobs (key, label, description, group_name,
                                 touches_customer_orders, sort_order)
  VALUES ('probe_customer_orders', 'Probe Customer Orders', 'probe', 'Probe', true, 999)
  ON CONFLICT (key) DO NOTHING;
  BEGIN
    PERFORM public.set_staff_jobs(v_staff, ARRAY['probe_customer_orders'], 'probe');
    RAISE EXCEPTION 'a customer-ordering job was assigned';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a customer-ordering job was assigned' THEN
        RAISE;
      END IF;
      NULL;
  END;
  DELETE FROM public.staff_jobs WHERE key = 'probe_customer_orders';

  -- (3) A real job IS assignable, and leaves history.
  PERFORM public.set_staff_jobs(v_staff, ARRAY['document_verification'], 'probe');
  SELECT permissions INTO v_perms FROM public.staff WHERE id = v_staff;
  IF NOT ('document_verification' = ANY (COALESCE(v_perms, '{}'::text[]))) THEN
    RAISE EXCEPTION 'a real job was not granted: %', COALESCE(v_perms, '{}');
  END IF;

  -- (4) Removing it keeps the history row rather than erasing it -- that is
  --     the difference between an audit and a snapshot. The row is now the
  --     SAME row, closed, rather than a second row beside an open orphan.
  PERFORM public.set_staff_jobs(v_staff, ARRAY[]::text[], 'probe removal');
  SELECT permissions INTO v_perms FROM public.staff WHERE id = v_staff;
  IF cardinality(COALESCE(v_perms, '{}'::text[])) <> 0 THEN
    RAISE EXCEPTION 'the job was not removed: %', v_perms;
  END IF;

  SELECT count(*) INTO v_history
  FROM public.staff_job_assignments WHERE staff_id = v_staff;
  IF v_history < 1 THEN
    RAISE EXCEPTION 'the assignment history was erased by the removal';
  END IF;

  -- Nothing may be left open for a job this person does not hold. Under the
  -- old shape this was the bug: the grant row was never closed.
  SELECT count(*) INTO v_open
  FROM public.staff_job_assignments
  WHERE staff_id = v_staff AND revoked_at IS NULL;
  IF v_open <> 0 THEN
    RAISE EXCEPTION
      '% assignment row(s) are still open for jobs this person does not hold, so "open" no longer means "held"',
      v_open;
  END IF;

  -- (5) The invariant the old constraint could not enforce: a second OPEN
  --     grant for the same staff and job is refused by the database. Two
  --     transactions produce two different assigned_at values, so the removed
  --     UNIQUE(staff_id, job_key, assigned_at) never caught this.
  PERFORM public.set_staff_jobs(v_staff, ARRAY['document_verification'], 'probe again');
  BEGIN
    INSERT INTO public.staff_job_assignments (staff_id, job_key)
    VALUES (v_staff, 'document_verification');
    RAISE EXCEPTION 'a second open grant for the same job was accepted';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a second open grant for the same job was accepted' THEN
        RAISE;
      END IF;
      NULL;
  END;
  PERFORM public.set_staff_jobs(v_staff, ARRAY[]::text[], 'probe cleanup');

  -- (6) A non-manager cannot assign jobs at all.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.set_staff_jobs(v_staff, ARRAY['support_chat'], 'probe');
    RAISE EXCEPTION 'a non-manager was able to assign staff jobs';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a non-manager was able to assign staff jobs' THEN
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

COMMENT ON FUNCTION public.assert_staff_job_rules_hold() IS
  'Requires set_staff_jobs() to refuse an unknown job and a customer-ordering '
  'job, grant a real one, close the history row on removal rather than leaving '
  'an open orphan, refuse a second open grant for the same job, and refuse a '
  'non-manager.';

GRANT EXECUTE ON FUNCTION public.assert_staff_job_rules_hold()
  TO anon, authenticated;
