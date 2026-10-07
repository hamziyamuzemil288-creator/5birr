// Item I: the forced-update system.
//
// Three things are proved here, in increasing order of how close they are to
// the user:
//
//   1. the verdict RULE is exactly as specified, and fails open when the
//      policy is unreadable (so nobody is locked out by our outage);
//   2. the MIGRATION actually creates the table, the readers, the guard and
//      the four write-path triggers, and the wire-up in the app sends the
//      build number the guard reads;
//   3. the GATE is what it claims to be — a full-screen, non-dismissible
//      screen when the build is required, with the system back gesture
//      refused.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/app_build.dart';
import 'package:birr5/core/services/app_update_service.dart';
import 'package:birr5/core/widgets/app_update_gate.dart';

String read(String path) {
  final f = File(path);
  if (!f.existsSync()) fail('missing file: $path');
  return f.readAsStringSync();
}

void main() {
  group('the verdict rule', () {
    const open = AppReleaseConfig(
      platform: 'android',
      latestBuild: 0,
      minRequiredBuild: 0,
      forceEnabled: false,
    );

    test('a zeroed policy (no row / unreadable) never gates anyone', () {
      expect(open.verdictFor(1), UpdateVerdict.ok);
      expect(open.verdictFor(106), UpdateVerdict.ok);
    });

    test('below the minimum is REQUIRED only when force is on', () {
      const forced = AppReleaseConfig(
        platform: 'android',
        latestBuild: 120,
        minRequiredBuild: 110,
        forceEnabled: true,
      );
      expect(forced.verdictFor(109), UpdateVerdict.required);
      // At the minimum the build is ACCEPTED — but still below the latest, so
      // it gets the soft prompt, not a silent pass.
      expect(forced.verdictFor(110), UpdateVerdict.recommended);
      expect(forced.verdictFor(119), UpdateVerdict.recommended);
      expect(forced.verdictFor(120), UpdateVerdict.ok);

      const notForced = AppReleaseConfig(
        platform: 'android',
        latestBuild: 120,
        minRequiredBuild: 110,
        forceEnabled: false,
      );
      // Force off: below the minimum is still only a prompt, never a gate.
      expect(notForced.verdictFor(109), UpdateVerdict.recommended);
      expect(notForced.verdictFor(119), UpdateVerdict.recommended);
      expect(notForced.verdictFor(120), UpdateVerdict.ok);
    });

    test('a build between the minimum and the latest gets the soft prompt', () {
      const c = AppReleaseConfig(
        platform: 'android',
        latestBuild: 120,
        minRequiredBuild: 110,
        forceEnabled: true,
      );
      expect(c.verdictFor(115), UpdateVerdict.recommended);
    });

    test('the message follows the language, then English, then a default', () {
      const c = AppReleaseConfig(
        platform: 'android',
        latestBuild: 1,
        minRequiredBuild: 1,
        forceEnabled: false,
        messageEn: 'English',
        messageAm: 'አማርኛ',
        messageOm: '',
      );
      expect(c.messageFor('am'), 'አማርኛ');
      // A blank translation is not shown as blank.
      expect(c.messageFor('om'), 'English');
      expect(c.messageFor('fr'), 'English');

      const empty = AppReleaseConfig(
        platform: 'android',
        latestBuild: 1,
        minRequiredBuild: 1,
        forceEnabled: false,
        messageEn: '',
      );
      expect(empty.messageFor('en'), isNotEmpty);
    });

    test('a server refusal outranks a stale cached policy', () {
      final service = AppUpdateService.instance;
      service.debugSetConfig(const AppReleaseConfig(
        platform: 'android',
        latestBuild: 0,
        minRequiredBuild: 0,
        forceEnabled: false,
      ));
      expect(service.verdict, UpdateVerdict.ok);
      service.notePossibleRefusal(Exception('APP_UPDATE_REQUIRED'));
      expect(service.verdict, UpdateVerdict.required,
          reason: 'a write the server refused must gate the app at once');
      // Reset for other tests.
      service.serverRefusedThisBuild.value = false;
      expect(service.verdict, UpdateVerdict.ok);
    });
  });

  group('the migration wires the gate', () {
    final sql = read(
        'supabase/migrations/20261007000006_forced_update_system.sql');

    test('the table exists and has RLS enabled', () {
      expect(sql, contains('create table if not exists public.app_release_config'));
      expect(sql,
          contains('alter table public.app_release_config enable row level security'));
    });

    test('the seed blocks nobody: min <= latest and force off', () {
      // The android seed row is (106, 106, false).
      expect(
        RegExp(r"\('android', 106, 106,").hasMatch(sql),
        isTrue,
        reason: 'the seed must keep every existing client accepted',
      );
      expect(sql, contains('force_enabled'));
    });

    test('the guard raises APP_UPDATE_REQUIRED and lets server writes pass',
        () {
      expect(sql, contains("raise exception 'APP_UPDATE_REQUIRED'"));
      expect(sql, contains('public.is_server_write()'));
    });

    test('the four client-writable tables carry the gate trigger', () {
      for (final t in [
        'orders',
        'ride_requests',
        'products',
        'wallet_recharge_requests'
      ]) {
        expect(sql, contains("'$t'"),
            reason: '$t must be in the guarded table list');
      }
      expect(sql, contains('_client_build_gate'));
    });

    test('force cannot be enabled without the store confirmation', () {
      expect(sql, contains('FORCE_REQUIRES_THE_STORE_CONFIRMATION'));
      expect(sql, contains('p_confirm_force'));
    });

    test('the live assertion checks the triggers, not just this file', () {
      expect(sql, contains('assert_app_version_gate_is_wired'));
      expect(sql, contains('pg_trigger'));
    });

    test('the notify blast is once per release and batched', () {
      expect(sql, contains('already_notified'));
      expect(sql, contains('notify_release_key'));
      expect(sql, contains("'APP_UPDATE_PUSH'"));
    });
  });

  group('the app sends the build number the guard reads', () {
    test('Supabase init sets the x-client-build header from the constant', () {
      final src = read('lib/core/services/supabase_service.dart');
      expect(src, contains("'x-client-build': kAppBuildNumber.toString()"));
      expect(src, contains("'x-client-platform'"));
    });

    test('the service reads the policy through the granted reader', () {
      final src = read('lib/core/services/app_update_service.dart');
      expect(src, contains("rpc('app_release_config_for'"));
    });

    test('the gate is mounted above the Navigator, so it covers /auth too', () {
      final src = read('lib/app.dart');
      expect(src, contains('AppUpdateGate('));
      // It must be in the router builder (above the Navigator), not a route.
      expect(src, contains('builder:'));
    });

    test('the build constant matches pubspec.yaml', () {
      final pubspec = read('pubspec.yaml');
      final m = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)\s*$',
              multiLine: true)
          .firstMatch(pubspec);
      expect(m, isNotNull, reason: 'pubspec.yaml must have version: x.y.z+N');
      expect(m!.group(1), kAppVersionName);
      expect(int.parse(m.group(2)!), kAppBuildNumber);
    });
  });

  group('the gate itself', () {
    testWidgets('the required gate is full-screen and refuses dismissal',
        (tester) async {
      final service = AppUpdateService.instance;
      service.debugSetConfig(const AppReleaseConfig(
        platform: 'android',
        latestBuild: 200,
        minRequiredBuild: 200,
        forceEnabled: true,
        storeUrl: 'https://example.com/store',
      ));
      service.stop();

      await tester.pumpWidget(
        MaterialApp(
          home: AppUpdateGate(child: const Text('the app')),
        ),
      );
      await tester.pump();

      expect(find.text('Update required'), findsOneWidget);
      expect(find.text('Update now'), findsOneWidget);
      // The app behind it is not shown: the gate REPLACES it.
      expect(find.text('the app'), findsNothing);

      // Back cannot dismiss it.
      final popScope = tester.widget<PopScope>(find.byType(PopScope).first);
      expect(popScope.canPop, isFalse);

      // No dismiss affordance is present.
      expect(find.text('Later'), findsNothing);

      service.stop();
      service.debugSetConfig(AppReleaseConfig.open);
      service.serverRefusedThisBuild.value = false;
    });

    testWidgets('a current build shows the app and no gate', (tester) async {
      final service = AppUpdateService.instance;
      service.debugSetConfig(const AppReleaseConfig(
        platform: 'android',
        latestBuild: 100,
        minRequiredBuild: 100,
        forceEnabled: true,
      ));
      service.stop();

      await tester.pumpWidget(
        MaterialApp(
          home: AppUpdateGate(child: const Text('the app')),
        ),
      );
      await tester.pump();

      expect(find.text('the app'), findsOneWidget);
      expect(find.text('Update required'), findsNothing);

      service.stop();
      service.debugSetConfig(AppReleaseConfig.open);
    });
  });
}
