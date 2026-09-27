-- Staff warnings, and a task feed that updates itself.
--
-- WHAT WAS MISSING
-- ----------------
-- The CEO's staff console could see progress, change permissions, assign
-- categories, revoke, and delete. It could NOT send a warning — the word did
-- not exist anywhere in the schema. Revoking is the blunt end (access gone,
-- reversible); there was nothing in between for "this is not acceptable and
-- here is why", which is the message a manager actually needs to send.
--
-- And the staff workspace showed a SNAPSHOT. staff_task_feed() is derived from
-- five live tables, but the dashboard loaded it once in initState with a manual
-- refresh button. A staff member watching the screen while work arrived into
-- their queue saw nothing until they thought to pull. The user's brief was
-- explicit: the interface must be connected to the assigned task immediately.
--
-- WHY A PUBLICATION CHANGE IS THE WHOLE FIX FOR THE SECOND ONE
-- ----------------------------------------------------------
-- The feed reads approval_requests, support_tickets, appeal_cases,
-- wallet_recharge_requests and payment_proofs. None of them was in the
-- supabase_realtime publication — 0041 added ride_requests and deliberately
-- left the rest out, and 20260925210000 had to add driver_status by hand for
-- the same reason (the rider's driver pin never moved). Without the tables
-- published, a client subscription is a silent no-op, so the Dart side and
-- this file have to land together.
--
-- Reassignment is left out on purpose. Reassigning a staff member's work would
-- need a real ownership column on each work item; nothing here pretends to
-- offer it.

-- ===========================================================================
-- 1. Publish the task-feed sources
-- ===========================================================================
-- Guarded, because `ALTER PUBLICATION ... ADD TABLE` has no IF NOT EXISTS and
-- re-running this migration would otherwise abort the whole push.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'approval_requests', 'support_tickets', 'appeal_cases',
    'wallet_recharge_requests', 'payment_proofs'
  ]
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime'
        AND schemaname = 'public'
        AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END;
$$;

