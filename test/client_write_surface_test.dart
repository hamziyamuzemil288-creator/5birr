// The client write surface, pinned.
//
// WHAT THIS IS FOR
// ----------------
// Supabase puts default privileges on the public schema that grant ALL on new
// tables, so every table starts out writable by `authenticated`. RLS is the
// layer that actually stops a client, and each table's intent is expressed
// only in a policy nobody reads until something goes wrong.
//
// 20260927000042 started revoking write privileges on the tables the app never
// writes. That revocation is only safe while the list stays true, and a list
// in a SQL file cannot notice when a Flutter screen starts writing somewhere
// new. This test is that missing link: it reads the app's own source and fails
// if a direct client write appears on a table the database has been told the
// app never writes.
//
// WHAT IT DOES NOT DO
// -------------------
// It does not prove those tables are unreachable. It cannot: RLS, SECURITY
// DEFINER functions and the Edge Functions are all invisible to a source scan,
// which is why the server-side half is asserted against the live database
// instead. What it does is fail the moment the two halves stop agreeing -- the
// failure that would otherwise surface in production as a permission-denied
// error on a working screen.
//
// WHEN IT FAILS
// -------------
// Either the write is wrong and belongs behind a SECURITY DEFINER function,
// or the table genuinely is client-written and belongs in
// expectedClientWrites AND in the expected list inside
// client_write_surface_report(). Updating one and not the other is the drift
// this test exists to catch.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Tables the app writes to directly, with .insert/.update/.delete/.upsert.
///
/// Deliberately an allowlist, not a denylist. A denylist would need updating
/// for every table in the schema and would silently stop protecting anything
/// added later; an allowlist fails closed, so a new table is treated as
/// server-only until someone proves otherwise.
const Set<String> expectedClientWrites = {
  'admin_expenses',
  'admin_notification_broadcasts',
  'appeal_cases',
  'cart_items',
  'chat_logs',
  // The crash/error sink. Genuinely a client write: ErrorLogger inserts
  // directly with no SECURITY DEFINER wrapper, because the point is that a
  // failing app can still record why it failed. Migration 64 grants INSERT
  // only, and RLS forces user_id = auth.uid().
  'client_error_logs',
  'favorites',
  'notifications',
  'order_messages',
  'payment_methods',
  'payment_proofs',
  'product_images',
  'products',
  'profiles',
  'provider_profiles',
  'reviews',
  'ride_ratings',
  'support_tickets',
  'user_documents',
  'vehicles',
  'wallet_recharge_requests',
};

/// `.storage.from('x')` is a storage bucket, not a table, and is deliberately
/// absent from the list above. Buckets are governed by storage.objects
/// policies, which assert_private_buckets_are_owner_scoped() covers.
final _bucket = RegExp(r"\.storage\s*\n?\s*\.from\(\s*'[^']*'", multiLine: true);
final _table = RegExp(r"\.from\(\s*'([^']*)'\s*\)", multiLine: true);
final _write = RegExp(r"\.(insert|update|delete|upsert)\s*\(");

/// Where the current statement ends. Used to stop the lookahead from running
/// into the next one.
final _statementEnd = RegExp(r";|\.from\(");

void main() {
  test('the app only writes to tables the database expects it to', () {
    final offenders = <String, String>{};
    final lib = Directory('lib');

    // Loudly rather than silently: a test that cannot find lib/ and passes
    // anyway is worse than no test, because it reports the surface is pinned
    // when nothing was checked.
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'lib/ not found from ${Directory.current.path}. This test must '
          'run from the project root, as `flutter test` does.',
    );

    for (final file in lib.listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();

      // Mask storage buckets so their names can never be read as tables. The
      // replacement is deliberately UNQUOTED so the table regex cannot match
      // it: an earlier version masked to `.from(' ')`, which the regex then
      // read as a table named " " and reported as an offender on four files.
      final withoutStorage = source.replaceAll(_bucket, 'storage.from(null)');

      for (final match in _table.allMatches(withoutStorage)) {
        final table = match.group(1)!.trim();
        if (table.isEmpty) continue;
        if (expectedClientWrites.contains(table)) continue;

        // Look ahead for a write verb, but STOP at the end of the current
        // statement. Without that stop, a read of one table followed by an
        // insert into another is reported as a write to the first: the
        // role-targeted broadcast reads user_roles and then inserts
        // notifications, which is how a false positive got in here.
        final rest = withoutStorage.substring(
          match.end,
          (match.end + 500).clamp(0, withoutStorage.length),
        );
        final boundary = _statementEnd.firstMatch(rest)?.start ?? rest.length;
        if (_write.hasMatch(rest.substring(0, boundary))) {
          offenders[table] = file.path;
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These tables are written to directly by the app, but the '
          'database was told the app never writes them, so their write '
          'privileges are being revoked:\n'
          '${offenders.entries.map((e) => '  ${e.key}  <- ${e.value}').join('\n')}\n\n'
          'Either move the write behind a SECURITY DEFINER function, or -- if '
          'it genuinely belongs to the client -- add the table to '
          'expectedClientWrites here AND to the expected list in '
          'client_write_surface_report(). Adding it to one and not the other '
          'is the drift this test exists to catch.',
    );
  });

  test('the allowlist and the database expected-list cannot drift', () {
    // The same 20 tables are written out by hand inside the SQL function,
    // because a migration cannot read a Dart file. Two hand-maintained copies
    // of one list is exactly how they drift, so the size is pinned here and a
    // mismatch surfaces in review rather than as a permission error later.
    expect(
      expectedClientWrites.length,
      20,
      reason: 'expectedClientWrites changed size. If a table was added or '
          'removed, the expected list inside client_write_surface_report() in '
          'supabase/migrations/20260927000042_... must change to match, or the '
          'report will classify a table wrongly.',
    );
  });
}
