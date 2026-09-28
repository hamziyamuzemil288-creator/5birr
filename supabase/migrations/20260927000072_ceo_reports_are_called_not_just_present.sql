-- 20260927000072 — the CEO reports are CALLED, not just present
--
-- WHY THIS EXISTS
-- ---------------
-- Migration 71's assertion, assert_ceo_staff_terms_is_wired(), is in the
-- Connectivity CI suite and checks that ceo_payroll_report() EXISTS:
--
--     if not exists (select 1 from pg_proc ... where proname = 'ceo_payroll_report')
--
-- It never calls it. Neither does anything else in CI. So the first deploy of
-- migration 69 shipped a ceo_city_finance() that referenced `pp.provider_city`
-- -- a column that exists on support_tickets, not on provider_profiles -- and
-- that 42703 was found by a human reading the deploy log, not by the suite.
-- A catalogue check cannot see that class of bug: the function exists, it is
-- wired, and it raises the first time somebody opens the Finance tab.
--
-- This adds the missing half. It CALLS both report functions the way the CEO
-- screen calls them (no arguments, as the same jsonb) and checks the keys the
-- Dart side actually reads. A rename, a dropped CTE, a bad join or a column
-- that no longer exists now fails Connectivity CI on the deploy that ships it,
-- in the same run that would otherwise report green.
--
-- RETURNS text AND REPORTS RATHER THAN RAISES, deliberately: a raising assert
-- surfaces through PostgREST as an opaque database error and is then
-- indistinguishable from a real outage, which is what made
-- assert_resilience_is_wired take three deploy cycles to pin down. The Dart
-- suite reads this as text via rpcTextDiagnosed().
--
-- The keys asserted here are exactly the ones lib/features/ceo/ceo_dashboard.dart
-- reads. If that screen grows a key, add it here in the same change:
--   payroll : company_monthly_payroll_birr, active_staff, staff_without_salary,
--             by_city[], by_staff[] (and per-staff rows: name, staff_code,
--             salary_birr, is_active, tasks_this_month, warnings_this_month)
--   finance : company{wallet_balances_birr, fees_collected_birr,
--             gross_volume_birr, pending_recharges, monthly_payroll_birr,
--             net_after_payroll_birr, unattributed_wallet_balance_birr},
--             by_city[], pending_recharge_proofs[]

create or replace function public.assert_ceo_reports_are_callable()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_problem  text[] := '{}';
  v_payroll  jsonb;
  v_finance  jsonb;
  v_row      text;
  v_company  jsonb;
  v_counts   text;
