-- =============================================================================
-- 20260927000073 — the fee switches actually switch
-- =============================================================================
-- Migration 69 created four fee switches and said, honestly, that they were
-- stored and NOT wired into charging:
--
--     fee_enabled_transaction, fee_enabled_subscription,
--     fee_enabled_registration, fee_enabled_ride
--
-- A switch that changes nothing is worse than no switch: the CEO flips it,
-- nothing happens, and the next person to look concludes the whole fee surface
-- is decorative. This migration makes each one stop/start the charge it names,
-- at every point the charge is actually applied, and adds the assertions that
-- prove it — so "Supabase is green" means these are wired, not merely present.
--
-- ── WHERE THE GUARD GOES, AND WHY THERE AND NOWHERE ELSE ────────────────────
--
-- The rule this migration follows is: put the switch at the single point where
-- the money would move, never at a call site. A guard at a call site is one
-- forgotten caller away from a switch that stops working, and the forgotten
-- caller is always the one nobody tests.
--
--   fee_enabled_transaction   -> platform_transaction_fee(), the ONE
--       implementation of the commission. deduct_transaction_fee() calls it,
--       wallet-deduct-fee calls deduct_transaction_fee, and the checkout screen
--       calls it to show the buyer what they will pay. Guarding it here means
--       the number displayed and the number charged stop together, which is the
--       whole reason that function exists.
--   fee_enabled_subscription  -> deduct_subscription_fee() (the charge) AND
--       charge_due_subscriptions() (the caller). Both, because the scheduler
--       decides whether to even call the charge based on the wallet balance
--       covering the fee — with the fee switched off, a provider whose balance
--       was below the (now irrelevant) fee would be pushed to GRACE and then
--       SUSPENDED for a bill the platform had stopped sending.
--   fee_enabled_registration  -> approve_wallet_recharge(), the only place the
--       one-time activation fee is withheld (0038 section 5).
--   fee_enabled_ride          -> calculate_fare_estimate(), the only place a
--       platform fare is computed.
--
-- ── THE ASSERTION THAT HAD TO MOVE WITH IT ─────────────────────────────────
--
-- assert_fees_are_data_driven() (migration 62) asserts
-- platform_transaction_fee(1000) == GREATEST(percent of 1000, minimum). It is
-- called by Connectivity CI. Wiring fee_enabled_transaction into that function
-- WITHOUT touching the assertion would turn the switch into a red CI run the
-- first time a CEO used it. So the assertion is restated here to be
-- toggle-aware: it checks the arithmetic when the switch is on, and checks that
-- the fee is exactly 0 when the switch is off. Both directions are asserted, so
-- a switch that is present but inert now fails instead of passing quietly.
--
-- Everything else about that function is copied verbatim.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The predicate, so "is this a fee switch?" is asked in one place
-- -----------------------------------------------------------------------------
create or replace function public.is_fee_toggle_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key is not null and p_key like 'fee_enabled_%'
$$;

comment on function public.is_fee_toggle_key(text) is
  'True for the fee on/off switches (fee_enabled_*). Separate from is_fee_key(), which names the NUMERIC fee keys: the fee editor parses a value as a number and would try to parse a boolean, so a switch must never appear in that catalogue. Used by admin_update_setting() to make the switches CEO-only like every other fee, and by the assertions to prove each switch is wired.';

-- -----------------------------------------------------------------------------
-- 2. The switches are the CEO's, like every other fee
-- -----------------------------------------------------------------------------
-- Before this, any admin could flip fee_enabled_* while every NUMERIC fee was
-- CEO-only (is_fee_key). Turning the platform's commission off is at least as
-- consequential as changing its size, so the two answer to the same person.
--
-- Full restatement of the function from migration 62. Body copied verbatim
-- except:
--   * the guard above now also accepts a fee switch,
--   * a switch must be a boolean,
--   * the audit row records a switch as a fee.
-- The fee-bounds branch is deliberately NOT extended to switches: it casts the
-- value to numeric and would reject 'true' with a confusing message.
create or replace function public.admin_update_setting(
  p_key text,
  p_value jsonb,
  p_description text default null
)
returns public.system_settings
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_row public.system_settings;
  v_old jsonb;
  v_problem text;
  v_numeric numeric;
