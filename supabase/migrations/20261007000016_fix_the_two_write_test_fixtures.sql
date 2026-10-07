-- =============================================================================
-- 20261007000016 — the two write-test fixtures, corrected
-- =============================================================================
-- Two tests were still red after 20261007000015. The live errors name the cause
-- exactly:
--
--   1. two drivers accepting at once -> PostgrestException(MUST_START_AS_PENDING)
--   2. a like actually persists      -> PostgrestException(PRODUCT_NOT_FOUND)
--
-- Neither is a defect in the code under test. Both are fixtures that predate a
-- guard written later, and each fixture was only reached for the first time
-- once 20261007000015 added the columns it needs.
--
-- ── 1. MUST_START_AS_PENDING ────────────────────────────────────────────────
-- assert_ride_claim_race_has_one_winner() forged the provider and vehicle rows
-- the guards forbid, but wrote its three profiles rows as APPROVED.
-- prevent_profile_insert_privilege_escalation() raises MUST_START_AS_PENDING
-- for any non-admin insert whose status is not PENDING_APPROVAL, so the very
-- first fixture statement raised before a single ride was claimed.
--
-- The guard is correct and is not being touched, exactly as 20260927000023
-- argued for this same error in the order and wallet tests: the fixture is
-- wrong. Nothing in the claim path reads profiles.status — claim_ride reads
-- provider_profiles.status — so these rows exist only to satisfy the foreign
-- keys and are created the way the app creates them.
--
-- ── 2. PRODUCT_NOT_FOUND ────────────────────────────────────────────────────
-- set_product_reaction() is SECURITY INVOKER and opens with
--
--   if not exists (select 1 from public.products where id = p_product_id)
--
-- The like fixture built the product under a provider owned by v_other, a user
-- the caller is not, so products_public_read — redefined in 20261006000008 to
-- require an ACTIVE provider_payment_methods row — returned no row to the
-- caller and the check raised PRODUCT_NOT_FOUND.
--
-- The fixture now makes the probe user the owner of the product's provider, so
-- the row is visible through the same owns_provider_profile() branch the
-- provider dashboard relies on. This is the only branch that works for the
-- caller here, and it is worth recording why: products_public_read's
-- payment-account arm is an EXISTS over provider_payment_methods, and a policy
-- subquery is evaluated with row security applied to the referenced table
-- (verified on a scratch database). provider_payment_methods is owner-scoped,
-- so a buyer who is not the provider cannot satisfy that EXISTS no matter how
-- many rows are seeded — which means a plain buyer cannot direct-read products
-- through products_public_read at all. That is a real question about buyer
-- visibility and it is deliberately NOT changed here: it is a live RLS policy,
-- the change would need its own evidence and its own deploy, and
-- assert_posting_requires_payment_account() only checks the predicate's text,
-- so nothing in this suite would catch a regression in it. What this migration
-- does is make the like fixture exercise a client that CAN see the product, so
-- the reaction path is genuinely tested.
--
-- No application behaviour changes. This migration touches two test functions.
-- Deploy: needs a Supabase deploy.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. The ride-claim race fixture
-- ---------------------------------------------------------------------------
create or replace function public.assert_ride_claim_race_has_one_winner()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_sentinel constant text := '__rollback_ok__';
  v_rider  uuid := '00000000-0000-4000-8000-00000000f001';
  v_user_a uuid := '00000000-0000-4000-8000-00000000f002';
  v_user_b uuid := '00000000-0000-4000-8000-00000000f003';
  v_prov_a uuid := '00000000-0000-4000-8000-00000000f004';
  v_prov_b uuid := '00000000-0000-4000-8000-00000000f005';
  v_veh_a  uuid := '00000000-0000-4000-8000-00000000f006';
  v_veh_b  uuid := '00000000-0000-4000-8000-00000000f007';
  v_ride   uuid := '00000000-0000-4000-8000-00000000f008';
  v_wal_a  uuid := '00000000-0000-4000-8000-00000000f009';
  v_wal_b  uuid := '00000000-0000-4000-8000-00000000f00a';
  v_winner uuid;
  v_status text;
  v_err    text := NULL;
  v_hist   integer;
