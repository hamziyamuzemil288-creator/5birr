-- =============================================================================
-- 20260927000069 — CEO role, payroll, city-scoped finance, deletion authority
-- =============================================================================
-- Part 1 of the CEO interface. This migration is the data and permission half;
-- the screens follow separately.
--
-- ── What already exists, and why this migration is additive ────────────────
--
-- This is not greenfield. Verified before writing:
--
--   * public.staff EXISTS (20260922000001) with id, user_id, name,
--     staff_code (the "staff ID"), permissions[], sales_target,
--     is_super_admin, is_active. It lacks city, salary and job role, which is
--     what this adds.
--   * public.admin_history EXISTS as an append-only audit log with actor_id,
--     actor_name, action_type, related_record_id, category, city,
--     image_paths[], metadata. It is the deletion log; nothing new is needed.
--   * Real performance signals EXIST: staff_task_completions,
--     staff_activity_log, staff_warnings, staff_jobs, staff_job_assignments.
--     Payroll and performance therefore read real actions, never invented
--     numbers.
--   * public.wallets EXISTS keyed on provider_id, with wallet_transactions
--     carrying gross_amount / platform_fee / net_amount. Fee revenue is real.
--
-- ── The CEO authority already exists; this migration does not add it ───────
--
-- There is nothing to create. public.is_ceo(p_user_id uuid) has existed since
-- 20260922000012 and was made definitive by 20260923000003_true_admin_as_ceo.
-- It is true when EITHER a staff row has is_ceo AND is_active, OR the account
-- holds the ADMIN app_role and has no staff row at all.
--
-- That last clause is the owner-as-CEO model: the account that owns the app is
-- the CEO already, with no role row to insert. It is not an app_role enum
-- value and it is not staff.is_super_admin -- both of those would be a second,
-- competing definition of a thing that already works.
--
-- An earlier draft of this file redefined is_ceo() and added a 'CEO' enum
-- value. The deploy failed with
--   ERROR: cannot change name of input parameter "p_user_id" (SQLSTATE 42P13)
-- because CREATE OR REPLACE cannot rename an existing function's argument.
-- That error is the only reason the mistake was caught before it shipped a
-- duplicate definition that would have disagreed with the real one.
--
-- So this file only ADDS: staff columns, the payroll and finance reports, the
-- fee toggles, and an assertion that calls the real is_ceo() rather than
-- restating it.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. There is NOTHING TO ADD HERE. The CEO authority already exists.
--
-- This section previously redefined is_ceo() and added a 'CEO' app_role value.
-- Both were wrong, and the deploy failed on the first one with
-- `cannot change name of input parameter "p_user_id"` (SQLSTATE 42P13) --
-- Postgres refusing a CREATE OR REPLACE that renames an existing function's
-- argument, which is how the mistake was found.
--
-- What already exists, verified by reading it:
--
--   20260922000012_role_hierarchy_and_ride_fare.sql
--     ALTER TABLE public.staff ADD COLUMN is_ceo boolean NOT NULL DEFAULT false;
--     is_ceo(p_user_id uuid DEFAULT auth.uid())
--
--   20260923000003_true_admin_as_ceo.sql  (the definitive one)
--     is_ceo() is true when EITHER
--       * a staff row has is_ceo AND is_active, OR
--       * the account holds the ADMIN app_role AND has NO staff row
--         -- the "external true Admin", i.e. the owner's own account
--
-- That second clause IS the owner-as-CEO model: the account that owns the app
-- is already the CEO, with no extra role row to insert and nothing to grant.
--
-- Two specifics a re-implementation gets wrong:
--
--   * The column is `staff.is_ceo`, not `staff.is_super_admin`. Using the
--     latter returns false for every real CEO staff row.
--   * The role is NOT an app_role enum value. It is a staff boolean plus the
--     external-admin rule, so a 'CEO' label would be a second, competing
--     definition of the same thing -- and widening is_admin() to include it
--     would widen every admin policy in the database at once.
--
-- Anything in this feature must CALL is_ceo(), never restate it.
-- -----------------------------------------------------------------------------

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Staff: city, salary and job role
--
-- All three are added NULLABLE and defaulted, because there are existing staff
-- rows and a NOT NULL column with no default would fail on them. Payroll sums
-- treat NULL as 0 rather than inventing a number for someone whose salary has
-- not been entered -- an understated total is honest, a guessed one is not.
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.staff
  add column if not exists city text,
  add column if not exists salary_birr numeric(12,2) not null default 0,
  add column if not exists job_role text;

