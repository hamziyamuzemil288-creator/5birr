-- 20260927000071 — CEO sets a staff member's city, salary and job role
--
-- WHY THIS IS ITS OWN NARROW FUNCTION INSTEAD OF NEW PARAMETERS ON update_staff
-- ---------------------------------------------------------------------------
-- The obvious move is to add p_city / p_salary_birr / p_job_role to
-- public.update_staff. That function is SECURITY DEFINER and already carries a
-- long list of guards (role-hierarchy checks, the "may not edit an account
-- above you" rule, the admin_history write, the boss/self protections).
-- Restating it to add three parameters means restating every one of those
-- conditions, and a restatement that drops one does not fail loudly — it just
-- silently drops a protection. That exact accident has already happened once
-- in this repo's history.
--
-- So this adds a second, deliberately narrow door. It can change exactly three
-- columns and nothing else, so it cannot bypass a check in update_staff: it
-- does not touch permissions, name, is_active, branch, is_super_admin or
-- assigned_categories, and it cannot create or delete anything. The worst a
-- bug here can do is write a wrong salary, which is visible on the payroll
-- screen and fixable.
--
-- WHO: CEO only, by the pre-existing is_ceo(). Note that is_ceo() is true for
-- "holds ADMIN and has no staff row", which is the owner's real account — the
-- person this interface is for.
--
-- Authorisation is enforced in the function body, not by the GRANT. The GRANT
-- exists because PostgREST needs EXECUTE, and it is granted to authenticated
-- rather than service_role so the app can call it as the signed-in CEO and
-- is_ceo() can see that identity at all — a SECURITY DEFINER function called
-- through the service role has no auth.uid() to test.

-- ─────────────────────────────────────────────────────────────────────────────
-- The function
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ceo_set_staff_terms(
  p_staff_id     uuid,
  p_city         text default null,
  p_salary_birr  numeric default null,
  p_job_role     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor      uuid := auth.uid();
  v_actor_name text;
  v_before     public.staff;
  v_after      public.staff;
  v_city       text;
  v_role       text;
begin
  if not public.is_ceo() then
    raise exception 'ONLY_CEO_CAN_SET_STAFF_TERMS';
  end if;

  select * into v_before from public.staff where id = p_staff_id;
  if not found then
    raise exception 'STAFF_NOT_FOUND';
  end if;

  -- A negative salary would subtract from the company payroll total and make
  -- the city subtotals disagree with it in the direction that looks like a
  -- savings. Refused rather than clamped, so a typo is visible.
  if p_salary_birr is not null and p_salary_birr < 0 then
    raise exception 'SALARY_MUST_NOT_BE_NEGATIVE';
  end if;

  -- Blank and whitespace-only city are stored as NULL, not as ''. Otherwise
  -- the city drill-down grows an empty-string group that looks like a real
  -- city with staff in it.
  v_city := nullif(btrim(coalesce(p_city, '')), '');
  v_role := nullif(btrim(coalesce(p_job_role, '')), '');

  update public.staff
     set city        = v_city,
         salary_birr = coalesce(p_salary_birr, salary_birr),
         job_role    = v_role
   where id = p_staff_id
  returning * into v_after;

  select coalesce(full_name, 'CEO')
    into v_actor_name
    from public.profiles
   where id = v_actor;

  -- Logged for the same reason a deletion is: payroll is money, and "who
  -- changed this salary, and to what" is the question that gets asked later.
  -- The before/after pair is in metadata because the row itself only holds the
  -- new value.
  insert into public.admin_history (
    actor_id, actor_name, action_type, related_record_id, category, city, metadata
  ) values (
    v_actor,
    v_actor_name,
    'STAFF_TERMS_CHANGED',
    p_staff_id,
    'STAFF',
    v_city,
    jsonb_build_object(
      'staff_code',     v_after.staff_code,
      'name',           v_after.name,
      'city_before',    v_before.city,
      'city_after',     v_after.city,
      'salary_before',  v_before.salary_birr,
      'salary_after',   v_after.salary_birr,
      'job_role_before', v_before.job_role,
      'job_role_after',  v_after.job_role
    )
  );

  return jsonb_build_object(
    'id',           v_after.id,
    'staff_code',   v_after.staff_code,
    'name',         v_after.name,
    'city',         v_after.city,
    'salary_birr',  v_after.salary_birr,
    'job_role',     v_after.job_role
  );
end;
$$;

comment on function public.ceo_set_staff_terms(uuid, text, numeric, text) is
  'CEO-only. Sets a staff member''s city, salary and job role. Narrow on purpose: it changes exactly those three columns and cannot touch permissions, name, is_active, branch or is_super_admin, so it cannot bypass a guard in update_staff. Logs STAFF_TERMS_CHANGED to admin_history.';

revoke all on function public.ceo_set_staff_terms(uuid, text, numeric, text)
  from public, anon;
grant execute on function public.ceo_set_staff_terms(uuid, text, numeric, text)
  to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- Assertion, in the shape the connectivity suite reads
-- (RETURNS text, reports rather than raises — a throwing assert surfaces as an
-- opaque DB error and is then indistinguishable from a real finding).
-- Appends with array_append, never `arr || 'literal'`: with an untyped literal
-- on the right, `||` is ambiguous between array_append and array_cat and can
-- resolve to array_cat, which throws 'malformed array literal'. That is the
-- exact bug that made assert_resilience_is_wired() report nothing for three
-- deploys.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.assert_ceo_staff_terms_is_wired()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_missing text[] := '{}';
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'ceo_set_staff_terms'
  ) then
    v_missing := array_append(v_missing, 'ceo_set_staff_terms() missing');
  end if;

  -- The three columns the function writes. If any were renamed the function
  -- would keep compiling against a stale definition only until the next
  -- replace; the column check is what actually catches a rename.
  if not exists (
    select 1
      from information_schema.columns
     where table_schema = 'public' and table_name = 'staff'
       and column_name in ('city', 'salary_birr', 'job_role')
     group by table_name having count(*) = 3
  ) then
    v_missing := array_append(v_missing, 'staff is missing city/salary_birr/job_role');
  end if;

  -- Payroll is only meaningful if the reader and this writer agree on the same
  -- columns, so assert the report function is still present too.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'ceo_payroll_report'
  ) then
    v_missing := array_append(v_missing, 'ceo_payroll_report() missing (nothing reads what this writes)');
  end if;

  if cardinality(v_missing) > 0 then
    return concat('CEO_STAFF_TERMS_NOT_WIRED: ', array_to_string(v_missing, '; '));
  end if;

  return 'ceo_set_staff_terms() + staff.city/salary_birr/job_role + ceo_payroll_report() reader: wired';
end;
$$;

grant execute on function public.assert_ceo_staff_terms_is_wired()
  to anon, authenticated, service_role;