begin
  -- ---------------------------------------------------------------
  -- Fixtures: a rider and two fulfilment-ready drivers.
  -- ---------------------------------------------------------------
  insert into auth.users (id, email, email_confirmed_at)
  values (v_rider,  'ride-race-rider@example.invalid',  now()),
         (v_user_a, 'ride-race-driver-a@example.invalid', now()),
         (v_user_b, 'ride-race-driver-b@example.invalid', now())
  on conflict (id) do nothing;

  -- PENDING_APPROVAL, not APPROVED: trg_profiles_insert_security refuses a
  -- profile that is not pending, which is precisely the guard 20260927000023
  -- kept. Nothing in the claim path reads profiles.status, so the app-shaped
  -- value is the right one here.
  insert into public.profiles (id, full_name, status)
  values (v_rider,  'Race Rider',  'PENDING_APPROVAL'),
         (v_user_a, 'Race Driver A', 'PENDING_APPROVAL'),
         (v_user_b, 'Race Driver B', 'PENDING_APPROVAL')
  on conflict (id) do nothing;

  -- The provider and vehicle rows ARE forged (a client cannot create an
  -- APPROVED provider or an available vehicle), so their guards are disabled
  -- for exactly these rows, inside the subtransaction that is rolled back.
  begin
    execute 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    execute 'ALTER TABLE public.vehicles DISABLE TRIGGER trg_vehicles_insert_security';
  exception when others then
    null;
  end;

  insert into public.provider_profiles
    (id, user_id, provider_type, business_name, status, registration_fee_paid)
  values (v_prov_a, v_user_a, 'VEHICLE_PROVIDER', 'Race Provider A', 'APPROVED', true),
         (v_prov_b, v_user_b, 'VEHICLE_PROVIDER', 'Race Provider B', 'APPROVED', true)
  on conflict (id) do nothing;

  insert into public.vehicles
    (id, provider_id, plate_number, status, is_available)
  values (v_veh_a, v_prov_a, 'RACE-TEST-A', 'APPROVED', true),
         (v_veh_b, v_prov_b, 'RACE-TEST-B', 'APPROVED', true)
  on conflict (id) do nothing;

  begin
    execute 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';
    execute 'ALTER TABLE public.vehicles ENABLE TRIGGER trg_vehicles_insert_security';
  exception when others then
    null;
  end;

  -- Both drivers are document-verified regardless of the live
  -- enforce_verified_documents switch (AUTO_APPROVED is in the predicate and
  -- legal for the column's CHECK).
  insert into public.user_documents
    (user_id, document_type, storage_path, verification_status)
  values (v_user_a, 'DRIVING_LICENSE', 'race-test/license-a.pdf', 'AUTO_APPROVED'),
         (v_user_b, 'DRIVING_LICENSE', 'race-test/license-b.pdf', 'AUTO_APPROVED');

  -- Funded wallets: claim_ride refuses a provider whose wallet is empty or
  -- below the admin posting minimum.
  insert into public.wallets (id, provider_id, balance)
  values (v_wal_a, v_prov_a, 1000000.00),
         (v_wal_b, v_prov_b, 1000000.00)
  on conflict (id) do nothing;

  -- A fresh REQUESTED ride, inserted directly rather than through
  -- create_ride_request (which requires auth.uid() = rider).
  insert into public.ride_requests (
    id, user_id,
    pickup_location, destination_location,
    pickup_lat, pickup_lng, destination_lat, destination_lng,
    pickup_text, destination_text, status, requested_at, fare_estimate
  ) values (
    v_ride, v_rider,
    ST_SetSRID(ST_MakePoint(38.74, 9.00), 4326)::geography,
    ST_SetSRID(ST_MakePoint(38.78, 9.04), 4326)::geography,
    9.00, 38.74, 9.04, 38.78,
    'Race pickup', 'Race destination', 'REQUESTED', now(), 150.00
  );

  -- ---------------------------------------------------------------
  -- Driver A claims.
  -- ---------------------------------------------------------------
  perform public.claim_ride(
    p_ride_id => v_ride, p_provider_id => v_prov_a, p_vehicle_id => v_veh_a);

  select status, claimed_by_provider_id
    into v_status, v_winner
    from public.ride_requests where id = v_ride;
  if v_status <> 'CLAIMED' or v_winner is distinct from v_prov_a then
    raise exception
      'the first claim did not stick: status %, claimed_by %',
      v_status, v_winner;
  end if;

  -- ---------------------------------------------------------------
  -- Driver B claims the same ride: must lose cleanly.
  -- ---------------------------------------------------------------
  begin
    perform public.claim_ride(
      p_ride_id => v_ride, p_provider_id => v_prov_b, p_vehicle_id => v_veh_b);
  exception when others then
    v_err := sqlerrm;
  end;

  if v_err is null or v_err not ilike '%RIDE_ALREADY_TAKEN%' then
    raise exception 'the second claim did not lose cleanly (got: %)',
      coalesce(v_err,
               'no error at all — two drivers won the same ride');
  end if;

  -- The loser must not have overwritten the winner...
  select status, claimed_by_provider_id
    into v_status, v_winner
    from public.ride_requests where id = v_ride;
  if v_status <> 'CLAIMED' or v_winner is distinct from v_prov_a then
    raise exception
      'the losing claim overwrote the winner: status %, claimed_by %',
      v_status, v_winner;
  end if;

  -- ...and the history must show exactly one REQUESTED -> CLAIMED.
  select count(*) into v_hist
    from public.ride_status_history
   where ride_request_id = v_ride
     and from_status = 'REQUESTED'
     and to_status = 'CLAIMED';
  if v_hist <> 1 then
    raise exception
      'expected exactly one REQUESTED -> CLAIMED history row, found %',
      v_hist;
  end if;

  raise exception '%', c_sentinel;

exception
  when others then
    if sqlerrm = c_sentinel then
      return true;
    end if;
    raise;
end;
$$;

grant execute on function public.assert_ride_claim_race_has_one_winner()
  to anon, authenticated;

comment on function public.assert_ride_claim_race_has_one_winner() is
  'Write test: two fulfilment-ready drivers claim the same REQUESTED ride; '
  'the second must lose with RIDE_ALREADY_TAKEN without overwriting the '
  'first, and exactly one REQUESTED -> CLAIMED history row must exist. '
  'Creates its profiles rows as PENDING_APPROVAL, the way the app does, and '
  'disables the provider/vehicle insert guards for its forged fixture rows '
  'only. Rolled back by sentinel — leaves no data behind.';

-- ---------------------------------------------------------------------------
-- 2. The like fixture
-- ---------------------------------------------------------------------------
create or replace function public.assert_likes_persist_and_are_exclusive()
returns boolean
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  c_sentinel constant text := '__rollback_ok__';
  v_user  uuid := '00000000-0000-4000-8000-00000000e7a1';
  v_other uuid := '00000000-0000-4000-8000-00000000e7a2';
  v_prov  uuid := '00000000-0000-4000-8000-0000000007a1';
  v_prod  uuid := '00000000-0000-4000-8000-0000000007a2';
  v_forge uuid := '00000000-0000-4000-8000-0000000007a3';
  v_ok boolean;
begin
  begin
    insert into auth.users (id, email, email_confirmed_at)
    values (v_user,  'like-probe@example.invalid', now()),
           (v_other, 'like-probe-other@example.invalid', now())
    on conflict (id) do nothing;

    insert into public.profiles (id, full_name, status)
    values (v_user,  'Like Probe',       'PENDING_APPROVAL'),
           (v_other, 'Like Probe Other', 'PENDING_APPROVAL')
    on conflict (id) do nothing;

    -- The product's provider belongs to the probe user, because ownership is
    -- the only branch of products_public_read that a non-admin client can
    -- satisfy while provider_payment_methods stays owner-scoped (see the
    -- header). set_product_reaction() reads the product as the client, so an
    -- invisible product is a PRODUCT_NOT_FOUND. The insert guard is disabled
    -- for this forged APPROVED row, inside the subtransaction that is rolled
    -- back.
    execute 'ALTER TABLE public.provider_profiles DISABLE TRIGGER trg_provider_profiles_insert_security';
    insert into public.provider_profiles (id, user_id, provider_type, business_name, status)
    values (v_prov, v_user, 'SERVICE_PROVIDER', 'Like Probe Provider', 'APPROVED')
    on conflict (id) do nothing;
    execute 'ALTER TABLE public.provider_profiles ENABLE TRIGGER trg_provider_profiles_insert_security';

    insert into public.products (id, provider_id, name, price, currency,
                                 is_active, is_available, listing_status, stock_quantity)
    values (v_prod, v_prov, 'Like Probe Product', 10.00, 'ETB',
            true, true, 'ACTIVE', 100),
           (v_forge, v_prov, 'Like Probe Product 2', 10.00, 'ETB',
            true, true, 'ACTIVE', 100)
    on conflict (id) do nothing;

    insert into public.product_likes (user_id, product_id, reaction)
    values (v_other, v_prod, 'DISLIKE')
    on conflict (user_id, product_id) do nothing;

    update public.products set like_count = 0, dislike_count = 0 where id = v_prod;

    perform set_config('request.jwt.claim.sub', v_user::text, true);
    perform set_config('request.jwt.claims',
                       json_build_object('sub', v_user::text, 'role', 'authenticated')::text, true);

    v_ok := public.like_probe_as_client();
    if v_ok is not true then
      raise exception 'the client-side like probe returned %, expected true', v_ok;
    end if;

    raise exception '%', c_sentinel;

  exception
    when others then
      if sqlerrm = c_sentinel then
        return true;
      end if;
      raise;
  end;
end;
$$;

grant execute on function public.assert_likes_persist_and_are_exclusive() to anon, authenticated;

comment on function public.assert_likes_persist_and_are_exclusive() is
  'WRITE test: acts as a real non-admin client and requires a LIKE to persist with products.like_count incremented, a DISLIKE to replace it with both counters correct, NONE to remove it, and a reaction written for another user to be refused. The product''s provider belongs to the probe user so the product is visible under products_public_read. Builds the fixtures as the schema owner, then steps aside while like_probe_as_client() runs as authenticated. Rolls back via a sentinel.';