-- ===========================================================================
-- 2. Warnings
-- ===========================================================================
-- Deliberately NOT a status column on staff. A warning is an event with a
-- reason, an author and a time; overloading is_active with it would destroy
-- the difference between "told off" and "access removed", which is exactly the
-- distinction revoke_staff already draws correctly.
CREATE TABLE IF NOT EXISTS public.staff_warnings (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  warned_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  warned_by_name text,
  reason text NOT NULL CHECK (length(btrim(reason)) BETWEEN 3 AND 1000),
  severity text NOT NULL DEFAULT 'WARNING'
    CHECK (severity IN ('WARNING', 'SERIOUS')),
  -- Set by the STAFF member, not the manager. An unacknowledged warning that
  -- the person never saw is not a warning, it is a note in a drawer.
  acknowledged_at timestamptz,
  acknowledged_note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_warnings_staff
  ON public.staff_warnings (staff_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staff_warnings_open
  ON public.staff_warnings (staff_id) WHERE acknowledged_at IS NULL;

ALTER TABLE public.staff_warnings ENABLE ROW LEVEL SECURITY;

-- The subject reads their own warnings; a manager reads anyone's. No INSERT,
-- UPDATE or DELETE policy at all: every write goes through warn_staff() or
-- acknowledge_staff_warning(), both of which re-check the caller.
DROP POLICY IF EXISTS staff_warnings_read ON public.staff_warnings;
CREATE POLICY staff_warnings_read ON public.staff_warnings FOR SELECT
  USING (
    EXISTS (SELECT 1 FROM public.staff s
            WHERE s.id = staff_id AND s.user_id = auth.uid())
    OR public.is_ceo()
    OR public.is_super_admin()
  );

REVOKE ALL ON public.staff_warnings FROM anon;
GRANT SELECT ON public.staff_warnings TO authenticated;

-- ===========================================================================
-- 3. The manager's side: warn_staff
-- ===========================================================================
-- The same posture as every other staff_* RPC in this codebase: the UI gate is
-- not security, so the authority is re-checked here against auth.uid().
--
-- SECURITY DEFINER is required only to write the row and the audit entry; the
-- check itself is explicit, and the function never consults current_user —
-- inside a SECURITY DEFINER body that is the function OWNER, which is how the
-- 0029/0030/0033/0034 guards shipped inert.
CREATE OR REPLACE FUNCTION public.warn_staff(
  p_staff_id uuid,
  p_reason text,
  p_severity text DEFAULT 'WARNING'
)
RETURNS public.staff_warnings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_staff public.staff;
  v_row public.staff_warnings;
  v_actor_name text;
  v_severity text := upper(btrim(coalesce(p_severity, 'WARNING')));
BEGIN
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_WARN_STAFF';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'WARNING_REASON_REQUIRED';
  END IF;
  IF v_severity NOT IN ('WARNING', 'SERIOUS') THEN
    RAISE EXCEPTION 'INVALID_WARNING_SEVERITY';
  END IF;

  SELECT * INTO v_staff
  FROM public.staff
  WHERE id = p_staff_id AND is_active;
  IF v_staff.id IS NULL THEN
    -- The row is genuinely gone or deactivated rather than merely hidden: the
    -- caller asked about a specific person and deserves to know which.
    RAISE EXCEPTION 'STAFF_NOT_FOUND_OR_INACTIVE';
  END IF;
  IF v_staff.is_ceo THEN
    -- The CEO row is the top of the hierarchy; a warning aimed at it can only
    -- be a mistake, and revoke/delete already refuse it for the same reason.
    RAISE EXCEPTION 'CANNOT_WARN_THE_CEO';
  END IF;

  SELECT COALESCE(full_name, '(admin)') INTO v_actor_name
  FROM public.profiles WHERE id = auth.uid();

  INSERT INTO public.staff_warnings (staff_id, warned_by, warned_by_name, reason, severity)
  VALUES (p_staff_id, auth.uid(), v_actor_name, btrim(p_reason), v_severity)
  RETURNING * INTO v_row;

  PERFORM public.log_admin_action(
    auth.uid(), 'STAFF_WARNED', p_staff_id, 'staff', NULL,
    '{}'::text[],
    jsonb_build_object('severity', v_severity, 'reason', btrim(p_reason))
  );

  -- The warning has to REACH them. A row in a table the staff workspace never
  -- reads would repeat the original defect in a new shape.
  IF v_staff.user_id IS NOT NULL THEN
    INSERT INTO public.notifications (user_id, type, title, body)
    VALUES (
      v_staff.user_id,
      'ADMIN_MESSAGE'::public.notification_type,
      CASE WHEN v_severity = 'SERIOUS'
           THEN 'A serious warning from management' ELSE 'A warning from management' END,
      btrim(p_reason)
    );
  END IF;

  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.warn_staff(uuid, text, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.warn_staff(uuid, text, text) TO authenticated;

-- ===========================================================================
-- 4. The staff member's side: acknowledge_staff_warning
-- ===========================================================================
-- Separate from warn_staff on purpose. Letting the manager set
-- acknowledged_at would make the column a record of what the manager believed
-- rather than what the person did, and the whole point of the field is that it
-- proves the warning was seen.
CREATE OR REPLACE FUNCTION public.acknowledge_staff_warning(
  p_warning_id uuid,
  p_note text DEFAULT NULL
)
RETURNS public.staff_warnings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.staff_warnings;
BEGIN
  UPDATE public.staff_warnings
  SET acknowledged_at = now(),
      acknowledged_note = NULLIF(btrim(coalesce(p_note, '')), '')
  WHERE id = p_warning_id
    AND EXISTS (SELECT 1 FROM public.staff s
                WHERE s.id = staff_warnings.staff_id
                  AND s.user_id = auth.uid())
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'WARNING_NOT_FOUND_OR_NOT_YOURS';
  END IF;
  RETURN v_row;
END;
$$;

REVOKE ALL ON FUNCTION public.acknowledge_staff_warning(uuid, text)
  FROM public, anon;
GRANT EXECUTE ON FUNCTION public.acknowledge_staff_warning(uuid, text)
  TO authenticated;

-- ===========================================================================
-- 5. A manager's roll-up across the whole team
-- ===========================================================================
-- The CEO's question is "who is in trouble", which is a question about every
-- staff member at once. Without this the console can only open one person at a
-- time, which is not a control surface.
CREATE OR REPLACE FUNCTION public.staff_warning_summary()
RETURNS TABLE (
  staff_id uuid,
  staff_name text,
  open_warnings bigint,
  serious_open bigint,
  last_warned_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT (public.is_ceo() OR public.is_super_admin()) THEN
    RAISE EXCEPTION 'ONLY_ADMINISTRATORS_CAN_VIEW_STAFF_WARNINGS';
  END IF;

  RETURN QUERY
  SELECT s.id,
         s.name,
         count(w.id) FILTER (WHERE w.acknowledged_at IS NULL),
         count(w.id) FILTER (WHERE w.acknowledged_at IS NULL
                               AND w.severity = 'SERIOUS'),
         max(w.created_at)
  FROM public.staff s
  LEFT JOIN public.staff_warnings w ON w.staff_id = s.id
  WHERE s.is_active
  GROUP BY s.id, s.name
  ORDER BY count(w.id) FILTER (WHERE w.acknowledged_at IS NULL) DESC, s.name;
END;
$$;

REVOKE ALL ON FUNCTION public.staff_warning_summary() FROM public, anon;
GRANT EXECUTE ON FUNCTION public.staff_warning_summary() TO authenticated;

-- ===========================================================================
-- 6. Assertion
-- ===========================================================================
-- Behavioural where it can be. The escalation shape — a client calling
-- warn_staff directly to write its own row — is the one a source-text check
-- cannot answer, and it is exactly the shape that shipped inert four times in
-- this schema.
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
  VALUES (v_user, 'Warning Probe', 'APPROVED')
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

COMMENT ON FUNCTION public.assert_staff_warnings_are_admin_only() IS
  'Attempts to write a staff warning as a non-manager, directly and through '
  'warn_staff(), and requires both refusals plus a refusal to acknowledge a '
  'warning that is not the caller''s.';

GRANT EXECUTE ON FUNCTION public.assert_staff_warnings_are_admin_only()
  TO anon, authenticated;

-- The publication half, read against pg_publication_tables rather than the
-- migration text: a table dropped from the publication later would leave the
-- Dart subscription silently dead, which is the exact failure 0041 and
-- 20260925210000 both shipped.
CREATE OR REPLACE FUNCTION public.assert_staff_task_sources_are_live()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  v_missing text[];
BEGIN
  SELECT array_agg(t) INTO v_missing
  FROM unnest(ARRAY[
    'approval_requests', 'support_tickets', 'appeal_cases',
    'wallet_recharge_requests', 'payment_proofs'
  ]) AS t
  WHERE NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = t
  );

  IF v_missing IS NULL THEN
    RETURN true;  -- none missing
  END IF;
  RAISE EXCEPTION
    'these staff task-feed tables are not in the supabase_realtime publication, so the staff workspace will silently stop updating: %',
    array_to_string(v_missing, ', ');
END;
$$;

COMMENT ON FUNCTION public.assert_staff_task_sources_are_live() IS
  'Raises with the offending table names unless every source behind '
  'staff_task_feed() is in the supabase_realtime publication, so a dead '
  'subscription fails CI instead of shipping as a screen that never updates.';

GRANT EXECUTE ON FUNCTION public.assert_staff_task_sources_are_live()
  TO anon, authenticated;
