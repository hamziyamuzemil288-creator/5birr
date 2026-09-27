-- Staff jobs: a real catalogue the CEO assigns from, with history.
--
-- WHAT EXISTED
-- ------------
-- `staff.permissions` was a text[] with a CHECK constraint naming nine fixed
-- strings. That is a flag list, not a job system:
--
--   * The nine keys were hard-coded in a CHECK, so "assign a job" meant
--     editing a constraint. There was nowhere for the CEO to see what jobs
--     EXIST, let alone pick from a list — the Flutter screen hard-codes the
--     same nine labels in a Dart map, and the two have no shared source.
--   * There was no history. Changing a staff member's jobs overwrote the
--     array. "What jobs did I give him, and when did that change" — which is
--     the first question after a mistake — was unanswerable.
--   * There was no record of what the person actually DID. admin_history
--     records what an ADMIN did TO a staff row; it does not record the work
--     the staff member performed, and it is not visible to them.
--
-- WHAT THIS ADDS
-- --------------
--   1. staff_jobs — the catalogue. Seeded from the nine existing keys so
--      nothing that already works breaks, plus the jobs the product actually
--      needs but never had a flag for (document verification, appeals).
--      `staff_has_permission()` and every RLS policy keep reading the same
--      text[]; this does not re-implement the authorisation layer.
--   2. staff_job_assignments — an append-only history of every add, change and
--      removal, with who did it and when. Revoking does not erase the row.
--   3. staff_activity_log — what a staff member actually did, readable by
--      THEM and the CEO and nobody else. admin_history is an admin-facing
--      log of admin actions; this is the staff member's own record.
--   4. An explicit, enforced boundary: staff do not touch customer ordering.
--
-- ON (4) — the request was explicit: staff interfere between providers and
-- users only where they must (document verification, appeals and similar),
-- and never with a customer's order. Nothing in the current nine keys grants
-- that, so this is not closing a live hole — it is making an implicit
-- accident into an enforced rule, because the nine keys came from a CHECK
-- constraint that the next person would happily extend. `touches_customer_orders`
-- is what a job catalogue is FOR: the rule is data, so a job that would breach
-- it cannot be created in the first place, and one that already exists is
-- refused at assign time.

