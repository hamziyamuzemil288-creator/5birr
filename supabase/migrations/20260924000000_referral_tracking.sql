-- Task 8 — Referral code tracking for provider/vehicle registration.
--
-- Purely additive. Three parts:
--   1. referral_codes table: admin-issued codes, each mapped to one staff
--      person (name + id resolve through staff). One person may hold several
--      codes (no campaign layer — issued per person on demand).
--   2. provider_profiles columns: the raw code as typed, the resolved
--      staff id, and a denormalized staff name snapshot (survives staff-row
--      deletion). All three NULL = self-registered; raw code kept but
--      staff_id NULL = "Other" (code didn't match a known person).
--   3. RPCs:
--        validate_referral_code(code)  — anon, signup-form live lookup only.
--        admin_referral_codes(...)     — admin CRUD helpers for the staff
--                                        screens (list / issue / deactivate),
--                                        gated by admin_can('registrations').
--        admin_registration_history()  — the full registration history with
--                                        channel + confirmation derivation,
--                                        gated by admin_can('registrations').
--
-- RLS: referral_codes is readable ONLY by admins (is_admin()). Signup-time
-- resolution happens inside handle_new_user() (security definer), so no
-- anon read policy exists. validate_referral_code leaks exactly one string:
-- the staff display name for a valid code.

-- ============================================================
-- 1. referral_codes
-- ============================================================
CREATE TABLE IF NOT EXISTS public.referral_codes (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  code text NOT NULL UNIQUE,
  staff_id uuid NOT NULL REFERENCES public.staff(id) ON DELETE CASCADE,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_referral_codes_staff
  ON public.referral_codes (staff_id);

ALTER TABLE public.referral_codes ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies
                 WHERE schemaname = 'public' AND tablename = 'referral_codes'
                   AND policyname = 'referral_codes_admin_read') THEN
    CREATE POLICY referral_codes_admin_read ON public.referral_codes
      FOR SELECT TO authenticated
      USING (public.is_admin());
  END IF;
END $$;

-- ============================================================
-- 2. provider_profiles referral columns
-- ============================================================
ALTER TABLE public.provider_profiles
  ADD COLUMN IF NOT EXISTS referral_code text,
  ADD COLUMN IF NOT EXISTS referred_by_staff_id uuid REFERENCES public.staff(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS referred_by_name text;

CREATE INDEX IF NOT EXISTS idx_provider_profiles_referrer
  ON public.provider_profiles (referred_by_staff_id)
  WHERE referred_by_staff_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_provider_profiles_referral_code
  ON public.provider_profiles (referral_code)
  WHERE referral_code IS NOT NULL;

-- ============================================================
-- 3a. validate_referral_code — signup-form live lookup (anon)
-- ============================================================
-- Returns the referrer display name, or NULL when the code is unknown or
-- inactive. Exposes nothing else; anonymous callers get one string.
CREATE OR REPLACE FUNCTION public.validate_referral_code(p_code text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT s.name
  FROM public.referral_codes c
  JOIN public.staff s ON s.id = c.staff_id
  WHERE upper(btrim(c.code)) = upper(btrim(p_code))
    AND c.is_active
    AND s.is_active
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.validate_referral_code(text) TO anon, authenticated;

-- ============================================================
-- 3b. Admin referral-code management
-- ============================================================
-- List every code with its staff person and usage count.
CREATE OR REPLACE FUNCTION public.admin_referral_codes()
RETURNS TABLE (
  id uuid,
  code text,
  staff_id uuid,
  staff_name text,
  staff_code text,
  is_active boolean,
  uses bigint,
  created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.id, c.code, s.id, s.name, s.staff_code, c.is_active,
         (SELECT count(*) FROM public.provider_profiles p
           WHERE p.referred_by_staff_id = s.id
             AND p.referral_code = c.code),
         c.created_at
  FROM public.referral_codes c
  JOIN public.staff s ON s.id = c.staff_id
  WHERE public.admin_can('registrations')
  ORDER BY c.created_at DESC;
$$;

-- Issue a new code for an existing staff person. Code is normalized to
-- uppercase; duplicates (case-insensitive) are rejected by the unique index.
CREATE OR REPLACE FUNCTION public.admin_issue_referral_code(
  p_staff_id uuid,
  p_code text
)
RETURNS public.referral_codes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text := upper(btrim(p_code));
  v_row public.referral_codes;
BEGIN
  IF NOT public.admin_can('registrations') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;
  IF v_code IS NULL OR length(v_code) < 3 OR length(v_code) > 40 THEN
    RAISE EXCEPTION 'INVALID_CODE';
  END IF;
  IF v_code !~ '^[A-Z0-9._-]+$' THEN
    RAISE EXCEPTION 'INVALID_CODE';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.staff WHERE id = p_staff_id AND is_active) THEN
    RAISE EXCEPTION 'STAFF_NOT_FOUND';
  END IF;

  INSERT INTO public.referral_codes (code, staff_id, created_by)
  VALUES (v_code, p_staff_id, auth.uid())
  RETURNING * INTO v_row;

  PERFORM public.log_admin_action(auth.uid(), 'REFERRAL_CODE_ISSUED', v_row.id,
    'referral', NULL, '{}',
    jsonb_build_object('code', v_code, 'staff_id', p_staff_id));
  RETURN v_row;
END;
$$;

-- Deactivate (or re-activate) a code. Deactivation keeps historical
-- registrations intact; the code simply stops validating for new signups.
CREATE OR REPLACE FUNCTION public.admin_set_referral_code_active(
  p_code_id uuid,
  p_active boolean
)
RETURNS public.referral_codes
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row public.referral_codes;
BEGIN
  IF NOT public.admin_can('registrations') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;
  UPDATE public.referral_codes
    SET is_active = p_active
    WHERE id = p_code_id
    RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'CODE_NOT_FOUND';
  END IF;
  PERFORM public.log_admin_action(auth.uid(), 'REFERRAL_CODE_UPDATED', v_row.id,
    'referral', NULL, '{}', jsonb_build_object('is_active', p_active));
  RETURN v_row;
END;
$$;

-- Delete a code entirely (allowed — registrations keep the denormalized
-- referred_by_name so history never loses the person).
CREATE OR REPLACE FUNCTION public.admin_delete_referral_code(p_code_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_code text;
BEGIN
  IF NOT public.admin_can('registrations') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;
  SELECT code INTO v_code FROM public.referral_codes WHERE id = p_code_id;
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'CODE_NOT_FOUND';
  END IF;
  DELETE FROM public.referral_codes WHERE id = p_code_id;
  PERFORM public.log_admin_action(auth.uid(), 'REFERRAL_CODE_DELETED', p_code_id,
    'referral', NULL, '{}', jsonb_build_object('code', v_code));
END;
$$;

-- ============================================================
-- 3c. admin_registration_history — one row per registration with the
--     channel + confirmation categorizations Task 8 requires.
-- ============================================================
-- Channel:
--   SELF_REGISTERED        referral_code IS NULL
--   SALES_REGISTERED       referral_code matched an active code at signup
--   OTHER                  referral_code kept but no staff match
-- Confirmation (derived from status + approval_history, no new columns):
--   SYSTEM_CONFIRMED       APPROVED and the approving approval_history row
--                          has performed_by IS NULL (document-verify agent;
--                          user-level approval is authoritative so a QR-
--                          approved provider never sits in Pending forever)
--   STAFF_CONFIRMED        APPROVED and performed_by is set → joined to
--                          staff for the confirming staff_code (falls back
--                          to admin_history actor_name / profile name)
--   PENDING                status = PENDING_APPROVAL
--   REJECTED               status = REJECTED (kept for completeness)
CREATE OR REPLACE FUNCTION public.admin_registration_history(
  p_channel text DEFAULT NULL,       -- 'SELF' | 'SALES' | 'OTHER' | NULL=all
  p_confirmation text DEFAULT NULL,  -- 'SYSTEM' | 'STAFF' | 'PENDING' | 'REJECTED' | NULL=all
  p_staff_id uuid DEFAULT NULL,      -- filter by the registering sales person
  p_confirmed_by_staff_id uuid DEFAULT NULL, -- filter by confirming staff
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL,
  p_limit int DEFAULT 500
)
RETURNS TABLE (
  record_id uuid,
  record_type text,                  -- 'USER' | 'VEHICLE_PROVIDER' | 'SERVICE_PROVIDER'
  display_name text,
  contact text,
  status text,
  referral_code text,
  referrer_staff_id uuid,
  referrer_name text,
  channel text,
  confirmation text,
  confirmed_by_staff_code text,
  confirmed_by_name text,
  confirmed_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.admin_can('registrations') THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  RETURN QUERY
  WITH latest AS (
    -- Latest non-null decision per subject; the document-verify agent
    -- inserts performed_by NULL + reason 'QR verification agent'.
    SELECT DISTINCT ON (h.subject_type, h.subject_id)
           h.subject_type, h.subject_id, h.action, h.performed_by, h.created_at
    FROM public.approval_history h
    WHERE h.action IN ('APPROVE', 'REJECT')
    ORDER BY h.subject_type, h.subject_id, h.created_at DESC
  ),
  provider_rows AS (
    SELECT pp.id AS provider_id, pp.user_id, pp.provider_type::text AS ptype,
           COALESCE(pp.business_name, pr.full_name, 'New Provider') AS dname,
           COALESCE(pr.phone, pr.email, '') AS contact,
           pp.status::text AS pstatus,
           pp.referral_code, pp.referred_by_staff_id, pp.referred_by_name,
           pp.created_at, pr.full_name AS owner_name, pr.status AS user_status
    FROM public.provider_profiles pp
    LEFT JOIN public.profiles pr ON pr.id = pp.user_id
    WHERE (p_start IS NULL OR pp.created_at >= p_start)
      AND (p_end   IS NULL OR pp.created_at <  p_end)
  ),
  staff_resolve AS (
    SELECT s.user_id, s.id AS s_id, s.name AS s_name, s.staff_code AS s_code
    FROM public.staff s
  )
  SELECT
    r.provider_id,
    r.ptype,
    r.dname,
    r.contact,
    -- The USER row's status is authoritative when the QR agent approved the
    -- account but the provider_profiles row still says PENDING.
    (CASE WHEN r.user_status = 'APPROVED' THEN r.user_status::text ELSE r.pstatus::text END) AS status_out,
    r.referral_code,
    r.referred_by_staff_id,
    r.referred_by_name,
    CASE
      WHEN r.referral_code IS NULL OR btrim(r.referral_code) = '' THEN 'SELF'
      WHEN r.referred_by_staff_id IS NOT NULL THEN 'SALES'
      ELSE 'OTHER'
    END AS channel_out,
    CASE
      WHEN r.user_status = 'APPROVED' AND l.performed_by IS NULL THEN 'SYSTEM'
      WHEN r.user_status = 'APPROVED' OR r.pstatus = 'APPROVED' THEN 'STAFF'
      WHEN r.user_status = 'REJECTED' OR r.pstatus = 'REJECTED' THEN 'REJECTED'
      ELSE 'PENDING'
    END AS confirmation_out,
    CASE WHEN (r.user_status = 'APPROVED' AND l.performed_by IS NULL)
              OR (r.user_status = 'APPROVED' OR r.pstatus = 'APPROVED') IS NULL
         THEN NULL ELSE cs.s_code END AS confirmed_code_out,
    CASE WHEN (r.user_status = 'APPROVED' AND l.performed_by IS NULL)
              OR (r.user_status = 'APPROVED' OR r.pstatus = 'APPROVED') IS NULL
         THEN NULL ELSE COALESCE(cs.s_name, ah.actor_name) END AS confirmed_name_out,
    CASE WHEN r.user_status = 'APPROVED' AND l.performed_by IS NULL THEN l.created_at
         WHEN r.user_status = 'APPROVED' OR r.pstatus = 'APPROVED' THEN l.created_at
         ELSE NULL END AS confirmed_at_out,
    r.created_at
  FROM provider_rows r
  LEFT JOIN latest l
    ON l.subject_type IN ('PROVIDER', 'USER')
   AND (l.subject_id = r.provider_id OR l.subject_id = r.user_id)
  LEFT JOIN staff_resolve cs ON cs.user_id = l.performed_by
  LEFT JOIN LATERAL (
    SELECT a.actor_name FROM public.admin_history a
    WHERE a.related_record_id = r.provider_id
      AND a.action_type = 'APPROVE_PROVIDER'
    ORDER BY a.created_at DESC LIMIT 1
  ) ah ON ah.actor_name IS NOT NULL
  WHERE
    (p_channel IS NULL
      OR (p_channel = 'SELF'  AND (r.referral_code IS NULL OR btrim(r.referral_code) = ''))
      OR (p_channel = 'SALES' AND r.referred_by_staff_id IS NOT NULL)
      OR (p_channel = 'OTHER' AND r.referral_code IS NOT NULL AND btrim(r.referral_code) <> ''
          AND r.referred_by_staff_id IS NULL))
    AND (p_confirmation IS NULL
      OR (p_confirmation = 'SYSTEM'   AND r.user_status = 'APPROVED' AND l.performed_by IS NULL)
      OR (p_confirmation = 'STAFF'    AND (r.user_status = 'APPROVED' OR r.pstatus = 'APPROVED')
                                      AND NOT (r.user_status = 'APPROVED' AND l.performed_by IS NULL))
      OR (p_confirmation = 'PENDING'  AND r.user_status <> 'APPROVED'
                                      AND r.pstatus NOT IN ('APPROVED','REJECTED'))
      OR (p_confirmation = 'REJECTED' AND (r.user_status = 'REJECTED' OR r.pstatus = 'REJECTED')))
    AND (p_staff_id IS NULL OR r.referred_by_staff_id = p_staff_id)
    AND (p_confirmed_by_staff_id IS NULL OR cs.s_id = p_confirmed_by_staff_id)
  UNION ALL
  SELECT
    pr.id,
    'USER'::text,
    pr.full_name,
    COALESCE(pr.phone, pr.email, ''),
    pr.status::text,
    NULL::text, NULL::uuid, NULL::text,
    'SELF'::text,
    CASE
      WHEN pr.status = 'APPROVED' AND l2.performed_by IS NULL THEN 'SYSTEM'
      WHEN pr.status = 'APPROVED' THEN 'STAFF'
      WHEN pr.status = 'REJECTED' THEN 'REJECTED'
      ELSE 'PENDING'
    END::text,
    cs2.s_code,
    cs2.s_name,
    CASE WHEN pr.status = 'APPROVED' THEN l2.created_at ELSE NULL END,
    pr.created_at
  FROM public.profiles pr
  LEFT JOIN LATERAL (
    SELECT h.subject_id, h.performed_by, h.created_at
    FROM public.approval_history h
    WHERE h.subject_type = 'USER' AND h.subject_id = pr.id
      AND h.action IN ('APPROVE', 'REJECT')
    ORDER BY h.created_at DESC LIMIT 1
  ) l2 ON l2.subject_id IS NOT NULL
  LEFT JOIN staff_resolve cs2 ON cs2.user_id = l2.performed_by
  WHERE pr.id NOT IN (SELECT user_id FROM public.provider_profiles WHERE user_id IS NOT NULL)
    AND (p_start IS NULL OR pr.created_at >= p_start)
    AND (p_end   IS NULL OR pr.created_at <  p_end)
    AND (p_channel IS NULL OR p_channel = 'SELF')
    AND (p_confirmation IS NULL
      OR (p_confirmation = 'SYSTEM'   AND pr.status = 'APPROVED' AND l2.performed_by IS NULL)
      OR (p_confirmation = 'STAFF'    AND pr.status = 'APPROVED' AND l2.performed_by IS NOT NULL)
      OR (p_confirmation = 'PENDING'  AND pr.status NOT IN ('APPROVED','REJECTED'))
      OR (p_confirmation = 'REJECTED' AND pr.status = 'REJECTED'))
    AND p_staff_id IS NULL
    AND p_confirmed_by_staff_id IS NULL
  ORDER BY created_at DESC
  LIMIT LEAST(p_limit, 1000);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_registration_history(text, text, uuid, uuid, timestamptz, timestamptz, int)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_referral_codes() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_issue_referral_code(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_referral_code_active(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_referral_code(uuid) TO authenticated;
