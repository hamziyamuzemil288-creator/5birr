-- Jobs the CEO creates, not a list baked into a constraint.
--
-- THE GAP THIS CLOSES
-- -------------------
-- 20260927000034 turned `staff.permissions` into a catalogue, but that
-- catalogue was still SEEDED — ten rows in a migration. Picking a job was
-- better than editing a CHECK constraint, but the set of jobs was still
-- fixed: adding "Fleet paperwork" meant writing a migration, and the person
-- who has to approve that is the same person who just hired somebody and
-- needs them working today. The request was explicit that a job must be
-- SELECTABLE, and a list you cannot extend is still a list you cannot
-- choose from.
--
-- So the catalogue is now writable at runtime, by the person who assigns from
-- it. create_staff_job() is the only way a job comes into existence.
--
-- The customer-ordering rule is enforced at CREATION, not just at assignment.
-- Refusing to assign a job that touches a customer's order left an obvious
-- hole: a manager could create such a job, and the catalogue would then carry
-- a row that no staff member can ever hold and that no screen can explain. A
-- rule the system will not let you write down is a rule the system believes.
--
-- Deactivation, not deletion: staff_job_assignments has a foreign key to
-- staff_jobs, and the whole point of the assignment history is that it
-- outlives the job. A deleted job would take "Alex had this job in March"
-- with it. Retiring the key keeps the history readable and refuses to strand
-- anyone who currently holds it.

-- ===========================================================================
-- 1. Create
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.create_staff_job(
  p_label text,
  p_key text DEFAULT NULL,
  p_group text DEFAULT 'General',
  p_description text DEFAULT NULL
)
RETURNS public.staff_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_key text;
  v_label text := btrim(p_label);
  v_job public.staff_jobs;
BEGIN
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_CREATE_STAFF_JOBS';
  END IF;

  IF length(v_label) < 2 OR length(v_label) > 80 THEN
    RAISE EXCEPTION 'JOB_LABEL_REQUIRED';
  END IF;

  v_key := lower(regexp_replace(COALESCE(NULLIF(btrim(p_key), ''), v_label),
                                '[^a-z0-9]+', '_', 'gi'));
  v_key := btrim(v_key, '_');

  IF v_key !~ '^[a-z][a-z0-9_]{1,39}$' THEN
    RAISE EXCEPTION
      'INVALID_STAFF_JOB_KEY: use 2-40 characters, letters, numbers and underscores, starting with a letter';
  END IF;

  IF EXISTS (SELECT 1 FROM public.staff_jobs WHERE key = v_key) THEN
    RAISE EXCEPTION 'STAFF_JOB_ALREADY_EXISTS: %', v_key;
  END IF;

  INSERT INTO public.staff_jobs (key, label, description, group_name, sort_order)
  VALUES (
    v_key,
    v_label,
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    COALESCE(NULLIF(btrim(COALESCE(p_group, '')), ''), 'General'),
    COALESCE((SELECT max(sort_order) + 10 FROM public.staff_jobs), 100)
  )
  RETURNING * INTO v_job;

  -- touches_customer_orders is left at its DEFAULT false and there is
  -- deliberately NO parameter for it. See the header: the rule is that staff
  -- never act on a customer's order, so a manager cannot author such a job in
  -- the first place. Offering the flag and then refusing it at assign time
  -- would put a row in the catalogue that nobody can ever hold and no screen
  -- can explain.
  PERFORM public.log_admin_action(
    auth.uid(), 'STAFF_JOB_CREATED', NULL, 'staff_job', NULL,
    '{}'::text[],
    jsonb_build_object('key', v_job.key, 'label', v_job.label,
                       'group', v_job.group_name)
  );

  RETURN v_job;
END;
$$;

REVOKE ALL ON FUNCTION public.create_staff_job(text, text, text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.create_staff_job(text, text, text, text)
  TO authenticated;

-- ===========================================================================
-- 2. Retire
-- ===========================================================================
-- is_active = false rather than DELETE. staff_job_assignments references
-- staff_jobs(key); deleting a job would delete the record that somebody once
-- held it, which is the opposite of what the history is for.
CREATE OR REPLACE FUNCTION public.deactivate_staff_job(
  p_key text,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_holders integer;
BEGIN
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_DEACTIVATE_STAFF_JOBS';
  END IF;

  SELECT count(*) INTO v_holders
  FROM public.staff s
  WHERE s.is_active AND p_key = ANY (COALESCE(s.permissions, '{}'::text[]));

  -- Refused, not cascaded. Retiring a job four people still hold would leave
  -- the CEO's own checklist lying: it would show four staff with a job the
  -- catalogue no longer offers, and no way to tell whether that is intended.
  IF v_holders > 0 THEN
    RAISE EXCEPTION
      'STAFF_JOB_STILL_ASSIGNED: % staff member(s) still hold this job. Remove it from them first.',
      v_holders;
  END IF;

  UPDATE public.staff_jobs
  SET is_active = false
  WHERE key = p_key AND is_active;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_JOB_NOT_FOUND: %', p_key;
  END IF;

  PERFORM public.log_admin_action(
    auth.uid(), 'STAFF_JOB_DEACTIVATED', NULL, 'staff_job', NULL,
    '{}'::text[],
    jsonb_build_object('key', p_key, 'reason', p_reason)
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.deactivate_staff_job(text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.deactivate_staff_job(text, text)
  TO authenticated;

-- ===========================================================================
-- 3. The CEO's view of the catalogue
-- ===========================================================================
-- Includes the INACTIVE ones. A list that silently drops what it retired is
-- how a job reappears from memory six months later.
CREATE OR REPLACE FUNCTION public.list_staff_jobs()
RETURNS TABLE (
  key text,
  label text,
  description text,
  group_name text,
  is_active boolean,
  holders bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT j.key, j.label, j.description, j.group_name, j.is_active,
         (SELECT count(*) FROM public.staff s
          WHERE s.is_active AND j.key = ANY (COALESCE(s.permissions, '{}'::text[])))
  FROM public.staff_jobs j
  ORDER BY j.is_active DESC, j.sort_order, j.label;
$$;

REVOKE ALL ON FUNCTION public.list_staff_jobs() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.list_staff_jobs() TO authenticated;

-- ===========================================================================
-- 4. Assertion
-- ===========================================================================
-- The behaviour that matters is that a job can be CREATED and then assigned —
-- otherwise the catalogue is a nicer-looking fixed list, which is the bug
-- this migration exists to fix — and that the customer-ordering rule holds at
-- the earliest possible point rather than only at assign time.
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
  VALUES (v_user, 'Job Create Probe', 'APPROVED'),
         (v_admin, 'Job Create Admin', 'APPROVED')
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

COMMENT ON FUNCTION public.assert_staff_jobs_are_creatable() IS
  'Requires create_staff_job() to refuse a non-manager, derive a safe key from '
  'a label alone, produce a job that can immediately be assigned, and '
  'deactivate_staff_job() to refuse while anyone holds the job and to preserve '
  'the history once they do not.';

GRANT EXECUTE ON FUNCTION public.assert_staff_jobs_are_creatable()
  TO anon, authenticated;