begin
  if p_key is null or btrim(p_key) = '' then
    raise exception 'SETTING_KEY_REQUIRED';
  end if;

  -- Fees are the owner's call, not any admin's.  The product already
  -- distinguishes the two (is_ceo(), 20260923000003), so the distinction the
  -- brief asks for already exists and is used here rather than inventing a
  -- new role.  Everything that is not a fee stays ordinary-admin editable,
  -- which is all the rest of this screen.
  if public.is_fee_key(p_key) or public.is_fee_toggle_key(p_key) then
    if not public.is_ceo() then
      raise exception 'FEES_CAN_ONLY_BE_CHANGED_BY_THE_CEO_OR_OWNER';
    end if;
  elsif not public.is_admin() then
    raise exception 'SYSTEM_SETTINGS_CAN_ONLY_BE_MODIFIED_BY_ADMINISTRATORS';
  end if;

  if p_value is null or p_value = 'null'::jsonb then
    raise exception 'SETTING_VALUE_REQUIRED';
  end if;

  select value into v_old from public.system_settings where key = p_key;

  -- Shape is preserved per key.  get_setting_numeric() casts
  -- (value #>> '{}')::numeric, so flipping a numeric key to a string turns
  -- every reader into a runtime cast failure; the same holds for
  -- get_setting_bool(). Caught here, where there is a message.
  if v_old is not null then
    if jsonb_typeof(v_old) in ('number', 'boolean')
       and jsonb_typeof(v_old) <> jsonb_typeof(p_value) then
      raise exception 'SETTING_%_MUST_STAY_A_%', p_key, upper(jsonb_typeof(v_old));
    end if;
  end if;

  -- A switch is read by get_setting_bool(), which casts the value to boolean.
  -- A number here would turn every charge site into a runtime cast failure on
  -- the next transaction, so it is refused with its own message rather than
  -- only the shape check's.
  if public.is_fee_toggle_key(p_key) and jsonb_typeof(p_value) <> 'boolean' then
    raise exception 'FEE_SWITCH_%_MUST_BE_TRUE_OR_FALSE', p_key;
  end if;

  -- Fee bounds.  A negative fee pays providers to trade; an absurd one is
  -- almost always a typo (a birr value entered in cents), and either way it
  -- would be silently live for the next transaction.
  if public.is_fee_key(p_key) then
    if jsonb_typeof(p_value) <> 'number' then
      raise exception 'FEE_%_MUST_BE_A_NUMBER', p_key;
    end if;
    v_numeric := (p_value #>> '{}')::numeric;

    if v_numeric < 0 then
      raise exception 'FEE_%_CANNOT_BE_NEGATIVE', p_key;
    end if;

    if p_key ~ 'percent$' and v_numeric > 100 then
      raise exception 'FEE_%_MUST_BE_AT_MOST_100_PERCENT', p_key;
    elsif p_key !~ 'percent$' and v_numeric > 1000000 then
      raise exception 'FEE_%_IS_ABOVE_THE_SANITY_LIMIT_OF_1000000_BIRR', p_key;
    end if;

    -- A zero-percent commission with no floor would mean free trades.  Legal
    -- if that is the deliberate choice, but not by accident: the pair must
    -- leave some fee standing.  (The supported way to charge nothing is to
    -- switch the fee off, which says so in the audit log.)
    if p_key = 'transaction_fee_percent'
       and v_numeric = 0
       and coalesce(public.get_setting_numeric('transaction_fee_min'), 0) = 0 then
      raise exception 'SETTING_BOTH_THE_FEE_PERCENT_AND_THE_MINIMUM_TO_ZERO_REMOVES_ALL_PLATFORM_COMMISSION';
    end if;
    if p_key = 'transaction_fee_min'
       and v_numeric = 0
       and coalesce(public.get_setting_numeric('transaction_fee_percent'), 0) = 0 then
      raise exception 'SETTING_BOTH_THE_FEE_PERCENT_AND_THE_MINIMUM_TO_ZERO_REMOVES_ALL_PLATFORM_COMMISSION';
    end if;
  end if;

  if p_key in (
    'points_per_order', 'points_per_ride', 'points_per_review',
    'points_per_recharge', 'points_first_provider_approval',
    'points_conversion_minimum'
  ) then
    if jsonb_typeof(p_value) <> 'number' then
      raise exception 'SETTING_%_MUST_BE_A_NUMBER', p_key;
    end if;
    if (p_value #>> '{}')::numeric < 0 then
      raise exception 'SETTING_%_CANNOT_BE_NEGATIVE', p_key;
    end if;
  end if;

  if p_key = 'points_to_birr_rate' then
    if jsonb_typeof(p_value) <> 'number' then
      raise exception 'POINTS_TO_BIRR_RATE_MUST_BE_A_NUMBER';
    end if;
    if (p_value #>> '{}')::numeric <= 0 or (p_value #>> '{}')::numeric > 1 then
      raise exception 'POINTS_TO_BIRR_RATE_MUST_BE_ABOVE_0_AND_AT_MOST_1';
    end if;
  end if;

  if p_key = 'rank_tiers' then
    v_problem := public.validate_rank_tiers(p_value);
    if v_problem is not null then
      raise exception '%', v_problem;
    end if;
  end if;

  insert into public.system_settings (key, value, description, updated_by, updated_at)
  values (
    p_key,
    p_value,
    coalesce(nullif(btrim(coalesce(p_description, '')), ''), 'Set from the admin settings screen'),
    auth.uid(),
    now()
  )
  on conflict (key) do update
    set value = excluded.value,
        description = case
                        when nullif(btrim(coalesce(p_description, '')), '') is null
                          then public.system_settings.description
                        else excluded.description
                      end,
        updated_by = auth.uid(),
        updated_at = now()
  returning * into v_row;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'SYSTEM_SETTING_UPDATED',
    'system_settings',
    null,
    jsonb_build_object(
      'key', p_key,
      'old_value', v_old,
      'new_value', p_value,
      'is_fee', public.is_fee_key(p_key) or public.is_fee_toggle_key(p_key),
      'is_fee_switch', public.is_fee_toggle_key(p_key)
    )
  );

  return v_row;
end;
$$;

comment on function public.admin_update_setting(text, jsonb, text) is
  'The only client path that writes system_settings. Fee keys AND fee switches (fee_enabled_*) are CEO-only; numeric fee keys are bounds-checked and switches must be boolean. Other keys are admin-gated. Type-checked per key so a reader cannot be broken by a shape change, and audited.';

revoke all on function public.admin_update_setting(text, jsonb, text) from public, anon;
grant execute on function public.admin_update_setting(text, jsonb, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 3. fee_enabled_transaction — the commission
-- -----------------------------------------------------------------------------
-- The one implementation. Guarding here stops the charge AND the on-screen
-- estimate together, because both read this function.
create or replace function public.platform_transaction_fee(p_amount numeric)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_percent numeric;
  v_min numeric;
begin
  if p_amount is null or p_amount < 0 then
    raise exception 'AMOUNT_MUST_BE_A_NON_NEGATIVE_NUMBER';
  end if;

  -- The switch. Checked before the settings are read so a switched-off fee
  -- cannot be resurrected by a bad numeric setting: off means 0, full stop.
  -- Default true, so a deployment that has not seeded the key charges as before.
  if not coalesce(public.get_setting_bool('fee_enabled_transaction'), true) then
    return 0;
  end if;

  v_percent := coalesce(public.get_setting_numeric('transaction_fee_percent'), 0);
  v_min := coalesce(public.get_setting_numeric('transaction_fee_min'), 0);

  if v_percent < 0 or v_min < 0 then
    raise exception 'TRANSACTION_FEE_SETTINGS_CANNOT_BE_NEGATIVE';
  end if;

  -- GREATEST(percentage, floor) is the documented 1%-with-5-birr-minimum
  -- rule, now charged instead of only described.
  return greatest(round(p_amount * v_percent / 100.0, 2), v_min);
end;
$$;

comment on function public.platform_transaction_fee(numeric) is
  'The single source of truth for the platform commission: GREATEST(transaction_fee_percent% of the amount, transaction_fee_min), or 0 when the fee_enabled_transaction switch is off. Read live from system_settings on every call so a CEO fee change applies to the next charge with no deploy.';

revoke execute on function public.platform_transaction_fee(numeric) from public, anon;
grant execute on function public.platform_transaction_fee(numeric) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. fee_enabled_subscription — the monthly charge
-- -----------------------------------------------------------------------------
-- Body copied from 0038 (the live definition) with one addition. When the
-- switch is off the cycle still advances — otherwise the daily scheduler
-- re-offers the same period forever — but no ledger row is written, because no
-- money moved, and a 0-birr SUBSCRIPTION_FEE row would still be a charge row
-- that income reporting counts.
create or replace function public.deduct_subscription_fee(p_provider_id uuid, p_period text)
returns public.wallet_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet wallets;
  v_fee numeric := get_setting_numeric('monthly_subscription_fee');
  v_key text := 'sub:' || p_provider_id::text || ':' || p_period;
  v_existing wallet_transactions;
  v_txn wallet_transactions;
begin
  select * into v_existing from wallet_transactions where idempotency_key = v_key;
  if v_existing.id is not null then
    return v_existing;
  end if;

  -- The switch. Same shape as the idempotency short-circuit above: the period
  -- is consumed either way, so a switch that is turned back on does not
  -- retro-charge the months it was off.
  if not coalesce(get_setting_bool('fee_enabled_subscription'), true) then
    update subscriptions
       set last_charged_at = now(),
           next_due_date = next_due_date + interval '1 month',
           status = 'ACTIVE'
     where provider_id = p_provider_id;
    return null;
  end if;

  select * into v_wallet from wallets where provider_id = p_provider_id for update;
  if v_wallet.id is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;

  update wallets set balance = balance - v_fee, updated_at = now()
   where id = v_wallet.id
   returning * into v_wallet;

  insert into wallet_transactions (wallet_id, provider_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  values (v_wallet.id, p_provider_id, 'SUBSCRIPTION_FEE', v_fee, v_fee, 0, v_wallet.balance, 'COMPLETED', v_key)
  returning * into v_txn;

  update subscriptions set last_charged_at = now(), next_due_date = next_due_date + interval '1 month', status = 'ACTIVE'
   where provider_id = p_provider_id;

  perform insert_notification(
    (select user_id from provider_profiles where id = p_provider_id),
    'SUBSCRIPTION_DUE',
    'Subscription charged',
    v_fee::text || ' birr deducted',
    jsonb_build_object('wallet_id', v_wallet.id, 'fee', v_fee)
  );

  perform maybe_notify_low_wallet(v_wallet, p_provider_id);

  return v_txn;
end;
$$;

comment on function public.deduct_subscription_fee(uuid, text) is
  'Charges one month of the provider subscription, idempotent per provider+period. When fee_enabled_subscription is off the period is still consumed (next_due_date advances) but nothing is charged and no ledger row is written.';

revoke execute on function public.deduct_subscription_fee(uuid, text) from public, anon, authenticated;
grant execute on function public.deduct_subscription_fee(uuid, text) to service_role;

-- -----------------------------------------------------------------------------
-- 5. The scheduler must not suspend anyone for a switched-off fee
-- -----------------------------------------------------------------------------
-- charge_due_subscriptions decides between "charge" and "grace/suspend" by
-- comparing the wallet balance against the fee. With the switch off that
-- comparison is meaningless: a provider with an empty wallet would be pushed to
-- GRACE and then SUSPENDED, and their account gated, for a bill the platform
-- had stopped sending. So the switch is honoured before the loop rather than
-- only inside the charge.
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
  -- The switch. Off means no charge, no grace and no suspension — a switched
  -- off fee must not cost anybody their account. The report keeps the same
  -- three keys so every existing reader still resolves them.
  if not coalesce(get_setting_bool('fee_enabled_subscription'), true) then
    return jsonb_build_object('charged', 0, 'deferred', 0, 'suspended', 0);
  end if;

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

revoke execute on function public.charge_due_subscriptions() from public, anon, authenticated;
grant execute on function public.charge_due_subscriptions() to service_role;

-- -----------------------------------------------------------------------------
-- 6. fee_enabled_registration — the one-time activation fee
-- -----------------------------------------------------------------------------
-- Body copied from 20260927000020 (the live definition) with the switch added.
-- Two things change when it is off, and both matter:
--   * v_reg_fee becomes 0, so the first recharge credits in full AND the
--     provider still activates (registration_fee_paid is set either way, and
--     the amount >= fee guard cannot fail against 0);
--   * the "Account activated" notice no longer claims a fee was applied.
--
-- The notice also stops hardcoding "100 birr". It said 100 no matter what
-- provider_registration_fee was set to, so a CEO who changed the fee was
-- contradicted by the message the provider received.
create or replace function public.approve_wallet_recharge(
  p_recharge_id uuid,
  p_admin_id uuid
)
returns public.wallet_recharge_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recharge wallet_recharge_requests;
  v_wallet wallets;
  v_txn wallet_transactions;
  v_credit numeric;
  v_reg_fee numeric;
  v_first boolean;
  v_user_id uuid;
begin
  -- Server-initiated (admin-wallet-recharge, which has already run
  -- requireRole(ADMIN)) is trusted and identifies the approving admin through
  -- p_admin_id. A direct client call must still prove both halves.
  if not public.is_server_write() then
    if not public.admin_can('sales_transactions') or p_admin_id is distinct from auth.uid() then
      raise exception 'INSUFFICIENT_PERMISSION';
    end if;
  end if;

  select * into v_recharge from wallet_recharge_requests where id = p_recharge_id for update;
  if v_recharge.id is null then
    raise exception 'RECHARGE_REQUEST_NOT_FOUND';
  end if;
  if v_recharge.status = 'APPROVED' then
    return v_recharge;
  end if;
  if v_recharge.status != 'PENDING' then
    raise exception 'RECHARGE_REQUEST_IS_NOT_PENDING';
  end if;

  select * into v_wallet from wallets where id = v_recharge.wallet_id for update;
  if v_wallet.id is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;

  select pp.registration_fee_paid into v_first
    from provider_profiles pp where pp.id = v_recharge.provider_id;
  if v_first is null then
    raise exception 'PROVIDER_NOT_FOUND';
  end if;

  v_credit := v_recharge.amount;
  if not v_first then
    -- One-time activation: withhold the registration fee from this first
    -- approved recharge and activate the provider. The switch turns the
    -- withholding off without turning activation off: the provider is still
    -- activated (registration_fee_paid is set below either way).
    v_reg_fee := case
      when coalesce(get_setting_bool('fee_enabled_registration'), true)
        then coalesce(get_setting_numeric('provider_registration_fee'), 100)
      else 0
    end;
    if v_recharge.amount < v_reg_fee then
      raise exception 'REGISTRATION_FEE_REQUIRED';
    end if;
    v_credit := v_recharge.amount - v_reg_fee;
  end if;

  update wallets set balance = balance + v_credit, updated_at = now()
   where id = v_wallet.id
   returning * into v_wallet;

  insert into wallet_transactions (
    wallet_id, provider_id, transaction_type,
    gross_amount, platform_fee, net_amount,
    balance_after, status, idempotency_key
  ) values (
    v_wallet.id, v_recharge.provider_id, 'RECHARGE',
    v_recharge.amount, v_recharge.amount - v_credit, v_credit,
    v_wallet.balance, 'COMPLETED', 'recharge:' || v_recharge.id::text
  ) returning * into v_txn;

  if not v_first then
    update provider_profiles
       set registration_fee_paid = true, updated_at = now()
     where id = v_recharge.provider_id;
  end if;

  update wallet_recharge_requests
     set status = 'APPROVED', approved_by = p_admin_id, approved_at = now(), updated_at = now()
   where id = p_recharge_id
   returning * into v_recharge;

  select user_id into v_user_id from provider_profiles where id = v_recharge.provider_id;

  -- The notice follows what actually happened. It used to say a fee was
  -- applied even when one was not.
  if not v_first and v_reg_fee > 0 then
    perform insert_notification(
      v_user_id, 'APPROVAL', 'Account activated',
      'Your ' || v_recharge.amount::text || ' birr payment was received. ' ||
        'The one-time ' || v_reg_fee::text || ' birr registration fee was applied and ' ||
        v_credit::text || ' birr was credited to your wallet. You are ready to trade!',
      jsonb_build_object('recharge_id', p_recharge_id, 'credited', v_credit, 'registration_fee', v_reg_fee)
    );
  else
    perform insert_notification(
      v_user_id, 'APPROVAL', 'Recharge Approved',
      v_recharge.amount::text || ' birr credited to your wallet.',
      jsonb_build_object('recharge_id', p_recharge_id, 'credited', v_credit)
    );
  end if;

  insert into audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (p_admin_id, 'WALLET_RECHARGE_APPROVED', 'wallets', v_wallet.id,
          jsonb_build_object(
            'recharge_id', p_recharge_id,
            'amount', v_recharge.amount,
            'credited', v_credit,
            'registration_fee_withheld', case when not v_first then v_recharge.amount - v_credit else 0 end,
            'registration_fee_enabled', coalesce(get_setting_bool('fee_enabled_registration'), true),
            'provider_activated', not v_first
          ));

  return v_recharge;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. fee_enabled_ride — the platform fare model
-- -----------------------------------------------------------------------------
-- Off means the platform does not quote a fare at all: the estimate is 0 and
-- the rider/driver price the trip themselves. The transaction commission is a
-- separate switch (fee_enabled_transaction) and still applies if it is on.
create or replace function public.calculate_fare_estimate(
  p_pickup_lat double precision,
  p_pickup_lng double precision,
  p_dest_lat double precision,
  p_dest_lng double precision,
  p_vehicle_category_id uuid default null
)
returns numeric(12,2)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_distance_km numeric;
  v_base numeric;
  v_per_km numeric;
  v_min numeric;
  v_meta jsonb;
  v_estimate numeric;
begin
  -- The switch, before the geometry: a switched-off pricing model should not
  -- quote a number, and the cheapest way to not quote one is to not compute it.
  if not coalesce(get_setting_bool('fee_enabled_ride'), true) then
    return 0;
  end if;

  v_distance_km := round(
    (st_distance(
      st_setsrid(st_makepoint(p_pickup_lng, p_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(p_dest_lng, p_dest_lat), 4326)::geography
    ) / 1000.0)::numeric, 2);

  v_base    := COALESCE(get_setting_numeric('ride_base_fare'), 50);
  v_per_km  := COALESCE(get_setting_numeric('ride_per_km'), 20);
  v_min     := COALESCE(get_setting_numeric('ride_minimum_fare'), 80);

  -- Per-category overrides win over the global settings.
  IF p_vehicle_category_id IS NOT NULL THEN
    SELECT metadata INTO v_meta FROM public.categories WHERE id = p_vehicle_category_id;
    v_base   := COALESCE((v_meta ->> 'base_fare')::numeric, v_base);
    v_per_km := COALESCE((v_meta ->> 'per_km')::numeric, v_per_km);
    v_min    := COALESCE((v_meta ->> 'minimum_fare')::numeric, v_min);
  END IF;

  v_estimate := GREATEST(v_min, v_base + v_per_km * v_distance_km);
  RETURN round(v_estimate, 2);
END;
$$;

comment on function public.calculate_fare_estimate(double precision, double precision, double precision, double precision, uuid) is
  'The platform ride fare model: GREATEST(minimum, base + per_km x km), with per-category overrides. Returns 0 when the fee_enabled_ride switch is off, because a switched-off pricing model must not quote a number.';

-- One GRANT covers 4-arg calls too: defaulted params live on the function
-- itself (no overload), so a 4-type GRANT here would raise 42883.
grant execute on function public.calculate_fare_estimate(double precision, double precision, double precision, double precision, uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 8. assert_fees_are_data_driven, made switch-aware
-- -----------------------------------------------------------------------------
-- Restated from migration 62, body copied verbatim except that each check now
-- expects what the SWITCHES say it should expect:
--   * transaction switch on  -> fee == GREATEST(percent, minimum)   (unchanged)
--   * transaction switch off -> fee == 0
--   * ride switch on         -> estimate == base + per_km x km, floored, and
--                               must vary with distance            (unchanged)
--   * ride switch off        -> estimate == 0
--
-- Both directions are asserted. A switch that is wired but inert fails the
-- "off" branch; a switch that leaked into the "on" branch fails the arithmetic.
-- Without this, wiring the switch would have turned CI red the first time a CEO
-- used it, which is exactly the trap migration 69 avoided by not wiring at all.
create or replace function public.assert_fees_are_data_driven()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_percent numeric;
  v_min numeric;
  v_actual numeric;
  v_expected numeric;
  v_src text;
  v_key text;
  v_distance numeric;
  v_base numeric;
  v_per_km numeric;
  v_fare_min numeric;
  v_estimate numeric;
  v_expected_estimate numeric;
  v_tx_on boolean;
  v_ride_on boolean;
  -- Two fixed points in Addis Ababa, matching calculate_fare_estimate's own
  -- (lng, lat) argument order.
  v_pickup_lat double precision := 9.010800;
  v_pickup_lng double precision := 38.761300;
  v_dest_lat double precision := 9.030000;
  v_dest_lng double precision := 38.790000;
begin
  -- Every fee the product charges must have a row.  A missing key means some
  -- reader is falling back to a literal in code.
  FOREACH v_key IN ARRAY ARRAY[
    'transaction_fee_percent', 'transaction_fee_min',
    'provider_registration_fee',
    -- deduct_subscription_fee() reads this with no fallback of its own, so a
    -- missing row there charges nothing and silently breaks subscriptions.
    'monthly_subscription_fee',
    'ride_base_fare', 'ride_per_km', 'ride_minimum_fare'
  ]
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.system_settings WHERE key = v_key) THEN
      RAISE EXCEPTION
        'FEE_%_IS_NOT_IN_system_settings, so it is still code-driven and cannot be changed without a deploy',
        v_key;
    END IF;

    IF (SELECT jsonb_typeof(value) FROM public.system_settings WHERE key = v_key) <> 'number' THEN
      RAISE EXCEPTION 'FEE_%_IS_NOT_STORED_AS_A_NUMBER', v_key;
    END IF;

    IF (SELECT (value #>> '{}')::numeric < 0 FROM public.system_settings WHERE key = v_key) THEN
      RAISE EXCEPTION 'FEE_%_IS_NEGATIVE', v_key;
    END IF;
  END LOOP;

  -- Every switch must exist and be a boolean, or get_setting_bool() has
  -- nothing to read and the coalesce default silently decides the behaviour.
  FOREACH v_key IN ARRAY ARRAY[
    'fee_enabled_transaction', 'fee_enabled_subscription',
    'fee_enabled_registration', 'fee_enabled_ride'
  ]
  LOOP
    IF NOT EXISTS (SELECT 1 FROM public.system_settings WHERE key = v_key) THEN
      RAISE EXCEPTION 'FEE_SWITCH_%_IS_NOT_IN_system_settings', v_key;
    END IF;
    IF (SELECT jsonb_typeof(value) FROM public.system_settings WHERE key = v_key) <> 'boolean' THEN
      RAISE EXCEPTION 'FEE_SWITCH_%_IS_NOT_STORED_AS_A_BOOLEAN', v_key;
    END IF;
  END LOOP;

  v_tx_on := coalesce(public.get_setting_bool('fee_enabled_transaction'), true);
  v_ride_on := coalesce(public.get_setting_bool('fee_enabled_ride'), true);

  v_percent := public.get_setting_numeric('transaction_fee_percent');
  v_min := public.get_setting_numeric('transaction_fee_min');

  -- (a) the charged fee equals the settings arithmetic, at two magnitudes, in
  -- whichever direction the switch points.
  v_actual := public.platform_transaction_fee(1000);
  v_expected := CASE
    WHEN v_tx_on THEN greatest(round(1000 * v_percent / 100.0, 2), v_min)
    ELSE 0
  END;
  IF v_actual <> v_expected THEN
    RAISE EXCEPTION
      'TRANSACTION_FEE_DOES_NOT_FOLLOW_SETTINGS: platform_transaction_fee(1000) is % but fee_enabled_transaction=% with transaction_fee_percent=%/transaction_fee_min=% implies %',
      v_actual, v_tx_on, v_percent, v_min, v_expected;
  END IF;

  -- (b) and the fee is percentage-driven, not a flat number wearing a
  -- setting's name: with a percent above zero a larger trade must cost more.
  -- Only meaningful while the switch is on; when it is off the correct answer
  -- is 0 at every magnitude and (a) already said so.
  IF v_tx_on AND v_percent > 0 AND public.platform_transaction_fee(100000) <= public.platform_transaction_fee(1000) THEN
    RAISE EXCEPTION
      'TRANSACTION_FEE_IS_FLAT: a 100000 gross and a 1000 gross are charged % and % even though transaction_fee_percent is %',
      public.platform_transaction_fee(100000), public.platform_transaction_fee(1000), v_percent;
  END IF;

  -- (c) the fee writer must still go through the settings-backed calculator.
  v_src := pg_get_functiondef('public.deduct_transaction_fee(uuid,uuid,uuid,numeric,text)'::regprocedure);
  IF position('platform_transaction_fee' in v_src) = 0 THEN
    RAISE EXCEPTION 'deduct_transaction_fee() no longer reads the fee from system_settings';
  END IF;
  -- Built with chr(39) rather than an escaped quote so the needle cannot
  -- unbalance this function's own dollar-quoted body.
  IF position(('get_setting_numeric(' || chr(39) || 'transaction_fee' || chr(39)) in v_src) > 0 THEN
    RAISE EXCEPTION 'deduct_transaction_fee() is reading the deleted flat transaction_fee key again';
  END IF;

  -- (d) the fare estimate equals the configured pricing for a known distance.
  v_base := coalesce(public.get_setting_numeric('ride_base_fare'), 50);
  v_per_km := coalesce(public.get_setting_numeric('ride_per_km'), 20);
  v_fare_min := coalesce(public.get_setting_numeric('ride_minimum_fare'), 80);

  v_distance := round((
    st_distance(
      st_setsrid(st_makepoint(v_pickup_lng, v_pickup_lat), 4326)::geography,
      st_setsrid(st_makepoint(v_dest_lng, v_dest_lat), 4326)::geography
    ) / 1000.0
  )::numeric, 2);

  v_estimate := public.calculate_fare_estimate(
    v_pickup_lat, v_pickup_lng, v_dest_lat, v_dest_lng, NULL::uuid
  );

  IF NOT v_ride_on THEN
    -- The "off" direction: a switched-off pricing model must quote nothing.
    IF v_estimate <> 0 THEN
      RAISE EXCEPTION
        'RIDE_PRICING_IS_OFF_BUT_A_FARE_IS_STILL_QUOTED: fee_enabled_ride=false yet calculate_fare_estimate() returned % for a %km trip',
        v_estimate, v_distance;
    END IF;
  ELSE
    v_expected_estimate := round(greatest(v_fare_min, v_base + v_per_km * v_distance), 2);
    IF v_estimate <> v_expected_estimate THEN
      RAISE EXCEPTION
        'RIDE_FARE_DOES_NOT_FOLLOW_SETTINGS: calculate_fare_estimate() returned % but ride_base_fare=% + ride_per_km=% x %km (floor ride_minimum_fare=%) implies %',
        v_estimate, v_base, v_per_km, v_distance, v_fare_min, v_expected_estimate;
    END IF;

    -- (e) distance-based pricing must exist as a concept: a ride fee that does
    -- not vary with distance is not distance-based pricing.
    IF public.calculate_fare_estimate(9.0108, 38.7613, 9.0300, 38.7900, NULL::uuid)
       = public.calculate_fare_estimate(9.0108, 38.7613, 9.0109, 38.7614, NULL::uuid)
       AND v_per_km > 0 THEN
      RAISE EXCEPTION 'RIDE_PRICING_IS_NOT_DISTANCE_BASED: ride_per_km is % but a 3km and a 30m trip estimate the same fare', v_per_km;
    END IF;
  END IF;

  -- (f) the CEO gate on fee writes must still be in place, and must now cover
  -- the switches as well as the numeric fees.
  v_src := pg_get_functiondef('public.admin_update_setting(text,jsonb,text)'::regprocedure);
  IF position('FEES_CAN_ONLY_BE_CHANGED_BY_THE_CEO_OR_OWNER' in v_src) = 0 THEN
    RAISE EXCEPTION 'the CEO-only gate on fee settings has been removed from admin_update_setting()';
  END IF;
  IF position('is_fee_toggle_key' in v_src) = 0 THEN
    RAISE EXCEPTION 'the fee SWITCHES are no longer CEO-only in admin_update_setting() (is_fee_toggle_key is not consulted)';
  END IF;

  RETURN format(
    'fees are data-driven OK: transaction switch=%s -> commission = %s (1000 -> %s, 100000 -> %s); ride switch=%s -> %s + %s/km floor %s, %s km -> %s',
    v_tx_on, CASE WHEN v_tx_on THEN format('GREATEST(%s%% of gross, %s birr)', v_percent, v_min) ELSE 'switched off' END,
    public.platform_transaction_fee(1000), public.platform_transaction_fee(100000),
    v_ride_on, v_base, v_per_km, v_fare_min, v_distance, v_estimate
  );
END;
$$;

grant execute on function public.assert_fees_are_data_driven() to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 9. assert_fee_switches_are_wired — the proof the switches switch
-- -----------------------------------------------------------------------------
-- Declarative for the two switches that only fire on a real money event
-- (registration at recharge approval, subscription on the monthly cycle),
-- behavioural for the two that can be called directly.
--
-- Reported, not raised, in the shape the Connectivity suite reads.
create or replace function public.assert_fee_switches_are_wired()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_problem text[] := '{}';
  v_key text;
  v_src text;
  -- (function, switch it must read)
  v_pairs text[][] := array[
    ['platform_transaction_fee', 'fee_enabled_transaction'],
    ['deduct_subscription_fee',  'fee_enabled_subscription'],
    ['charge_due_subscriptions', 'fee_enabled_subscription'],
    ['approve_wallet_recharge',  'fee_enabled_registration'],
    ['calculate_fare_estimate',  'fee_enabled_ride']
  ];
  v_fn text;
  v_flag text;
  i int;
  v_tx_on boolean;
  v_ride_on boolean;
  v_fee numeric;
  v_gt numeric;
begin
  for i in 1 .. array_length(v_pairs, 1) loop
    v_fn := v_pairs[i][1];
    v_flag := v_pairs[i][2];

    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_fn
    ) then
      v_problem := array_append(v_problem, v_fn || '() is missing');
      continue;
    end if;

    -- pg_get_functiondef needs a resolvable signature; take the one the DB
    -- reports for the name so an overload would be reported rather than
    -- guessed at.
    begin
      select pg_get_functiondef(p.oid) into v_src
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_fn
       order by p.oid
       limit 1;
    exception when others then
      v_problem := array_append(v_problem, v_fn || '(): ' || sqlerrm);
      continue;
    end;

    if position(v_flag in coalesce(v_src, '')) = 0 then
      v_problem := array_append(v_problem,
        v_fn || '() does not read ' || v_flag || ', so that switch is stored but inert');
    end if;
  end loop;

  -- Behavioural, direction 1: with the transaction switch ON the commission
  -- must be the settings arithmetic; with it OFF it must be exactly 0.
  v_tx_on := coalesce(public.get_setting_bool('fee_enabled_transaction'), true);
  v_fee := public.platform_transaction_fee(1000);
  if v_tx_on then
    v_gt := greatest(round(1000 * coalesce(public.get_setting_numeric('transaction_fee_percent'), 0) / 100.0, 2),
                     coalesce(public.get_setting_numeric('transaction_fee_min'), 0));
    if v_fee <> v_gt then
      v_problem := array_append(v_problem,
        format('fee_enabled_transaction is ON but platform_transaction_fee(1000) is % rather than %', v_fee, v_gt));
    end if;
  else
    if v_fee <> 0 then
      v_problem := array_append(v_problem,
        format('fee_enabled_transaction is OFF but platform_transaction_fee(1000) still charges %', v_fee));
    end if;
  end if;

  -- Behavioural, direction 2: the ride model must quote nothing when off.
  v_ride_on := coalesce(public.get_setting_bool('fee_enabled_ride'), true);
  if not v_ride_on then
    if public.calculate_fare_estimate(9.0108, 38.7613, 9.0300, 38.7900, null::uuid) <> 0 then
      v_problem := array_append(v_problem,
        'fee_enabled_ride is OFF but calculate_fare_estimate() still quotes a fare');
    end if;
  end if;

  -- The switches must be reachable and writable by the CEO, or the UI shows a
  -- control that cannot save.
  foreach v_key in array array[
    'fee_enabled_transaction', 'fee_enabled_subscription',
    'fee_enabled_registration', 'fee_enabled_ride'
  ] loop
    if not exists (select 1 from public.system_settings where key = v_key) then
      v_problem := array_append(v_problem, 'switch ' || v_key || ' has no row in system_settings');
    end if;
  end loop;

  if cardinality(v_problem) > 0 then
    return concat('FEE_SWITCHES_NOT_WIRED: ', array_to_string(v_problem, '; '));
  end if;

  return format(
    'all four fee switches are wired: transaction=%s, subscription=%s, registration=%s, ride=%s',
    coalesce(public.get_setting_bool('fee_enabled_transaction'), true),
    coalesce(public.get_setting_bool('fee_enabled_subscription'), true),
    coalesce(public.get_setting_bool('fee_enabled_registration'), true),
    coalesce(public.get_setting_bool('fee_enabled_ride'), true));
end;
$$;

comment on function public.assert_fee_switches_are_wired() is
  'Proves each fee_enabled_* switch is actually consulted: checks the five functions that apply a charge read their switch, and behaviourally checks the two that can be called directly in both directions (on = the settings arithmetic, off = exactly 0). Returns a diagnostic string; never raises.';

grant execute on function public.assert_fee_switches_are_wired() to anon, authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 10. Catalogue the switches for the CEO screen
-- -----------------------------------------------------------------------------
-- The fee editor (admin_fee_catalogue) is a NUMERIC editor: it parses a value
-- as a number, so a boolean must never appear in it. The switches therefore get
-- their own reader, which is what the CEO fee screen binds to.

-- Backwards-compatible single-switch reader, so the app does not have to
-- hardcode the setting table's shape to render a switch.
create or replace function public.fee_switch_state(p_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := nullif(btrim(coalesce(p_key, '')), '');
  v_row public.system_settings;
begin
  if v_key is null or not public.is_fee_toggle_key(v_key) then
    raise exception 'NOT_A_FEE_SWITCH';
  end if;

  select * into v_row from public.system_settings where key = v_key;

  return jsonb_build_object(
    'key', v_key,
    -- Defaults mirror the money functions exactly (coalesce(..., true)), so a
    -- missing row reads as ON in the UI on the same terms it charges as ON.
    'enabled', coalesce((v_row.value #>> '{}')::boolean, true),
    'description', v_row.description,
    'updated_at', v_row.updated_at
  );
end;
$$;

grant execute on function public.fee_switch_state(text) to authenticated, service_role;
revoke execute on function public.fee_switch_state(text) from public, anon;
