-- =============================================================================
-- 20260927000110_staff_city_guards_on_the_registration_queue.sql
--
-- The first real enforcement site for the city scope added in 0109.
--
-- WHY THE REGISTRATION QUEUE IS THE RIGHT FIRST SITE
-- ---------------------------------------------------
-- `registrations` is the permission most staff actually hold, the queue is
-- where a city-scoped person's mistake is most expensive (approving a
-- provider in the wrong city is a business decision, not a UI annoyance), and
-- the function was last restated by migration 0108 in this same series -- so
-- its body is known verbatim rather than reconstructed from a snapshot.
--
-- WHAT CHANGES, EXACTLY
-- ----------------------
-- Three `AND public.staff_scope_allows_city(...)` clauses are added to the
-- WHERE of the three UNION branches. Nothing else.
--
-- The predicate returns TRUE when:
--   * the principal is an ADMIN, the CEO or a super admin, or
--   * the staff row has no city assigned, or
--   * the row itself has no city.
--
-- Every existing staff row has a NULL city today, so **no authorization
-- decision changes for anyone until a CEO deliberately assigns a city**. That
-- is the same inert-until-switched property the fee table has, and it is the
-- reason this can ship without a coordinated data backfill.
--
-- City source per branch:
--   provider branch -> provider_profiles.city, falling back to the owner's
--                      profile city (a provider registered before that column
--                      existed still has a city, and dropping it to '' would
--                      make the row unscoped rather than wrong)
--   buyer branch    -> profiles.city
--   staff branch    -> the staff row's own city, so a Hawassa manager does
--                      not see the staff roster of Addis Ababa
--
-- The staff branch is the subtle one: a city-scoped manager can be scoped
-- *into* their own city's staff list without this, because the staff rows a
-- manager most needs are their own. Scoping them out too would leave a
-- manager unable to see the colleague sitting beside them.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_registration_history(
  p_channel text DEFAULT NULL,
  p_confirmation text DEFAULT NULL,
  p_staff_id uuid DEFAULT NULL,
  p_confirmed_by_staff_id uuid DEFAULT NULL,
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL,
  p_limit int DEFAULT 500
)
RETURNS TABLE (
  record_id uuid,
  record_type text,
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
    SELECT DISTINCT ON (h.subject_type, h.subject_id)
           h.subject_type, h.subject_id, h.action, h.performed_by, h.created_at
    FROM public.approval_history h
    WHERE h.action IN ('APPROVE', 'REJECT')
    ORDER BY h.subject_type, h.subject_id, h.created_at DESC
  ),
  staff_accounts AS (
    SELECT user_id FROM public.staff WHERE user_id IS NOT NULL
    UNION
    SELECT ur.user_id
      FROM public.user_roles ur
     WHERE ur.role::text = 'ADMIN'
  ),
  provider_rows AS (
    SELECT pp.id AS provider_id, pp.user_id, pp.provider_type::text AS ptype,
           COALESCE(pp.business_name, pr.full_name, 'New Provider') AS dname,
           COALESCE(pr.phone, pr.email, '') AS contact,
           pp.status::text AS pstatus,
           pp.referral_code, pp.referred_by_staff_id, pp.referred_by_name,
           pp.created_at, pr.full_name AS owner_name, pr.status AS user_status,
           -- NEW: the city this registration belongs to. See the header for
           -- why the owner's profile city is the fallback.
           COALESCE(NULLIF(btrim(pp.city), ''), NULLIF(btrim(pr.city), '')) AS city
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
    (CASE WHEN r.user_status = 'APPROVED' THEN r.user_status::text
          ELSE r.pstatus::text END) AS status_out,
    r.referral_code,
    r.referred_by_staff_id,
    r.referred_by_name,
    CASE
      WHEN p_channel = 'VEHICLE_PROVIDER' THEN 'VEHICLE_PROVIDER'
      WHEN p_channel = 'SERVICE_PROVIDER' THEN 'SERVICE_PROVIDER'
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
     OR p_channel = 'BUYER'
     OR p_channel = r.ptype
     OR (p_channel IN ('SELF', 'SALES', 'OTHER')
         AND (
           (p_channel = 'SELF'  AND (r.referral_code IS NULL OR btrim(r.referral_code) = ''))
        OR (p_channel = 'SALES' AND r.referred_by_staff_id IS NOT NULL)
        OR (p_channel = 'OTHER' AND r.referral_code IS NOT NULL AND btrim(r.referral_code) <> ''
            AND r.referred_by_staff_id IS NULL)
         )))
    -- NEW: the city scope. Inert until a CEO assigns a staff member a city.
    AND public.staff_scope_allows_city(coalesce(r.city, ''), auth.uid())
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
    'BUYER'::text,
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
    AND pr.id NOT IN (SELECT user_id FROM staff_accounts)
    AND (p_start IS NULL OR pr.created_at >= p_start)
    AND (p_end   IS NULL OR pr.created_at <  p_end)
    AND (p_channel IS NULL OR p_channel IN ('BUYER', 'SELF'))
    -- NEW: the city scope, on the buyer's own profile city.
    AND public.staff_scope_allows_city(coalesce(pr.city, ''), auth.uid())
    AND (p_confirmation IS NULL
      OR (p_confirmation = 'SYSTEM'   AND pr.status = 'APPROVED' AND l2.performed_by IS NULL)
      OR (p_confirmation = 'STAFF'    AND pr.status = 'APPROVED' AND l2.performed_by IS NOT NULL)
      OR (p_confirmation = 'PENDING'  AND pr.status NOT IN ('APPROVED','REJECTED'))
      OR (p_confirmation = 'REJECTED' AND pr.status = 'REJECTED'))
    AND p_staff_id IS NULL
    AND p_confirmed_by_staff_id IS NULL

  UNION ALL

  SELECT
    sa.id,
    'STAFF'::text,
    COALESCE(st.name, pr.full_name, 'Staff member'),
    COALESCE(pr.phone, pr.email, ''),
    COALESCE(pr.status::text, 'APPROVED'),
    NULL::text, NULL::uuid, NULL::text,
    'STAFF'::text,
    'SYSTEM'::text,
    NULL::text,
    st.staff_code,
    st.created_at,
    COALESCE(st.created_at, pr.created_at)
  FROM staff_accounts sa
  LEFT JOIN public.staff st ON st.user_id = sa.id
  LEFT JOIN public.profiles pr ON pr.id = sa.id
  WHERE (p_channel IS NULL OR p_channel = 'STAFF')
    AND (p_confirmation IS NULL OR p_confirmation = 'SYSTEM')
    AND p_staff_id IS NULL
    AND p_confirmed_by_staff_id IS NULL
    AND (p_start IS NULL OR COALESCE(st.created_at, pr.created_at) >= p_start)
    AND (p_end   IS NULL OR COALESCE(st.created_at, pr.created_at) <  p_end)
    -- NEW: a city-scoped manager sees only their own city's staff.
    AND public.staff_scope_allows_city(coalesce(st.city, ''), auth.uid())

  ORDER BY created_at DESC
  LIMIT LEAST(p_limit, 1000);
