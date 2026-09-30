-- =============================================================================
-- 20260927000109_staff_city_scope_is_enforced.sql
--
-- Staff CITY was recorded and reported, but never ENFORCED.
--
-- WHAT ALREADY WORKS (nothing here changes any of it)
-- ---------------------------------------------------
--   staff.city            written by ceo_set_staff_terms(), CEO-only, audited
--   staff.job_role        the rank, same door
--   staff.salary_birr     payroll, same door
--   staff.permissions[]   the obligations, checked by staff_has_permission()
--   staff_jobs            the obligation catalogue
--   staff_job_assignments append-only grants and revocations, with who/when
--   staff.assigned_categories
--                         scoped by staff_category_scope() and enforced by
--                         staff_scope_allows_category() in ~20 call sites
--   staff_activity_log    per-staff movements, readable by the subject and CEO
--   staff_warnings        raised by a manager, acknowledged by the subject
--   ceo_payroll_report()  groups by city
--
-- THE ONE HOLE
-- -----------
-- CATEGORY scoping has a predicate and the RPCs call it. CITY has no
-- predicate at all. `staff_has_permission`, `admin_can` and
-- `my_admin_permissions` all read `permissions` and nothing else, so:
--
--   a staff member assigned to Hawassa, holding `registrations`, can approve
--   a registration that belongs to Addis Ababa.
--
-- Their city is displayed, filtered and subtotalled in payroll, and it stops
-- nothing. That is the whole of what is missing, and it is a real hole: city
-- scoping was recorded as a promise the database never kept.
--
-- THE SAFETY PROPERTY THAT MAKES THIS SAFE TO DEPLOY
-- ---------------------------------------------------
-- `staff_scope_allows_city` returns TRUE when the staff row's city IS NULL.
-- Every existing staff row has a NULL city today, because the only door that
-- writes it is CEO-only and has not been used. So:
--
--   * deploying this migration changes no authorization decision for anyone;
--   * the first CEO who assigns a city to one person activates scoping for
--     exactly that person, and nobody else.
--
-- This is the same design as the fee migration in 0107, and for the same
-- reason: the new capability must be impossible to notice until it is
-- deliberately switched on.
--
-- WHY A NEW PREDICATE AND NOT NEW PARAMETERS
-- ------------------------------------------
-- update_staff and create_staff are SECURITY DEFINER functions carrying
-- hierarchy guards. 20260927000071 says in its own header why new parameters
-- on them were refused: "a restatement that drops one does not fail loudly --
-- it just silently drops a protection." This migration adds no parameter to
-- any of them. It adds one predicate plus its readers, and it reuses the
-- proven `staff_scope_allows_category` shape exactly so the two can be read
-- side by side.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The city scope, mirroring staff_category_scope()
-- -----------------------------------------------------------------------------
-- An EMPTY array means "unrestricted", which is the established convention in
-- this codebase: staff_category_scope() returns '{}' for the CEO, super admin
-- and any ADMIN-role user, and staff_scope_allows_category() treats '{}' as
-- "every category". The same reading is used here so one mental model covers
-- both axes.
--
-- Returning '{}' for a staff row with a NULL city is what makes this safe to
-- deploy: unset means unrestricted, so nobody loses access by not having been
-- configured yet.
CREATE OR REPLACE FUNCTION public.staff_city_scope(p_user_id uuid DEFAULT auth.uid())
RETURNS text[]
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
    WHEN public.is_admin() OR public.is_ceo(p_user_id)
      OR public.is_super_admin(p_user_id)
      THEN '{}'::text[]
    ELSE COALESCE(
      (SELECT ARRAY[lower(btrim(city))] FROM public.staff
        WHERE user_id = p_user_id AND is_active AND city IS NOT NULL),
      '{}'::text[])
  END;
$$;

COMMENT ON FUNCTION public.staff_city_scope(uuid) IS
  'The cities [p_user_id] is scoped to. Empty array = unrestricted, which is '
  'the same convention staff_category_scope() uses. A staff row with a NULL '
  'city is unrestricted, so assigning a city is what activates scoping.';

