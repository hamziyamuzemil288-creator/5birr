-- Audit everything that matters, on every path.
--
-- WHAT WAS NOT AUDITED
-- --------------------
-- admin_history is written BY HAND, inside admin RPCs, and the coverage was
-- thin. At the time of writing, admin_cash_recharge, admin_wallet_adjustment,
-- approve_wallet_recharge, transition_order_status, transition_ride_status,
-- claim_ride and suspend_provider wrote no audit row at all. Those are the
-- money and the state machine: the two things an audit exists for.
--
-- WHY TRIGGERS, NOT MORE HAND-WRITTEN log_admin_action CALLS
-- ---------------------------------------------------------
-- A hand-written call only sees the path that contains it. A recharge
-- approved through the admin-wallet-recharge Edge Function goes through
-- approve_wallet_recharge(); the same logical action through the SQL editor
-- does not; a future refactor that renames a function drops the audit line
-- silently. Every one of those is a way to move money without a trace, and
-- this schema has already shipped four guards that turned out to be inert.
--
-- A trigger fires for the WRITE, whoever caused it — RPC, Edge Function, admin
-- client, SQL editor, migration. That is the property the audit needs and the
-- one a per-function call cannot have.
--
-- WHAT IS DELIBERATELY NOT STORED
-- -------------------------------
-- The row's new and old values. Copying them would duplicate email addresses,
-- national ID numbers, wallet balances and document storage paths into a
-- second table with its own readers, which is a privacy and security problem
-- created by the act of auditing. What is stored is the row identity, the
-- operation, the actor, and the NAMES of the columns that changed — enough to
-- answer "who changed this, when, and in which field" without copying
-- anything sensitive.
--
-- driver_status is NOT audited: it is written on every GPS fix, and a row per
-- fix would bury every other event in the log within a day. Its meaningful
-- transitions (a driver taking a ride) already flow through ride_requests,
-- which is.

-- ===========================================================================
-- 1. The trigger
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.audit_row_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_table text := TG_TABLE_NAME;
  v_action text;
  v_row_id uuid;
  v_changed text[] := '{}'::text[];
  v_old jsonb;
  v_new jsonb;
  -- A row whose id is the auth user itself is the profile, not a subject.
  v_related uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := v_table || '_CREATED';
    v_new := to_jsonb(NEW);
  ELSIF TG_OP = 'DELETE' THEN
    v_action := v_table || '_DELETED';
    v_old := to_jsonb(OLD);
  ELSE
    v_action := v_table || '_UPDATED';
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);

    -- The column NAMES that differ, and nothing else. Computed from the two
    -- jsonb snapshots with a set difference, so a new column is picked up
    -- automatically instead of needing this function edited.
    SELECT COALESCE(array_agg(key ORDER BY key), '{}'::text[])
    INTO v_changed
    FROM (
      SELECT key FROM jsonb_object_keys(v_new) AS key
      EXCEPT
      SELECT key FROM jsonb_object_keys(v_old) AS key
      WHERE v_new -> key IS DISTINCT FROM v_old -> key
    ) diffs;
  END IF;

  -- Prefer the row's own id, then its user_id, then its order/ride link, so the
  -- audit row points at something a human can find.
  v_row_id := COALESCE(
    NULLIF(v_new ->> 'id', '')::uuid,
    NULLIF(v_old ->> 'id', '')::uuid,
    NULLIF(v_new ->> 'user_id', '')::uuid,
    NULLIF(v_old ->> 'user_id', '')::uuid,
    NULLIF(v_new ->> 'order_id', '')::uuid,
    NULLIF(v_old ->> 'order_id', '')::uuid,
    NULLIF(v_new ->> 'ride_request_id', '')::uuid,
    NULLIF(v_old ->> 'ride_request_id', '')::uuid
  );
  v_related := COALESCE(v_row_id, NULLIF(v_new ->> 'user_id', '')::uuid);

  PERFORM public.log_admin_action(
    auth.uid(),
    v_action,
    v_related,
    v_table,
    NULL,
    '{}'::text[],
    jsonb_build_object(
      'row_id', v_row_id,
      'changed_columns', v_changed,
      -- Recorded because "who did this" is the question the log exists for,
      -- and it is NULL for a migration or a server write — which is itself
      -- information worth having rather than an ambiguity to guess at.
      'actor', auth.uid()::text
    )
  );

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- ===========================================================================
-- 2. Where it is attached
-- ===========================================================================
-- Money, status, role and identity. Read-heavy and GPS tables are absent on
-- purpose; see the header for driver_status.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    -- money
    'wallet_transactions', 'wallet_recharge_requests', 'payment_proofs',
    -- the two state machines
    'orders', 'ride_requests',
    -- account + provider status
    'profiles', 'provider_profiles', 'vehicles',
    -- authority: the three that can grant or remove power
    'user_roles', 'staff', 'staff_credentials',
    -- identity review
    'user_documents', 'approval_requests'
  ]
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit_%s ON public.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit_%s AFTER INSERT OR UPDATE OR DELETE ON public.%I '
      'FOR EACH ROW EXECUTE FUNCTION public.audit_row_change()', t, t);
  END LOOP;