END;
$$;

COMMENT ON FUNCTION public.admin_registration_history(text, text, uuid, uuid, timestamptz, timestamptz, int) IS
  'One row per registered person, categorised by record_type and filtered by '
  'p_channel. Row visibility is narrowed by staff_scope_allows_city(), so a '
  'staff member assigned to a city sees only that city''s registrations. A '
  'staff row with no city assigned stays unrestricted.';

GRANT EXECUTE ON FUNCTION public.admin_registration_history(text, text, uuid, uuid, timestamptz, timestamptz, int)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- Prove the two halves of this pair of migrations are both present and that the
-- separation survived: the scope separates staff from the registration list,
-- and the city scope does not undo it.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_staff_separation_survives_city_scope()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_body text;
BEGIN
  SELECT prosrc INTO v_body FROM pg_proc
   WHERE proname = 'admin_registration_history'
     AND pronamespace = 'public'::regnamespace
   LIMIT 1;

  IF v_body IS NULL THEN
    RAISE EXCEPTION 'admin_registration_history is missing';
  END IF;

  -- 0108's fix must still be here. The city guard was added afterwards and a
  -- careless restatement is exactly how that fix would be lost.
  IF v_body NOT LIKE '%pr.id NOT IN (SELECT user_id FROM staff_accounts)%' THEN
    RAISE EXCEPTION 'admin_registration_history no longer excludes staff_accounts from the USER branch -- staff accounts are being filed as customer registrations again';
  END IF;

  -- All three branches must carry the city guard. One missing would leave a
  -- city-scoped manager able to read another city's rows through the branch
  -- nobody remembered to guard. The quoted literals are the actual call
  -- sites: `''` is doubled because the needle itself contains a quote.
  IF v_body NOT LIKE '%staff_scope_allows_city(coalesce(r.city, ''''), auth.uid())%'
     OR v_body NOT LIKE '%staff_scope_allows_city(coalesce(pr.city, ''''), auth.uid())%'
     OR v_body NOT LIKE '%staff_scope_allows_city(coalesce(st.city, ''''), auth.uid())%'
  THEN
    RAISE EXCEPTION 'admin_registration_history is missing a staff_scope_allows_city() guard on at least one of its three branches';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_staff_separation_survives_city_scope() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_staff_separation_survives_city_scope()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
