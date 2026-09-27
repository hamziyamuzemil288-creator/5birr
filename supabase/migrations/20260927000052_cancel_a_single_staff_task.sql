-- Cancel a single staff task — without deleting the staff member and
-- without deleting history.
--
-- WHAT EXISTED
-- ------------
-- staff_task_completions could only record DONE: staff_mark_task_done()
-- writes a row once the underlying work item reaches a terminal state, and
-- the feed reads EXISTS(completion) as "is_completed". There was no way to
-- say "this item must leave THIS person's queue" — the only levers were
-- revoking the permission (hides every task of that kind) or deleting the
-- staff member (the blunt end). The product ask was explicit: the CEO can
-- delete a single task or an entire staff member's task queue.
--
-- WHAT THIS ADDS
-- --------------
--   1. A disposition column on staff_task_completions — DONE (default, so
--      every existing row keeps meaning exactly what it meant) or CANCELLED,
--      plus who cancelled it, when and why. Nothing is hard-deleted; the row
--      IS the audit history, same append-then-update convention as
--      staff_job_assignments (open/closed) and staff_warnings.
--   2. staff_cancel_task(p_task_key, p_staff_id, p_reason) — CEO / Super
--      Admin only, mirroring the view-all gate staff_task_feed already
--      enforces. It re-reads the target's own feed (so the authority to
--      cancel is the authority to see), refuses a task that is already
--      completed, and logs into the staff member's own activity record
--      (kind 'job' — a management decision, not the person's own work).
--   3. staff_task_feed() now filters cancelled rows out of the queue. The
--      filter is in the feed because the feed is the single source of truth:
--      the staff dashboard, the CEO's queue view and staff_progress() all
--      read it, so a cancelled task disappears from all three at once and
--      history stays in the table where an auditor can find it.
--
-- A cancelled task is cancelled for THAT staff member only — the underlying
-- work item (the appeal, the recharge, the registration) still exists and
-- still appears in the admin queues and in every other staff queue. This is
-- queue management, not work-item deletion.
--
-- ALSO FIXED HERE — a dead authorization gate the console would have sat on
-- ------------------------------------------------------------------------
-- staff_task_feed() (and staff_progress(), replaced below) looked v_staff up
-- BY the supplied p_staff_id and then compared p_staff_id <> v_staff.id —
-- which is false by construction, so ONLY_ADMINISTRATORS_CAN_VIEW_OTHER_
-- STAFF_TASKS could never fire. Any authenticated caller could pass someone
-- else's staff id and read that queue (appeal descriptions, registration
-- names, recharge amounts) and progress numbers. The lookup now resolves the
-- CALLER's own staff row and compares against THAT: staff keep their own
-- queue, only a true CEO / Super Admin reaches another, and the exceptions
-- keep their original names so nothing user-facing changes.

-- ===========================================================================
-- 1. The disposition columns
-- ===========================================================================
ALTER TABLE public.staff_task_completions
  ADD COLUMN IF NOT EXISTS disposition text NOT NULL DEFAULT 'DONE'
    CHECK (disposition IN ('DONE', 'CANCELLED')),
  ADD COLUMN IF NOT EXISTS cancelled_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz,
  ADD COLUMN IF NOT EXISTS cancel_reason text;

COMMENT ON COLUMN public.staff_task_completions.disposition IS
  'DONE = the task was completed (the original meaning of a row here). '
  'CANCELLED = a CEO/Super Admin removed it from this staff member''s queue; '
  'the row stays as the audit trail and the feed hides the task.';

