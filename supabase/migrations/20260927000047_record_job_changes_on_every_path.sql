-- The admin screen's job edits were never recorded, and one verdict rule lied.
--
-- FINDING 1: TWO WRITE PATHS FOR ONE COLUMN, AND ONLY ONE KEPT THE HISTORY
-- -----------------------------------------------------------------------
-- staff.permissions is the list of jobs a staff member holds. It is written by
-- two paths:
--
--   * set_staff_jobs(p_staff_id, p_job_keys, p_reason) -- validates each key
--     against the catalogue, refuses a job that touches a customer order, and
--     records the change: an OPEN row per grant in staff_job_assignments, the
--     open row CLOSED on removal, a staff_activity_log entry, and a
--     log_admin_action entry. 20260927000034/39 built it and asserted it.
--
--   * update_staff(..., p_permissions, ...) -- the call the CEO's staff editor
--     actually makes, and create_staff() when the account is first created.
--     Both write `permissions = COALESCE(p_permissions, permissions)` and
--     nothing else.
--
-- So the console granted and revoked jobs through update_staff, and the only
-- call that writes history had no caller anywhere in lib/:
--
--   StaffGatewayService.setJobs() is the sole reference to set_staff_jobs in
--   Dart, and setJobs() itself is not called by anything.
--
-- The visible result is asymmetric, which is why it survived: the staff
-- member's "My jobs" list still fills in, because my_staff_record() builds it
-- from staff.permissions. What stays empty is job_history, which
-- my_staff_record() reads from staff_job_assignments -- so the history card
-- the staff workspace shows, and the "Added DATE -> removed DATE" line
-- 20260927000039 fixed in Dart, rendered nothing at all. The history table
-- only ever gained rows from a code path the app never takes, and from the
-- assertions themselves.
--
-- THE FIX: RECORD THE CHANGE, NOT THE CALLER
-- ------------------------------------------
-- The repair is not "make the Dart call set_staff_jobs". That would leave the
-- same hole one refactor away: any future screen, any SQL editor session, any
-- admin RPC that writes permissions would be unrecorded again. This is the
-- argument 20260927000035 already made for the audit table -- a trigger sees
-- every path, a hand-written call sees only the one that contains it -- and
-- staff.permissions is the thing that means "holds these jobs", so the record
-- belongs to the column.
--
-- record_staff_job_changes() is an AFTER INSERT OR UPDATE OF permissions
-- trigger on staff that diffs OLD and NEW and writes exactly what
-- set_staff_jobs writes: an open row per added job, a CLOSED row per removed
-- one, and the activity entry. Then:
--
--   * update_staff()      -> recorded
--   * create_staff()      -> recorded, so the first grants are not invisible
--   * set_staff_jobs()    -> recorded ONCE, because it raises
--                            app.staff_jobs_recorded around its own UPDATE
--                            (see below), so a job granted through it does
--                            not get two rows and trip
--                            uq_staff_job_assignments_open
--   * the SQL editor      -> recorded, with a NULL actor rather than a guess
--
-- Why the flag rather than deleting the duplication from set_staff_jobs: that
-- function returns the error codes the UI maps (UNKNOWN_STAFF_JOB,
-- STAFF_JOB_TOUCHES_CUSTOMER_ORDERS, ...) and writes an ADMIN_ACTIONS row
-- with the reason text. Ripping its history block out and trusting the
-- trigger to reproduce it byte for byte is a behaviour change to a path with
-- its own assertion, for no gain. The flag is a transaction-local signal that
-- says "this change is already recorded", which is exactly and only what it
-- means -- the same shape as the insert-time signal the signup gate uses.
--
-- Legacy keys: staff_job_assignments.job_key has a FOREIGN KEY to
-- staff_jobs(key), and a staff row can still hold a key that predates the
-- catalogue. The trigger records only keys that have a catalogue row, rather
-- than aborting the administrator's edit with a foreign key violation. The
-- key stays in permissions (which is what the app reads) and simply has no
-- history, which is honest: nothing can say when it was granted.
--
-- FINDING 2: THE VERDICT RULE CALLED A CORRECT POLICY WIDE
-- -------------------------------------------------------
-- The assertion added in 20260927000046 stopped the pipeline on
-- ride_requests_user_cancel:
--
--   UPDATE USING   (user_id = auth.uid() AND status = 'REQUESTED')
--          CHECK  (status = 'CANCELLED')
--
-- That policy is correct, and tighter than naming the caller in the check: the
-- USING half proves the row is the caller's own, and the WITH CHECK half
-- constrains the row being written to CANCELLED. The caller cannot touch
-- anyone else's ride, and cannot write any status but CANCELLED.
--
-- The rule required BOTH halves to mention the caller, so a WITH CHECK that
-- names a VALUE rather than a PERSON was reported WIDE. The question a WITH
-- CHECK has to answer is not "does it mention auth.uid()" -- the USING half
-- already fixed whose row this is -- but "is it an unconditional yes". So:
--
--   * the row-targeting half (USING) must name the caller. That is the half
--     that decides whose rows can be reached, and it is the one that can be
--     wide open;
--   * the written half must not be a bare `true`. `true` is what makes a
--     policy unconditional -- `WITH CHECK (true)` on user_roles was the
--     escalation 20260927000046 closed -- while `status = 'CANCELLED'` is a
--     constraint on the result and cannot widen the reach.
--
-- An INSERT policy is unchanged and still judged on WITH CHECK alone, because
-- it has no USING clause: there, WITH CHECK is the row-targeting half.
--
-- This is the fifth artifact of one heuristic and the last one that can be
-- read off the report: the WIDE list is empty after it, and it is an
-- assertion, so a sixth cannot survive unnoticed.