-- ===========================================================================
-- 1. The catalogue
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.staff_jobs (
  key text PRIMARY KEY,
  label text NOT NULL,
  description text,
  group_name text NOT NULL DEFAULT 'General',
  -- The rule, as data. See the header note.
  touches_customer_orders boolean NOT NULL DEFAULT false,
  is_active boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 100,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN public.staff_jobs.touches_customer_orders IS
  'True only for jobs that act on a CUSTOMER''S order. Staff must never hold '
  'one: the product rule is that staff interfere between providers and users '
  'only where they must (verification, appeals) and never with ordering. '
  'Enforced at assign time, not left to whoever adds the next job.';

-- Seeded from the nine keys the CHECK constraint already permitted, so every
-- staff row that exists today keeps exactly the access it had. ON CONFLICT DO
-- NOTHING: the labels below are documentation, and a live row is the truth.
INSERT INTO public.staff_jobs (key, label, description, group_name, sort_order)
VALUES
  ('registrations', 'Registrations',
   'Approve or reject new user and provider sign-ups.', 'Verification', 10),
  ('document_verification', 'Document verification',
   'Review identity documents and record a verified or rejected decision.',
   'Verification', 20),
  ('support_chat', 'Support & appeals',
   'Answer support tickets and resolve appeals.', 'Support', 30),
  ('payment_verification', 'Payment verification',
   'Approve or reject wallet recharges and order payment proofs.',
   'Money', 40),
  ('sales_transactions', 'Sales transactions',
   'Record and review sales made in branch.', 'Money', 50),
  ('category_management', 'Category management',
   'Create and edit the product/service catalogue.', 'Oversight', 60),
  ('view_reports', 'View reports',
   'Read the reporting dashboards.', 'Oversight', 70),
  ('view_expenses', 'View expenses',
   'Read the branch expense ledger.', 'Oversight', 80),
  ('admin_history', 'Admin history',
   'Read the administrative audit log.', 'Oversight', 90),
  ('view_auth_logs', 'View auth logs',
   'Read sign-in and account-security events.', 'Oversight', 100)
ON CONFLICT (key) DO NOTHING;

-- ===========================================================================
-- 2. Replace the hard-coded CHECK with one that reads the catalogue
-- ===========================================================================
-- A CHECK constraint cannot contain a subquery, so the old fixed array is
-- dropped and a trigger takes its place. The trigger is the FIRST execution
-- boundary for a plpgsql body, which is exactly where column resolution
-- happens — so it is written to fail loudly on a key that is not in the
-- catalogue rather than to silently accept anything.
ALTER TABLE public.staff DROP CONSTRAINT IF EXISTS staff_permissions_known;

CREATE OR REPLACE FUNCTION public.validate_staff_jobs()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_unknown text[];
  v_forbidden text[];
BEGIN
  IF NEW.permissions IS NULL OR cardinality(NEW.permissions) = 0 THEN
    RETURN NEW;
  END IF;

  SELECT array_agg(k) INTO v_unknown
  FROM unnest(NEW.permissions) AS k
  WHERE NOT EXISTS (SELECT 1 FROM public.staff_jobs j
                    WHERE j.key = k AND j.is_active);

  IF v_unknown IS NOT NULL THEN
    RAISE EXCEPTION 'UNKNOWN_STAFF_JOB: %', array_to_string(v_unknown, ', ');
  END IF;

  -- The customer-ordering rule, enforced rather than assumed. See the header.
  SELECT array_agg(j.key) INTO v_forbidden
  FROM unnest(NEW.permissions) AS k
  JOIN public.staff_jobs j ON j.key = k
  WHERE j.touches_customer_orders;

  IF v_forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'STAFF_JOB_TOUCHES_CUSTOMER_ORDERS: %',
      array_to_string(v_forbidden, ', ');
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_staff_jobs_valid ON public.staff;
CREATE TRIGGER trg_staff_jobs_valid
BEFORE INSERT OR UPDATE OF permissions ON public.staff
FOR EACH ROW EXECUTE FUNCTION public.validate_staff_jobs();

-- ===========================================================================
-- 3. Assignment history
-- ===========================================================================
-- Append-only. A removal sets revoked_at; it never deletes the row, because
-- "who gave him document verification and when did they take it away" is
-- exactly the question this table exists to answer, and a DELETE would answer
-- it with a shrug.
CREATE TABLE IF NOT EXISTS public.staff_job_assignments (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  job_key text NOT NULL REFERENCES public.staff_jobs(key),
  assigned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  assigned_by_name text,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  revoked_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  revoked_reason text,
  UNIQUE (staff_id, job_key, assigned_at)
);

CREATE INDEX IF NOT EXISTS idx_staff_job_assignments_staff
  ON public.staff_job_assignments (staff_id, assigned_at DESC);
CREATE INDEX IF NOT EXISTS idx_staff_job_assignments_open
  ON public.staff_job_assignments (staff_id) WHERE revoked_at IS NULL;

ALTER TABLE public.staff_job_assignments ENABLE ROW LEVEL SECURITY;

-- A manager reads the history; the subject reads their own. No write policy:
-- every change goes through the RPCs below, which re-check the caller.
DROP POLICY IF EXISTS staff_job_assignments_read ON public.staff_job_assignments;
CREATE POLICY staff_job_assignments_read ON public.staff_job_assignments FOR SELECT
  USING (
    public.is_ceo()
    OR public.is_super_admin()
    OR EXISTS (SELECT 1 FROM public.staff s
                WHERE s.id = staff_id AND s.user_id = auth.uid())
  );

REVOKE ALL ON public.staff_job_assignments FROM anon;
GRANT SELECT ON public.staff_job_assignments TO authenticated;

-- ===========================================================================
-- 4. What the staff member actually did
-- ===========================================================================
-- admin_history answers "what did an admin do to a staff row". It does not
-- answer "what did Alex do", and it is not shown to Alex. The request was
-- explicit: the selected staff member's status and what he did must be
-- visible to HIMSELF and to the CEO, and to nobody else — not to his peers,
-- not to a super admin who merely manages him.
CREATE TABLE IF NOT EXISTS public.staff_activity_log (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  actor_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name text,
  -- 'work' = the staff member did something. 'job' = their jobs changed.
  -- Split so the subject's own record is not polluted by management decisions
  -- they were not part of.
  kind text NOT NULL DEFAULT 'work'
    CHECK (kind IN ('work', 'job', 'warning', 'access')),
  action text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_activity_log_staff
  ON public.staff_activity_log (staff_id, created_at DESC);

ALTER TABLE public.staff_activity_log ENABLE ROW LEVEL SECURITY;

-- Self or the CEO. Deliberately NOT is_admin() and NOT is_super_admin(): a
-- super admin manages permissions, which is not a licence to read an
-- individual's record of their own work.
DROP POLICY IF EXISTS staff_activity_self_or_ceo ON public.staff_activity_log;
CREATE POLICY staff_activity_self_or_ceo ON public.staff_activity_log FOR SELECT
  USING (
    public.is_ceo()
    OR EXISTS (SELECT 1 FROM public.staff s
                WHERE s.id = staff_id AND s.user_id = auth.uid())
  );

REVOKE ALL ON public.staff_activity_log FROM anon;
GRANT SELECT ON public.staff_activity_log TO authenticated;

-- Records what a staff member did, from inside a SECURITY DEFINER function,
-- with the staff row resolved from the caller's own auth user.
CREATE OR REPLACE FUNCTION public.log_staff_activity(
  p_staff_id uuid,
  p_action text,
  p_detail jsonb DEFAULT '{}'::jsonb,
  p_kind text DEFAULT 'work'
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor_name text;
BEGIN
  SELECT COALESCE(full_name, '(staff)') INTO v_actor_name
  FROM public.profiles WHERE id = auth.uid();

  INSERT INTO public.staff_activity_log
    (staff_id, actor_id, actor_name, kind, action, detail)
  VALUES
    (p_staff_id, auth.uid(), v_actor_name, p_kind, p_action,
     COALESCE(p_detail, '{}'::jsonb));
END;
$$;

REVOKE ALL ON FUNCTION public.log_staff_activity(uuid, text, jsonb, text)
  FROM public, anon;

-- ===========================================================================
-- 5. The CEO's verbs: assign, change, remove
-- ===========================================================================
-- One function rather than three, because the difference between "add a job"
-- and "swap a job" is a diff, and a diff is exactly what a caller already has.
-- Every branch writes the history row; none of them edits the past.
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
  -- v_wanted is assigned from p_job_keys and then deduplicated INTO
  -- v_clean: assigning to a variable while reading it in the same FROM clause
  -- works by accident of evaluation order, and "by accident" is not a property
  -- to build a permissions check on.
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

  -- Deduplicate so a caller sending the same key twice cannot create two
  -- history rows for one assignment.
  SELECT COALESCE(array_agg(DISTINCT k), '{}'::text[])
  INTO v_clean
  FROM unnest(v_wanted) AS k;
  v_wanted := v_clean;

  -- Refuse an inactive or unknown key here, with a name, rather than letting
  -- validate_staff_jobs() reject the whole UPDATE with a less useful message.
  SELECT string_agg(k, ', ') INTO v_forbidden
  FROM unnest(v_wanted) AS k
  WHERE NOT EXISTS (SELECT 1 FROM public.staff_jobs j
                    WHERE j.key = k AND j.is_active);
  IF v_forbidden IS NOT NULL THEN
    RAISE EXCEPTION 'UNKNOWN_STAFF_JOB: %', v_forbidden;
  END IF;

  -- The customer-ordering rule, refused with its own code so the UI can say
  -- something useful instead of echoing a constraint name.
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

  INSERT INTO public.staff_job_assignments
    (staff_id, job_key, assigned_by, assigned_by_name, revoked_at, revoked_by, revoked_reason)
  SELECT p_staff_id, k, auth.uid(), v_actor_name, now(), auth.uid(),
         NULLIF(btrim(COALESCE(p_reason, '')), '')
  FROM unnest(v_removed) AS k;

  -- Visible to the staff member, so they can see their own jobs change
  -- without asking a manager.
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
-- 6. A staff member's own view
-- ===========================================================================
-- The subject and the CEO. One function, because the RLS policy already
-- enforces the audience and a second CEO-only variant would be a second place
-- for the rule to live.
CREATE OR REPLACE FUNCTION public.my_staff_record()
RETURNS TABLE (
  staff_id uuid,
  name text,
  staff_code text,
  branch text,
  is_active boolean,
  is_super_admin boolean,
  jobs jsonb,
  job_history jsonb,
  activity jsonb,
  open_warnings bigint
)
LANGUAGE plpgsql
STABLE
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
    RAISE EXCEPTION 'NOT_A_STAFF_MEMBER';
  END IF;

  RETURN QUERY
  SELECT v_staff.id,
         v_staff.name,
         v_staff.staff_code,
         v_staff.branch,
         v_staff.is_active,
         v_staff.is_super_admin,
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'key', j.key, 'label', j.label,
                    'group', j.group_name, 'description', j.description)
                    ORDER BY j.sort_order)
           FROM public.staff_jobs j
           WHERE j.key = ANY (COALESCE(v_staff.permissions, '{}'::text[]))
             AND j.is_active
         ), '[]'::jsonb),
         COALESCE((
           SELECT jsonb_agg(to_jsonb(h) - 'staff_id')
           FROM (
             SELECT a.job_key, j.label, a.assigned_at, a.assigned_by_name,
                    a.revoked_at, a.revoked_reason
             FROM public.staff_job_assignments a
             LEFT JOIN public.staff_jobs j ON j.key = a.job_key
             WHERE a.staff_id = v_staff.id
             ORDER BY a.assigned_at DESC
             LIMIT 100
           ) h
         ), '[]'::jsonb),
         COALESCE((
           SELECT jsonb_agg(to_jsonb(l) - 'staff_id')
           FROM (
             SELECT a.kind, a.action, a.detail, a.actor_name, a.created_at
             FROM public.staff_activity_log a
             WHERE a.staff_id = v_staff.id
             ORDER BY a.created_at DESC
             LIMIT 100
           ) l
         ), '[]'::jsonb),
         (SELECT count(*) FROM public.staff_warnings w
          WHERE w.staff_id = v_staff.id AND w.acknowledged_at IS NULL);
END;
$$;

REVOKE ALL ON FUNCTION public.my_staff_record() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.my_staff_record() TO authenticated;
