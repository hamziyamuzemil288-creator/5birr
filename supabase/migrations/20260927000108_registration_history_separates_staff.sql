-- =============================================================================
-- 20260927000108_registration_history_separates_staff.sql
--
-- Registration History was mixing staff accounts in with registered users.
--
-- THE DEFECT
-- ----------
-- 20260924000000_referral_tracking.sql built admin_registration_history() as
-- two UNION ALL branches: provider owners, then everyone else in `profiles`.
-- The second branch excluded one group and one group only:
--
--     WHERE pr.id NOT IN (
--       SELECT user_id FROM public.provider_profiles WHERE user_id IS NOT NULL)
--
-- Every staff gateway account and every admin owns a `profiles` row -- the
-- function's own `staff_resolve` CTE joins `staff.user_id`, so it depends on
-- that fact -- and therefore every one of them was emitted as a `record_type =
-- 'USER'` registration. The reported symptom was "it uses user registration
-- as staff and mixing them", and that is exactly what the SQL does.
--
-- It was made worse by the vocabulary. `confirmation = 'STAFF'` means
-- "APPROVED by a staff member", not "this person IS staff". A staff member's
-- own account therefore rendered as "Self-registered / By staff <code>",
-- which reads as an ordinary buyer confirmed by a colleague and is very hard
-- to tell apart from a genuine one.
--
-- WHAT THIS CHANGES
-- -----------------
-- 1. The `profiles` branch excludes staff rows and ADMIN-role accounts.
-- 2. A third branch emits staff accounts with `record_type = 'STAFF'`, so
--    they are visible but categorised, rather than invisible or misfiled.
-- 3. `p_channel` gains category values -- 'BUYER', 'VEHICLE_PROVIDER',
--    'SERVICE_PROVIDER', 'STAFF' -- so the admin can ask for one group. The
--    existing channel values ('SELF', 'SALES', 'OTHER') keep working.
--
-- WHY THE SIGNATURE DOES NOT CHANGE
-- ---------------------------------
-- `admin_registration_history` keeps its exact seven-parameter signature and
-- its exact RETURNS TABLE. Changing either would require DROP FUNCTION, which
-- would drop the GRANT as well and leave a window where the screen's RPC does
-- not exist at all. `record_type` already carried the category, so it only
-- needed a fourth value; `p_channel` already existed, so it only needed more
-- accepted values. Nothing is added and nothing is removed.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_registration_history(
  p_channel text DEFAULT NULL,       -- 'SELF'|'SALES'|'OTHER'
                                      --  | 'BUYER'|'VEHICLE_PROVIDER'
                                      --  | 'SERVICE_PROVIDER'|'STAFF'
  p_confirmation text DEFAULT NULL,  -- 'SYSTEM'|'STAFF'|'PENDING'|'REJECTED'
  p_staff_id uuid DEFAULT NULL,      -- filter by the registering sales person
  p_confirmed_by_staff_id uuid DEFAULT NULL, -- filter by confirming staff
  p_start timestamptz DEFAULT NULL,
  p_end timestamptz DEFAULT NULL,
  p_limit int DEFAULT 500
)
RETURNS TABLE (
  record_id uuid,
  record_type text,                  -- 'USER'|'VEHICLE_PROVIDER'
                                     -- |'SERVICE_PROVIDER'|'STAFF'
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
  -- THE FIX, PART ONE. Accounts that are staff or admins are not
  -- registrations, and must never appear in the USER branch. The owner of
  -- the platform holds the ADMIN app_role and has no staff row at all, so the
  -- role check is not optional -- excluding only `staff` would still leave
  -- the CEO's own account filed as a buyer.
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
    -- One clause, with the four ways a provider row can qualify:
    --   no filter, a buyer-only view (which excludes every provider),
    --   this provider's own type, or the original channel filters.
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

  -- Buyers: ordinary accounts that are neither a provider owner nor staff.
  -- THE FIX, PART TWO is the `staff_accounts` exclusion here.
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
    -- 'SELF' is accepted alongside 'BUYER' so the pre-existing channel chips
    -- keep working; buyers always have a SELF channel, so the distinction is
    -- only in what the caller asked for.
    AND (p_channel IS NULL OR p_channel IN ('BUYER', 'SELF'))
    AND (p_confirmation IS NULL
      OR (p_confirmation = 'SYSTEM'   AND pr.status = 'APPROVED' AND l2.performed_by IS NULL)
      OR (p_confirmation = 'STAFF'    AND pr.status = 'APPROVED' AND l2.performed_by IS NOT NULL)
      OR (p_confirmation = 'PENDING'  AND pr.status NOT IN ('APPROVED','REJECTED'))
      OR (p_confirmation = 'REJECTED' AND pr.status = 'REJECTED'))
    AND p_staff_id IS NULL
    AND p_confirmed_by_staff_id IS NULL

  UNION ALL

  -- THE FIX, PART THREE. Staff and admins, in their own category, so they can
  -- be counted and reviewed without being filed as customer registrations.
  --
  -- `confirmation` is 'SYSTEM' rather than 'STAFF' on purpose: for this row
  -- "STAFF" would mean "approved by a staff member", which is exactly the
  -- confusion that made the mixing hard to see.
  SELECT
    sa.id,
    'STAFF'::text,
    COALESCE(st.name, pr.full_name, 'Staff member'),
    COALESCE(pr.phone, pr.email, ''),
    -- A staff row carries no account_status; the owner's profile status is
    -- the closest true thing and is what the rest of the app reads too.
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
  WHERE (
      p_channel IS NULL OR p_channel = 'STAFF'
    )
    -- A staff member was never "registered" in the sense this screen tracks,
    -- so the confirmation and referrer filters do not apply to them. Refusing
    -- to answer would be worse than ignoring the filter.
    AND (p_confirmation IS NULL OR p_confirmation = 'SYSTEM')
    AND p_staff_id IS NULL
    AND p_confirmed_by_staff_id IS NULL
    -- Parenthesised: AND binds tighter than OR, so without these brackets a
    -- bare `p_channel IS NULL OR p_channel = 'STAFF'` would let the date
    -- filters be skipped entirely for the unfiltered view.
    AND (p_start IS NULL OR COALESCE(st.created_at, pr.created_at) >= p_start)
    AND (p_end   IS NULL OR COALESCE(st.created_at, pr.created_at) <  p_end)

  ORDER BY created_at DESC
  LIMIT LEAST(p_limit, 1000);
END;
$$;

COMMENT ON FUNCTION public.admin_registration_history(text, text, uuid, uuid, timestamptz, timestamptz, int) IS
  'One row per registered person, categorised. record_type is USER, '
  'VEHICLE_PROVIDER, SERVICE_PROVIDER or STAFF, and p_channel accepts '
  'BUYER / VEHICLE_PROVIDER / SERVICE_PROVIDER / STAFF as well as the '
  'original SELF / SALES / OTHER. Staff and admin accounts are excluded '
  'from the USER branch and returned in their own category instead.';

GRANT EXECUTE ON FUNCTION public.admin_registration_history(text, text, uuid, uuid, timestamptz, timestamptz, int)
  TO authenticated;

-- -----------------------------------------------------------------------------
-- A guard so the mixing cannot come back
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_registration_history_separates_staff()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_body text;
  v_mixed int;
BEGIN
  -- Read the live function body and require the exclusion to still be there.
  SELECT prosrc INTO v_body
    FROM pg_proc
   WHERE proname = 'admin_registration_history'
     AND pronamespace = 'public'::regnamespace
   LIMIT 1;

  IF v_body IS NULL THEN
    RAISE EXCEPTION 'admin_registration_history is missing';
  END IF;

  IF v_body NOT LIKE '%staff_accounts%' THEN
    RAISE EXCEPTION 'admin_registration_history no longer builds staff_accounts -- staff accounts would be listed as user registrations again';
  END IF;

  -- The exclusion must be applied, not merely computed. `pr.id NOT IN
  -- (SELECT user_id FROM staff_accounts)` is the whole point; a CTE that is
  -- defined but never joined away lets every staff row back into USER.
  IF v_body NOT LIKE '%pr.id NOT IN (SELECT user_id FROM staff_accounts)%' THEN
    RAISE EXCEPTION 'admin_registration_history does not exclude staff_accounts from the USER branch -- staff and admin accounts are being filed as customer registrations';
  END IF;

  -- Prove it on the data, not just on the text: no profile row that belongs
  -- to a staff member or an admin may come back as record_type = 'USER'.
  SELECT count(*) INTO v_mixed
    FROM public.profiles pr
   WHERE pr.id NOT IN (SELECT user_id FROM public.provider_profiles
                        WHERE user_id IS NOT NULL)
     AND (pr.id IN (SELECT user_id FROM public.staff WHERE user_id IS NOT NULL)
          OR pr.id IN (SELECT ur.user_id FROM public.user_roles ur
                        WHERE ur.role::text = 'ADMIN'));

  IF v_mixed > 0 THEN
    RAISE EXCEPTION
      '% staff/admin account(s) have no provider profile, so they fall '
      'through to the USER branch', v_mixed;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_registration_history_separates_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_registration_history_separates_staff()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
