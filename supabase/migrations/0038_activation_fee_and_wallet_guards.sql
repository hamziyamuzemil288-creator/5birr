-- 0038_activation_fee_and_wallet_guards.sql
-- Applied: 2026-09-20
--
-- One migration, five related fixes (requested 2026-09-20):
--
-- 1. REGISTRATION FEE (activation gate)
--    provider_profiles.registration_fee_paid (bool, default false). A provider
--    cannot upload listings, receive order-location reveals, or accept orders
--    until their FIRST wallet recharge is approved. That first approval credits
--    (amount - registration_fee) and flips the flag; later approvals credit in
--    full. Fee amount is the 'provider_registration_fee' setting (default 100).
--
-- 2. LOW-BALANCE NOTIFICATION (shared, non-spamming)
--    maybe_notify_low_wallet() fires a WALLET_LOW notification once per drop
--    below the threshold — deduped against the provider's most recent wallet
--    credit, so it re-arms only after the balance actually goes back up.
--    Threshold 'low_wallet_threshold' is raised 15 -> 20 per spec.
--
-- 3. MINIMUM TRANSACTION FEE
--    deduct_transaction_fee() now charges fee = max(amount * 1%, 5 birr)
--    (minimum via 'transaction_fee_min' setting, default 5). The separate
--    5birr MONTHLY subscription fee (deduct_subscription_fee) is untouched.
--
-- 4. ZERO-BALANCE ORDER GATE
--    create_order_secure() rejects orders for unactivated providers
--    (PROVIDER_NOT_ACTIVATED) and for providers whose wallet balance is 0
--    (PROVIDER_WALLET_EMPTY), notifying the provider in both cases so they
--    know to recharge. Location reveal functions respect the same gate.
--
-- 5. PROVIDER PRESENCE
--    provider_profiles.last_active_at + touch_provider_activity() RPC
--    (caller-owned rows only) for online / last-seen display.
--
-- No destructive statements; nothing existing is weakened. RLS on
-- provider_profiles is untouched (presence + flag changes happen only via
-- SECURITY DEFINER functions with strict, narrow WHERE clauses).

-- ============================================================================
-- 1. Registration fee flag + setting
-- ============================================================================
alter table public.provider_profiles
  add column if not exists registration_fee_paid boolean not null default false;
alter table public.provider_profiles
  add column if not exists last_active_at timestamptz;

insert into system_settings (key, value, description) values
  ('provider_registration_fee', '100', 'One-time birr fee withheld from the first approved recharge to activate a provider account'),
  ('transaction_fee_min', '5', 'Minimum birr transaction fee charged per completed provider transaction')
on conflict (key) do nothing;

update system_settings set value = '20', description = 'Balance at or below this triggers the one-time-per-drop low-wallet warning'
  where key = 'low_wallet_threshold' and value <> '20';

