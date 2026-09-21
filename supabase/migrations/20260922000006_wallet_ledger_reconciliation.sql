-- ============================================================
-- Migration 20260922000006_wallet_ledger_reconciliation.sql
-- Phase 3: ongoing money-flow health check (scheduled).
-- ============================================================
-- Every ledger row is written together with the wallets.balance update in
-- one transaction, so sum(net_amount) must equal each wallet balance. A
-- divergence means some path changed balances without writing the ledger
-- (the exact class of bug that produced a 0.00 Total Income).
--
-- reconcile_income_and_log() compares the two and, on drift, appends an
-- ADMIN_HISTORY row (action_type 'WALLET_LEDGER_DRIFT', metadata carrying
-- wallet id and both totals). Nothing is auto-corrected — the drift row is
-- the alert the admin acts on. Scheduled daily by pg_cron right after the
-- subscription charge job, so drift caused by charging bugs is caught
-- between deploys.
--
-- Additive only: no existing table, column, function, or policy changes.
-- ============================================================

create or replace function public.reconcile_income_and_log()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  v_ledger numeric;
  v_count int := 0;
begin
  for r in
    select w.id, w.provider_id, w.balance
      from wallets w
  loop
    select coalesce(sum(t.net_amount), 0) into v_ledger
      from wallet_transactions t
     where t.wallet_id = r.id
       and t.status = 'COMPLETED';

    if v_ledger <> r.balance then
      perform public.log_admin_action(
        null,
        'WALLET_LEDGER_DRIFT',
        r.id,
        'payment_verification',
        null,
        '{}',
        jsonb_build_object(
          'provider_id', r.provider_id,
          'wallet_balance', r.balance,
          'ledger_net_total', v_ledger,
          'difference', r.balance - v_ledger
        )
      );
      v_count := v_count + 1;
    end if;
  end loop;

  return jsonb_build_object('checked', true, 'drifted_wallets', v_count);
end;
$$;

revoke execute on function public.reconcile_income_and_log()
  from public, anon, authenticated;
grant execute on function public.reconcile_income_and_log() to service_role;

do $$
begin
  if not exists (select 1 from cron.job where jobname = '5birr-ledger-reconciliation') then
    perform cron.schedule(
      '5birr-ledger-reconciliation',
      '47 3 * * *',
      $cron$select public.reconcile_income_and_log()$cron$
    );
  end if;
end $$;