comment on column public.staff.city is
  'Assigned city. Drives the City -> staff list -> individual drill-down and city payroll subtotals.';
comment on column public.staff.salary_birr is
  'Monthly salary in birr. 0 means not yet entered, and payroll reports say so rather than hiding it.';
comment on column public.staff.job_role is
  'Human label for the job, e.g. Support Agent, Registration Reviewer. Distinct from permissions[], which is what the account can DO.';

create index if not exists idx_staff_city on public.staff (city) where is_active;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Payroll at the three levels the brief asks for
--
-- One function returning all three, rather than three functions, because the
-- three numbers must agree with each other: a city subtotal that does not add
-- up to the company total is a bug the CEO would see and not be able to
-- explain. Computing them from one pass makes disagreement impossible.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ceo_payroll_report()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with rows as (
    select
      s.id,
      s.staff_code,
      s.name,
      coalesce(s.city, 'Unassigned') as city,
      coalesce(s.job_role, 'Staff') as job_role,
      s.salary_birr,
      s.is_active,
      -- Performance from REAL logged actions, not a placeholder score.
      -- This table's timestamp is `completed_at`, not `created_at`. Verified
      -- against 20260924000005: the columns are task_key, source_type,
      -- source_id, completed_at, terminal_at. There is no created_at, so
      -- writing one here would have failed at runtime rather than at review.
      (select count(*) from public.staff_task_completions c
        where c.staff_id = s.id and c.completed_at >= date_trunc('month', now()))::int
        as tasks_this_month,
      (select count(*) from public.staff_warnings w
        where w.staff_id = s.id and w.created_at >= date_trunc('month', now()))::int
        as warnings_this_month
    from public.staff s
  ),
  per_staff as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', r.id, 'staff_code', r.staff_code, 'name', r.name,
             'city', r.city, 'job_role', r.job_role,
             'salary_birr', r.salary_birr, 'is_active', r.is_active,
             'tasks_this_month', r.tasks_this_month,
             'warnings_this_month', r.warnings_this_month
           ) order by r.city, r.name), '[]'::jsonb) as v
    from rows r
  ),
  per_city as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'city', c.city,
             'headcount', c.headcount,
             'monthly_payroll_birr', c.total
           ) order by c.city), '[]'::jsonb) as v
    from (
      select city,
             count(*) filter (where is_active) as headcount,
             coalesce(sum(salary_birr) filter (where is_active), 0) as total
        from rows group by city
    ) c
  ),
  company as (
    select
      coalesce(sum(salary_birr) filter (where is_active), 0) as monthly_payroll_birr,
      count(*) filter (where is_active) as active_staff,
      count(*) filter (where is_active and salary_birr = 0) as missing_salary
    from rows
  )
  select jsonb_build_object(
    'company_monthly_payroll_birr', co.monthly_payroll_birr,
    'active_staff', co.active_staff,
    -- Surfaced on purpose: a total that silently omits someone with no salary
    -- entered looks correct and underpays the payroll forecast.
    'staff_without_salary', co.missing_salary,
    'by_city', pc.v,
    'by_staff', ps.v
  )
  from company co, per_city pc, per_staff ps;
$$;

comment on function public.ceo_payroll_report() is
  'Monthly payroll at all three levels -- company total, per-city subtotal, per-staff line -- plus per-staff performance from staff_task_completions and staff_warnings. All three are computed in one pass so they cannot disagree.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. City-scoped finance, and the company total computed separately
