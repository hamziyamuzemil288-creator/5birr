// tools/integration_test/connectivity_test.dart
//
// Phase 3: integration-verification safety net (see CONNECTIONS.md).
// Verifies the app's cross-actor connections end to end against the LIVE
// Supabase project using READ-ONLY RPC assertions — it writes no app data.
//
// Run:   flutter test tools/integration_test/connectivity_test.dart \
//          --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
// CI:    .github/workflows/connectivity-ci.yml runs it on push/PR and fails
//        the pipeline if any connection is broken.
//
// A missing SUPABASE_URL / SUPABASE_ANON_KEY is a HARD FAILURE (the safety
// net must never silently pass), except on fork PRs where secrets are
// unavailable; there the workflow skips with an explicit notice.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

const _url = String.fromEnvironment('SUPABASE_URL');
const _anonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

void main() {
  if (_url.isEmpty || _anonKey.isEmpty) {
    // Safety nets must never silently pass: fail loudly so CI surfaces the
    // misconfiguration instead of reporting a green-but-meaningless run.
    fail('SUPABASE_URL / SUPABASE_ANON_KEY missing. Supply them via '
        '--dart-define (see CONNECTIONS.md).');
  }

  late final SupabaseClient client;

  setUpAll(() {
    client = SupabaseClient(_url, _anonKey);
  });

  Future<bool> ok(String fn) async => (await client.rpc(fn)) == true;

  group('money: wallet ledger -> admin income (Phase 1)', () {
    test('subscription scheduler is wired (pg_cron -> charge_due_subscriptions)',
        () async {
      expect(await ok('assert_subscription_scheduler_scheduled'), isTrue,
          reason: 'The Phase 1 break: nothing scheduled the monthly fee, so '
              'SUBSCRIPTION_FEE rows were never written and Total Income '
              'stayed 0.00. If this fails, the pg_cron jobs are missing.');
    });

    test('wallet balances equal completed ledger totals (no drift)', () async {
      expect(await ok('assert_income_ledger_consistent'), isTrue,
          reason: 'A balance diverging from sum(net_amount) means some path '
              'moved money without writing the ledger — the bug class that '
              'produced a 0.00 Total Income.');
    });

    test('recent completed rides charged their transaction fee', () async {
      expect(await ok('assert_recent_completed_rides_have_fees'), isTrue,
          reason: 'transition_ride_status must charge the fee on COMPLETED; '
              'a missing row means rides froze before completion (break #2).');
    });

    test('recent started/completed orders charged their transaction fee',
        () async {
      expect(await ok('assert_recent_started_orders_have_fees'), isTrue,
          reason: 'transition_order_status must charge the fee on STARTED.');
    });

    test('recent approved recharges credited their wallets', () async {
      expect(await ok('assert_recent_approved_recharges_credited'), isTrue,
          reason: 'approve_wallet_recharge must write the RECHARGE ledger '
              'row the income summary and wallet UI read.');
    });
  });

  group('ride chain: claim -> progress -> fee (Phase 2 #5)', () {
    test('transition function covers the live ARRIVED/TRIP_STARTED chain',
        () async {
      expect(await ok('assert_ride_transition_covers_chain'), isTrue,
          reason: 'The live function previously raised UNEXPECTED_RIDE_STATUS '
              'for ARRIVED/TRIP_STARTED, freezing rides before COMPLETED so '
              'the ride fee never reached the ledger (break #2).');
    });

    test('every ride status has a transition branch', () async {
      // assert_ride_transition_covers_chain only proves ARRIVED and
      // TRIP_STARTED are handled AT ALL. It says nothing about the other
      // statuses — and DRIVER_EN_ROUTE, a live enum value, had no branch at
      // all, so a ride in it raised UNEXPECTED_RIDE_STATUS on every
      // transition: neither rider nor driver could move it, and no fee was
      // ever charged.
      expect(await ok('assert_ride_chain_has_no_dead_ends'), isTrue,
          reason: 'transition_ride_status has no branch for at least one '
              'non-terminal ride status, so a ride in that state is frozen '
              'and cannot be advanced, cancelled, or completed.');
    });
  });

  group('staff attribution: actions -> performance view (Phase 2 #6)', () {
    test('staff_performance uses the real ride ownership column', () async {
      expect(await ok('assert_staff_performance_uses_claimed_by'), isTrue,
          reason: 'ride_requests has no provider_id column — the old query '
              'raised undefined-column and the staff performance view errored '
              'for every staff member (break #3).');
    });
  });

  group('city/GPS: signup city -> scoping (Phase 2 #2)', () {
    test('profiles carry the city column the scoping helpers read', () async {
      expect(await ok('assert_profiles_have_city'), isTrue,
          reason: 'CityService writes profiles.city and the city-scoping '
              'helpers read it; a missing column silently unscopes every '
              'feed.');
    });
  });

  group('user<->provider: order routing (Phase 2 #3)', () {
    test('create_order_secure persists fulfillment + city', () async {
      expect(await ok('assert_create_order_persists_fulfillment'), isTrue,
          reason: 'Checkout fulfillment_mode/delivery_address and city '
              'scoping must survive order creation, or provider queues and '
              'delivery flows lose the data.');
    });
  });

  group('account status stays in sync with provider status', () {
    test('no account is gated by a stale suspension status', () async {
      // suspend_provider set both provider_profiles and profiles to
      // SUSPENDED; unsuspend_provider restored only provider_profiles. The
      // profile stayed SUSPENDED forever and the router — which gates on
      // profiles.status — locked that user out of their own account while the
      // admin panel showed APPROVED.
      final synced = await ok('assert_profile_status_synced');
      if (!synced) {
        try {
          final n = await client.rpc('count_status_mismatches');
          // ignore: avoid_print
          print('accounts with a stale suspension status: $n');
        } catch (_) {
          // Diagnostic is best-effort; the assertion below still fails.
        }
      }
      expect(synced, isTrue,
          reason: 'profiles.status disagrees with provider_profiles.status '
              'for at least one account, so someone is either locked out of '
              'the app or gated as suspended while active. Run '
              'public.count_status_mismatches() for the number affected.');
    });
  });

  group('signup OTP gate', () {
    test('gate keys off verified_at, not attempt arithmetic', () async {
      // The bug this guards: verify_email_otp increments `attempts` on every
      // guess, so a user who typed their code correctly on the third try was
      // told { ok: true } and then rejected at account creation with
      // EMAIL_OTP_REQUIRED. The gate must not infer success from attempts.
      expect(await ok('assert_otp_gate_uses_verified_at'), isTrue,
          reason: 'otp_verified_recently no longer keys off verified_at, so '
              'the signup gate is back to rejecting correctly-typed codes '
              'that needed more than one attempt.');
    });
  });

  group('PostgREST embeds are backed by real foreign keys', () {
    test('every relationship the app embeds resolves', () async {
      // supabase_flutter embeds with `select('a, child(b)')`, which PostgREST
      // resolves through a foreign key only. It does not infer a relationship
      // because two tables point at the same auth.users row — so
      // `provider_profiles(profiles(...))` breaks unless a real FK exists.
      //
      // When this fails, the missing pair is worth reporting: a screen whose
      // embed is invalid gets PGRST201 and renders an error (or, before load
      // -failure handling, an empty list that looked like "no data").
      final okEmbeds = await ok('assert_embed_relationships_exist');
      if (!okEmbeds) {
        try {
          final missing = await client.rpc('missing_embed_relationships');
          // ignore: avoid_print
          print('missing embed relationships: $missing');
        } catch (_) {
          // The diagnostic RPC is best-effort; the assertion below still fails.
        }
      }
      expect(okEmbeds, isTrue,
          reason: 'At least one PostgREST relationship the app embeds is not '
              'backed by a foreign key, so those screens error with PGRST201. '
              'Run public.missing_embed_relationships() for the pair names.');
    });
  });

  group('suspended providers cannot trade', () {
    test('orders are refused for providers that are not APPROVED', () async {
      // Suspension gated the provider out of the app, hid their products
      // from search, and stopped them publishing — but nothing stopped an
      // order being created against a listing that was already ACTIVE. A
      // saved cart or a direct product link still went through, so a
      // suspended provider kept taking work and still earned the fee.
      //
      // That also made non-payment pointless: get suspended for an unpaid
      // subscription fee, then keep trading regardless.
      expect(await ok('assert_orders_block_unapproved_providers'), isTrue,
          reason: 'create_order_secure no longer refuses providers that are '
              'not APPROVED, so a suspended provider can still receive and '
              'be paid for orders.');
    });
  });

  group('order lifecycle has no dead ends', () {
    test('every order status can be advanced out of', () async {
      // Two dead ends lived here for a long time and neither was covered:
      //
      //  * orders were created as CREATED and nothing ever moved them —
      //    the provider had no Accept button and the buyer no transition,
      //    so no order could leave CREATED;
      //  * PAYMENT_VERIFICATION can only be left by an admin, and no admin
      //    screen existed for it, so a customer who had paid sat there
      //    forever and the provider never got APPROVED to start work.
      //
      // The check asserts both that each non-terminal status has an onward
      // branch, and that PAYMENT_VERIFICATION is STILL admin-only — the
      // second is an assertion of the restriction, because loosening it
      // would let a customer approve their own payment.
      expect(await ok('assert_order_chain_has_no_dead_ends'), isTrue,
          reason: 'transition_order_status no longer lets every order status '
              'be advanced, or no longer restricts PAYMENT_VERIFICATION to '
              'admins. Either way an order can get stuck with nobody able to '
              'move it.');
    });
  });

  group('reactivation restores a provider\'s whole account', () {
    test('vehicles go back in service when a provider is reactivated',
        () async {
      // Suspension is three parts: provider_profiles.status,
      // profiles.status, and vehicles.is_available. The revenue-driven
      // reactivation only undid the first two, so a provider whose fee was
      // collected after an admin suspension was left APPROVED everywhere the
      // UI reads it, but their vehicle stayed unavailable — and an
      // unavailable vehicle is filtered out of find_nearby_drivers() and
      // refused by claim_ride(). Approved, unsuspended, fully paid, and
      // unable to take a single ride, with nothing on screen explaining it.
      expect(await ok('assert_vehicle_sync_handled'), isTrue,
          reason: 'sync_profile_status_from_provider() no longer returns '
              'vehicles.is_available to true on reactivation, so a reactivated '
              'provider stays unable to take rides. The trigger must handle '
              'both halves of a suspension, not just the account status.');
    });
  });
}
