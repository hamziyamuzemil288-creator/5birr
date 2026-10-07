// The rule that decides whether a failed live connectivity call is reported as
// PENDING DEPLOY (a skip) or as a finding (a red run).
//
// This is a safety net, and safety nets fail in one direction only: they turn
// real failures into passes. The rule already did that once. After a deploy
// applied migrations and then failed, supabase/DEPLOYED_HEAD was never updated,
// so a set of names that were very much present on the live database was still
// classified "pending" — and every ordinary failure for those names was
// relabelled PENDING DEPLOY and passed. The suite went green while reporting
// two skips that were actually real findings.
//
// So the contract under test here is the FLOOR of the rule — conditions 1 and
// 2 of the three-way check (see tools/integration_test/pending_deploy.dart).
// The third condition, the live database confirming the function is absent,
// needs a SupabaseClient and belongs to the connectivity suite itself; what
// this file pins down is that the repo-side half can never widen on its own.
import 'package:flutter_test/flutter_test.dart';

import '../tools/integration_test/pending_deploy.dart';

void main() {
  group('the repo half of the rule reads the real migration boundary', () {
    late Set<String> pending;

    setUpAll(() {
      pending = readPendingDeployFunctions();
    });

    test('the boundary is readable and non-empty in this working tree', () {
      // An unreadable marker yields an empty set, which is the strict
      // behaviour — but silently losing the boundary entirely would be a
      // different bug, so assert we are actually reading it.
      expect(pending, isNotEmpty,
          reason: 'supabase/DEPLOYED_HEAD or supabase/migrations could not be '
              'read; the tolerance would silently degrade to "never skip", '
              'which turns every pre-deploy push red.');
    });

    test('a function created only after the head is classified pending', () {
      expect(pending, contains('assert_charge_paths_use_the_shared_fee_resolvers'),
          reason: 'defined only by 20261007000005 and 20261007000008, both '
              'newer than supabase/DEPLOYED_HEAD');
    });

    test('functions defined at or before the head are never pending', () {
      expect(pending, isNot(contains('assert_income_ledger_consistent')),
          reason: 'created by 20260922000007, long before the applied head — '
              'classifying it pending would let a real failure skip');
      expect(pending, isNot(contains('assert_every_assertion_is_reachable')),
          reason: 'created by 20260927000091, before the applied head — this '
              'is the assertion whose whole job is to catch unreachable '
              'assertions, so it must never be skippable');
    });
  });

  group('only PostgREST\'s "could not find the function" counts as absence', () {
    const absent = <String, String>{
      'could not find the function':
          'PostgrestException(code: PGRST202, message: Could not find the '
              'function public.foo() in the schema cache.)',
      'bare pgrst202': 'PostgrestException(code: PGRST202)',
      'lowercase body':
          '{"code":"pgrst202","message":"could not find the function '
              'public.foo in the schema cache"}',
      '42883 undefined function':
          'ERROR: function public.foo() does not exist (SQLSTATE 42883)',
    };

    absent.forEach((name, body) {
      test('recognises $name', () {
        expect(isMissingFunctionError(body), isTrue,
            reason: 'this is the one reply that means "the server has no such '
                'function for this role"');
      });
    });

    const finding = <String, String>{
      'rpc error name':
          'PostgrestException(code: PGRST116, message: PRODUCT_NOT_FOUND)',
      'sqlstate from the body':
          'ERROR: PRODUCT_NOT_FOUND (SQLSTATE P0002)',
      'plain failing assertion': 'false',
      'sentinel rollback': 'ROLLBACK_SENTINEL: assertion forced unwind',
      'permission denied':
          'permission denied for table wallets (SQLSTATE 42501)',
    };

    finding.forEach((name, body) {
      test('does not mistake $name for a missing function', () {
        expect(isMissingFunctionError(body), isFalse,
            reason: 'only condition 1 separates a missing migration from a '
                'database finding; letting anything else through would skip a '
                'real failure');
      });
    });
  });

  group('the truth table', () {
    const pgrst202 =
        'PostgrestException(code: PGRST202, message: Could not find the '
        'function public.x() in the schema cache.)';
    const notFound = 'PostgrestException(code: PGRST116, message: PRODUCT_NOT_FOUND)';

    test('tolerates the one intended case: pending name, reported absent',
        () {
      expect(isPendingDeploy(pgrst202, 'some_new_assert', {'some_new_assert'}),
          isTrue);
    });

    test('a pending name with an ordinary failure is NOT tolerated', () {
      // This is the masking bug: the old name-only rule skipped exactly this.
      expect(isPendingDeploy(notFound, 'some_new_assert', {'some_new_assert'}),
          isFalse,
          reason: 'PRODUCT_NOT_FOUND for a function that happens to sit past '
              'DEPLOYED_HEAD is a finding about data, not about a migration');
    });

    test('a pending name with a plain failing assertion is NOT tolerated', () {
      expect(isPendingDeploy('false', 'some_new_assert', {'some_new_assert'}),
          isFalse);
    });

    test('a deployed name reported absent is NOT tolerated', () {
      // PostgREST answers PGRST202 for a missing GRANT as well as a missing
      // migration, so this must stay red — it is the whole reason migration
      // 20261007000008 exists.
      expect(isPendingDeploy(pgrst202, 'assert_income_ledger_consistent', {}),
          isFalse);
    });

    test('an unknown name reported absent is NOT tolerated', () {
      expect(isPendingDeploy(pgrst202, 'typoed_function', {'some_new_assert'}),
          isFalse);
    });
  });

  group('the notice it reports', () {
    test('is never mistaken for a finding', () {
      final notice = pendingDeployNotice('some_new_assert');
      expect(notice, isNotEmpty);
      expect(notice, startsWith('PENDING DEPLOY: '),
          reason: 'callers use this to satisfy isNotNull and to keep it out of '
              'the FAIL-prefixed findings');
      expect(notice.toLowerCase(), isNot(startsWith('fail')));
    });
  });
}