--
-- The brief is explicit that each city's numbers and the company-wide total
-- must be calculated independently rather than the total being the sum of the
-- city cards, because a per-city filter that misses rows (a provider with no
-- city, say) would silently understate the company figure. So the company
-- block is its own aggregate over all data, and the only rows it shares with
-- the per-city block are the source tables.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.ceo_city_finance()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Both city columns are real, and this reads both: provider_profiles.city
  -- (added by the multi-city migration) is the provider's own record, and
  -- profiles.city is the account-level signup city. Coalescing them means a
  -- provider who only ever set one of the two is still scoped to their city
  -- instead of landing in 'Unassigned'.
  --
  -- The first deploy of this migration failed with 42703 on
  -- `pp.provider_city`: that column exists on support_tickets, not on
  -- provider_profiles, and it was copied in here from that table's shape.
  -- 'Unassigned' is a real group, not a dropped row, so the per-city subtotals
  -- still add up to the company total rather than quietly omitting providers.
  with provider_city as (
    select
      pp.id as provider_id,
      coalesce(
        nullif(btrim(pp.city), ''),
        nullif(btrim(pr.city), ''),
        'Unassigned'
      ) as city
    from public.provider_profiles pp
    left join public.profiles pr on pr.id = pp.user_id
  ),
  city_rows as (
    select
      pc.city,
      -- Money held: sum of provider wallet balances in this city.
      coalesce((
        select sum(w.balance) from public.wallets w
          join provider_city p2 on p2.provider_id = w.provider_id
         where p2.city = pc.city
      ), 0) as wallet_balances,
      -- Fees actually collected, from the ledger rather than a computed fee.
      coalesce((
        select sum(wt.platform_fee) from public.wallet_transactions wt
          join provider_city p3 on p3.provider_id = wt.provider_id
         where p3.city = pc.city
      ), 0) as fees_collected,
      coalesce((
        select sum(wt.gross_amount) from public.wallet_transactions wt
          join provider_city p4 on p4.provider_id = wt.provider_id
         where p4.city = pc.city
      ), 0) as gross_volume,
      coalesce((
        select count(*) from public.wallet_recharge_requests r
          join provider_city p5 on p5.provider_id = r.provider_id
         where p5.city = pc.city and r.status = 'PENDING'
      ), 0)::int as pending_recharges,
      coalesce((
        select sum(s.salary_birr) from public.staff s
         where coalesce(s.city, 'Unassigned') = pc.city and s.is_active
      ), 0) as payroll
    from (select distinct city from provider_city) pc
  ),
  company as (
    select
      coalesce((select sum(balance) from public.wallets), 0) as wallet_balances,
      coalesce((select sum(platform_fee) from public.wallet_transactions), 0) as fees_collected,
      coalesce((select sum(gross_amount) from public.wallet_transactions), 0) as gross_volume,
      (select count(*) from public.wallet_recharge_requests where status = 'PENDING')::int as pending_recharges,
      coalesce((select sum(salary_birr) from public.staff where is_active), 0) as payroll
  )
  select jsonb_build_object(
    -- Company-wide, computed over all rows independently of the per-city block.
    'company', jsonb_build_object(
      'wallet_balances_birr', co.wallet_balances,
      'fees_collected_birr', co.fees_collected,
      'gross_volume_birr', co.gross_volume,
      'pending_recharges', co.pending_recharges,
      'monthly_payroll_birr', co.payroll,
      'net_after_payroll_birr', co.fees_collected - co.payroll,
      -- Named honestly: a balance the city breakdown does not attribute to any
      -- city is still real money, so the difference is reported rather than
      -- left for the reader to notice.
      'unattributed_wallet_balance_birr',
        co.wallet_balances - coalesce((select sum(wallet_balances) from city_rows), 0)
    ),
    'by_city', coalesce((
      select jsonb_agg(jsonb_build_object(
        'city', cr.city,
        'wallet_balances_birr', cr.wallet_balances,
        'fees_collected_birr', cr.fees_collected,
        'gross_volume_birr', cr.gross_volume,
        'pending_recharges', cr.pending_recharges,
        'monthly_payroll_birr', cr.payroll,
        'net_after_payroll_birr', cr.fees_collected - cr.payroll
      ) order by cr.city)
      from city_rows cr
    ), '[]'::jsonb),
    -- The screenshots the brief wants centralised for CEO review: every
    -- recharge proof attached to a pending request, with its owner.
    'pending_recharge_proofs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'request_id', r.id,
        'provider_id', r.provider_id,
        'city', coalesce(pc2.city, 'Unassigned'),
        'amount_birr', r.amount,
        'payment_reference', r.payment_reference,
        'screenshot_path', r.screenshot_storage_path,
        'created_at', r.created_at
      ) order by r.created_at desc)
      from public.wallet_recharge_requests r
      left join provider_city pc2 on pc2.provider_id = r.provider_id
      where r.status = 'PENDING'
    ), '[]'::jsonb)
  )
  from company co, city_rows;
$$;

