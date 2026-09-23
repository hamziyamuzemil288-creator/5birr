-- Appeal cases: user-submitted appeal / spam-report cases with an evidence
-- photo, description and contact details, reviewed and resolved by admins
-- (and support staff) from the admin dashboard.
--
-- Distinct from the existing `appeals` table (0022a), which models account
-- reinstatement cases tied to a related entity — that table and its policies
-- are intentionally left untouched.

-- ── Table ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.appeal_cases (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  photo_path text NOT NULL,
  description text NOT NULL CHECK (length(btrim(description)) > 0),
  phone text NOT NULL CHECK (length(btrim(phone)) > 0),
  email text,
  status text NOT NULL DEFAULT 'OPEN' CHECK (status IN ('OPEN','RESOLVED','CLOSED')),
  resolution_note text,
  resolved_by uuid REFERENCES auth.users(id),
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_appeal_cases_user ON public.appeal_cases(user_id);
CREATE INDEX IF NOT EXISTS idx_appeal_cases_status_created ON public.appeal_cases(status, created_at DESC);

ALTER TABLE public.appeal_cases ENABLE ROW LEVEL SECURITY;

-- ── RLS: owner, admin, and support-chat staff (same gate as support_tickets) ──
DO $$ BEGIN CREATE POLICY appeal_cases_owner_select ON public.appeal_cases FOR SELECT
  USING (user_id = auth.uid() OR public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN CREATE POLICY appeal_cases_owner_insert ON public.appeal_cases FOR INSERT
  WITH CHECK (user_id = auth.uid());
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- Users cannot edit their own cases after submission; admins/staff resolve.
DO $$ BEGIN CREATE POLICY appeal_cases_admin_update ON public.appeal_cases FOR UPDATE
  USING (public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'))
  WITH CHECK (public.is_admin() OR public.staff_has_permission(auth.uid(), 'support_chat'));
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- No DELETE policy: cases are never destroyed, only closed.

-- ── Resolution audit: every resolve/close writes an admin_actions row ──────
CREATE OR REPLACE FUNCTION public.on_appeal_case_resolved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.status IN ('RESOLVED','CLOSED') AND (OLD.status IS NULL OR OLD.status NOT IN ('RESOLVED','CLOSED')) THEN
    INSERT INTO public.admin_actions (admin_id, action, target_type, target_id, details)
    VALUES (
      auth.uid(),
      'APPEAL_CASE_' || NEW.status,
      'appeal_case',
      NEW.id,
      jsonb_build_object('resolution_note', NEW.resolution_note)
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_appeal_case_resolved ON public.appeal_cases;
CREATE TRIGGER trg_appeal_case_resolved
  AFTER UPDATE ON public.appeal_cases
  FOR EACH ROW EXECUTE FUNCTION public.on_appeal_case_resolved();

GRANT SELECT, INSERT, UPDATE ON public.appeal_cases TO authenticated;

-- staff_has_permission keeps p_permission defaulted (NULL → fail closed) per
-- the 42P13 fix in migration 20260922000010; it is called with an explicit
-- permission above.