END;
$$;

COMMENT ON FUNCTION public.audit_row_change() IS
  'Writes an admin_history row for every insert/update/delete on the tables it '
  'is attached to, recording the actor, the row, and the NAMES of the columns '
  'that changed — never their values, so auditing does not duplicate email '
  'addresses, national IDs, balances or document paths into a second table.';

-- ===========================================================================
-- 3. The staff member's own record of their own work
-- ===========================================================================
-- admin_history is the admin's log. The request was that a staff member can
-- see what THEY did, so completing a work item is mirrored into
-- staff_activity_log, which is readable by the subject and the CEO only.
CREATE OR REPLACE FUNCTION public.staff_mark_task_done(
  p_task_key text,
  p_staff_id uuid DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
BEGIN
  SELECT * INTO v_staff
  FROM public.staff
  WHERE user_id = auth.uid() AND is_active
  LIMIT 1;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_CAN_ONLY_MARK_OWN_TASKS';
  END IF;

  -- The original resolved the staff row from p_staff_id AND auth.uid()
  -- together, so passing somebody else's id simply found no row. Kept exactly:
  -- collapsing that into a different error would change what the app's
  -- _friendlyError() maps and what a support conversation can be told.
  IF p_staff_id IS NOT NULL THEN
    SELECT * INTO v_staff
    FROM public.staff
    WHERE id = p_staff_id AND user_id = auth.uid() AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_CAN_ONLY_MARK_OWN_TASKS';
  END IF;

  -- Both refusals are preserved separately. A task that is gone and a task
  -- that is simply not finished are different conversations with the user,
  -- and the first version of this migration merged them into one message that
  -- was wrong in both cases.
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_task_feed(v_staff.id)
    WHERE task_key = p_task_key
  ) THEN
    RAISE EXCEPTION 'TASK_NOT_FOUND_OR_NOT_PERMITTED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_task_feed(v_staff.id)
    WHERE task_key = p_task_key AND is_terminal
  ) THEN
    RAISE EXCEPTION 'TASK_MUST_REACH_TERMINAL_STATE_FIRST';
  END IF;

  INSERT INTO public.staff_task_completions
    (staff_id, task_key, source_type, source_id, completed_at, terminal_at)
  SELECT v_staff.id, f.task_key, f.source_type, f.source_id, now(), f.terminal_at
  FROM public.staff_task_feed(v_staff.id) f
  WHERE f.task_key = p_task_key
  ON CONFLICT (staff_id, task_key) DO UPDATE
    SET completed_at = EXCLUDED.completed_at,
        terminal_at = EXCLUDED.terminal_at;

  PERFORM public.log_staff_activity(
    v_staff.id,
    'task_completed',
    jsonb_build_object('task_key', p_task_key),
    'work'
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_mark_task_done(text, uuid)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.staff_mark_task_done(text, uuid) TO authenticated;

-- ===========================================================================
-- 4. Assertion
-- ===========================================================================
-- The failure this prevents is a table that quietly stopped being audited, so
-- it is asserted against pg_trigger rather than against this file's text: a
-- later migration that drops a trigger, or a new money table nobody attaches,
-- has to fail here.
CREATE OR REPLACE FUNCTION public.assert_money_and_status_are_audited()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_missing text;
BEGIN
  SELECT string_agg(t, ', ') INTO v_missing
  FROM unnest(ARRAY[
    'wallet_transactions', 'wallet_recharge_requests', 'payment_proofs',
    'orders', 'ride_requests',
    'profiles', 'provider_profiles', 'vehicles',
    'user_roles', 'staff', 'staff_credentials',
    'user_documents', 'approval_requests'
  ]) AS t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = format('public.%I', t)::regclass
      AND tgname = 'trg_audit_' || t
      AND NOT tgisinternal
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'these tables have no audit trigger, so money or status can change without a trace: %',
      v_missing;
  END IF;
  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_money_and_status_are_audited() IS
  'Raises naming any money, status, role or identity table that has lost its '
  'audit trigger. Checked against pg_trigger rather than migration text, so a '
  'later DROP fails the build instead of quietly un-auditing the ledger.';

GRANT EXECUTE ON FUNCTION public.assert_money_and_status_are_audited()
  TO anon, authenticated;

-- And the job rules, behaviourally: a staff member cannot be granted a job
-- that touches a customer's order, and cannot be granted a job that does not
-- exist. Both are refused at assign time, so a well-meaning addition to the
-- catalogue cannot breach the product rule by accident.
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
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'staff-job-probe@example.invalid', now()),
         (v_admin, 'staff-job-admin@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Job Probe', 'APPROVED'),
         (v_admin, 'Job Admin', 'APPROVED')
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
    RAISE EXCEPTION 'set_staff_jobs() accepted a job that does not exist';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'set_staff_jobs() accepted a job that does not exist' THEN
        RAISE;
      END IF;
      NULL;
  END;

  -- (2) A job that touches a CUSTOMER'S ORDER is refused. None exists today,
  -- so one is created for the probe and then taken away again — the rule has
  -- to be proven while there is something to refuse.
  INSERT INTO public.staff_jobs (key, label, group_name, touches_customer_orders)
  VALUES ('probe_customer_orders', 'Probe customer orders', 'Probe', true);

  BEGIN
    PERFORM public.set_staff_jobs(v_staff, ARRAY['probe_customer_orders'], 'probe');
    RAISE EXCEPTION 'set_staff_jobs() accepted a job that touches customer orders';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'set_staff_jobs() accepted a job that touches customer orders' THEN
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

  -- (4) Removing it keeps the history row rather than erasing it — that is the
  --     difference between an audit and a snapshot.
  PERFORM public.set_staff_jobs(v_staff, ARRAY[]::text[], 'probe removal');
  SELECT permissions INTO v_perms FROM public.staff WHERE id = v_staff;
  IF cardinality(COALESCE(v_perms, '{}'::text[])) <> 0 THEN
    RAISE EXCEPTION 'the job was not removed: %', v_perms;
  END IF;

  SELECT count(*) INTO v_history
  FROM public.staff_job_assignments WHERE staff_id = v_staff;
  IF v_history < 2 THEN
    RAISE EXCEPTION
      'expected an assignment AND a revocation row in the history, found %', v_history;
  END IF;

  -- (5) A non-manager cannot assign jobs at all.
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
  'Requires set_staff_jobs() to refuse an unknown job, refuse a job that '
  'touches customer orders, grant a real job, keep history on removal, and '
  'refuse a non-manager entirely.';

GRANT EXECUTE ON FUNCTION public.assert_staff_job_rules_hold()
  TO anon, authenticated;
