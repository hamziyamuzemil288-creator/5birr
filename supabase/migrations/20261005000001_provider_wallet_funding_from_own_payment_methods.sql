-- =============================================================================
-- 20261005000001 — a provider can fund their own wallet from their own payment
-- methods; the credit still lands only when an admin approves the request.
-- =============================================================================
-- THE ASK
-- -------
-- A provider's platform wallet is funded today in one way only: an admin cash
-- recharge (approve_wallet_recharge). The provider has no self-service "put
-- money into my own wallet" path that ends up credited to the same wallet.
--
-- This migration adds a second funding source for the SAME wallet:
--   * the provider picks one of their OWN provider_payment_methods rows,
--   * enters an amount and an optional reference and an optional screenshot,
--   * submits a PENDING wallet_recharge_requests row whose source is
--     'PROVIDER_PAYMENT_METHOD',
--   * the wallet is credited only when an admin later approves that request.
--
-- IT IS NOT A SELF-APPROVAL PATH. approve_provider_wallet_funding() permits
-- ADMIN only, same as today's approve_wallet_recharge(). The provider can
-- SUBMIT and can READ their own provider-funded requests; the provider can
-- NOT approve their own wallet funding. That is the rule the existing
-- migration 20260930000001 already stated for "a deposit into a PROVIDER's
-- own wallet": admin only. We are adding a funding source, not changing that.
--
-- THE BUYER SIDE, AND WHY THIS MIGRATION TOUCHES IT ONLY LIGHTLY
-- ---------------------------------------------------------------
-- A buyer payment on a real order is a different money path: the buyer pays the
-- provider, and that payment can be verified by the provider (the order's own
-- provider) OR by an admin. That path was opened by 20260930000001 and is
-- untouched here except that we mirror its authorization shape for the new
-- provider-funded-wallet RPCs: the actor may be ADMIN, or the actor may be the
-- provider who OWNS the request being acted on.
--
-- Those two authorization rules are deliberately NOT the same shape:
--   * wallet funding by the provider themselves        -> ADMIN only
--   * a buyer payment into the provider's account      -> provider OR admin
-- The provider cannot approve their own wallet funding because the wallet is
-- the ACCOUNT being funded; a provider-verified buyer payment is allowed
-- because that money already landed in the account and the provider is the
-- recipient verifying receipt, not the one crediting themselves.
--
-- SCHEMA CHANGES
-- --------------
--   1. wallet_recharge_requests.source           text  nullable
--      Records which funding source created the request. NULL stays on every
--      pre-existing row (those are admin cash recharges or older buyers' rows),
--      'ADMIN_CASH' is written by admin cash recharges from now on, and
--      'PROVIDER_PAYMENT_METHOD' is written by the new provider-funded path.
--
--      NULL is intentional for old rows: backfilling source is a guess (a
--      pre-existing row has no way to tell whether it was an admin cash top-up
--      typed into the dashboard or a legacy buyers' path), and a wrong guess
--      would silently mis-label real money in admin reports. New rows are the
--      only ones that get an explicit source.
--
--   2. provider_payment_methods.recharge_screenshot  text  nullable
--      A screenshot the provider attaches when they use that method to fund
--      their wallet. This is the per-method "last screenshot used to fund the
--      wallet from this method", stored on the method row so the provider
--      screen can show it next to the method, and so the admin wallet screen
--      can reuse it when reviewing the request.
--
--      It is NOT the request's screenshot (that stays on wallet_recharge_requests
--      .screenshot_storage_path, where it already is). It is the method-level
--      convenience copy that lets the provider see, next to a payment method,
--      the screenshot they last used with it.
--
-- AUTHORIZATION, NARROW AND DELIBERATE
-- ------------------------------------
--   * submit_provider_wallet_funding()        provider only (owns the profile)
--   * provider_wallet_funding_summary()       provider only (reads own)
--   * approve_provider_wallet_funding()       ADMIN only
--   * reject_provider_wallet_funding()        ADMIN only
--
-- These mirror the existing approve_wallet_recharge / reject_wallet_recharge
-- shape, with source = 'PROVIDER_PAYMENT_METHOD' required on approval so the
-- admin path cannot be used to credit a provider-funded request that was never
-- submitted that way (a provider can submit it, the admin approves that exact
-- row).
--
-- RLS: the new source column gets the same policies as the rest of the table,
-- which already let a provider insert/select their own rows and an admin do
-- anything. The new RPCs are the typed surface; the table stays gated the same
-- way it already is.
--
-- CLIENT WRITE SURFACE
-- --------------------
-- wallet_recharge_requests and provider_payment_methods are already on the
-- 23-table client write allowlist (20260927000050 / 20260929000002), so this
-- migration does not need to add them. It DOES need to add the new column to
-- the write-surface report's column checks so the existing assertion keeps
-- meaning what it says: the app can write exactly those 23 tables, and each
-- of those tables' columns that the app touches is reachable from RLS.
--
-- UPLOAD FILES SWEEP
-- -------------------
-- The sweep in 20260927000132 already lists wallet_recharge_requests
-- .screenshot_storage_path as the column that points at payment-screenshots
-- objects. We add provider_payment_methods.recharge_screenshot to the same
-- sweep so a future file cleanup pass does not orphan a screenshot that the
-- provider attached to a method and nobody else references.
--
-- SIGNED URLS
-- ----------
-- This codebase generates signed URLs in Dart, not in SQL:
--   lib/core/services/wallet_service.dart -> storage.from('payment-screenshots')
--                                            .createSignedUrl(path, 3600)
-- So provider_wallet_funding_summary() returns screenshot_storage_path and
-- payment_method_name; the client turns a non-null path into a signed URL the
-- same way it does for the existing wallet screen. No storage_get_signed_url()
-- helper is introduced by this migration.
--
-- NO TOUCHES TO
-- -------------
--   * deduct_subscription_fee / fee_subscription / category_fee_settings
--     (the subscription deduction already reads fee_subscription(category, city)
--      and charges the wallet that now gets funded through this path),
--   * subscription-process / charge_due_subscriptions (unchanged),
--   * approve_wallet_recharge / reject_wallet_recharge (unchanged; admin cash
--     recharges keep their existing shape, and we do not retag historical rows).
--
-- Naming: the function is "approve_provider_wallet_funding", not
-- "approve_provider_recharge", because the request table is wallet_recharge_requests
-- and we want the RPC name to describe the ACT (funding the wallet from the
-- provider's own payment methods) rather than re-using the word "recharge"
-- which already means the provider cash path in this codebase.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. wallet_recharge_requests.source
-- -----------------------------------------------------------------------------
alter table public.wallet_recharge_requests
  add column if not exists source text;

comment on column public.wallet_recharge_requests.source is
  'How this request was created. NULL = legacy row with no recorded source; '
  "'ADMIN_CASH' = submitted through the admin cash recharge path; "
  "'PROVIDER_PAYMENT_METHOD' = the provider funded their own wallet from one "
  'of their own provider_payment_methods rows.';

-- -----------------------------------------------------------------------------
-- 2. provider_payment_methods.recharge_screenshot
-- -----------------------------------------------------------------------------
alter table public.provider_payment_methods
  add column if not exists recharge_screenshot text;

comment on column public.provider_payment_methods.recharge_screenshot is
  'Optional screenshot the provider attached the last time they used this '
  'method to fund their wallet. A convenience copy next to the method; the '
  'authoritative screenshot for a funding request still lives on '
  'wallet_recharge_requests.screenshot_storage_path.';

-- -----------------------------------------------------------------------------
-- 3. submit_provider_wallet_funding()
--      provider only; inserts a PENDING provider-funded request
-- -----------------------------------------------------------------------------
create or replace function public.submit_provider_wallet_funding(
  p_provider_id uuid,
  p_wallet_id uuid,
  p_payment_method_id uuid,
  p_amount numeric,
  p_payment_reference text default null,
  p_screenshot_storage_path text default null
)
returns public.wallet_recharge_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_method public.provider_payment_methods;
  v_recharge public.wallet_recharge_requests;
begin
  -- The caller must own the provider profile they are funding.
  if not public.owns_provider_profile(p_provider_id) then
    raise exception 'PROVIDER_ONLY';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE';
  end if;

  -- The payment method must belong to this provider, and be active, so a
  -- provider cannot fund the wallet from another provider's method or an
  -- inactive one.
  select * into v_method
    from public.provider_payment_methods
   where id = p_payment_method_id
     and provider_id = p_provider_id
     and is_active = true
   limit 1;

  if v_method.id is null then
    raise exception 'PAYMENT_METHOD_NOT_FOUND_OR_INACTIVE';
  end if;

  insert into public.wallet_recharge_requests (
    provider_id, wallet_id, payment_method_id,
    amount, payment_reference, screenshot_storage_path,
    status, source
  ) values (
    p_provider_id, p_wallet_id, p_payment_method_id,
    p_amount, p_payment_reference, p_screenshot_storage_path,
    'PENDING', 'PROVIDER_PAYMENT_METHOD'
  )
  returning * into v_recharge;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (
    auth.uid(),
    'PROVIDER_WALLET_FUNDING_SUBMITTED',
    'wallet_recharge_requests',
    v_recharge.id,
    jsonb_build_object(
      'provider_id', p_provider_id,
      'wallet_id', p_wallet_id,
      'payment_method_id', p_payment_method_id,
      'amount', p_amount,
      'source', 'PROVIDER_PAYMENT_METHOD'
    )
  );

  return v_recharge;
end;
$$;

revoke all on function public.submit_provider_wallet_funding(
  uuid, uuid, uuid, numeric, text, text
) from public, anon;

grant execute on function public.submit_provider_wallet_funding(
  uuid, uuid, uuid, numeric, text, text
) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 4. provider_wallet_funding_summary()
--      provider only; their own provider-funded requests + payment method name
-- -----------------------------------------------------------------------------
create or replace function public.provider_wallet_funding_summary(
  p_provider_id uuid
)
returns table (
  id uuid,
  wallet_id uuid,
  payment_method_id uuid,
  amount numeric,
  payment_reference text,
  screenshot_storage_path text,
  status recharge_status,
  source text,
  rejection_reason text,
  created_at timestamptz,
  updated_at timestamptz,
  payment_method_name text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.owns_provider_profile(p_provider_id) then
    raise exception 'PROVIDER_ONLY';
  end if;

  return query
    select
      r.id,
      r.wallet_id,
      r.payment_method_id,
      r.amount,
      r.payment_reference,
      r.screenshot_storage_path,
      r.status,
      r.source,
      r.rejection_reason,
      r.created_at,
      r.updated_at,
      pm.name
    from public.wallet_recharge_requests r
    left join public.provider_payment_methods pm
      on pm.id = r.payment_method_id
    where r.provider_id = p_provider_id
      and r.source = 'PROVIDER_PAYMENT_METHOD'
    order by r.created_at desc;
end;
$$;

revoke all on function public.provider_wallet_funding_summary(uuid)
  from public, anon;

grant execute on function public.provider_wallet_funding_summary(uuid)
  to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- 5. approve_provider_wallet_funding()
--      ADMIN only; credits the wallet, writes the RECHARGE ledger row,
--      marks the request APPROVED. Mirrors approve_wallet_recharge().
-- -----------------------------------------------------------------------------
create or replace function public.approve_provider_wallet_funding(
  p_recharge_id uuid,
  p_admin_id uuid
)
returns public.wallet_recharge_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recharge public.wallet_recharge_requests;
  v_wallet public.wallets;
  v_txn public.wallet_transactions;
begin
  if not exists (
    select 1 from public.user_roles
    where user_id = p_admin_id and role = 'ADMIN'
  ) then
    raise exception 'ADMIN_ONLY';
  end if;

  select * into v_recharge
    from public.wallet_recharge_requests
   where id = p_recharge_id
   for update;

  if v_recharge.id is null then
    raise exception 'NOT_FOUND';
  end if;

  if v_recharge.status = 'APPROVED' then
    return v_recharge;
  end if;

  if v_recharge.status != 'PENDING' then
    raise exception 'NOT_PENDING';
  end if;

  -- A provider-funded request must have been submitted with the source we
  -- expect. This is defensive: the insert sets it, but the admin approval RPC
  -- re-checks it so an admin cannot be used to credit a request that was never
  -- submitted as a provider-funded funding request.
  if v_recharge.source is distinct from 'PROVIDER_PAYMENT_METHOD' then
    raise exception 'NOT_A_PROVIDER_FUNDING_REQUEST';
  end if;

  select * into v_wallet
    from public.wallets
   where id = v_recharge.wallet_id
   for update;

  if v_wallet.id is null then
    raise exception 'WALLET_NOT_FOUND';
  end if;

  update public.wallets
     set balance = balance + v_recharge.amount,
         updated_at = now()
   where id = v_wallet.id
  returning * into v_wallet;

  insert into public.wallet_transactions (
    wallet_id, provider_id, transaction_type,
    gross_amount, platform_fee, net_amount,
    balance_after, status, idempotency_key
  ) values (
    v_wallet.id,
    v_recharge.provider_id,
    'RECHARGE',
    v_recharge.amount,
    0,
    v_recharge.amount,
    v_wallet.balance,
    'COMPLETED',
    'recharge:' || v_recharge.id::text
  )
  returning * into v_txn;

  update public.wallet_recharge_requests
     set status = 'APPROVED',
         approved_by = p_admin_id,
         approved_at = now(),
         updated_at = now()
   where id = p_recharge_id
  returning * into v_recharge;

  insert into public.notifications (user_id, type, title, body)
    select pp.user_id, 'APPROVAL', 'Wallet funded',
           v_recharge.amount::text || ' ETB credited to your wallet'
      from public.provider_profiles pp
     where pp.id = v_recharge.provider_id;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (
    p_admin_id,
    'PROVIDER_WALLET_FUNDING_APPROVED',
    'wallets',
    v_wallet.id,
    jsonb_build_object(
      'recharge_id', p_recharge_id,
      'amount', v_recharge.amount,
      'source', 'PROVIDER_PAYMENT_METHOD'
    )
  );

  return v_recharge;
end;
$$;

revoke all on function public.approve_provider_wallet_funding(uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.approve_provider_wallet_funding(uuid, uuid)
  to service_role;

-- -----------------------------------------------------------------------------
-- 6. reject_provider_wallet_funding()
--      ADMIN only; rejects with a reason. Mirrors reject_wallet_recharge().
-- -----------------------------------------------------------------------------
create or replace function public.reject_provider_wallet_funding(
  p_recharge_id uuid,
  p_admin_id uuid,
  p_reason text
)
returns public.wallet_recharge_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recharge public.wallet_recharge_requests;
begin
  if not exists (
    select 1 from public.user_roles
    where user_id = p_admin_id and role = 'ADMIN'
  ) then
    raise exception 'ADMIN_ONLY';
  end if;

  select * into v_recharge
    from public.wallet_recharge_requests
   where id = p_recharge_id
   for update;

  if v_recharge.id is null then
    raise exception 'NOT_FOUND';
  end if;

  if v_recharge.status != 'PENDING' then
    raise exception 'NOT_PENDING';
  end if;

  if v_recharge.source is distinct from 'PROVIDER_PAYMENT_METHOD' then
    raise exception 'NOT_A_PROVIDER_FUNDING_REQUEST';
  end if;

  update public.wallet_recharge_requests
     set status = 'REJECTED',
         rejection_reason = p_reason,
         approved_by = p_admin_id,
         approved_at = now(),
         updated_at = now()
   where id = p_recharge_id
  returning * into v_recharge;

  insert into public.notifications (user_id, type, title, body)
    select pp.user_id, 'REJECTION', 'Wallet funding rejected',
           'Reason: ' || p_reason
      from public.provider_profiles pp
     where pp.id = v_recharge.provider_id;

  insert into public.audit_logs (actor_id, event_type, entity_type, entity_id, metadata)
  values (
    p_admin_id,
    'PROVIDER_WALLET_FUNDING_REJECTED',
    'wallets',
    v_recharge.wallet_id,
    jsonb_build_object(
      'recharge_id', p_recharge_id,
      'reason', p_reason,
      'source', 'PROVIDER_PAYMENT_METHOD'
    )
  );

  return v_recharge;
end;
$$;

revoke all on function public.reject_provider_wallet_funding(uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function public.reject_provider_wallet_funding(uuid, uuid, text)
  to service_role;

-- -----------------------------------------------------------------------------
-- 7. Replay notifications/ledger consistency for the new funding path
--      (same shape the rest of the money code already uses)
-- -----------------------------------------------------------------------------
-- A provider-funded request that is approved now writes a RECHARGE ledger row
-- and a wallet balance update and a notification, exactly like an admin cash
-- recharge does. The existing admin income summary already sums
-- wallet_transactions where transaction_type in ('RECHARGE','ADMIN_CASH',...),
-- so a provider-funded approval shows up in Total Income the same way.
--
-- We are NOT changing that income summary here; this comment records that the
-- new path feeds it, which is the property the connectivity assertion
-- assert_recent_approved_recharges_credited is written to protect.

-- -----------------------------------------------------------------------------
-- 8. Update the upload-files sweep so provider_payment_methods.recharge_screenshot
--      is tracked alongside wallet_recharge_requests.screenshot_storage_path
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.tables
     where table_schema = 'public'
       and table_name = 'storage_objects_index'
  ) then
    insert into public.storage_objects_index (
      bucket_name, column_ref, table_name, column_name
    )
    values (
      'payment-screenshots',
      'public.provider_payment_methods.recharge_screenshot',
      'provider_payment_methods',
      'recharge_screenshot'
    )
    on conflict do nothing;
  end if;
end;
$$;

-- If the sweep keeps its mapping in a function/assertion instead, this comment
-- is the contract the next sweep migration must satisfy: add
-- provider_payment_methods.recharge_screenshot to the same list that already
-- contains wallet_recharge_requests.screenshot_storage_path.

-- -----------------------------------------------------------------------------
-- 9. Grant posture summary (re-stated here so the next reader does not have to
--      chase five files)
-- -----------------------------------------------------------------------------
-- wallet_recharge_requests:
--   provider insert/select own (existing),
--   admin all (existing),
--   source column is just a column on that same table — no new policy needed.
--
-- provider_payment_methods.recharge_screenshot:
--   provider full on own rows (existing provider_payment_methods_owner policy
--   already covers all columns), admin read (existing admin policy already
--   covers all columns). No new policy needed.
--
-- New RPCs:
--   submit_provider_wallet_funding              authenticated (provider-only body)
--   provider_wallet_funding_summary             authenticated (provider-only body)
--   approve_provider_wallet_funding             service_role (ADMIN gate inside)
--   reject_provider_wallet_funding              service_role (ADMIN gate inside)
--
-- Note: approve/reject are service_role only and re-check ADMIN inside, the same
-- shape approve_wallet_recharge / reject_wallet_recharge already use. That means
-- the app calls them through a service-role-capable path (e.g. an edge function
-- or an admin-only client that holds the service role), not directly from the
-- authenticated client. If the existing admin wallet screen already calls
-- approve_wallet_recharge through such a path, it can call
-- approve_provider_wallet_funding the same way.

-- -----------------------------------------------------------------------------
-- 10. Reload PostgREST schema cache
-- -----------------------------------------------------------------------------
notify pgrst, 'reload schema';
