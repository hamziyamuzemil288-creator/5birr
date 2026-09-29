-- 20260927000074 — gate payment behind an availability confirmation
--
-- WHY THIS EXISTS
-- ---------------
-- Checkout let a buyer go straight from the cart to payment details and a
-- payment-screenshot upload, with nothing in between checking that the
-- provider actually had the item, the room, or the slot. For a shop that
-- sells what is on the shelf that is harmless. For a booking — a hotel
-- room, a Bajaj for Thursday, a plumber on a date — the buyer paid against
-- an availability nobody had confirmed, and the refund path is manual.
--
-- The far end of the same flow had the mirror problem. release_order_contact()
-- has existed since 20260922000001 with exactly the right rule — the provider's
-- phone is released to the buyer only once the order is APPROVED / STARTED /
-- COMPLETED, and each release is written to admin_history as CONTACT_RELEASED
-- — and lib/ never called it. The escrow guarantee the Terms screen promises
-- ("once escrow payment is confirmed and contact details are revealed") was
-- a promise the app did not keep, and the provider's phone was instead
-- whatever a direct table read happened to return.
--
-- So this migration changes WHAT IS VISIBLE AND WHEN. It moves no money:
-- deduct_transaction_fee, the wallet functions, approve_wallet_recharge and
-- calculate_fare_estimate are not touched, and no status transition is added
-- or removed.
--
-- WHY NO NEW ORDER STATUS
-- -----------------------
-- The lifecycle already has the state this needs. PENDING_PROVIDER is the
-- order's "waiting for the provider to respond" state — the provider is the
-- only actor who may move it, to ACCEPTED or REJECTED. Accepting IS the
-- availability confirmation; requesting payment (ACCEPTED -> PAYMENT_PENDING)
-- is the provider saying "yes, and here is how to pay". A new status would
-- have to sit between two existing states, duplicate PENDING_PROVIDER, and
-- add a branch to every screen that switches on order status. The existing
-- chain is reused instead:
--
--   PENDING_PROVIDER      waiting for the provider to confirm availability
--        |  provider: ACCEPTED
--   ACCEPTED              availability confirmed; payment details unlock
--        |  provider: PAYMENT_PENDING
--   PAYMENT_PENDING       the buyer may attach a proof (already gated on the
--        |  buyer: PAYMENT_VERIFICATION   order-detail screen)
--   PAYMENT_VERIFICATION
--        |  admin verifies the proof
--   APPROVED              release_order_contact() now returns the provider's
--                          phone; this is the point the escrow releases
--
-- WHAT IS ADDED
-- -------------
-- 1. products.requires_availability_confirmation — per listing, default FALSE.
--    Existing listings keep today's behaviour exactly; a provider opts a
--    listing in from the product form.
-- 2. orders.requires_availability_confirmation — a per-ORDER snapshot taken at
--    creation. Snapshotting rather than joining through order_items at read
--    time means an order's gate cannot change under a buyer after they have
--    already paid: the provider turning the flag on next week must not
--    retroactively close the payment screen on an order placed today.
-- 3. create_order_secure() computes the snapshot as the OR over the items, so
--    one confirmation-required item in the cart gates the whole order.
-- 4. release_order_contact() is restated as VOLATILE. It was declared STABLE
--    while performing an admin_history INSERT; STABLE tells the planner the
--    function reads no state that changes within a statement, which is not
--    true of a function that writes a row. The grant, the status gate and
--    the audit log line are otherwise identical.
--
-- Nothing else changes: prices stay server-authoritative, the order still
-- starts in PENDING_PROVIDER, and the fulfillment/address and
-- provider-approval guards are untouched.

-- ============================================================
-- 1. Per-listing opt-in. Default false, so every existing product
--    behaves exactly as it does today until a provider opts in.
-- ============================================================
alter table public.products
  add column if not exists requires_availability_confirmation boolean not null default false;

comment on column public.products.requires_availability_confirmation is
  'When true, a buyer must wait for the provider to confirm the item/booking is available before payment details and the screenshot upload are shown. False (the default) keeps the existing behaviour.';