-- ===========================================================================
-- 2. The cancel verb
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.staff_cancel_task(
  p_task_key text,
  p_staff_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_task record;
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_CEO_OR_SUPER_ADMIN_CAN_CANCEL_TASKS';
  END IF;
  IF p_task_key IS NULL OR p_staff_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_ID_AND_TASK_KEY_ARE_REQUIRED';
  END IF;

  -- Read the target's own feed: seeing the queue and cancelling from it are
  -- the same authority (staff_task_feed enforces it server-side).
  SELECT * INTO v_task
  FROM public.staff_task_feed(p_staff_id) f
  WHERE f.task_key = p_task_key
  LIMIT 1;
  IF v_task.task_key IS NULL THEN
    RAISE EXCEPTION 'TASK_NOT_FOUND_OR_NOT_PERMITTED';
  END IF;
  IF v_task.is_completed THEN
    RAISE EXCEPTION 'TASK_ALREADY_COMPLETED';
  END IF;

  INSERT INTO public.staff_task_completions
    (staff_id, task_key, source_type, source_id, completed_at, terminal_at,
     disposition, cancelled_by, cancelled_at, cancel_reason)
  VALUES
    (p_staff_id, v_task.task_key, v_task.source_type, v_task.source_id,
     now(), v_task.terminal_at,
     'CANCELLED', v_actor, now(),
     NULLIF(btrim(coalesce(p_reason, '')), ''))
  ON CONFLICT (staff_id, task_key) DO UPDATE
    SET disposition = 'CANCELLED',
        cancelled_by = EXCLUDED.cancelled_by,
        cancelled_at = EXCLUDED.cancelled_at,
        cancel_reason = EXCLUDED.cancel_reason;

  -- The staff member's own record (readable by them and the CEO) shows why
  -- the task left their queue. Kind 'job' = a management decision about
  -- their work, not something they did.
  PERFORM public.log_staff_activity(
    p_staff_id,
    'task_cancelled',
    jsonb_build_object(
      'task_key', p_task_key,
      'cancelled_by', v_actor,
      'reason', NULLIF(btrim(coalesce(p_reason, '')), '')
    ),
    'job'
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_cancel_task(text, uuid, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.staff_cancel_task(text, uuid, text)
  TO authenticated;

-- ===========================================================================
-- 3. The feed hides cancelled rows
-- ===========================================================================
-- Full CREATE OR REPLACE of the single definition (20260924000005): two
-- changes — the caller-identity gate from the header note, and a final SELECT
-- that drops any task this staff member has a CANCELLED row for. Permission
-- scoping, category scoping and the five sources are byte-for-byte the same.

CREATE OR REPLACE FUNCTION public.staff_task_feed(
  p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE (
  task_key text,
  source_type text,
  source_id uuid,
  title text,
  description text,
  required_permission text,
  status text,
  is_terminal boolean,
  is_completed boolean,
  action_route text,
  category_id uuid,
  created_at timestamptz,
  terminal_at timestamptz,
  completed_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
  v_caller public.staff;
  v_view_all boolean;
BEGIN
  -- The CALLER's own staff row is the authority to view any queue. Resolving
  -- it separately from the target is what makes the comparison below
  -- meaningful (see the header note: comparing p_staff_id against a row that
  -- was looked up BY p_staff_id can never differ).
  SELECT * INTO v_caller FROM public.staff
  WHERE user_id = v_actor AND is_active LIMIT 1;

  IF p_staff_id IS NULL THEN
    v_staff := v_caller;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND_OR_INACTIVE';
  END IF;
  IF p_staff_id IS NOT NULL
     AND (v_caller.id IS NULL OR p_staff_id <> v_caller.id)
     AND NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_OTHER_STAFF_TASKS';
  END IF;

  -- is_admin() alone includes linked staff, so task visibility intentionally
  -- uses only the true CEO and Super Admin exceptions here.
  v_view_all := public.is_ceo() OR public.is_super_admin();

  RETURN QUERY
  WITH tasks AS (
    SELECT
      'approval:' || a.subject_type::text || ':' || a.subject_id::text AS task_key,
      'REGISTRATION'::text AS source_type,
      a.subject_id AS source_id,
      CASE WHEN a.subject_type = 'PROVIDER'
           THEN 'Approve provider registration'
           ELSE 'Approve user registration' END::text AS title,
      COALESCE(pp.business_name, us.full_name, 'Registration request')::text AS description,
      'registrations'::text AS required_permission,
      a.status::text AS status,
      a.status IN ('APPROVED', 'REJECTED', 'SUSPENDED', 'INACTIVE') AS is_terminal,
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key =
                    'approval:' || a.subject_type::text || ':' || a.subject_id::text) AS is_completed,
      CASE WHEN a.subject_type = 'PROVIDER'
           THEN '/admin/approvals' ELSE '/admin/users' END::text AS action_route,
      pp.category_id,
      a.created_at,
      CASE WHEN a.status IN ('APPROVED', 'REJECTED', 'SUSPENDED', 'INACTIVE')
           THEN a.created_at ELSE NULL END AS terminal_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key =
             'approval:' || a.subject_type::text || ':' || a.subject_id::text) AS completed_at
    FROM (
      SELECT DISTINCT ON (subject_type, subject_id) *
      FROM public.approval_requests
      ORDER BY subject_type, subject_id, created_at DESC
    ) a
    LEFT JOIN public.profiles us ON a.subject_type = 'USER' AND us.id = a.subject_id
    LEFT JOIN public.provider_profiles pp ON a.subject_type = 'PROVIDER' AND pp.id = a.subject_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'registrations'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))

    UNION ALL
    SELECT
      'support:' || t.id::text, 'SUPPORT_TICKET', t.id,
      COALESCE(NULLIF(t.subject, ''), 'Support ticket'),
      COALESCE(t.description, ''), 'support_chat', t.status,
      t.status IN ('RESOLVED', 'CLOSED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'support:' || t.id::text),
      '/admin/support-tickets', NULL, t.created_at, t.resolved_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'support:' || t.id::text)
    FROM public.support_tickets t
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'support_chat'))

    UNION ALL
    SELECT
      'appeal:' || a.id::text, 'APPEAL', a.id,
      'Resolve user appeal',
      COALESCE(a.description, ''), 'support_chat', a.status,
      a.status IN ('RESOLVED', 'CLOSED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'appeal:' || a.id::text),
      '/admin/appeals', NULL, a.created_at, a.resolved_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'appeal:' || a.id::text)
    FROM public.appeal_cases a
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'support_chat'))

    UNION ALL
    SELECT
      'recharge:' || r.id::text, 'WALLET_RECHARGE', r.id,
      'Review wallet recharge',
      format('ETB %s recharge request', r.amount), 'payment_verification', r.status::text,
      r.status IN ('APPROVED', 'REJECTED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'recharge:' || r.id::text),
      '/admin/payments', pp.category_id, r.created_at,
      COALESCE(r.approved_at, r.updated_at),
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'recharge:' || r.id::text)
    FROM public.wallet_recharge_requests r
    LEFT JOIN public.provider_profiles pp ON pp.id = r.provider_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'payment_verification'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))

    UNION ALL
    SELECT
      'payment-proof:' || p.id::text, 'PAYMENT_PROOF', p.id,
      'Verify order payment proof',
      COALESCE(p.storage_path, 'Payment proof'), 'payment_verification',
      p.verification_status, p.verification_status IN ('VERIFIED', 'REJECTED'),
      EXISTS (SELECT 1 FROM public.staff_task_completions c
              WHERE c.staff_id = v_staff.id AND c.task_key = 'payment-proof:' || p.id::text),
      '/admin/payments', pp.category_id, p.created_at, p.verified_at,
      (SELECT c.completed_at FROM public.staff_task_completions c
       WHERE c.staff_id = v_staff.id AND c.task_key = 'payment-proof:' || p.id::text)
    FROM public.payment_proofs p
    JOIN public.orders o ON o.id = p.order_id
    LEFT JOIN public.provider_profiles pp ON pp.id = o.provider_id
    WHERE (v_view_all OR public.staff_has_permission(v_staff.user_id, 'payment_verification'))
      AND (v_view_all OR public.staff_scope_allows_category(pp.category_id, v_staff.user_id))
  ) t
  -- A cancelled row means "this must leave THIS person's queue": filter the
  -- task out entirely. The completion row itself stays (audit history), and
  -- staff_progress() reads this same feed, so cancelled tasks drop out of
  -- the denominator too — they were never completed, and are no longer due.
  WHERE NOT EXISTS (
    SELECT 1 FROM public.staff_task_completions c
    WHERE c.staff_id = v_staff.id
      AND c.disposition = 'CANCELLED'
      AND c.task_key = t.task_key
  )
  ORDER BY t.is_completed, t.is_terminal, t.created_at DESC;
