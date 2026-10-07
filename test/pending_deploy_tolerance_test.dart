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
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/integration_test/pending_deploy.dart';

void main() {
  group('the repo half of the rule reads the migration boundary', () {
    // The set of functions newer than the applied head is a property of how
    // far the live database has been deployed, not of the code: a fully
    // deployed repo has NONE, so asserting the set is non-empty — or that a
    // particular function is in it — turns green into red for a reason nobody
    // can act on, and would pass for the wrong reason the moment a name is
    // redefined. What must hold at every deploy state is the RULE, so it is
    // exercised below against a synthetic tree; the working tree is checked
    // only for the thing that is genuinely its job — that the marker is
    // readable and names a real migration, because an unreadable marker
    // silently degrades the tolerance to "never skip".
    test('the marker is readable and names a real migration', () {
      final head = File(deployedHeadFile).readAsStringSync().trim();
      expect(head, isNotEmpty,
          reason: 'supabase/DEPLOYED_HEAD is empty, so the tolerance would '
              'silently degrade to "never skip" and turn every pre-deploy '
              'push red.');
      final migrations = Directory(migrationsDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sql'))
          .map((f) => f.path)
          .toList();
      expect(migrations.any((p) => p.endsWith(head)), isTrue,
          reason: 'supabase/DEPLOYED_HEAD must name a migration that exists '
              'in supabase/migrations; when it does not, '
              'readPendingDeployFunctions() returns an empty set and the '
              'tolerance degrades to "never skip".');
    });

    late Directory root;
    late String headPath;
    late String migrationsPath;

    setUp(() {
      root = Directory.systemTemp.createTempSync('pending-deploy-test');
      migrationsPath = '${root.path}/migrations';
      Directory(migrationsPath).createSync();
      // shared_fn is restated by a newer migration, so it is on the live
      // database and must not be classified pending; after_the_head_fn is not.
      File('$migrationsPath/20260101000000_old.sql').writeAsStringSync(
          "create or replace function public.shared_fn() returns boolean "
          "language sql as 'select true';\n"
          "create or replace function public.at_the_head_fn() returns boolean "
          "language sql as 'select true';\n");
      File('$migrationsPath/20260202000000_new.sql').writeAsStringSync(
          "create or replace function public.shared_fn() returns boolean "
          "language sql as 'select true';\n"
          "create or replace function public.after_the_head_fn() returns "
          "boolean language sql as 'select true';\n");
      headPath = '${root.path}/DEPLOYED_HEAD';
      File(headPath).writeAsStringSync('20260101000000_old.sql');
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('a function created only after the head is classified pending', () {
      final pending = readPendingDeployFunctions(
          headPath: headPath, migrationsPath: migrationsPath);
      expect(pending, contains('after_the_head_fn'),
          reason: 'defined only by the migration past the applied head');
    });

    test('functions defined at or before the head are never pending', () {
      final pending = readPendingDeployFunctions(
          headPath: headPath, migrationsPath: migrationsPath);
      expect(pending, isNot(contains('shared_fn')),
          reason: 'restated by a newer migration, but defined at or before '
              'the head too, so it is on the live database — classifying it '
              'pending would let a real failure skip');
      expect(pending, isNot(contains('at_the_head_fn')),
          reason: 'defined by the head migration itself');
    });

    test('an unreadable boundary skips nothing', () {
      final pending = readPendingDeployFunctions(
          headPath: '${root.path}/does-not-exist',
          migrationsPath: migrationsPath);
      expect(pending, isEmpty,
          reason: 'a boundary that cannot be read must widen the tolerance '
              'to nothing, never to everything');
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