-- ===========================================================================
-- 1. The record belongs to the column
-- ===========================================================================

CREATE OR REPLACE FUNCTION public.record_staff_job_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_before text[] := '{}'::text[];
  v_after  text[] := '{}'::text[];
  v_added   text[] := '{}'::text[];
  v_removed text[] := '{}'::text[];
  v_actor  uuid := auth.uid();
  v_actor_name text;
BEGIN
  -- set_staff_jobs() records its own history and its own ADMIN_ACTIONS row
  -- with the administrator's reason text. It raises this flag around its own
  -- UPDATE so one change produces exactly one record: without it the trigger
  -- would add a second open row for the same job and violate
  -- uq_staff_job_assignments_open, aborting the whole grant.
  IF current_setting('app.staff_jobs_recorded', true) = 'on' THEN
    RETURN NEW;
  END IF;

  v_before := CASE WHEN TG_OP = 'INSERT' THEN '{}'::text[]
                   ELSE COALESCE(OLD.permissions, '{}'::text[]) END;
  v_after  := COALESCE(NEW.permissions, '{}'::text[]);

  -- UPDATE OF permissions fires when the column is MENTIONED in the SET list,
  -- not when it changes, and update_staff() always mentions it. An edit that
  -- only renamed the staff member must not write a history row or an activity
  -- entry -- a log that records non-events stops being evidence.
  IF v_before = v_after THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT k), '{}'::text[]) INTO v_added
  FROM unnest(v_after) AS k WHERE NOT (k = ANY (v_before));

  SELECT COALESCE(array_agg(DISTINCT k), '{}'::text[]) INTO v_removed
  FROM unnest(v_before) AS k WHERE NOT (k = ANY (v_after));

  -- A staff row can still hold a key that predates the catalogue, and
  -- staff_job_assignments.job_key has a foreign key to staff_jobs(key). Such a
  -- key is left unrecorded rather than aborting the edit.
  v_added := ARRAY(
    SELECT k FROM unnest(v_added) AS k
    WHERE EXISTS (SELECT 1 FROM public.staff_jobs j WHERE j.key = k)
  );

  SELECT COALESCE(full_name, '(admin)') INTO v_actor_name
  FROM public.profiles WHERE id = v_actor;

  IF cardinality(v_added) > 0 THEN
    INSERT INTO public.staff_job_assignments
      (staff_id, job_key, assigned_by, assigned_by_name)
    SELECT NEW.id, k, v_actor, v_actor_name
    FROM unnest(v_added) AS k
    -- Defensive: an open row already means the job is held. Inserting anyway
    -- would collide with uq_staff_job_assignments_open and take the update
    -- down with it.
    WHERE NOT EXISTS (
      SELECT 1 FROM public.staff_job_assignments a
      WHERE a.staff_id = NEW.id AND a.job_key = k AND a.revoked_at IS NULL
    );
  END IF;

  IF cardinality(v_removed) > 0 THEN
    -- A removal CLOSES the open row. 20260927000039 fixed this exact bug
    -- inside set_staff_jobs -- a second row born closed left the original
    -- open forever, so "revoked_at IS NULL" stopped meaning "held" -- and the
    -- same mistake must not reappear here under a different caller.
    UPDATE public.staff_job_assignments a
    SET revoked_at = now(),
        revoked_by = v_actor,
        revoked_reason = COALESCE(a.revoked_reason,
                                  'the job was removed from the staff record')
    WHERE a.staff_id = NEW.id
      AND a.revoked_at IS NULL
      AND a.job_key = ANY (v_removed);
  END IF;

  -- The actor is whoever changed the record, and NULL when there was no
  -- caller at all (a migration or a SQL editor session). Logging the owner of
  -- the function instead would be a fabricated name in an audit trail.
  PERFORM public.log_staff_activity(
    NEW.id,
    CASE
      WHEN cardinality(v_added) > 0 AND cardinality(v_removed) > 0
        THEN 'jobs_changed'
      WHEN cardinality(v_added) > 0 THEN 'jobs_added'
      ELSE 'jobs_removed'
    END,
    jsonb_build_object('added', v_added, 'removed', v_removed),
    'job',
    v_actor
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_staff_job_changes() IS
  'Records a change to staff.permissions wherever it came from: one open row '
  'per added job in staff_job_assignments, the open row CLOSED per removed '
  'job, and a staff_activity_log entry. Exists because the CEO staff editor '
  'writes permissions through update_staff(), which wrote no history at all, '
  'so the staff workspace history card was filled only by the assertions. '
  'set_staff_jobs() raises app.staff_jobs_recorded around its own UPDATE to '
  'record once and not twice.';

DROP TRIGGER IF EXISTS trg_staff_permissions_history ON public.staff;
CREATE TRIGGER trg_staff_permissions_history
AFTER INSERT OR UPDATE OF permissions ON public.staff
FOR EACH ROW EXECUTE FUNCTION public.record_staff_job_changes();

-- ===========================================================================
-- 2. set_staff_jobs: same function, one flag, no second record
-- ===========================================================================
-- Everything else is restated byte for byte, including the error codes the UI
-- maps and the ordering of the history writes, because assert_staff_job_rules_
-- hold asserts this behaviour and the console depends on those codes.
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

  -- This change is recorded by the code below, and
  -- trg_staff_permissions_history must not record it a second time. The flag
  -- is transaction-local and cleared immediately after, so it can never leak
  -- into an unrelated update in the same transaction.
  PERFORM set_config('app.staff_jobs_recorded', 'on', true);

  UPDATE public.staff
  SET permissions = v_wanted, updated_at = now()
  WHERE id = p_staff_id
  RETURNING * INTO v_staff;

  PERFORM set_config('app.staff_jobs_recorded', 'off', true);

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
-- 3. The verdict: name the caller in USING, do not accept a bare true
-- ===========================================================================
-- Same result shape as 20260927000046, so this replaces the body without the
-- DROP that a changed RETURNS TABLE would have required.
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
      -- The half that decides WHOSE row can be reached. For an INSERT policy
      -- there is no USING clause: WITH CHECK is the whole rule, and the new
      -- row is the only row there is.
      CASE WHEN w.cmd = 'INSERT' THEN w.check_expr ELSE w.using_expr END AS reach,
      -- The half that decides what the written row may look like, defaulting
      -- to USING exactly as Postgres does when a policy omits WITH CHECK.
      CASE WHEN w.cmd = 'INSERT' THEN w.check_expr
           ELSE coalesce(nullif(w.check_expr, ''), w.using_expr) END AS written,
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
      -- USING must tie the row to the caller. A rule that never mentions a
      -- caller is reachable by every caller, which is what WIDE means.
      WHEN j.reach ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
       -- ...and the written half must not be an unconditional yes.
       AND j.written NOT IN ('true', '(true)', '1 = 1', 'true=true')
        THEN 'scoped'
      ELSE 'WIDE'
    END
  FROM judged j
  ORDER BY
    (CASE
       WHEN j.client_reachable
        AND NOT (
          j.reach ~ '(auth\.uid|is_admin|is_ceo|is_super_admin|owns_provider_profile|has_role|is_server_write)'
          AND j.written NOT IN ('true', '(true)', '1 = 1', 'true=true')
        )
       THEN 0 ELSE 1 END) ASC,
    j.tablename,
    j.cmd;
$$;

COMMENT ON FUNCTION public.client_write_policy_detail() IS
  'Diagnostic. For every write policy on a client-writable public table: the '
  'table, the command, the policy name, the roles it applies to, and BOTH '
  'pg_policies expression columns -- using_expr (USING) and check_expr (WITH '
  'CHECK) -- labelled scoped, WIDE, or client-unreachable. The row-targeting '
  'half must mention the caller; the written half must not be a bare true. An '
  'INSERT policy is judged on WITH CHECK alone, because it has no USING '
  'clause -- reading only qual reported 21 tightly scoped policies as wide '
  'open, and requiring both halves to name a person reported '
  'ride_requests_user_cancel, which fixes ownership in USING and constrains '
  'the result to CANCELLED, as WIDE. WIDE means nothing in the policy ties the '
  'write to a person. It is a sorting label, not a judgement.';

GRANT EXECUTE ON FUNCTION public.client_write_policy_detail()
  TO anon, authenticated;

-- ===========================================================================
-- 4. The assertion: drive the path the console drives
-- ===========================================================================
-- Behavioural, and it has to be: the finding was not a missing trigger, it was
-- a RECORD that never happened on the path a real screen takes. A catalog
-- check would have passed on the broken system for the same reason the
-- history table did -- the function it would have looked at was fine.
--
-- So this drives update_staff() as a verified admin, with the real trigger
-- attached, and then reads the history the staff workspace reads.
CREATE OR REPLACE FUNCTION public.assert_staff_job_changes_are_recorded()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_admin   uuid := '00000000-0000-4000-8000-00000000e701';
  v_subject uuid := '00000000-0000-4000-8000-00000000e702';
  v_staff   uuid := '00000000-0000-4000-8000-00000000e703';
  v_job     text;
  v_total   int;
  v_open    int;
  v_closed  int;
BEGIN
  -- A real catalogue job, so the foreign key and the validator both apply to
  -- the same value the console would send.
  SELECT j.key INTO v_job
  FROM public.staff_jobs j WHERE j.is_active
  ORDER BY j.sort_order, j.key LIMIT 1;
  IF v_job IS NULL THEN
    RAISE EXCEPTION 'the job catalogue is empty, so there is nothing to grant';
  END IF;

  BEGIN
    INSERT INTO auth.users (id, email, email_confirmed_at)
    VALUES (v_admin, 'staff-jobs-admin@example.invalid', now()),
           (v_subject, 'staff-jobs-subject@example.invalid', now())
    ON CONFLICT (id) DO NOTHING;

    -- PENDING_APPROVAL, never APPROVED: trg_profiles_insert_security raises
    -- MUST_START_AS_PENDING on an insert that claims to be approved.
    INSERT INTO public.profiles (id, full_name, status)
    VALUES (v_admin, 'Staff Jobs Admin', 'PENDING_APPROVAL'),
           (v_subject, 'Staff Jobs Subject', 'PENDING_APPROVAL')
    ON CONFLICT (id) DO NOTHING;

    -- The ADMIN row is what makes is_admin() true; can_manage_staff() reads
    -- the true-Admin case as "ADMIN role and no staff row of its own", which
    -- is exactly this account.
    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_admin, 'ADMIN')
    ON CONFLICT (user_id, role) DO NOTHING;

    INSERT INTO public.staff (id, user_id, name, staff_code, permissions)
    VALUES (v_staff, v_subject, 'Staff Jobs Subject', 'JOB-PROBE-1', '{}')
    ON CONFLICT (id) DO UPDATE SET permissions = '{}'::text[];

    -- A known starting point: no history for the probe.
    DELETE FROM public.staff_job_assignments WHERE staff_id = v_staff;

    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_admin::text,
                                         'role', 'authenticated')::text, true);

    -- Guard against proving the wrong branch: as an authenticated client this
    -- must be false, and the caller must be a manager or update_staff() would
    -- be refused before writing anything.
    IF public.is_server_write() THEN
      RAISE EXCEPTION 'is_server_write() is true for an authenticated client, so this test would exercise the server branch';
    END IF;
    IF NOT public.is_admin() THEN
      RAISE EXCEPTION 'the probe account is not an admin, so update_staff() would be refused and nothing would be proven';
    END IF;

    -- 1. GRANT, through the call the staff editor makes.
    PERFORM public.update_staff(p_staff_id := v_staff,
                               p_permissions := ARRAY[v_job]);

    SELECT count(*) INTO v_total
      FROM public.staff_job_assignments WHERE staff_id = v_staff;
    SELECT count(*) INTO v_open
      FROM public.staff_job_assignments
     WHERE staff_id = v_staff AND job_key = v_job AND revoked_at IS NULL;

    IF v_total <> 1 OR v_open <> 1 THEN
      RAISE EXCEPTION 'granting % through update_staff() left % history rows (% open); expected exactly 1, open. This is the CEO staff editor path, and it recorded nothing before 20260927000047.',
        v_job, v_total, v_open;
    END IF;

    -- 2. REVOKE: the open row CLOSES, and no second row appears.
    PERFORM public.update_staff(p_staff_id := v_staff,
                               p_permissions := '{}'::text[]);

    SELECT count(*) INTO v_total
      FROM public.staff_job_assignments WHERE staff_id = v_staff;
    SELECT count(*) INTO v_open
      FROM public.staff_job_assignments
     WHERE staff_id = v_staff AND job_key = v_job AND revoked_at IS NULL;
    SELECT count(*) INTO v_closed
      FROM public.staff_job_assignments
     WHERE staff_id = v_staff AND job_key = v_job AND revoked_at IS NOT NULL;

    IF v_total <> 1 OR v_open <> 0 OR v_closed <> 1 THEN
      RAISE EXCEPTION 'removing % through update_staff() left % rows (% open, % closed); a removal must close the open row, not write a second one',
        v_job, v_total, v_open, v_closed;
    END IF;

    -- 3. An edit that does not touch jobs writes no history. Without this the
    --    test would pass on a trigger that records every update of the row,
    --    which turns the history into noise.
    PERFORM public.update_staff(p_staff_id := v_staff, p_name := 'Staff Jobs Subject (renamed)');
    SELECT count(*) INTO v_total
      FROM public.staff_job_assignments WHERE staff_id = v_staff;
    IF v_total <> 1 THEN
      RAISE EXCEPTION 'renaming a staff member added a job history row (% rows now); the trigger must fire on a permission CHANGE, not on the mention of the column', v_total;
    END IF;

    -- Everything above rolls back, so the probe leaves nothing behind.
    RAISE EXCEPTION '%', c_sentinel;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> c_sentinel THEN RAISE; END IF;
  END;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_staff_job_changes_are_recorded() IS
  'Drives update_staff() as a verified admin -- the call the CEO staff editor '
  'makes -- and requires the job history to follow: one open '
  'staff_job_assignments row per grant, the same row closed on removal rather '
  'than a second row written, and no history for an edit that does not change '
  'the jobs. Behavioural because the broken system had the right function in '
  'it and simply never called it. Rolls back through a sentinel.';

REVOKE ALL ON FUNCTION public.assert_staff_job_changes_are_recorded()
  FROM public;
-- anon as well as authenticated: the connectivity suite calls every assertion
-- with the anon key and no session, so a grant to authenticated alone makes
-- the call fail with a permission error that reads like a broken test.
GRANT EXECUTE ON FUNCTION public.assert_staff_job_changes_are_recorded()
  TO anon, authenticated;