-- ============================================================================
-- 2. Shared, non-spamming low-balance notification
--    Called from every wallet-deduction path (transaction fee, subscription
--    fee). Fires once per drop below the threshold: deduped against the last
--    wallet CREDIT, so a fresh drop after a recharge notifies again, but
--    consecutive deductions below the threshold do not repeat.
-- ============================================================================
create or replace function public.maybe_notify_low_wallet(
  p_wallet public.wallets,
  p_provider_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_threshold numeric;
  v_last_credit timestamptz;
  v_user_id uuid;
begin
  v_threshold := coalesce(get_setting_numeric('low_wallet_threshold'), 20);
  if p_wallet.balance > v_threshold then
    return; -- above threshold: nothing to do
  end if;

  -- Only notify if the provider has not been warned since their most recent
  -- wallet credit (i.e. this is a NEW drop below the threshold, not a
  -- continuation of an already-reported low balance).
  select max(t.created_at) into v_last_credit
    from wallet_transactions t
   where t.wallet_id = p_wallet.id
     and t.net_amount > 0
     and t.status = 'COMPLETED'
     and t.transaction_type in ('RECHARGE','ADMIN_CASH','DEPOSIT','ADJUSTMENT','REFUND');

  if exists (
    select 1 from notifications n
     where n.type = 'WALLET_LOW'
       and n.data->>'wallet_id' = p_wallet.id::text
       and (v_last_credit is null or n.created_at > v_last_credit)
  ) then
    return;
  end if;

  select user_id into v_user_id from provider_profiles where id = p_provider_id;
  if v_user_id is null then
    return;
  end if;

  perform insert_notification(
    v_user_id,
    'WALLET_LOW',
    'Wallet balance low',
    'Your wallet balance is ' || p_wallet.balance::text ||
      ' birr — recharge now so fees and orders are not blocked.',
    jsonb_build_object(
      'wallet_id', p_wallet.id,
      'balance', p_wallet.balance,
      'threshold', v_threshold
    )
  );
end;
$$;

revoke execute on function public.maybe_notify_low_wallet(public.wallets, uuid)
  from public, anon, authenticated;
-- service_role (edge functions) and SECURITY DEFINER callers reach it through
-- the fee functions below; no direct grants needed.

-- ============================================================================
-- 3. Trade/readiness gate used by order creation and location reveal
-- ============================================================================
create or replace function public.can_provider_trade(p_provider_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from provider_profiles pp
     where pp.id = p_provider_id
       and pp.status = 'APPROVED'
       and pp.registration_fee_paid
  );
$$;

revoke execute on function public.can_provider_trade(uuid) from public, anon;
grant execute on function public.can_provider_trade(uuid) to authenticated, service_role;

-- ============================================================================
-- 4. Transaction fee: max(1%, 5birr) + shared low-balance check
--    (single shared function — the same one the order/ride transitions and
--    the wallet-deduct-fee endpoint already call; no duplicates introduced.
--    The 5birr MONTHLY fee lives in deduct_subscription_fee() and is untouched.)
-- ============================================================================
create or replace function public.deduct_transaction_fee(
  p_provider_id uuid,
  p_order_id uuid,
  p_ride_id uuid,
  p_gross_amount numeric,
  p_idempotency_key text
)
returns public.wallet_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_wallet wallets;
  v_fee numeric;
  v_fee_min numeric;
  v_allow boolean := get_setting_bool('allow_negative_wallet');
  v_txn wallet_transactions;
  v_existing wallet_transactions;
begin
  select * into v_existing from wallet_transactions where idempotency_key = p_idempotency_key;
  if v_existing.id is not null then
    return v_existing;
  end if;

  -- Fee = 1% of the transaction amount, with a flat minimum (default 5 birr):
  -- fee = max(amount * 0.01, transaction_fee_min).
  v_fee_min := coalesce(get_setting_numeric('transaction_fee_min'), 5);
  v_fee := greatest(p_gross_amount * 0.01, v_fee_min);

  select * into v_wallet from wallets where provider_id = p_provider_id for update;
  if v_wallet.id is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;

  if not v_allow and (v_wallet.balance - v_fee) < 0 then
    insert into wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
    values (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'FAILED', p_idempotency_key)
    returning * into v_txn;
    perform insert_notification(
      (select user_id from provider_profiles where id = p_provider_id),
      'WALLET_EMPTY',
      'Wallet balance too low',
      'Transaction fee could not be deducted — please recharge your wallet.',
      jsonb_build_object('wallet_id', v_wallet.id)
    );
    raise exception 'INSUFFICIENT_WALLET_BALANCE';
  end if;

  update wallets set balance = balance - v_fee, updated_at = now()
   where id = v_wallet.id
   returning * into v_wallet;

  insert into wallet_transactions (wallet_id, provider_id, order_id, ride_request_id, transaction_type, gross_amount, platform_fee, net_amount, balance_after, status, idempotency_key)
  values (v_wallet.id, p_provider_id, p_order_id, p_ride_id, 'TRANSACTION_FEE', p_gross_amount, v_fee, p_gross_amount - v_fee, v_wallet.balance, 'COMPLETED', p_idempotency_key)
  returning * into v_txn;

  insert into audit_logs (event_type, entity_type, entity_id, metadata)
  values ('TRANSACTION_FEE_DEDUCTED', 'wallets', v_wallet.id,
          jsonb_build_object('provider_id', p_provider_id, 'fee', v_fee, 'balance_after', v_wallet.balance));

  perform insert_notification(
    (select user_id from provider_profiles where id = p_provider_id),
    'TRANSACTION_FEE_DEDUCTED',
    'Platform fee deducted',
    v_fee::text || ' birr deducted from your wallet.',
    jsonb_build_object('wallet_id', v_wallet.id, 'fee', v_fee)
  );

  -- Shared, non-spamming low-balance check (fix: fires once per drop, at 20).
  perform maybe_notify_low_wallet(v_wallet, p_provider_id);

  return v_txn;
end;
$$;

-- The monthly subscription deduction gets the same shared low-balance check
-- (fee AMOUNT and cycle logic are unchanged).
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

-- ============================================================================
-- 5. Recharge approval: withhold the one-time registration fee on the FIRST
--    recharge, credit (amount - fee), flip registration_fee_paid. Every later
--    recharge credits the full amount. Admin cash/manual paths keep their
--    existing behaviour.
-- ============================================================================
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
  if not exists (select 1 from user_roles where user_id = p_admin_id and role = 'ADMIN') then
    raise exception 'ONLY_ADMINISTRATORS_CAN_APPROVE_RECHARGES';
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
    -- approved recharge and activate the provider.
    v_reg_fee := coalesce(get_setting_numeric('provider_registration_fee'), 100);
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

  if not v_first then
    perform insert_notification(
      v_user_id, 'APPROVAL', 'Account activated',
      'Your ' || v_recharge.amount::text || ' birr payment was received. ' ||
        'The one-time 100 birr registration fee was applied and ' ||
        v_credit::text || ' birr was credited to your wallet. You are ready to trade!',
      jsonb_build_object('recharge_id', p_recharge_id, 'credited', v_credit, 'registration_fee', v_recharge.amount - v_credit)
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
            'provider_activated', not v_first
          ));

  return v_recharge;
