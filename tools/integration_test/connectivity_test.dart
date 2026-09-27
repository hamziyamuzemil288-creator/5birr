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

  group('the CEO can manage the team, and the team sees it happen', () {
    test('a warning is admin-only, from both doors', () async {
      // The word "warning" did not exist anywhere in this schema. A manager
      // whose only options were silence and revocation had neither, which is
      // why the console could "control" a staff member only by removing their
      // access. Checked behaviourally because the shape that matters — a
      // client writing the row directly, or calling the RPC — is exactly the
      // one a source-text check cannot answer.
      expect(await ok('assert_staff_warnings_are_admin_only'), isTrue,
          reason: 'A non-manager can write a staff warning (directly or '
              'through warn_staff), or can acknowledge a warning that is not '
              'theirs — which would make the acknowledged_at column prove '
              'nothing.');
    });

    test('staff jobs are assignable, and customer ordering is not', () async {
      // staff.permissions was a text[] behind a CHECK naming nine fixed
      // strings, so "assign a job" meant editing a constraint and the Flutter
      // screen carried a third copy of the same list in Dart. It is now a
      // catalogue the CEO picks from, with the product rule — staff never act
      // on a customer's order — as DATA rather than as an accident of which
      // nine keys someone happened to type.
      expect(await ok('assert_staff_job_rules_hold'), isTrue,
          reason: 'set_staff_jobs() must refuse an unknown job, refuse a job '
              'that touches a customer order, grant a real one, keep the '
              'history row when it is removed, and refuse a non-manager.');
    });

    test('the CEO can add a job, not just pick from a seeded list', () async {
      // The catalogue was still, in practice, fixed: ten rows in a migration.
      // Picking a job became easy, but CHOOSING WHICH jobs exist still needed
      // a deploy — so the set was frozen one layer above the CHECK constraint
      // that was removed to unfreeze it.
      expect(await ok('assert_staff_jobs_are_creatable'), isTrue,
          reason: 'create_staff_job() must refuse a non-manager, derive a safe '
              'key from a label alone, and produce a job that can be assigned '
              'immediately; deactivate_staff_job() must refuse while anybody '
              'holds the job and keep the assignment history once they do '
              'not.');
    });

    test('storage writes stay in the caller\'s own folder', () async {
      // Migration 0033 created a second, looser set of policies on three
      // private buckets, and RLS policies OR together -- so the looser set won.
      // One of its disjuncts was a copy-paste from the wrong bucket, letting
      // any signed-in user write outside their own folder in a private
      // bucket. Not readable back, so not a leak, but it breaks the {uid}/
      // invariant every document path depends on.
      //
      // The same migration also replaced product_images_insert with
      // WITH CHECK (bucket_id = 'product-images') and no path check, which the
      // assertion could not see: it read pg_policies.qual, and an INSERT
      // policy has no USING clause, so its rule -- all of it -- is invisible
      // there. product-images is a PUBLIC bucket, so the consequence was not a
      // leak but a write: any signed-in account could overwrite any provider's
      // listing photo, and buyers would be served it immediately. Both halves
      // are covered now.
      expect(await ok('assert_bucket_writes_are_owner_scoped'), isTrue,
          reason: 'A write policy on user-documents, payment-screenshots, '
              'payment-proofs or product-images is not scoped to the caller''s '
              'own folder, or one of them also allows a path in a different '
              'bucket. 0033 shipped both mistakes -- the second as a copy-paste '
              'in the private buckets, and the first as a public bucket anyone '
              'could write to.');
    });

    test('REPORT: the client write surface', () async {
      // A diagnostic, not an assertion. It prints so the next run shows the
      // LIVE state of what a client can write, which cannot be read from the
      // migration files -- a policy created in 0002 and dropped in
      // 20260927000014 is visible in both, and only the database knows which
      // won.
      //
      // This is deliberately print-only on the NUMBERS. Failing the build on a
      // count nobody has read yet would turn the pipeline red for a reason
      // nobody can act on. Once the report has been read and the unexpected
      // entries triaged, the numbers become the contract and this becomes a
      // real assertion.
      //
      // It is NOT silent about the report itself failing, which is what it used
      // to do. The first run of this test went green while the report printed
      // "relation public.objects does not exist" -- the whole point of the
      // work produced no output and nothing noticed. A broken safety net must
      // not read as good news, so the call is unguarded and the report must
      // return one row per kind.
      final rows = await client.rpc('client_write_surface_report');
      expect(rows, isA<List>(), reason: 'client_write_surface_report did not '
          'return a list -- the report is broken, and a broken report is the '
          'finding, not a pass.');
      final byKind = <String, List<String>>{};
      for (final row in (rows as List)) {
        final r = Map<String, dynamic>.from(row as Map);
        byKind['${r['kind']}'] = (r['tables'] as List?)?.cast<String>() ?? const [];
      }
      for (final kind in const ['expected', 'unexpected', 'unguarded']) {
        final names = byKind[kind];
        // ignore: avoid_print
        print('WRITE SURFACE [$kind] (${names?.length ?? -1}): ${names?.join(', ')}');
        expect(names, isNotNull,
            reason: 'client_write_surface_report returned no "$kind" row, so '
                'it is not reporting what it claims to. The safety net is '
                'reporting silence as success.');
      }
      expect(byKind['expected'], hasLength(20),
          reason: 'The expected list in client_write_surface_report() is the '
              'contract for what the app writes client-side. It has drifted '
              'from test/client_write_surface_test.dart, which pins 20.');
    });

    test('REPORT: every client write policy, quoted', () async {
      // The summary buckets classify; this one quotes, because classifying from
      // the catalog went wrong three times: a quoted relation name that does
      // not resolve, a candidate list taken from a view that spans schemas, and
      // -- the one that got here -- reading pg_policies.qual for INSERT
      // policies, whose entire rule lives in with_check. All 21 INSERT
      // policies came back "WIDE" and were about to be treated as findings,
      // including user_roles_admin_write, which is WITH CHECK (is_admin()).
      //
      // All three were invisible to a passing build. This is found only by
      // reading what the output SAYS rather than whether it ran, which is why
      // the report prints and why it fails when it cannot.
      //
      // Judging a policy is a product decision, so this prints both
      // expression columns, the roles the policy applies to, and lets a human
      // read them. The roles are not decoration: `WITH CHECK (true)` that
      // belongs to PUBLIC was the user_roles escalation, and the identical
      // `CHECK: true` on a policy scoped TO service_role is unreachable rather
      // than dangerous. Without the roles the two read the same.
      final rows = await client.rpc('client_write_policy_detail');
      expect(rows, isA<List>(), reason: 'client_write_policy_detail failed; a '
          'broken report is a finding, not a pass.');
      final wide = <String>[];
      for (final row in (rows as List)) {
        final r = Map<String, dynamic>.from(row as Map);
        final roles = '${r['roles'] ?? ''}';
        final using = '${r['using_expr'] ?? ''}';
        final check = '${r['check_expr'] ?? ''}';
        // ignore: avoid_print
        print('WRITE POLICY | ${r['verdict'] == 'WIDE' ? 'WIDE ' : '      '}'
            '${r['table_name']} · ${r['cmd']} · ${r['policy_name']} · to $roles'
            '${using.isEmpty ? '' : '\n          USING: $using'}'
            '${check.isEmpty ? '' : '\n          CHECK: $check'}');
        if (r['verdict'] == 'WIDE') wide.add('${r['table_name']} (${r['cmd']})');
      }
      // ignore: avoid_print
      print('WRITE POLICY | WIDE count: ${wide.length}');
      // ignore: avoid_print
      print('WRITE POLICY | wide list: ${wide.join(', ')}');
    });

    test('a job change is recorded wherever it is made', () async {
      // The CEO's staff editor grants and revokes jobs through update_staff(),
      // and set_staff_jobs() -- the only call that wrote job history -- had no
      // caller anywhere in lib/. The staff member's "My jobs" list still
      // filled in, because my_staff_record() builds it from staff.permissions;
      // what stayed empty was job_history, which it reads from
      // staff_job_assignments. So the history card rendered nothing for every
      // job the console ever granted, and a missing record is invisible in a
      // way a missing screen is not.
      //
      // Behavioural on purpose. A trigger-exists check would have passed on the
      // broken system, because the bug was a record that never happened on the
      // path the app takes, not a function that was wrong.
      expect(await ok('assert_staff_job_changes_are_recorded'), isTrue,
          reason: 'A job granted or removed through update_staff() -- the call '
              'the CEO staff editor makes -- left no staff_job_assignments '
              'row, or a removal wrote a second row instead of closing the '
              'open one, or an edit that changed no job wrote history anyway. '
              'The staff workspace history card reads those rows.');
    });

    test('no function is shadowed by a superseded overload', () async {
      // update_staff had two live signatures: the five-argument one from
      // 20260922000001, and the wider one a later migration replaced it with.
      // 20260923 dropped the six-argument version explicitly and missed this
      // one, so both were live.
      //
      // Nothing was visibly broken, and that is the point: PostgREST resolves a
      // call by argument NAME, so a call whose names fit exactly one overload
      // works. Every caller in the app happens to send a distinctive name, so
      // the ambiguity only bites a caller sending a smaller subset -- which is
      // what the assertion added in 20260927000047 did, and it came back as
      // 42725 "function is not unique". A "Set active" toggle posting
      // {p_staff_id, p_is_active} would have failed the same way, in
      // production, for a user with no way to tell why.
      expect(await ok('assert_no_stale_function_overloads'), isTrue,
          reason: 'A public function has a superseded overload beside it: same '
              'name, parameter names a strict subset with matching types. Any '
              'call whose argument names fit both fails with 42725 "function '
              'is not unique", and which callers are affected depends only on '
              'which optional parameters they happen to send.');
    });

    test('the client write surface is closed, not just reported', () async {
      // The test above prints; this one decides. Turning the report into an
      // assertion is only safe once its numbers have been read, and they now
      // have: the first clean run printed four WIDE rows. Two were real and are
      // fixed in 20260927000046 -- `Service role can insert roles` on
      // user_roles is WITH CHECK (true) on PUBLIC, so any signed-in user could
      // insert themselves an ADMIN row with the anon key that ships in the app
      // bundle and hold every admin policy in the schema, and email_otp_codes
      // let a client seed its own verification row and pass the signup gate
      // without receiving any email. The other two were artifacts of the
      // report's own rule (a missing WITH CHECK means USING for the written
      // row, and a policy no client role reaches is not a finding), and were
      // fixed in the report instead of in the schema.
      //
      // Both halves are asserted together because either alone is insufficient
      // and reports success: a table grant with no write policy still fails in
      // RLS, and a permissive policy on a table a client cannot write is
      // unreachable.
      expect(await ok('assert_client_write_surface_is_closed'), isTrue,
          reason: 'Either a client role can write user_roles, email_otp_codes '
              'or order_items again, or a write policy that a client reaches '
              'has an expression that never mentions the caller. The first is '
              'privilege escalation — a user_roles row with role=ADMIN is '
              'is_admin() for every policy in the schema. Run '
              'public.client_write_policy_detail() for the offending policy '
              'and its roles.');
    });

    test('a staff password change leaves a record of who did it', () async {
      // Self-service password change is the one consequential act a staff
      // member can take on their own account, and it wrote nothing anywhere.
      // The subtlety: the Edge Function authenticates as service_role, which
      // carries no JWT, so log_staff_activity's auth.uid() was NULL there. The
      // row still appeared — with no actor, on the table whose whole purpose
      // is saying who did what. Only the actor value can catch that.
      expect(await ok('assert_staff_password_changes_are_audited'), isTrue,
          reason: 'A self-service password change must be recorded in '
              'staff_activity_log against the real actor (not NULL), as an '
              '"access" event, with no password in the detail — and the '
              '4-argument log_staff_activity() must still mean "the caller".');
    });

    test('money and status changes cannot happen unlogged', () async {
      // admin_cash_recharge, admin_wallet_adjustment, approve_wallet_recharge,
      // transition_order_status, transition_ride_status, claim_ride and
      // suspend_provider wrote no audit row at all. The audit is a trigger
      // rather than a hand-written call in each function, because a call only
      // sees the path that contains it — the same action through an Edge
      // Function was logged, through the SQL editor it was not.
      expect(await ok('assert_money_and_status_are_audited'), isTrue,
          reason: 'A money, status, role or identity table has lost its audit '
              'trigger, so it can change with no trace. The assertion names '
              'the tables.');
    });

    test('the staff task feed updates itself', () async {
      // The feed was a snapshot: loaded once in initState with a manual
      // refresh button, on the one screen whose whole job is to say what to
      // work on. The Dart side subscribes to postgres_changes, which is a
      // silent no-op unless the tables are in the publication — 0041 left
      // them out for ride_requests and 20260925210000 had to add
      // driver_status by hand for exactly this reason. This asserts the
      // publication, not the migration text, so a later DROP fails here.
      expect(await ok('assert_staff_task_sources_are_live'), isTrue,
          reason: 'A table behind staff_task_feed() is not in the '
              'supabase_realtime publication, so the staff workspace '
              'subscription is dead and the screen silently stops updating. '
              'The assertion names the offending table.');
    });
  });
}
