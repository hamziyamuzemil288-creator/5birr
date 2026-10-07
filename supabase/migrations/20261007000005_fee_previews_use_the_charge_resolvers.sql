-- =============================================================================
-- 20261007000005_fee_previews_use_the_charge_resolvers.sql
--
-- ITEM H (remainder): every number the app DISPLAYS must come from the same
-- resolver the CHARGE uses.
--
-- The fee editor (00107, 00126) made commission, subscription, activation,
-- ride and booking fees per-CATEGORY and per-CITY through the ten scalar
-- readers `fee_*`. Two paths were left behind:
--
--   1. The one-time activation fee the platform actually withholds. The
--      client previewed it by reading system_settings.provider_registration_fee
--      DIRECTLY, and approve_wallet_recharge() withheld the GLOBAL setting too.
--      So an admin who set a per-city activation fee saw the charge ignore it:
--      the platform quoted one number and withheld another. 00107's own
--      docstring calls that out as the failure mode ("a fee that silently
--      applied to a city the admin did not name is worse than a fee that does
--      not apply") -- here it is the reverse, a fee the admin DID name and the
--      charge ignored.
--
--   2. The product listing fee had no reader at all. It existed as a column
--      (category_fee_settings.product_listing_fee) and in the admin catalogue,
--      but nothing granted to `authenticated` could resolve it, so a provider
--      preview had no door and the posting gate showed no number.
--
-- WHAT THIS MIGRATION CHANGES
-- ---------------------------
--   A. Adds one scalar reader, fee_product_listing_fee(uuid, text), matching
--      the shape and the grant posture of the existing ten.
--   B. Restates approve_wallet_recharge() so the withheld registration fee
--      comes from fee_activation(category, city) -- the SAME resolver the
--      preview calls. The body is otherwise byte-for-byte the function from
--      migration 20260927000073.
--   C. Adds assert_charge_paths_use_the_shared_fee_resolvers(), a live check
--      that reads the DEPLOYED function bodies and fails if a charge path
--      stops calling the shared reader.
--
-- BEHAVIOUR IS UNCHANGED UNLESS AN ADMIN NAMED A PER-CATEGORY ACTIVATION FEE
-- ---------------------------------------------------------------------------
-- fee_activation() already falls back to system_settings.provider_registration_fee,
-- so on every deployment that has no per-category activation override the
-- withheld number is identical to before. The `nullif(..., 0)` wrapper keeps
-- the exact old default (100) for a deployment whose setting row is missing
-- entirely, which fee_activation alone would resolve to 0.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- A. The product listing fee, made resolvable to the same callers as the others
-- -----------------------------------------------------------------------------
-- Deliberately the same precedence as every other reader: the (category, city)
-- row wins, then the category-wide row (city = ''), then system_settings, then
-- 0. A NULL column means "inherit", never "free", so an unedited deployment
-- resolves to exactly the global it would have used.
create or replace function public.fee_product_listing_fee(
  p_category_id uuid,
  p_city text
)
returns numeric
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select f.product_listing_fee
       from public.category_fee_settings f
      where f.id = (select (public.category_fee(p_category_id, p_city)).id)),
    coalesce(public.get_setting_numeric('product_listing_fee'), 0));
$$;

comment on function public.fee_product_listing_fee(uuid, text) is
  'The one-time product listing fee for a category and city. Falls back to '
  'the (category, all-cities) row and then to system_settings.product_listing_fee. '
  'The reader the posting gate and the product form preview from -- the same '
  'number the catalogue the admin edits resolves.';

-- Same grant posture as the ten readers in 00107: authenticated only, never anon.
revoke all on function public.fee_product_listing_fee(uuid, text)
  from public, anon;
grant execute on function public.fee_product_listing_fee(uuid, text)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- A2. The booking fee, given one home for its formula
-- -----------------------------------------------------------------------------
-- fee_booking_base_fare / _per_km / _minimum_fee exist, but nothing composed
-- them: a booking preview would have had to reproduce
-- GREATEST(min, base + per_km * km) in Dart, which is a second copy of a
-- pricing rule and drifts the moment the server changes it. This composes the
-- three readers on the server, exactly as calculate_fare_estimate_at() does
-- for rides, so a booking screen calls ONE reader and cannot disagree with it.
create or replace function public.calculate_booking_fee_at(
  p_category_id uuid,
  p_city text,
  p_distance_km numeric
)
returns numeric
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_base   numeric;
  v_per_km numeric;
  v_min    numeric;
begin
  -- A negative distance is not a booking; it is a bad request. Same posture
  -- as platform_transaction_fee_for(): raise, never quietly quote a number.
  if p_distance_km is null or p_distance_km < 0 then
    raise exception 'DISTANCE_MUST_BE_A_NON_NEGATIVE_NUMBER';
  end if;

  v_base   := public.fee_booking_base_fare(p_category_id, p_city);
  v_per_km := public.fee_booking_per_km(p_category_id, p_city);
  v_min    := public.fee_booking_minimum_fee(p_category_id, p_city);

  return round(greatest(v_min, v_base + v_per_km * p_distance_km), 2);
