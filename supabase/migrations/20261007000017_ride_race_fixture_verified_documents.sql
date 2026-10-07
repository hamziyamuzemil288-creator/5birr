-- =============================================================================
-- 20261007000017 — the ride-race fixture's documents
-- =============================================================================
-- 20261007000016 cleared MUST_START_AS_PENDING; the same test then reached the
-- next guard it had never met:
--
--   PostgrestException(message: PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED)
--
-- provider_fulfilment_blockers() adds DOCUMENTS_UNVERIFIED when the
-- enforce_verified_documents setting is on and provider_documents_verified()
-- is false. The fixture inserts two AUTO_APPROVED driving licences so it does
-- not depend on that setting — but the row does not keep that value.
--
-- prevent_document_verification_forgery(), on trg_user_documents_verification_
-- security, unconditionally rewrites every INSERT to
--
--   NEW.verification_status := 'MANUAL_REVIEW'
--
-- which is exactly right: a client must not be able to upload a document that
-- is already approved. It is also why a fixture cannot forge one by value. The
-- guard is left alone and disabled for the two fixture rows only, inside the
-- subtransaction the sentinel already rolls back — the same shape this
-- assertion already uses for the provider and vehicle guards.
--
-- No application behaviour changes. This migration touches one test function.
-- Deploy: needs a Supabase deploy.
-- =============================================================================

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
  -- profile that is not pending. Nothing in the claim path reads
  -- profiles.status, so the app-shaped value is the right one here.
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

  -- Document-verified regardless of the live enforce_verified_documents
  -- switch, which requires forging the verdict: the insert guard rewrites any
  -- new row to MANUAL_REVIEW, so it is disabled for these two rows only.
  begin
    execute 'ALTER TABLE public.user_documents DISABLE TRIGGER trg_user_documents_verification_security';
  exception when others then
    null;
  end;

  insert into public.user_documents
    (user_id, document_type, storage_path, verification_status)
  values (v_user_a, 'DRIVING_LICENSE', 'race-test/license-a.pdf', 'AUTO_APPROVED'),
         (v_user_b, 'DRIVING_LICENSE', 'race-test/license-b.pdf', 'AUTO_APPROVED');

  begin
    execute 'ALTER TABLE public.user_documents ENABLE TRIGGER trg_user_documents_verification_security';
  exception when others then
    null;
  end;

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
  'disables the provider/vehicle/document-verification insert guards for its '
  'forged fixture rows only. Rolled back by sentinel — leaves no data behind.';
