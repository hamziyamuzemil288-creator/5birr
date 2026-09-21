-- ============================================================
-- Migration 20260922000004_revenue_scheduler.sql
-- Phase 1 fix (money-flow command, 2026-09-21):
--   the 5birr monthly subscription fee was ORPHANED.
-- ============================================================
-- DIAGNOSIS (from docs/functional_audit_2026-09-19.md, confirmed by code
-- trace on 2026-09-21):
--   * deduct_subscription_fee() exists (0022c restated by 0038) and writes
--     wallet_transactions rows with transaction_type 'SUBSCRIPTION_FEE'.
--   * The Dart admin reads (AdminDashboard + AdminIncomeSummaryScreen) sum
--     platform_fee over TRANSACTION_FEE + SUBSCRIPTION_FEE ledger rows
--     (fixed previously in d0d41c7 — the old sources, orders.admin_fee and
--     subscriptions, are written by nothing / hold schedules only).
--   * The only caller of deduct_subscription_fee() is the subscription-process
--     Edge Function — which NOTHING schedules (no pg_cron, no pg_net trigger,
--     no GitHub schedule; it needs a manual X-N8N-SECRET dispatch). So in
--     normal operation SUBSCRIPTION_FEE rows are NEVER written and the
--     "5birr Monthly Fees" half of Total Income is permanently 0.00.
--
-- FIX (additive only): one SECURITY DEFINER wrapper that charges every due
-- subscription idempotently (deduct_subscription_fee already dedupes per
-- provider+period via idempotency_key 'sub:<provider>:<period>') and
-- advances/flags providers it could NOT charge, exactly mirroring the edge
-- function's grace/suspension semantics — scheduled daily with pg_cron
-- (free-plan supported; pg_net would also need an auth secret, which the
-- owner has not supplied, so no credentials are introduced here).
--
-- No existing table, column, function signature, or policy is modified.
-- ============================================================

create or replace function public.charge_due_subscriptions()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub record;
  v_fee numeric := coalesce(get_setting_numeric('monthly_subscription_fee'), 5);
  v_grace_days int := coalesce(get_setting_numeric('subscription_grace_period_days'), 3)::int;
  v_balance numeric;
  v_user_id uuid;
  v_charged int := 0;
  v_deferred int := 0;
  v_suspended int := 0;
begin
  for v_sub in
    select provider_id, next_due_date, status
      from subscriptions
     where next_due_date <= now()
       and status in ('ACTIVE', 'DUE', 'GRACE')
  loop
    select balance into v_balance from wallets where provider_id = v_sub.provider_id;

    if v_balance is not null and v_balance >= v_fee then
      -- Idempotent per provider+period; writes the SUBSCRIPTION_FEE ledger
      -- row, advances next_due_date, sets status = 'ACTIVE'.
      begin
        perform deduct_subscription_fee(v_sub.provider_id,
          to_char(v_sub.next_due_date, 'YYYY-MM'));
        v_charged := v_charged + 1;
      exception when others then
        -- Leave the schedule row for the next run; do not abort the batch.
        v_deferred := v_deferred + 1;
      end;
    else
      -- Insufficient balance: grace first, suspend when past grace days
      -- (same semantics as the subscription-process edge function).
      if v_sub.next_due_date < now() - make_interval(days => v_grace_days) then
        update subscriptions
           set status = 'SUSPENDED'
         where provider_id = v_sub.provider_id;
        update provider_profiles
           set status = 'SUSPENDED', updated_at = now()
         where id = v_sub.provider_id
           and status = 'APPROVED';
        v_suspended := v_suspended + 1;
      else
        update subscriptions
           set status = 'GRACE'
         where provider_id = v_sub.provider_id;
        v_deferred := v_deferred + 1;
      end if;

      select user_id into v_user_id from provider_profiles where id = v_sub.provider_id;
      if v_user_id is not null then
        perform insert_notification(
          v_user_id,
          'SUBSCRIPTION_DUE',
          'Subscription payment overdue',
          'Your wallet balance is too low for the monthly fee. Please recharge before your account is suspended.',
          jsonb_build_object('next_due_date', v_sub.next_due_date)
        );
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'charged', v_charged,
    'deferred', v_deferred,
    'suspended', v_suspended
  );
end;
$$;

revoke execute on function public.charge_due_subscriptions()
  from public, anon, authenticated;
-- Runnable by service_role (edge functions / manual ops calls).
grant execute on function public.charge_due_subscriptions() to service_role;

-- ---------------------------------------------------------------------------
-- pg_cron schedule (daily 03:17 UTC). Idempotent: the job is only created if
-- absent, so re-running this migration never duplicates schedules.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;

do $$
begin
  if not exists (select 1 from cron.job where jobname = '5birr-subscription-daily') then
    perform cron.schedule(
      '5birr-subscription-daily',
      '17 3 * * *',
      $cron$select public.charge_due_subscriptions()$cron$
    );
  end if;
end $$;