end;
$$;

-- ============================================================================
-- 6. Order creation gate: unactivated providers and 0-balance wallets cannot
--    take orders. The provider is notified in both cases so they know to
--    recharge. Everything else about order creation is unchanged.
-- ============================================================================
create or replace function public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_sector text;
  v_order_number text;
  v_provider_user uuid;
  v_balance numeric;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;

  select user_id into v_provider_user from provider_profiles where id = p_provider_id;
  if v_provider_user is null then
    raise exception 'PROVIDER_NOT_FOUND';
  end if;

  -- Activation gate: the one-time registration fee must be paid.
  if not can_provider_trade(p_provider_id) then
    perform insert_notification(
      v_provider_user,
      'PAYMENT_REMINDER',
      'Recharge required to accept orders',
      'A customer tried to order from you but your account is not activated yet. Complete your first wallet recharge (includes the one-time 100 birr registration fee) to start receiving orders.',
      jsonb_build_object('reason', 'NOT_ACTIVATED')
    );
    raise exception 'PROVIDER_NOT_ACTIVATED';
  end if;

  -- Zero-balance gate: the provider must be able to cover the transaction fee.
  select balance into v_balance from wallets where provider_id = p_provider_id;
  if v_balance is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;
  if v_balance <= 0 then
    perform insert_notification(
      v_provider_user,
      'PAYMENT_REMINDER',
      'Recharge required to accept orders',
      'A customer tried to order from you but your wallet balance is 0. Recharge your wallet so you can accept this order.',
      jsonb_build_object('reason', 'WALLET_EMPTY')
    );
    raise exception 'PROVIDER_WALLET_EMPTY';
  end if;

  -- Category group for the order number (from the first product's sector).
  select c.marketplace_sector into v_sector
    from products p
    join categories c on c.id = p.category_id
   where p.id = (p_items->0->>'product_id')::uuid
   limit 1;

  if v_sector is null then
    select c.marketplace_sector into v_sector
      from provider_profiles pp
      join categories c on c.id = pp.category_id
     where pp.id = p_provider_id
     limit 1;
  end if;

  v_order_number := allocate_order_number(coalesce(v_sector, 'OTHER'));

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, order_number, created_at
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'CREATED', p_total_amount,
    coalesce(p_currency, 'ETB'), true, v_order_number, now()
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(),
      v_order_id,
      (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::int,
      (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'CREATED', p_user_id, p_note);

  perform insert_notification(
    v_provider_user,
    'ORDER_RECEIVED',
    'New order received',
    'Order ' || v_order_number || ' has been placed.',
    jsonb_build_object('order_id', v_order_id, 'order_number', v_order_number)
  );

  return (select to_jsonb(o) from orders o where o.id = v_order_id);
end;
$$;

revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text)
  to service_role;

-- ============================================================================
-- 7. Location reveal respects the activation gate
--    (escrow timing itself is unchanged — still APPROVED/STARTED only)
-- ============================================================================
create or replace function public.set_order_delivery_location(
  p_order_id uuid, p_lat double precision, p_lng double precision
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_status text; v_owner uuid; v_provider uuid;
begin
  select o.user_id, o.status::text, o.provider_id into v_owner, v_status, v_provider
    from orders o where o.id = p_order_id;
  if v_owner is null then raise exception 'ORDER_NOT_FOUND'; end if;
  if v_owner != auth.uid() then raise exception 'NOT_YOUR_ORDER'; end if;
  if v_status not in ('APPROVED', 'STARTED') then
    raise exception 'LOCATION_NOT_REVEALED';
  end if;
  -- Unactivated providers cannot receive order location reveals.
  if not can_provider_trade(v_provider) then
    raise exception 'PROVIDER_NOT_ACTIVATED';
  end if;
  update orders
     set delivery_lat = p_lat,
         delivery_lng = p_lng,
         delivery_shared_at = now()
   where id = p_order_id;
end;
$$;

create or replace function public.get_order_delivery_location(p_order_id uuid)
returns table (lat double precision, lng double precision, shared_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_provider_id uuid;
  v_status text;
  v_caller_provider uuid;
begin
  select pp.id into v_caller_provider
    from provider_profiles pp
   where pp.user_id = auth.uid() and pp.status = 'APPROVED';
  if v_caller_provider is null then
    raise exception 'NOT_APPROVED_PROVIDER';
  end if;

  select o.provider_id, o.status::text into v_provider_id, v_status
    from orders o where o.id = p_order_id;
  if v_provider_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;
  if v_provider_id != v_caller_provider then
    raise exception 'NOT_YOUR_ORDER';
  end if;
  if v_status not in ('APPROVED', 'STARTED') then
    raise exception 'LOCATION_NOT_REVEALED';
  end if;
  if not can_provider_trade(v_provider_id) then
    raise exception 'PROVIDER_NOT_ACTIVATED';
  end if;

  return query
    select o.delivery_lat, o.delivery_lng, o.delivery_shared_at
      from orders o where o.id = p_order_id;
end;
$$;

-- ============================================================================
-- 8. Provider presence (online / last seen)
-- ============================================================================
-- Caller-owned heartbeat: each signed-in provider touches ONLY their own
-- profile rows, and only the presence column.
create or replace function public.touch_provider_activity()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update provider_profiles
     set last_active_at = now()
   where user_id = auth.uid()
     and (last_active_at is null or last_active_at < now() - interval '45 seconds');
end;
$$;

revoke execute on function public.touch_provider_activity()
  from public, anon;
grant execute on function public.touch_provider_activity() to authenticated;

-- Read status for one provider (users viewing a profile/listing).
create or replace function public.get_provider_online_status(p_provider_id uuid)
returns table (online boolean, last_seen timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select
    pp.last_active_at is not null
      and pp.last_active_at > now() - interval '3 minutes' as online,
    pp.last_active_at as last_seen
  from provider_profiles pp
  where pp.id = p_provider_id and pp.status = 'APPROVED';
$$;

revoke execute on function public.get_provider_online_status(uuid)
  from public, anon;
grant execute on function public.get_provider_online_status(uuid) to authenticated;

notify pgrst, 'reload schema';