END;
$$;

-- ===========================================================================
-- 4. staff_progress(): same dead gate, same fix
-- ===========================================================================
-- Only the lookup/gate changes — the aggregation below is byte-for-byte the
-- original. staff_progress() reads the feed, so after this migration it
-- counts cancelled tasks out of the totals automatically.

CREATE OR REPLACE FUNCTION public.staff_progress(
  p_staff_id uuid DEFAULT NULL
)
RETURNS TABLE (
  completed_tasks bigint,
  remaining_tasks bigint,
  total_tasks bigint,
  progress_percent numeric,
  average_resolution_hours numeric,
  completed_last_30_days bigint,
  last_activity_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_staff public.staff;
  v_caller public.staff;
BEGIN
  SELECT * INTO v_caller FROM public.staff
  WHERE user_id = v_actor AND is_active LIMIT 1;

  IF p_staff_id IS NULL THEN
    v_staff := v_caller;
  ELSE
    SELECT * INTO v_staff FROM public.staff
    WHERE id = p_staff_id AND is_active LIMIT 1;
  END IF;
  IF v_staff.id IS NULL OR (
    p_staff_id IS NOT NULL
    AND (v_caller.id IS NULL OR p_staff_id <> v_caller.id)
    AND NOT (public.is_ceo() OR public.is_super_admin())
  ) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_PROGRESS';
  END IF;

  RETURN QUERY
  WITH feed AS (
    SELECT * FROM public.staff_task_feed(v_staff.id)
  )
  SELECT
    count(*) FILTER (WHERE is_completed),
    count(*) FILTER (WHERE NOT is_completed),
    count(*),
    CASE WHEN count(*) = 0 THEN 0
         ELSE round(100.0 * count(*) FILTER (WHERE is_completed) / count(*), 1)
    END,
    COALESCE(avg(extract(epoch FROM (terminal_at - created_at)) / 3600.0)
      FILTER (WHERE is_completed AND terminal_at IS NOT NULL), 0),
    count(*) FILTER (WHERE is_completed AND completed_at >= now() - interval '30 days'),
    max(completed_at)
  FROM feed;
END;
$$;

-- New function + new columns: refresh PostgREST's schema cache (house
-- convention since 20260927000049).
NOTIFY pgrst, 'reload schema';
