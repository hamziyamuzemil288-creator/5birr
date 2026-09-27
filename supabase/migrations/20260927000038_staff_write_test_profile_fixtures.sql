-- The staff write-test fixtures, corrected the way 20260927000023 did.
--
-- WHAT THE DEPLOY AND CI SHOWED
-- ----------------------------
-- With migrations 33-37 finally live, the PGRST202 errors cleared and four
-- assertions started failing on a real one:
--
--   PostgrestException(message: MUST_START_AS_PENDING, code: P0001)
--
-- That is not the orders guard (that one raises
-- ORDERS_MUST_START_AS_PENDING_PROVIDER, fixed in 00016). This is
-- prevent_profile_insert_privilege_escalation:
--
--   IF NOT is_admin() THEN
--     IF new.status != 'PENDING_APPROVAL' THEN
--       RAISE EXCEPTION 'MUST_START_AS_PENDING';
--
-- on trg_profiles_insert_security, BEFORE INSERT ON profiles.
--
-- THE GUARD IS CORRECT AND IS NOT BEING CHANGED. It stops a client from
-- creating an account that is already APPROVED, and every legitimate
-- server-side insert -- handle_new_user, the signup chain -- uses
-- PENDING_APPROVAL for exactly that reason. Widening it to let a server
-- insert an APPROVED profile would remove a real protection to suit a test.
--
-- 20260927000023 fixed exactly this for the order and wallet write tests.
-- These four fixtures were written afterwards and made the same mistake, so
-- they were failing for the same reason and for no other: none of them
-- depends on the profile's status. They read public.staff, user_roles, and
-- auth.uid() -- none of which look at profiles.status. The profile row exists
-- only to satisfy a foreign key.
--
-- WHY A NEW MIGRATION RATHER THAN AN EDIT
-- --------------------------------------
-- 33-37 are applied. Editing them changes nothing in the database, because
-- `supabase db push` only runs files the remote has not recorded. The
-- functions have to be re-emitted, so they are restated verbatim here with
-- one substitution and nothing else -- no logic touched, no assertion
-- weakened, no new coverage. The bodies are byte-identical to their sources
-- apart from the fixture status, which is what makes this safe to review:
-- every line that is not a profiles fixture is unchanged.

-- from 20260927000033_staff_warnings_and_live_task_feed.sql
CREATE OR REPLACE FUNCTION public.assert_staff_warnings_are_admin_only()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e604';
  v_staff uuid;
  v_note text;
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

  -- Non-admin: the attack is writing a warning row directly.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  IF public.is_ceo() OR public.is_super_admin() THEN
    RAISE EXCEPTION 'the probe user is unexpectedly a manager, so this test cannot prove anything';
  END IF;

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

  -- Acknowledging someone else's warning must fail too: the column is
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

-- from 20260927000035_audit_every_mutation_path.sql
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

-- from 20260927000036_ceo_creates_staff_jobs.sql
CREATE OR REPLACE FUNCTION public.assert_staff_jobs_are_creatable()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e607';
  v_admin uuid := '00000000-0000-4000-8000-00000000e608';
  v_staff uuid;
  v_job public.staff_jobs;
  v_perms text[];
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'job-create-probe@example.invalid', now()),
         (v_admin, 'job-create-admin@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Job Create Probe', 'PENDING_APPROVAL'),
         (v_admin, 'Job Create Admin', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.staff (user_id, name, staff_code, permissions)
  VALUES (v_user, 'Job Create Probe', 'JOB-CREATE-1', '{}')
  RETURNING id INTO v_staff;

  -- (1) A non-manager cannot author a job.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.create_staff_job('Probe Job', 'probe_job', 'Probe', NULL);
    RAISE EXCEPTION 'a non-manager was able to create a staff job';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a non-manager was able to create a staff job' THEN
        RAISE;
      END IF;
      NULL;
  END;

  -- (2) The manager can, from a LABEL ALONE — the key is derived, because
  --     making someone invent a machine-safe key is how job creation gets
  --     abandoned in favour of editing a migration.
  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_admin::text,
                                       'role', 'authenticated')::text, true);
  INSERT INTO public.user_roles (user_id, role)
  VALUES (v_admin, 'ADMIN') ON CONFLICT (user_id, role) DO NOTHING;
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'the admin probe fixture is not a manager';
  END IF;

  PERFORM public.create_staff_job('Fleet paperwork!!', NULL, 'Operations',
                                  'Vehicle paperwork and fleet docs.');
  SELECT * INTO v_job FROM public.staff_jobs WHERE label = 'Fleet paperwork!!';
  -- staff_jobs is keyed on `key`, not a surrogate id.
  IF v_job.key IS NULL THEN
    RAISE EXCEPTION 'create_staff_job() did not persist the job';
  END IF;
  -- The label had to be cleaned into a key that can live in a text[] and in a
  -- policy comparison.
  IF v_job.key !~ '^[a-z][a-z0-9_]{1,39}$' THEN
    RAISE EXCEPTION 'the derived key is not a safe identifier: %', v_job.key;
  END IF;

  -- (3) And the whole point: a brand-new job can immediately be assigned.
  PERFORM public.set_staff_jobs(v_staff, ARRAY[v_job.key], 'probe');
  SELECT permissions INTO v_perms FROM public.staff WHERE id = v_staff;
  IF NOT (v_job.key = ANY (COALESCE(v_perms, '{}'::text[]))) THEN
    RAISE EXCEPTION 'a freshly created job could not be assigned';
  END IF;

  -- (4) It cannot be retired out from under the person who holds it.
  BEGIN
    PERFORM public.deactivate_staff_job(v_job.key, 'probe');
    RAISE EXCEPTION 'a job still held by a staff member was retired';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'a job still held by a staff member was retired' THEN
        RAISE;
      END IF;
      NULL;
  END;

  -- (5) Once nobody holds it, retirement works and the history survives.
  PERFORM public.set_staff_jobs(v_staff, ARRAY[]::text[], 'probe');
  PERFORM public.deactivate_staff_job(v_job.key, 'probe');
  IF (SELECT is_active FROM public.staff_jobs WHERE key = v_job.key) THEN
    RAISE EXCEPTION 'the job was not retired';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.staff_job_assignments
                 WHERE staff_id = v_staff AND job_key = v_job.key) THEN
    RAISE EXCEPTION 'retiring a job destroyed its assignment history';
  END IF;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