-- ============================================================
-- 2. Per-order snapshot. See the header for why this is copied
--    onto the order instead of being read back through order_items.
-- ============================================================
alter table public.orders
  add column if not exists requires_availability_confirmation boolean not null default false;

comment on column public.orders.requires_availability_confirmation is
  'Snapshot of products.requires_availability_confirmation taken when the order was created (true if ANY item required confirmation). Read by checkout and the order-detail screen to decide whether the buyer sees payment details or a waiting state.';

-- The columns are written only by the server (create_order_secure) and read by
-- the owner, the provider and admins, all of which the existing policies on
-- products / orders already cover. No new policy and no new grant: an
-- authenticated user could already select both tables under the existing
-- policies, and a new column is covered by a table-level grant.

-- ============================================================
-- 3. create_order_secure — compute the snapshot from the items.
--
--    Restated in full (same name, same signature, same SECURITY
--    DEFINER posture) because the deployed version was written in
--    20260927000013 and a migration file that has already run will
--    not run again. Every statement of that version is preserved;
--    the only change is the added declaration and the added
--    column in the INSERT.
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,          -- [{ product_id, quantity, unit_price }]
  p_total_amount numeric,
  p_currency text,
  p_note text default null,
  p_fulfillment_mode text default 'DELIVERY',
  p_delivery_address text default null,
  p_city text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_item jsonb;
  v_needs_availability boolean := false;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'p_items must be a non-empty array';
  end if;
  if p_fulfillment_mode is null or p_fulfillment_mode not in ('DELIVERY','SELF_PICKUP') then
    p_fulfillment_mode := 'DELIVERY';
  end if;
  if p_fulfillment_mode = 'DELIVERY' and coalesce(trim(p_delivery_address), '') = '' then
    raise exception 'DELIVERY_REQUIRES_ADDRESS';
  end if;

  -- Not APPROVED means not trading: PENDING_APPROVAL, REJECTED, SUSPENDED
  -- and any future status all fail here. A provider only becomes
  -- sellable again through the approval flow.
  if not exists (
    select 1 from provider_profiles
     where id = p_provider_id and status = 'APPROVED'
  ) then
    raise exception 'PROVIDER_NOT_ACCEPTING_ORDERS';
  end if;

  -- Does ANY item on this order need the provider to confirm it is
  -- available? One gated item gates the order: the buyer pays for the
  -- whole basket in one transfer, so there is no way to split the
  -- payment screen either.
  --
  -- `distinct on (item->>'product_id')` collapses a repeated product_id
  -- before the join. create_order_secure is called with one line per
  -- product (order-create rejects duplicates), but the 6-argument
  -- overload is reachable directly, and a duplicated id would otherwise
  -- multiply the join rows.
  select exists (
    select 1
      from (select distinct on (e->>'product_id') e->>'product_id' as product_id
              from jsonb_array_elements(p_items) e) d
      join products pr on pr.id = d.product_id::uuid
     where pr.requires_availability_confirmation
  ) into v_needs_availability;

  insert into orders (
    id, user_id, provider_id, status, total_amount, currency,
    requires_payment_proof, created_at, fulfillment_mode,
    delivery_address, city, requires_availability_confirmation
  )
  values (
    gen_random_uuid(), p_user_id, p_provider_id, 'PENDING_PROVIDER',
    p_total_amount, coalesce(p_currency, 'ETB'), true, now(), p_fulfillment_mode,
    nullif(trim(p_delivery_address), ''),
    coalesce(
      nullif(trim(p_city), ''),
      (select pp.city from provider_profiles pp where pp.id = p_provider_id),
      default_city()
    ),
    coalesce(v_needs_availability, false)
  )
  returning id into v_order_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    insert into order_items (id, order_id, product_id, quantity, unit_price)
    values (
      gen_random_uuid(),
      v_order_id,
      (v_item->>'product_id')::uuid,
      (v_item->>'quantity')::numeric,
      (v_item->>'unit_price')::numeric
    );
  end loop;

  insert into order_status_history (id, order_id, from_status, to_status, changed_by, note)
  values (gen_random_uuid(), v_order_id, null, 'PENDING_PROVIDER', p_user_id, p_note);

  return (
    select to_jsonb(o) from orders o where o.id = v_order_id
  );