begin
  -- ── 1. Both reports must be CALLABLE with no arguments ──
  -- Called in the same shape the app calls them. An exception here is the
  -- 42703 class of failure, caught here rather than by whoever opens the tab.
  begin
    v_payroll := public.ceo_payroll_report();
  exception when others then
    v_problem := array_append(v_problem, 'ceo_payroll_report() raised ' || sqlstate || ': ' || sqlerrm);
  end;

  begin
    v_finance := public.ceo_city_finance();
  exception when others then
    v_problem := array_append(v_problem, 'ceo_city_finance() raised ' || sqlstate || ': ' || sqlerrm);
  end;

  -- ── 2. The payroll shape the Staff tab reads ──
  if v_payroll is null then
    v_problem := array_append(v_problem,
      'ceo_payroll_report() returned NULL (a non-SETOF SQL function with an empty FROM returns NULL, so the Staff tab would show "no payroll data" with no error)');
  else
    foreach v_row in array array[
      'company_monthly_payroll_birr', 'active_staff', 'staff_without_salary',
      'by_city', 'by_staff'
    ] loop
      if not (v_payroll ? v_row) then
        v_problem := array_append(v_problem, 'ceo_payroll_report() is missing key ' || v_row);
      end if;
    end loop;

    -- by_city and by_staff must be arrays, because the screen maps over them.
    -- A scalar where a list is expected is a runtime error on the device, not
    -- a missing value, so it is worth asserting the type and not just presence.
    if v_payroll ? 'by_city' and jsonb_typeof(v_payroll -> 'by_city') <> 'array' then
      v_problem := array_append(v_problem, 'ceo_payroll_report().by_city is not an array');
    end if;
    if v_payroll ? 'by_staff' and jsonb_typeof(v_payroll -> 'by_staff') <> 'array' then
      v_problem := array_append(v_problem, 'ceo_payroll_report().by_staff is not an array');
    end if;

    -- When there are staff rows, the first one must carry the per-staff keys
    -- the drill-down renders. Skipped when the table is empty, so a fresh
    -- deployment is not reported as broken.
    if v_payroll ? 'by_staff' and jsonb_typeof(v_payroll -> 'by_staff') = 'array'
       and jsonb_array_length(v_payroll -> 'by_staff') > 0 then
      foreach v_row in array array[
        'name', 'staff_code', 'salary_birr', 'is_active',
        'tasks_this_month', 'warnings_this_month'
      ] loop
        if not ((v_payroll -> 'by_staff' -> 0) ? v_row) then
          v_problem := array_append(v_problem, 'ceo_payroll_report().by_staff[0] is missing key ' || v_row);
        end if;
      end loop;
    end if;
  end if;

  -- ── 3. The finance shape the Finance tab reads ──
  if v_finance is null then
    v_problem := array_append(v_problem,
      'ceo_city_finance() returned NULL (the Finance tab would show "no finance data" and ask the CEO to run a deploy that already ran)');
  else
    if not (v_finance ? 'company') then
      v_problem := array_append(v_problem, 'ceo_city_finance() is missing key company');
    else
      v_company := v_finance -> 'company';
      if jsonb_typeof(v_company) <> 'object' then
        v_problem := array_append(v_problem, 'ceo_city_finance().company is not an object');
      else
        foreach v_row in array array[
          'wallet_balances_birr', 'fees_collected_birr', 'gross_volume_birr',
          'pending_recharges', 'monthly_payroll_birr', 'net_after_payroll_birr',
          'unattributed_wallet_balance_birr'
        ] loop
          if not (v_company ? v_row) then
            v_problem := array_append(v_problem, 'ceo_city_finance().company is missing key ' || v_row);
          end if;
        end loop;
      end if;
    end if;

    foreach v_row in array array['by_city', 'pending_recharge_proofs'] loop
      if not (v_finance ? v_row) then
        v_problem := array_append(v_problem, 'ceo_city_finance() is missing key ' || v_row);
      elsif jsonb_typeof(v_finance -> v_row) <> 'array' then
        v_problem := array_append(v_problem, 'ceo_city_finance().' || v_row || ' is not an array');
      end if;
    end loop;

    -- A pending recharge proof is what the Data tab renders from. Its keys are
    -- only assertable when at least one is pending, so the count is reported
    -- either way and the keys are checked when there is something to check.
    if v_finance ? 'pending_recharge_proofs'
       and jsonb_typeof(v_finance -> 'pending_recharge_proofs') = 'array'
       and jsonb_array_length(v_finance -> 'pending_recharge_proofs') > 0 then
      foreach v_row in array array[
        'city', 'amount_birr', 'payment_reference', 'screenshot_path'
      ] loop
        if not ((v_finance -> 'pending_recharge_proofs' -> 0) ? v_row) then
          v_problem := array_append(v_problem,
            'ceo_city_finance().pending_recharge_proofs[0] is missing key ' || v_row);
        end if;
      end loop;

      -- The screenshot path must name a real object, or the CEO reviews a
      -- broken image instead of a receipt. The bucket itself is not knowable
      -- from here (storage.objects is not queryable in this role), so this
      -- asserts only that a path was recorded rather than left blank.
      if coalesce(v_finance -> 'pending_recharge_proofs' -> 0 ->> 'screenshot_path', '') = '' then
        v_problem := array_append(v_problem,
          'a pending recharge proof has no screenshot_path, so the Data tab would render a placeholder instead of the receipt');
      end if;
    end if;

    v_counts := format('by_city=%s, pending_recharge_proofs=%s',
      coalesce(jsonb_array_length(v_finance -> 'by_city'), -1),
      coalesce(jsonb_array_length(v_finance -> 'pending_recharge_proofs'), -1));
  end if;

  if cardinality(v_problem) > 0 then
    return concat('CEO_REPORTS_NOT_CALLABLE: ', array_to_string(v_problem, '; '));
  end if;

  return format(
    'ceo_payroll_report() and ceo_city_finance() both call clean with every key the CEO screens read; %s',
    coalesce(v_counts, 'finance shape not reached'));
end;
$$;

comment on function public.assert_ceo_reports_are_callable() is
  'Behavioural: CALLS ceo_payroll_report() and ceo_city_finance() and checks the keys lib/features/ceo/ceo_dashboard.dart reads, so a runtime failure or a renamed key fails Connectivity CI rather than only showing up when a human opens the Finance tab. Returns a diagnostic string; never raises.';

-- Granted to anon for the same reason every other assertion is: Connectivity
-- CI calls the suite as anon with no session, so a function that needs
-- `authenticated` can never be checked there. It is SECURITY DEFINER and reads
-- only aggregate shapes and counts -- no row-level data, no provider identity.
grant execute on function public.assert_ceo_reports_are_callable()
  to anon, authenticated, service_role;