-- from 20260927000037_staff_password_change_is_audited.sql
CREATE OR REPLACE FUNCTION public.assert_staff_password_changes_are_audited()
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  c_sentinel constant text := '__rollback_ok__';
  v_user uuid := '00000000-0000-4000-8000-00000000e609';
  v_actor uuid := '00000000-0000-4000-8000-00000000e610';
  v_staff uuid;
  v_actor_id uuid;
  v_action text;
  v_kind text;
  v_detail jsonb;
  v_staff_id uuid;
BEGIN
  INSERT INTO auth.users (id, email, email_confirmed_at)
  VALUES (v_user, 'pw-change-probe@example.invalid', now()),
         (v_actor, 'pw-change-actor@example.invalid', now())
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.profiles (id, full_name, status)
  VALUES (v_user, 'Password Probe', 'PENDING_APPROVAL'),
         (v_actor, 'Password Actor', 'PENDING_APPROVAL')
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO public.staff (user_id, name, staff_code, permissions)
  VALUES (v_user, 'Password Probe', 'PW-CHANGE-1', '{}')
  RETURNING id INTO v_staff;
  IF v_staff IS NULL THEN
    RAISE EXCEPTION 'could not create the probe staff row';
  END IF;

  -- (1) A caller that supplies its own actor has THAT actor recorded, not
  --     NULL. This is the Edge Function case: service_role carries no JWT, so
  --     auth.uid() is NULL and the unguarded version silently writes an audit
  --     row that cannot answer "who changed this password".
  PERFORM public.log_staff_password_change(v_staff, v_actor);
  SELECT actor_id, action, kind, detail, staff_id
    INTO v_actor_id, v_action, v_kind, v_detail, v_staff_id
  FROM public.staff_activity_log
  WHERE staff_id = v_staff AND action = 'PASSWORD_CHANGED'
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_actor_id IS NULL THEN
    RAISE EXCEPTION
      'a password change was logged with no actor, so the record cannot say who changed it';
  END IF;
  IF v_actor_id <> v_actor THEN
    RAISE EXCEPTION 'the wrong actor was recorded: %', v_actor_id;
  END IF;
  IF v_kind <> 'access' THEN
    RAISE EXCEPTION 'a password change was not recorded as an access event: %', v_kind;
  END IF;
  IF v_staff_id <> v_staff THEN
    RAISE EXCEPTION 'the password change was recorded against the wrong staff row';
  END IF;
  -- The record must not become a plaintext store of the secret it exists to
  -- protect. Anything password-shaped in the detail is a leak.
  IF v_detail::text ~* 'pass(word|_hash)?\s*[:=]' THEN
    RAISE EXCEPTION 'the activity detail appears to contain a password';
  END IF;

  -- (2) A self-service change is identified as such, because "the person
  --     changed their own" and "an administrator reset it" are different
  --     events and the CEO has to be able to tell them apart later.
  IF NOT COALESCE((v_detail ->> 'self_service')::boolean, false) THEN
    RAISE EXCEPTION 'a self-service password change was not marked self_service';
  END IF;

  -- (3) The 4-argument call still works and still means "the caller". A
  --     dropped default here would break every existing call site at runtime,
  --     which is the regression this restatement could plausibly introduce.
  PERFORM set_config('request.jwt.claim.sub', v_user::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_user::text,
                                       'role', 'authenticated')::text, true);
  PERFORM public.log_staff_activity(v_staff, 'WORK_DONE', '{"task":"probe"}'::jsonb);
  SELECT actor_id INTO v_actor_id
  FROM public.staff_activity_log
  WHERE staff_id = v_staff AND action = 'WORK_DONE'
  ORDER BY created_at DESC LIMIT 1;
  IF v_actor_id IS DISTINCT FROM v_user THEN
    RAISE EXCEPTION
      'the 4-argument form no longer records the calling user (got %)',
      v_actor_id;
  END IF;

  RAISE EXCEPTION '%', c_sentinel;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM = c_sentinel THEN
      RETURN true;
    END IF;
    RAISE;
END;
$$;

