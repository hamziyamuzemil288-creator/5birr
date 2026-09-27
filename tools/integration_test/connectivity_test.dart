// tools/integration_test/connectivity_test.dart
//
// Phase 3: integration-verification safety net (see CONNECTIONS.md).
// Verifies the app's cross-actor connections end to end against the LIVE
// Supabase project.
//
// Most assertions are read-only. A few are WRITE tests: they do the real work
// inside a subtransaction that is always rolled back (the function raises a
// sentinel to force the unwind), so real rows with real triggers are
// exercised and nothing is left behind. Those exist because the read-only
// ones pass vacuously when a whole feature is dead — see the
// assert_recent_approved_recharges_credited note below.
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

  group('client-write guards do not block the server', () {
    test('order and notification guards exempt server roles', () async {
      // These guards gate on is_admin() = auth.uid(), which is NULL for
      // anything the server does, so each one rejected the server's own
      // writes.
      //
      // The order INSERT guard is the serious one: it required new.status
      // = 'CREATED', and create_order_secure now inserts PENDING_PROVIDER,
      // so it would reject every order the app creates with
      // ORDERS_MUST_START_AS_CREATED. The notification guard rejected
      // pg_cron, which is what aborts the daily subscription run on its
      // overdue-notification path.
      expect(await ok('assert_client_guards_are_server_safe'), isTrue,
          reason: 'An order or notification write guard is no longer '
              'client-scoped, so the server is refused its own writes — which '
              'means orders cannot be created, or the billing job aborts.');
    });
  });

  group('provider status: server may change it, clients may not', () {
    test('the self-approval guard exempts server roles only', () async {
      // The guard reads is_admin(), which is auth.uid() — NULL for anything
      // the server initiates. So it used to reject the pg_cron subscription
      // job and the subscription-process edge function when they moved
      // provider_profiles.status. The suspend branch is not wrapped in an
      // exception block, so the raise aborted the whole daily run: the first
      // provider needing suspension killed the job and everyone after them
      // was skipped. Auto-suspension had never actually worked, and the
      // reactivation path was silently swallowed.
      //
      // The fix scopes the guard to clients via session_user. Both halves
      // are asserted, because the fix must not become "remove the guard":
      // the client branch has to still refuse a status change.
      expect(await ok('assert_provider_status_guard_is_client_scoped'), isTrue,
          reason: 'prevent_provider_self_privilege_escalation either lost its '
              'session_user exemption (breaking the subscription scheduler '
              'again) or lost the client-side refusal (reinstating '
              'self-approval).');
    });
  });

  group('order creation actually works (write test)', () {
    test('a real order is created and persisted, then rolled back', () async {
      // This is the only test in the suite that WRITES, and it exists
      // because the read-only ones let a 25-minute production outage ship
      // green. When create_order_secure was changed to insert
      // PENDING_PROVIDER while a live trigger still demanded CREATED, every
      // order failed — and the order assertion here was a prosrc grep that
      // never created an order, so it could not have caught it.
      //
      // The function does its work in a subtransaction it always rolls back
      // (raising a sentinel to force the unwind), so it asserts against real
      // rows with real triggers attached and leaves nothing behind.
      expect(await ok('assert_order_creation_writes'), isTrue,
          reason: 'create_order_secure did not produce a real order in '
              'PENDING_PROVIDER with its items, or accepted an order from a '
              'non-approved provider. This is the write path, so this failing '
              'means customers cannot check out.');
    });
  });

  group('the server/client discriminator is correct', () {
    test('a client is never classified as a server write', () async {
      // Every client-write guard decides whether to enforce itself with one
      // shared helper, so this single question has two ways to be wrong and
      // both have already happened:
      //
      //  * 0030 tested current_user inside a SECURITY DEFINER trigger, where
      //    current_user is always the function owner — so every caller,
      //    clients included, read as "the server" and the guards disabled
      //    themselves. That left the wallet balance guard inert.
      //  * 00015/16/17 tested session_user, which PostgREST never changes
      //    from `authenticator` — so edge functions still read as clients
      //    and were refused their own writes.
      //
      // This is behavioural, not a source grep: it evaluates the helper in
      // the caller's own context (a Data API call as anon) and requires the
      // answer to be false.
      expect(await ok('assert_server_write_discriminator'), isTrue,
          reason: 'is_server_write() reports true for an ordinary client '
              'call, so every client-write guard is standing down and a '
              'client can write rows that only the server may write.');
    });
  });

  group('a user cannot approve their own account', () {
    test('a non-admin is refused when they try to set their status to APPROVED', () async {
      // profiles_update_own is FOR UPDATE USING (id = auth.uid()) with no
      // column restriction, so a user can write any column of their own row
      // including status. The guard meant to stop that,
      // prevent_profile_self_privilege_escalation, branched on
      // current_user inside a SECURITY DEFINER trigger — where current_user
      // is the function owner for every caller. It returned on its first
      // line, so the check never ran and any authenticated user could
      // PATCH /rest/v1/profiles?id=eq.<their uid> with {"status":"APPROVED"}
      // and approve their own account. The anon key ships in the app bundle.
      //
      // Every other assertion in this suite reads pg_proc.prosrc, and the
      // inert guard had all the right-looking strings in it. This one
      // performs the attack instead.
      expect(await ok('assert_profile_self_approval_is_refused'), isTrue,
          reason: 'A non-admin was able to set their own profile status to '
              'APPROVED, or profiles.city is no longer writable by its '
              'owner. The first is self-approval of the whole account.');
    });
  });

  group('server-mediated admin actions can authorize', () {
    test('the six edge-function RPCs accept service_role and still refuse clients',
        () async {
      // These RPCs are reached through Edge Functions that build a
      // service-role client after authenticating the caller themselves. Under
      // service_role auth.uid() is NULL, so the guard
      //
      //   admin_can(...) OR p_admin_id IS DISTINCT FROM auth.uid()
      //
      // was true on both halves and raised INSUFFICIENT_PERMISSION on every
      // call, before touching a row. Wallet recharges and the whole provider
      // approval pipeline were dead, silently, with no ledger entry and no
      // audit row to notice.
      expect(await ok('assert_admin_rpc_service_role_access'), isTrue,
          reason: 'One of the six admin RPCs reached through an edge function '
              '(approve_wallet_recharge, approve/reject/request_correction/'
              'suspend/unsuspend_provider) either stopped exempting '
              'service_role — so that admin action fails for everyone — or '
              'lost its client-side permission and identity checks, which '
              'would let any caller perform admin actions.');
    });
  });

  group('wallet crediting actually works (write test)', () {
    test('a real recharge is credited through the service-role path, then rolled back',
        () async {
      // assert_recent_approved_recharges_credited, above, cannot answer this
      // question: it asks whether no approved recharge from the last 7 days
      // lacks a ledger row, which is trivially true when nothing was ever
      // approved. It stayed green through a total outage of the feature.
      //
      // This one reproduces the edge function's context with
      // set_config('role','service_role') and calls approve_wallet_recharge
      // for real — the failure only ever appeared under service_role, so a
      // test that called it as itself would have passed against the broken
      // code. It then checks the balance, the request status and the ledger
      // row, and that a second approval does not pay twice.
      expect(await ok('assert_wallet_crediting_writes'), isTrue,
          reason: 'approve_wallet_recharge did not credit the wallet through '
              'the service-role path (250.00 in, 250.00 balance, one RECHARGE '
              'ledger row, still 250.00 after a second attempt), or a direct '
              'client call was allowed. This is the revenue path, so this '
              'failing means providers cannot be paid at all.');
    });
  });

  group('orders cannot be forged by a client', () {
    test('no non-admin INSERT path exists on orders', () async {
      // orders carried a policy allowing any authenticated user to insert
      // their own row with an arbitrary status, total_amount and
      // provider_id. The anon key ships in the app bundle, so anyone could
      // POST a COMPLETED order to /rest/v1/orders and then use it as a
      // ticket for a fabricated review of any product (reviews.target_id
      // has no FK), plus a bypass of server-side pricing and junk in every
      // admin report.
      //
      // Dropping the policy is safe because nothing inserts into orders
      // except create_order_secure(), which is SECURITY DEFINER and is
      // called by the order-create edge function over service_role.
      expect(await ok('assert_orders_not_client_insertable'), isTrue,
          reason: 'A non-admin INSERT policy exists on orders again, so a '
              'client can forge orders — including COMPLETED ones, which '
              'unlock fabricated reviews on any product.');
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

  group('identity documents tell the truth (profile "Verified" bug)', () {
    test('a document has a real admin review lifecycle', () async {
      // The profile tile reported a fixed "Verified" for everyone. The cause
      // was upstream: the status CHECK constraint allowed only MANUAL_REVIEW,
      // AUTO_APPROVED and SUSPECTED_FRAUD, so an administrator had no value to
      // write when they approved an ID — and the client read "a document
      // exists" as "verified". Both halves have to hold: the enum must carry
      // VERIFIED/REJECTED, and provider_docs_satisfied() must still count a
      // VERIFIED document, or approving an ID closes the very gate it was
      // meant to open.
      expect(await ok('assert_document_review_is_admin_only'), isTrue,
          reason: 'review_user_document() is not admin-only, or does not '
              'really write verification_status, or provider_docs_satisfied() '
              'no longer counts a VERIFIED document — so either users can '
              'self-verify or approving an ID locks the provider out.');
    });

    test('a user cannot verify their own document, an admin can', () async {
      // Behavioural, and the half a source-text check cannot do: 0029/0030/
      // 0033/0034 all shipped guards that MENTIONED their condition and never
      // ran it, and the suite was green the whole time. This performs the
      // attack, then requires the legitimate path to still work — removing
      // the admin check would pass an attack-only test and break the feature.
      expect(await ok('assert_document_review_refuses_non_admins'), isTrue,
          reason: 'Either an ordinary user can mark their own ID VERIFIED, or '
              'an administrator cannot verify one at all, or a verified '
              'document leaves provider_docs_satisfied() false.');
    });
  });

  group('staff accounts can actually sign in', () {
    test('every linked staff member has a gateway username', () async {
      // "I created the staff in the admin interface and the login says
      // invalid login or username." link_staff_user attached an auth account
      // and told the operator "$email can now sign in as staff" — while
      // creating no staff_credentials row, which is the only thing
      // staff-login looks the typed name up in. Every linked staff member was
      // permanently locked out, and the non-CEO create path still is.
      expect(await ok('assert_staff_link_gets_a_login'), isTrue,
          reason: 'At least one staff row with an auth user has no '
              'staff_credentials row, so staff-login cannot find it and the '
              'account is unreachable. link_staff_user() must write the row '
              'and refuse a username collision rather than skip it.');
    });
  });
}