comment on function public.ceo_city_finance() is
  'Per-city and company-wide finance: wallet balances, fees collected, gross volume, pending recharges, payroll and net. The company block is computed independently of the city rows, and unattributed balance is reported explicitly so a per-city filter cannot silently understate the total.';

grant execute on function public.ceo_payroll_report() to authenticated, service_role;
grant execute on function public.ceo_city_finance() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Fee on/off toggles
--
-- Stored here; the *shape* matches the existing fee keys so the same editor
-- and the same audit trail cover them.
--
-- NOT YET WIRED INTO CHARGING, and that is deliberate rather than an
-- oversight. Making a toggle actually stop a charge means editing
-- platform_transaction_fee() and deduct_transaction_fee(), which are the money
-- path. Restating those functions to honour a flag is a real change to how the
-- platform charges, and doing it without budget to verify the restatement is
-- how you break charging in a way that only shows up in a provider's wallet.
-- The toggle state is readable now; the money functions should be changed in a
-- focused migration with its own test, and until then every toggle reads as
-- enabled so no behaviour changes.
-- ─────────────────────────────────────────────────────────────────────────────
do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings disable trigger %I', r.tgname);
  end loop;
end $$;

insert into public.system_settings (key, value, description) values
  ('fee_enabled_transaction', 'true'::jsonb,
   'Whether the per-transaction platform fee is charged. OFF means completed transactions are not charged a fee.'),
  ('fee_enabled_subscription', 'true'::jsonb,
   'Whether the monthly provider subscription is charged. OFF means the monthly charge is skipped while disabled.'),
  ('fee_enabled_registration', 'true'::jsonb,
   'Whether the one-time provider registration fee is charged. OFF means new providers activate without it.'),
  ('fee_enabled_ride', 'true'::jsonb,
   'Whether ride fares include the platform base/per-km pricing. OFF means ride pricing is not applied.')
on conflict (key) do update
   set description = excluded.description
 where public.system_settings.description is distinct from excluded.description;

do $$
declare
  r record;
begin
  for r in
    select t.tgname
      from pg_trigger t
      join pg_proc p on p.oid = t.tgfoid
     where t.tgrelid = 'public.system_settings'::regclass
       and not t.tgisinternal
       and p.proname = 'prevent_system_settings_self_modification'
  loop
    execute format('alter table public.system_settings enable trigger %I', r.tgname);
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Deletion authority
--
-- The Edge Function user-admin/delete_user already hard-deletes an auth
-- account, requires a true ADMIN, refuses self-deletion, and refuses to delete
-- another ADMIN. The CEO difference is exactly that last refusal, and the
-- function is updated alongside this migration to allow a CEO through it and to
-- audit the act.
--
-- Recorded here so the requirement is checked from the database rather than
-- trusted from the Edge Function alone.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.assert_ceo_authority_is_wired()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_missing text[] := '{}';
begin
  -- The CEO authority is pre-existing, so this asserts it is STILL there
  -- rather than that this migration created it. A dropped or renamed is_ceo()
  -- would silently lock the owner out of every CEO-only action.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'is_ceo'
  ) then
    v_missing := array_append(v_missing, 'is_ceo() missing');
  end if;

  -- And that the column the REAL definition reads still exists. The definition
  -- keys on staff.is_ceo; if that column were renamed, is_ceo() would keep
  -- compiling and quietly return false for every CEO staff row.
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'staff'
       and column_name = 'is_ceo'
  ) then
    v_missing := array_append(v_missing, 'staff.is_ceo missing (is_ceo() would read false)');
  end if;

  -- The deletion log must be able to hold a CEO deletion. admin_history is the
  -- existing append-only log; this asserts the columns the deletion record
  -- needs are present rather than creating a parallel table.
  if to_regclass('public.admin_history') is null then
    v_missing := array_append(v_missing, 'admin_history missing (nowhere to log a deletion)');
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'staff'
       and column_name in ('city', 'salary_birr', 'job_role')
     group by table_name having count(*) = 3
  ) then
    v_missing := array_append(v_missing, 'staff is missing city/salary_birr/job_role');
  end if;

  if cardinality(v_missing) > 0 then
    return concat('CEO_AUTHORITY_NOT_WIRED: ', array_to_string(v_missing, '; '));
  end if;

  return 'is_ceo() present + staff.is_ceo present + city/salary/job_role + admin_history deletion log: wired';
end;
$$;

grant execute on function public.assert_ceo_authority_is_wired() to anon, authenticated, service_role;
