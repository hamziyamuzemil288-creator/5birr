-- Restore subscriptions this function suspended, and the accounts it gated.
--
-- charge_due_subscriptions() selected only subscriptions in
-- ('ACTIVE','DUE','GRACE') and, when a balance was short, set the row to
-- SUSPENDED. That made the state it created terminal: the next run's filter
-- excluded SUSPENDED, so a provider who recharged was never charged again and
-- nothing ever lifted the suspension. subscription-process had the identical
-- filter, so both entry points shared the flaw.
--
-- The user-facing cost was a broken promise. The notification sent on
-- suspension reads "Recharge your wallet to reactivate" — and recharging did
-- nothing at all, because no run would ever look at that subscription again.
-- Revenue cost: a provider unsuspended by hand had subscriptions.status left
-- at SUSPENDED, so they were never billed again and kept trading for free.
--
-- Both fixes here:
--   1. include SUSPENDED in the batch filter, so a provider whose balance now
--      covers the fee is charged and the subscription returns to ACTIVE via
--      deduct_subscription_fee;
--   2. when the subscription being charged was SUSPENDED, also restore
--      provider_profiles.status. trg_sync_profile_status (20260927000004)
--      carries that to profiles.status, which is what the app router gates on
--      — otherwise the account would be restored in the database and still
--      refused by the app.
--
-- The grace/suspension path below is unchanged, so nothing is re-suspended
-- that was not already suspended. Restoring is conditional on the row still
-- being SUSPENDED, so an admin action taken in the meantime is not undone.
--
-- Body otherwise verbatim from 20260922000004_revenue_scheduler.sql, with
-- only the two changes above, so the scheduled behaviour converges on what
-- was already running rather than on a reconstruction of it.

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
       and status in ('ACTIVE', 'DUE', 'GRACE', 'SUSPENDED')
  loop
    select balance into v_balance from wallets where provider_id = v_sub.provider_id;

    if v_balance is not null and v_balance >= v_fee then
      -- Idempotent per provider+period; writes the SUBSCRIPTION_FEE ledger
      -- row, advances next_due_date, sets status = 'ACTIVE'.
      begin
        perform deduct_subscription_fee(v_sub.provider_id,
          to_char(v_sub.next_due_date, 'YYYY-MM'));
        -- deduct_subscription_fee sets subscriptions.status = 'ACTIVE', but
        -- nothing restored provider_profiles.status when the fee could not be
        -- paid, so a provider who has now paid was left suspended forever.
        -- Restoring it here also lifts profiles.status via
        -- trg_sync_profile_status, so the app stops gating the account.
        if v_sub.status = 'SUSPENDED' then
          -- Only notify for an account actually restored, so a payment does
          -- not claim success for an admin suspension issued in the meantime.
          with restored as (
            update provider_profiles
               set status = 'APPROVED', updated_at = now()
             where id = v_sub.provider_id
               and status = 'SUSPENDED'
            returning user_id
          )
          insert into notifications (user_id, type, title, body)
          select user_id, 'APPROVAL', 'Account reactivated',
                 'Your subscription payment went through and your account is active again.'
            from restored;
        end if;
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
grant execute on function public.charge_due_subscriptions() to service_role;