end;
$$;

comment on function public.calculate_booking_fee_at(uuid, text, numeric) is
  'The booking fee for a category, city and distance. Composes the three '
  'fee_booking_* readers with the same GREATEST(minimum, base + per_km * km) '
  'rule calculate_fare_estimate_at() uses for rides, so the formula has one '
  'home and a preview cannot hold a second copy of it.';

revoke all on function public.calculate_booking_fee_at(uuid, text, numeric)
  from public, anon;
grant execute on function public.calculate_booking_fee_at(uuid, text, numeric)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- B. The activation charge resolves through fee_activation()
-- -----------------------------------------------------------------------------
-- Reproduced from migration 20260927000073_...sql in full. The ONLY change is
-- the `v_reg_fee` assignment inside the `if not v_first` branch: it now asks
-- public.fee_activation() for the provider's own category and city instead of
-- reading the global setting directly. Every guard, ledger row, notification,
-- audit entry and early-return is unchanged.
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
  v_fee_ctx record;
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
    --
    -- The number comes from the SAME resolver the app previews with
    -- (fee_activation for the provider's category and city). It used to read
    -- the global setting directly, so a per-category or per-city activation
    -- fee an admin had set was quoted in the app and ignored at the charge.
    -- provider_fee_context() is the single place that decides a provider's
    -- category and city, so the resolver here and the preview in the app
    -- cannot disagree about WHICH fee applies either.
    select * into v_fee_ctx
      from public.provider_fee_context(v_recharge.provider_id);
    v_reg_fee := case
      when coalesce(get_setting_bool('fee_enabled_registration'), true)
        then coalesce(
          nullif(public.fee_activation(v_fee_ctx.category_id, v_fee_ctx.city), 0),
          coalesce(get_setting_numeric('provider_registration_fee'), 100))
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
            'registration_fee_source', 'fee_activation',
            'provider_activated', not v_first
          ));

  return v_recharge;
end;
$$;

-- -----------------------------------------------------------------------------
-- C. The assertion that keeps the charge paths on the shared readers
-- -----------------------------------------------------------------------------
-- Reads the DEPLOYED function bodies out of pg_proc rather than trusting this
-- file, so it cannot pass on a deployment where an older body is still live.
-- It fails loudly with the exact path that drifted.
create or replace function public.assert_charge_paths_use_the_shared_fee_resolvers()
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  -- path (charge function) -> reader it must call
  c_expected constant text[][] := array[
    ['create_ride_request',     'calculate_fare_estimate_at'],
    ['deduct_transaction_fee',  'platform_transaction_fee_for'],
    ['deduct_subscription_fee', 'fee_subscription'],
    ['approve_wallet_recharge', 'fee_activation']
  ];
  -- The composed readers must keep composing, not re-implement the arithmetic:
  -- each of these must call at least the readers named.
  c_composed constant text[][] := array[
    ['calculate_fare_estimate_at', 'fee_ride_per_km'],
    ['calculate_booking_fee_at',   'fee_booking_per_km']
  ];
  v_def text;
  v_missing text[] := '{}';
  i int;
begin
  for i in 1 .. array_length(c_expected, 1) loop
    v_def := null;
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = c_expected[i][1]
     limit 1;

    if v_def is null then
      v_missing := v_missing || (c_expected[i][1] || ' (function not found)');
    elsif position(c_expected[i][2] in v_def) = 0 then
      v_missing := v_missing || (c_expected[i][1] || ' no longer calls ' || c_expected[i][2]);
    end if;
  end loop;

  for i in 1 .. array_length(c_composed, 1) loop
    v_def := null;
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = c_composed[i][1]
     limit 1;

    if v_def is null then
      v_missing := v_missing || (c_composed[i][1] || ' (function not found)');
    elsif position(c_composed[i][2] in v_def) = 0 then
      v_missing := v_missing || (c_composed[i][1] || ' no longer composes ' || c_composed[i][2]);
    end if;
  end loop;

  if array_length(v_missing, 1) is not null then
    raise exception
      'CHARGE_PATH_VERSION_A_FEE_PREVIEW: % -- displayed and charged numbers '
      'must resolve through the same reader', array_to_string(v_missing, '; ');
  end if;

  return true;
end;
$$;

comment on function public.assert_charge_paths_use_the_shared_fee_resolvers() is
  'Fails when a charge path stops resolving its fee through the shared '
  'fee_* reader the app previews with: create_ride_request -> '
  'calculate_fare_estimate_at, deduct_transaction_fee -> '
  'platform_transaction_fee_for, deduct_subscription_fee -> fee_subscription, '
  'approve_wallet_recharge -> fee_activation. Also fails when the composed '
  'readers stop composing (calculate_fare_estimate_at must keep calling '
  'fee_ride_per_km, calculate_booking_fee_at must keep calling '
  'fee_booking_per_km), so the pricing rule cannot be duplicated in client code.';

revoke all on function public.assert_charge_paths_use_the_shared_fee_resolvers()
  from public, anon;
grant execute on function public.assert_charge_paths_use_the_shared_fee_resolvers()
  to authenticated, service_role;
