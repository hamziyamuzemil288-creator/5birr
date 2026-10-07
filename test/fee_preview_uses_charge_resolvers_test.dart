// Item H: the proof that a DISPLAYED fee and a CHARGED fee resolve through the
// same reader.
//
// The failure this test exists to catch is not a crash. It is the quiet one:
// the app computes `amount * percent / 100` in Dart, an admin edits a fee, and
// the screen keeps quoting the old number while the charge uses the new one.
// Or the charge path is restated to call a different reader and nobody notices
// every quote is now wrong.
//
// So it reads BOTH sides out of the repository — the migration SQL (the charge
// side) and the Dart source (the display side) — and fails when they disagree.
// It is the repo-side mirror of the live assertion
// public.assert_charge_paths_use_the_shared_fee_resolvers() added in
// 20261007000005, which does the same check against the DEPLOYED bodies.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The charge function -> the resolver reader it must call. Kept in step with
/// FeeResolver.chargePathResolvers and the SQL assertion by the tests below.
const chargeResolverPairs = <String, String>{
  'create_ride_request': 'calculate_fare_estimate_at',
  'deduct_transaction_fee': 'platform_transaction_fee_for',
  'deduct_subscription_fee': 'fee_subscription',
  'approve_wallet_recharge': 'fee_activation',
};

/// Every migration file, in deploy order (the filenames are fixed-width
/// timestamps, so a lexicographic sort is the deploy order).
List<File> migrationFiles() {
  final dir = Directory('supabase/migrations');
  if (!dir.existsSync()) {
    fail('supabase/migrations not found — run this test from the package root');
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The body of the LATEST definition of `public.<name>` across all migrations —
/// what is actually live after a full deploy, not the first draft of it.
String latestFunctionBody(String name) {
  final pattern = RegExp(
    r'create\s+or\s+replace\s+function\s+public\.' + name + r'\b',
    caseSensitive: false,
  );
  String? found;
  for (final f in migrationFiles()) {
    final text = f.readAsStringSync();
    for (final m in pattern.allMatches(text)) {
      final end = text.indexOf(r'$$;', m.start);
      if (end == -1) continue;
      found = text.substring(m.start, end);
    }
  }
  if (found == null) {
    fail('no definition of public.$name in any migration');
  }
  return found;
}

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing source file: $path');
  return f.readAsStringSync();
}

/// The file with comment-only lines removed, so a docstring that *names* a
/// forbidden pattern (like the one explaining why this test exists) is not
/// mistaken for the pattern in code.
String readCode(String path) {
  return read(path)
      .split('\n')
      .where((line) {
        final t = line.trimLeft();
        return !(t.startsWith('//') ||
            t.startsWith('/*') ||
            t.startsWith('*') ||
            t.startsWith('*/'));
      })
      .join('\n');
}

void main() {
  test('every charge path resolves through its shared reader', () {
    for (final entry in chargeResolverPairs.entries) {
      final body = latestFunctionBody(entry.key);
      expect(
        body.contains(entry.value),
        isTrue,
        reason: '${entry.key} must call ${entry.value}: if it does not, the '
            'app quotes one number and the charge applies another.',
      );
    }
  });

  test('the composed readers keep composing, not re-implementing', () {
    // A preview calls ONE reader and inherits the formula from it. If the
    // reader stops calling its per_km fee, the formula is duplicated
    // somewhere else — which is the drift this whole test file guards.
    expect(latestFunctionBody('calculate_fare_estimate_at'),
        contains('fee_ride_per_km'));
    expect(latestFunctionBody('calculate_booking_fee_at'),
        contains('fee_booking_per_km'));
    expect(latestFunctionBody('platform_transaction_fee_for'),
        contains('fee_commission_percent'));
  });

  test('FeeResolver exposes exactly the readers the charges use', () {
    final src = read('lib/core/services/fee_resolver.dart');

    // The Dart map and the SQL pairs must agree, name for name.
    for (final entry in chargeResolverPairs.entries) {
      expect(
        src.contains("'${entry.key}': '${entry.value}'"),
        isTrue,
        reason: 'FeeResolver.chargePathResolvers must map ${entry.key} -> '
            '${entry.value}',
      );
      // And each reader must actually be called off the RPC client.
      expect(
        src.contains("rpc('${entry.value}'"),
        isTrue,
        reason: 'FeeResolver must call ${entry.value} over RPC, not compute it',
      );
    }
  });

  test('FeeResolver never computes a fee itself', () {
    final src = readCode('lib/core/services/fee_resolver.dart');
    // No local pricing arithmetic: no `* 0.01`, no `* percent / 100`, and no
    // arithmetic on a resolved value. The numbers come off an RPC whole.
    final forbidden = <String>[
      '* 0.01',
      '/ 100',
      'percent /',
      '.value! *',
      '.value! /',
    ];
    for (final needle in forbidden) {
      expect(
        src.contains(needle),
        isFalse,
        reason: 'FeeResolver must not do fee arithmetic ("$needle"); resolve '
            'it server-side and read it back.',
      );
    }
  });

  test('every fee preview goes through FeeResolver, not its own RPC', () {
    // The surfaces item H wired. Each must reference the shared service.
    const previews = <String>[
      'lib/features/user/user_ride_request_screen.dart',
      'lib/features/user/user_checkout_screen.dart',
      'lib/core/services/posting_gate.dart',
      'lib/features/provider/provider_product_form_screen.dart',
    ];
    for (final path in previews) {
      final src = read(path);
      expect(
        src.contains('FeeResolver.instance'),
        isTrue,
        reason: '$path must preview fees through FeeResolver so the displayed '
            'number and the charged number share one resolver',
      );
    }
  });

  test('the ride preview no longer calls the fare RPC before FeeResolver did',
      () {
    // Guard against the refactor being reverted in one file only: if the ride
    // screen calls calculate_fare_estimate_at directly again, the resolver is
    // no longer the single door.
    final src = read('lib/features/user/user_ride_request_screen.dart');
    expect(
      src.contains("rpc(\n        'calculate_fare_estimate_at'") ||
          src.contains("rpc('calculate_fare_estimate_at'"),
      isFalse,
      reason: 'the ride screen must preview through FeeResolver.rideFare, '
          'not call the fare RPC itself',
    );
  });

  test('the activation charge and the activation preview name one reader', () {
    // approve_wallet_recharge withholds; the preview quotes. Both must go
    // through fee_activation (20261007000005).
    expect(latestFunctionBody('approve_wallet_recharge'),
        contains('fee_activation'));
    expect(read('lib/core/services/fee_resolver.dart'),
        contains("rpc('fee_activation'"));
  });
}