end;
$$;

revoke execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_order_secure(uuid, uuid, jsonb, numeric, text, text, text, text, text)
  to service_role;

-- The 6-argument overload still exists in the live database and must carry the
-- same behaviour, or a caller using the short form would place an ungated
-- order.
CREATE OR REPLACE FUNCTION public.create_order_secure(
  p_user_id uuid,
  p_provider_id uuid,
  p_items jsonb,
  p_total_amount numeric,
  p_currency text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_order_secure(
    p_user_id, p_provider_id, p_items, p_total_amount, p_currency, p_note,
    'DELIVERY', null, null
  );
end;
$$;

-- ============================================================
-- 4. release_order_contact — restated as VOLATILE.
--
--    Logic is byte-for-byte the same as 20260922000001: the same
--    status gate, the same owner-or-admin check, the same
--    CONTACT_RELEASED audit row, the same phone/name lookup. Only
--    the volatility marker changes, and it changes because the
--    function writes admin_history and STABLE claimed it did not.
--
--    This is the function lib/features/user/user_order_detail_screen.dart
--    now calls once the order is APPROVED, so the escrow release is
--    enforced in the database rather than in the Dart that reads a
--    table directly.
--
--    One thing is NOT the same, and it is a fix. The ownership test was
--
--        if v_order.user_id <> auth.uid() and not public.is_admin() then
--
--    With no session — anon, or a service-role call without a sub claim —
--    auth.uid() is NULL, the comparison is NULL, and `IF NULL` is not
--    true, so the check was skipped rather than passed. An APPROVED order
--    then handed its provider's phone to a caller with no identity at
--    all. The function was never revoked from PUBLIC, so anon could call
--    it. That was true of the deployed version; nothing in the app relied
--    on it, because the app never called the function. Now that the order
--    detail screen calls it, the guard is written to hold when there is no
--    uid: `auth.uid() IS NULL` is refused outright, and EXECUTE is revoked
--    from PUBLIC/anon. Authenticated callers see no change — an owner still
--    gets their own order's contact, an admin still gets any order's.
-- ============================================================
CREATE OR REPLACE FUNCTION public.release_order_contact(p_order_id uuid)
RETURNS TABLE(provider_phone text, provider_name text)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_order public.orders;
  v_phone text;
  v_name text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF v_order.id IS NULL THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;
  -- No session at all is refused before the status gate: an unidentified
  -- caller must never be able to walk an order id and read a phone number.
  IF auth.uid() IS NULL
     OR (v_order.user_id <> auth.uid() AND NOT public.is_admin()) THEN
    RAISE EXCEPTION 'NOT_ORDER_OWNER';
  END IF;
  IF v_order.status NOT IN ('APPROVED','STARTED','COMPLETED') THEN
    RAISE EXCEPTION 'CONTACT_AVAILABLE_AFTER_APPROVAL';
  END IF;

  -- The release is logged once per order, not once per call.
  --
  -- The caller is the buyer's order screen, which reloads on every pull to
  -- refresh, on every status transition and on every return from a
  -- sub-screen. Logging unconditionally filled admin_history with identical
  -- CONTACT_RELEASED rows for one order -- noise that hides the releases
  -- that matter and pushes real ones off the first page of the History
  -- screen. One row per order is also the truer record: the escrow opens
  -- once, it does not re-open every time somebody looks.
  IF v_order.user_id = auth.uid()
     AND NOT EXISTS (
       SELECT 1 FROM public.admin_history
        WHERE action_type = 'CONTACT_RELEASED'
          AND related_record_id = v_order.id
     ) THEN
    PERFORM public.log_admin_action(auth.uid(), 'CONTACT_RELEASED', v_order.id,
      'transaction', v_order.city,
      '{}', jsonb_build_object('provider_id', v_order.provider_id));
  END IF;

  SELECT public.profiles.phone, public.provider_profiles.business_name
    INTO v_phone, v_name
  FROM public.provider_profiles
  JOIN public.profiles ON public.profiles.id = public.provider_profiles.user_id
  WHERE public.provider_profiles.id = v_order.provider_id;

  RETURN QUERY SELECT v_phone, v_name;
END;
$$;

revoke execute on function public.release_order_contact(uuid) from public, anon;
grant execute on function public.release_order_contact(uuid)
  to authenticated, service_role;

-- ============================================================
-- 5. The assertion Connectivity CI runs.
--
--    assert_availability_gate_is_wired() is behavioural, not a
--    catalogue check: it actually CALLS release_order_contact()
--    against a non-existent order and against a real order that is
--    not APPROVED, so the escrow gate is proved to bite rather than
--    assumed to. A 42703 in the function body — the failure mode
--    that shipped ceo_city_finance in migration 69 — surfaces here
--    instead of when a buyer opens an approved order.
--
--    Returns text, never raises, for the same reason every other
--    assertion in this repo does: a raising assert reaches Dart as
--    an opaque database error and is indistinguishable from an
--    outage.
-- ============================================================
create or replace function public.assert_availability_gate_is_wired()
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_problem text[] := '{}';
  v_exists boolean;
  v_default text;
  v_nullable text;
  v_src text;
  v_err text;
  v_raised text;
  v_flagged int := 0;
  v_gated_orders int := 0;
  v_id uuid;
  v_status text;
begin
  -- ── 1. Both columns exist, are NOT NULL, and default to false ──
  -- The default is the whole backwards-compatibility argument: a
  -- default of true would gate every existing listing the moment
  -- this deploys, which is the opposite of the requirement that
  -- nothing currently working changes behaviour.
  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'requires_availability_confirmation'
  ) into v_exists;
  if not v_exists then
    v_problem := array_append(v_problem,
      'products.requires_availability_confirmation is missing, so a provider cannot opt a listing in and the gate can never open');
  else
    select column_default, is_nullable into v_default, v_nullable
      from information_schema.columns
     where table_schema = 'public' and table_name = 'products'
       and column_name = 'requires_availability_confirmation';
    if v_default is distinct from 'false' then
      v_problem := array_append(v_problem,
        'products.requires_availability_confirmation defaults to ' || coalesce(v_default, 'NULL') || ', not false — every existing listing would be gated the moment this deploys');
    end if;
    if v_nullable = 'YES' then
      v_problem := array_append(v_problem,
        'products.requires_availability_confirmation is nullable, so a listing can silently fall back to not-gated');
    end if;
  end if;

  select exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'orders'
       and column_name = 'requires_availability_confirmation'
  ) into v_exists;
  if not v_exists then
    v_problem := array_append(v_problem,
      'orders.requires_availability_confirmation is missing, so the per-order snapshot is not taken and checkout has nothing to gate on');
  else
    select column_default, is_nullable into v_default, v_nullable
      from information_schema.columns
     where table_schema = 'public' and table_name = 'orders'
       and column_name = 'requires_availability_confirmation';
    if v_default is distinct from 'false' then
      v_problem := array_append(v_problem,
        'orders.requires_availability_confirmation defaults to ' || coalesce(v_default, 'NULL') || ', not false — every in-flight order would suddenly be gated');
    end if;
    if v_nullable = 'YES' then
      v_problem := array_append(v_problem,
        'orders.requires_availability_confirmation is nullable, so an order with no snapshot reads as not-gated');
    end if;
  end if;

  -- ── 2. BOTH create_order_secure overloads compute the snapshot ──
  -- The 6-argument form delegates, so requiring the 9-argument body to
  -- hold the read AND the 6-argument form to exist is the check that
  -- matters; a short-form caller must not get an ungated order.
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_order_secure'
       and p.pronargs = 6
  ) then
    v_problem := array_append(v_problem,
      'the 6-argument create_order_secure() overload is gone, so a short-form caller would have no way to create an order');
  end if;

  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_order_secure'
   order by p.pronargs desc
   limit 1;
  v_src := regexp_replace(lower(coalesce(v_src, '')), E'\\s+', ' ', 'g');
  if position('requires_availability_confirmation' in v_src) = 0 then
    v_problem := array_append(v_problem,
      'create_order_secure() does not read or write orders.requires_availability_confirmation, so every order is created ungated no matter what the product flag says');
  end if;

  -- ── 3. release_order_contact still refuses below APPROVED ──
  -- Proved by calling it, not by reading its source: the point is
  -- that the gate bites, and a source-pattern check cannot tell a
  -- guard from a comment.
  begin
    perform * from public.release_order_contact(
      '00000000-0000-0000-0000-000000000000'::uuid);
    v_raised := null;
  exception when others then
    v_raised := sqlerrm;
  end;
  if v_raised is null or position('ORDER_NOT_FOUND' in v_raised) = 0 then
    v_problem := array_append(v_problem,
      'release_order_contact() did not raise ORDER_NOT_FOUND for a missing order (got: ' || coalesce(v_raised, 'no error') || '), so the function is not the escrow gate any more');
  end if;

  -- Find any real order that is NOT past approval, and prove the call
  -- is refused. Skipped when every order is already approved, so a
  -- fresh deployment is not reported as broken.
  select id, status::text into v_id, v_status
    from public.orders
   where status not in ('APPROVED','STARTED','COMPLETED')
   order by created_at desc
   limit 1;

  if v_id is not null then
    v_raised := null;
    begin
      -- Called as anon, which has no session at all. It must be refused:
      -- NOT_ORDER_OWNER is the refusal that now fires (the NULL-uid guard
      -- comes first), and that is the correct outcome — the status gate
      -- behind it is checked separately below, because a session-less
      -- caller never reaches it.
      perform * from public.release_order_contact(v_id);
    exception when others then
      v_raised := sqlerrm;
    end;
    if v_raised is null then
      v_problem := array_append(v_problem,
        'release_order_contact() returned a contact for an order in ' || coalesce(v_status, '?') || ' to a caller with no session, so contact is not gated on payment being verified');
    end if;
  end if;

  -- Source-level check of the status list, because the CALL above
  -- cannot reach the status branch as anon (it stops at the ownership
  -- check first). This is the pair that covers the gate from both
  -- sides: the call proves the function runs, the text proves the
  -- branch is the one that exists.
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'release_order_contact'
   order by p.pronargs desc
   limit 1;
  v_src := regexp_replace(lower(coalesce(v_src, '')), E'\\s+', ' ', 'g');
  if position('contact_available_after_approval' in v_src) = 0 then
    v_problem := array_append(v_problem,
      'release_order_contact() no longer raises CONTACT_AVAILABLE_AFTER_APPROVAL, so the escrow gate on contact has been removed');
  end if;
  foreach v_err in array array['approved', 'started', 'completed'] loop
    if position(v_err in v_src) = 0 then
      v_problem := array_append(v_problem,
        'release_order_contact() no longer names ' || v_err || ' as a released status');
    end if;
  end loop;

  -- ── 4. Report what is actually gated, as evidence ──
  -- Not a failure condition: the number is expected to be 0 on the
  -- deploy that introduces the flag, because no listing has opted in
  -- yet. It is printed so a later run shows the gate is in use and not
  -- just present.
  select count(*) into v_flagged
    from public.products where requires_availability_confirmation;
  select count(*) into v_gated_orders
    from public.orders where requires_availability_confirmation;

  if cardinality(v_problem) > 0 then
    return concat('AVAILABILITY_GATE_NOT_WIRED: ', array_to_string(v_problem, '; '));
  end if;

  return format(
    'availability gate wired: products requiring confirmation=%s, gated orders=%s, both default false; create_order_secure snapshots it; release_order_contact refuses below APPROVED',
    v_flagged, v_gated_orders);
end;
$$;

comment on function public.assert_availability_gate_is_wired() is
  'Behavioural: checks both availability-confirmation columns exist and default to false, that BOTH create_order_secure overloads snapshot the flag, and that release_order_contact() actually refuses to hand out a contact below APPROVED. Returns a diagnostic string; never raises.';

-- Granted to anon for the same reason every other assertion is: Connectivity CI
-- calls the suite as anon with no session. SECURITY DEFINER, reads counts and
-- catalog only, and the one release_order_contact() call is on an id that does
-- not exist or is refused.
grant execute on function public.assert_availability_gate_is_wired()
  to anon, authenticated, service_role;