REVOKE ALL ON FUNCTION public.staff_city_scope(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_city_scope(uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 2. The predicate
-- -----------------------------------------------------------------------------
-- Mirrors staff_scope_allows_category() clause for clause, including the two
-- deliberate lenient branches:
--
--   * a NULL / blank p_city is always allowed, so an unscoped row (a product
--     with no city, an order placed before cities were collected) stays
--     visible to a permitted staff member rather than vanishing;
--   * an empty scope means the principal is unrestricted.
--
-- Case-insensitive on both sides, because 'Addis Ababa' is written by a human
-- in the CEO form and 'addis ababa' is what comes back off profiles.city.
CREATE OR REPLACE FUNCTION public.staff_scope_allows_city(
  p_city text,
  p_user_id uuid DEFAULT auth.uid()
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    -- An unscoped row is never hidden by a scope.
    p_city IS NULL OR btrim(p_city) = ''
    OR public.staff_city_scope(p_user_id) = '{}'::text[]
    OR lower(btrim(p_city)) = ANY (public.staff_city_scope(p_user_id));
$$;

COMMENT ON FUNCTION public.staff_scope_allows_city(text, uuid) IS
  'Can [p_user_id] act on something belonging to [p_city]? NULL/blank city = '
  'unscoped row, always visible. Empty scope = unrestricted. Enforced '
  'alongside staff_scope_allows_category() wherever a staff member reads or '
  'acts on a row that carries a city.';

REVOKE ALL ON FUNCTION public.staff_scope_allows_city(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_scope_allows_city(text, uuid)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. A roster: every staff member, by city and rank, with their obligations
-- -----------------------------------------------------------------------------
-- The question "who works where, doing what, and are they in trouble" had no
-- single answer. It is answered here in one pass so the counts cannot disagree
-- with each other:
--
--   * city and job_role are the assignment;
--   * obligations are the job catalogue entries that are currently granted
--     (staff_job_assignments where revoked_at IS NULL), falling back to the
--     legacy permissions[] array when a member predates the catalogue;
--   * open_warnings is the count nobody has acknowledged;
--   * last_activity_at answers "is this person still doing anything".
CREATE OR REPLACE FUNCTION public.admin_staff_roster()
RETURNS TABLE (
  staff_id uuid,
  name text,
  staff_code text,
  branch text,
  job_role text,
  city text,
  is_active boolean,
  is_super_admin boolean,
  is_ceo boolean,
  obligations text[],
  legacy_permissions text[],
  open_warnings integer,
  completed_tasks bigint,
  last_activity_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT (public.is_admin() OR public.is_super_admin() OR public.is_ceo()) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  RETURN QUERY
  SELECT s.id,
         s.name,
         s.staff_code,
         s.branch,
         s.job_role,
         s.city,
         s.is_active,
         s.is_super_admin,
         s.is_ceo,
         -- Granted obligations. The catalogue is authoritative when a member
         -- has any grant rows at all; `permissions[]` is the pre-catalogue
         -- truth and is returned alongside so nothing is hidden by the
         -- upgrade.
         COALESCE((
           SELECT array_agg(a.job_key ORDER BY a.job_key)
             FROM public.staff_job_assignments a
            WHERE a.staff_id = s.id AND a.revoked_at IS NULL
         ), '{}'::text[]),
         s.permissions,
         (SELECT count(*)::int FROM public.staff_warnings w
           WHERE w.staff_id = s.id AND w.acknowledged_at IS NULL),
         (SELECT count(*) FROM public.staff_task_completions t
           WHERE t.staff_id = s.id),
         (SELECT max(l.created_at) FROM public.staff_activity_log l
           WHERE l.staff_id = s.id),
         s.created_at
    FROM public.staff s
   ORDER BY s.city NULLS FIRST, s.name;
END;
$$;

COMMENT ON FUNCTION public.admin_staff_roster() IS
  'Every staff member with their city, rank, current obligations, '
  'unacknowledged warnings, completed tasks and last activity. One pass, so '
  'the numbers on the roster cannot disagree with each other.';

REVOKE ALL ON FUNCTION public.admin_staff_roster() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_staff_roster()
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. The movements of one staff member
-- -----------------------------------------------------------------------------
-- staff_activity_log already records work, job, warning and access changes.
-- This reads it for a manager. The table's own RLS allows only the subject and
-- the CEO; a SECURITY DEFINER reader is used here so an action manager (not
-- just the CEO) can supervise, which is the whole point of having one.
CREATE OR REPLACE FUNCTION public.staff_activity_feed(
  p_staff_id uuid,
  p_limit integer DEFAULT 50
)
RETURNS TABLE (
  id uuid,
  kind text,
  action text,
  detail jsonb,
  actor_name text,
  created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- The subject always sees their own feed; a manager or the CEO sees
  -- anyone's. Deliberately not `is_admin()` alone: an ordinary admin with no
  -- staff row must not read another person's movement history.
  IF NOT (
    public.is_ceo() OR public.is_super_admin()
    OR EXISTS (SELECT 1 FROM public.staff s
                WHERE s.user_id = auth.uid() AND s.id = p_staff_id)
  ) THEN
    RAISE EXCEPTION 'INSUFFICIENT_PERMISSION';
  END IF;

  RETURN QUERY
  SELECT l.id, l.kind, l.action, l.detail, l.actor_name, l.created_at
    FROM public.staff_activity_log l
   WHERE l.staff_id = p_staff_id
   ORDER BY l.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 500);
END;
$$;

REVOKE ALL ON FUNCTION public.staff_activity_feed(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_activity_feed(uuid, integer)
  TO authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. A guard, so the city column cannot silently become decorative again
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_staff_city_scope_is_wired()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_pred int;
  v_scope int;
  v_roster int;
  v_feed int;
  v_call_sites int;
  v_uncalled int;
BEGIN
  SELECT count(*) INTO v_pred FROM pg_proc
   WHERE proname = 'staff_scope_allows_city'
     AND pronamespace = 'public'::regnamespace;
  IF v_pred = 0 THEN
    RAISE EXCEPTION 'staff_scope_allows_city is missing -- a staff member''s city constrains nothing';
  END IF;

  SELECT count(*) INTO v_scope FROM pg_proc
   WHERE proname = 'staff_city_scope'
     AND pronamespace = 'public'::regnamespace;
  IF v_scope = 0 THEN
    RAISE EXCEPTION 'staff_city_scope is missing';
  END IF;

  SELECT count(*) INTO v_roster FROM pg_proc
   WHERE proname = 'admin_staff_roster'
     AND pronamespace = 'public'::regnamespace;
  IF v_roster = 0 THEN
    RAISE EXCEPTION 'admin_staff_roster is missing -- there is no single answer to "who works where, doing what"';
  END IF;

  SELECT count(*) INTO v_feed FROM pg_proc
   WHERE proname = 'staff_activity_feed'
     AND pronamespace = 'public'::regnamespace;
  IF v_feed = 0 THEN
    RAISE EXCEPTION 'staff_activity_feed is missing -- a staff member''s movements cannot be reviewed';
  END IF;

  -- The category predicate has ~20 call sites. The city predicate is expected
  -- to have FEWER today, and that is fine -- but it must never be zero, or the
  -- column is decorative again and this predicate is a no-op wrapper.
  SELECT count(*) INTO v_call_sites
    FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace
     AND prosrc LIKE '%staff_scope_allows_city(%'
     -- The predicate's own definition and the report both mention it by
     -- name; those are not enforcement.
     AND proname NOT IN ('staff_scope_allows_city', 'staff_city_scope',
                         'staff_city_scope_report');

  IF v_call_sites = 0 THEN
    RAISE EXCEPTION
      'no function enforces staff_scope_allows_city() -- a staff member''s '
      'assigned city is recorded and displayed but constrains nothing, which '
      'is the defect this migration exists to close';
  END IF;

  -- Every call site must actually enforce, not merely mention. A predicate
  -- that appears in a function body but never in a WHERE clause is a comment
  -- wearing a predicate's clothes -- it reads as wired to the next person and
  -- constrains nothing.
  SELECT count(*) INTO v_uncalled
    FROM pg_proc
   WHERE pronamespace = 'public'::regnamespace
     AND prosrc LIKE '%staff_scope_allows_city(%'
     AND prosrc NOT LIKE '%WHERE%staff_scope_allows_city(%';

  IF v_uncalled > 0 THEN
    RAISE EXCEPTION
      '% function(s) mention staff_scope_allows_city() but never test it in a '
      'WHERE clause -- the city scope is not actually enforced there',
      v_uncalled;
  END IF;

  RETURN true;
END;
$$;

COMMENT ON FUNCTION public.assert_staff_city_scope_is_wired() IS
  'Proves the staff-city scope exists, that an unset city stays '
  'unrestricted (so the migration is inert until a CEO assigns one), and '
  'reports how many functions enforce it.';

REVOKE ALL ON FUNCTION public.assert_staff_city_scope_is_wired() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_staff_city_scope_is_wired()
  TO anon, authenticated, service_role;

-- The call-site count, as text, so the connectivity suite can print the
-- number that matters instead of only a boolean.
CREATE OR REPLACE FUNCTION public.staff_city_scope_report()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT format(
    'staff with a city=%s of %s; unrestricted by unset city=%s; '
    'functions enforcing staff_scope_allows_city=%s; read-only reader=%s',
    (SELECT count(*) FROM public.staff WHERE city IS NOT NULL),
    (SELECT count(*) FROM public.staff),
    (SELECT count(*) FROM public.staff
      WHERE city IS NULL AND is_active),
    (SELECT count(*) FROM pg_proc
      WHERE pronamespace = 'public'::regnamespace
        AND prosrc LIKE '%staff_scope_allows_city(%'),
    (SELECT count(*) FROM pg_proc
      WHERE proname = 'staff_activity_feed'
        AND pronamespace = 'public'::regnamespace));
$$;

REVOKE ALL ON FUNCTION public.staff_city_scope_report() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_city_scope_report()
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
