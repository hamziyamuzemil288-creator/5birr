// The provider publish path, tested where it was broken.
//
// The bug this covers: a provider filled in a whole listing, pressed Save, and
// was shown PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED — a machine token, no
// reason, no next step — while the client gate (ProviderDocGate) had already
// told the form everything was fine. Every test here is one of the ways that
// went wrong, asserted so it cannot go wrong again silently.

import 'package:birr5/core/services/provider_readiness.dart';
import 'package:birr5/core/widgets/publish_readiness_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      // No theme: the banner only reads AppTheme colour constants, so a test
      // theme would be a second thing to keep in sync for no coverage.
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('a refusal always arrives as a sentence', () {
    test('the reason-carrying code is recognised', () {
      expect(
        ProviderReadiness.isPublishRefusal(
            'PostgrestException(code: 400, message: '
            'PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,WALLET_EMPTY)'),
        isTrue,
      );
    });

    // Migration 0117 changed the server, not the clients already installed. An
    // app build from before it can still receive the bare code, and treating
    // that as an ordinary failure is what produced the original report.
    test('the BARE code is recognised too, so old builds are not left behind',
        () {
      expect(
        ProviderReadiness.isPublishRefusal(
            'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED'),
        isTrue,
      );
    });

    test('an ordinary failure is NOT treated as a gate refusal', () {
      expect(ProviderReadiness.isPublishRefusal('SocketException: failed host'),
          isFalse);
      expect(ProviderReadiness.isPublishRefusal('23505 duplicate key'), isFalse);
    });

    test('the reasons are recovered from the refusal text', () {
      final reasons = ProviderReadiness.reasonsFromRefusal(
          'PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,WALLET_EMPTY');
      expect(reasons, ['DOCUMENTS_UNVERIFIED', 'WALLET_EMPTY']);
    });

    test('lowercase from the transport is normalised', () {
      expect(
        ProviderReadiness.reasonsFromRefusal(
            'provider_not_fulfilment_ready: wallet_empty'),
        ['WALLET_EMPTY'],
      );
    });

    // Inventing a reason the server did not give would be worse than saying
    // nothing, so the bare code yields an empty list and the dialog falls back
    // to a generic, still-actionable remedy.
    test('the bare code yields NO invented reasons', () {
      expect(ProviderReadiness.reasonsFromRefusal(
          'PROVIDER_NOT_ACTIVATED_OR_DOCUMENTS_REQUIRED'), isEmpty);
    });
  });

  group('every reason is displayable', () {
    test('each code the server can emit has a phrase and somewhere to go', () {
      // The server's own vocabulary, from provider_fulfilment_blockers.
      const emitted = [
        'DOCUMENTS_UNVERIFIED',
        'ACTIVATION_FEE_UNPAID',
        'WALLET_EMPTY',
        'SUBSCRIPTION_UNPAID',
        'ACCOUNT_NOT_APPROVED',
        'PROVIDER_NOT_FOUND',
      ];
      for (final code in emitted) {
        final r = ProviderReadiness.remedyFor(code);
        expect(r.phrase, isNotEmpty, reason: '$code has no phrase');
        expect(r.action, isNotEmpty, reason: '$code has no action');
        expect(r.phrase, isNot(equals(code)),
            reason: '$code would be shown to the provider as a raw token');
      }
    });

    // A new reason added to provider_fulfilment_blockers() must not make the
    // banner print a machine code — the banner exists so nobody has to read
    // one. So the fallback is generic, not empty.
    test('an unrecognised code still yields a sentence and a destination', () {
      final r = ProviderReadiness.remedyFor('SOME_REASON_ADDED_NEXT_YEAR');
      expect(r.phrase, isNotEmpty);
      expect(r.action, isNotEmpty);
      expect(r.phrase, isNot(contains('SOME_REASON_ADDED_NEXT_YEAR')));
    });

    test('every route a remedy names is a real route', () {
      // Sending a provider to a path that matches no GoRoute is a new dead end
      // in place of the old one, and it cannot be seen from here — so the
      // harness check asserts it against app_router.dart, and this test
      // asserts the remedy table is the single source of those routes.
      for (final entry in ProviderReadiness.remedies.entries) {
        final route = entry.value.route;
        if (route == null) continue;
        expect(route, startsWith('/'), reason: '${entry.key}: bad route');
        expect(route, isNot(contains('undefined')),
            reason: '${entry.key}: route looks unresolved');
      }
    });
  });

  group('readiness never lies in either direction', () {
    test('a provider with no blockers is ready', () {
      const r = ProviderReadiness(reasons: [], checked: true);
      expect(r.isReady, isTrue);
    });

    // "We could not ask" is not "there is nothing wrong". Showing a green
    // "you can publish" on an unreachable server is the same lie as the
    // original bug, in the opposite direction.
    test('an unanswered question is NOT reported as ready', () {
      expect(ProviderReadiness.unknown.isReady, isFalse);
    });

    test('a known blocker is not ready', () {
      const r = ProviderReadiness(reasons: ['WALLET_EMPTY'], checked: true);
      expect(r.isReady, isFalse);
    });
  });

  group('the dashboard banner', () {
    testWidgets('shows nothing when the server says go ahead', (tester) async {
      await tester.pumpWidget(_wrap(const PublishReadinessBanner(
        readiness: ProviderReadiness(reasons: [], checked: true),
      )));
      expect(find.text('Finish these before you can publish'), findsNothing);
    });

    // Not a green light. An unreachable server must not clear the banner's own
    // heading, but it also must not invent blockers.
    testWidgets('shows nothing when the server could not be asked',
        (tester) async {
      await tester.pumpWidget(_wrap(const PublishReadinessBanner(
        readiness: ProviderReadiness.unknown,
      )));
      expect(find.text('Finish these before you can publish'), findsNothing);
    });

    testWidgets('names each outstanding reason and what to do', (tester) async {
      await tester.pumpWidget(_wrap(const PublishReadinessBanner(
        readiness: ProviderReadiness(
          reasons: const ['DOCUMENTS_UNVERIFIED', 'WALLET_EMPTY'],
          checked: true,
        ),
      )));

      expect(find.text('Finish these before you can publish'), findsOneWidget);
      expect(
        find.text('your ID has not been verified yet'),
        findsOneWidget,
      );
      expect(
        find.text('your wallet is empty, so the platform fee cannot be covered'),
        findsOneWidget,
      );
      // The buttons are the point: a banner that only explains leaves the
      // provider exactly where they were.
      expect(find.text('Upload or check your ID'), findsOneWidget);
      expect(find.text('Top up your wallet'), findsOneWidget);
    });

    testWidgets('never shows a raw reason code to a provider',
        (tester) async {
      await tester.pumpWidget(_wrap(const PublishReadinessBanner(
        readiness: ProviderReadiness(
          reasons: const ['DOCUMENTS_UNVERIFIED', 'MYSTERY_CODE'],
          checked: true,
        ),
      )));
      expect(find.textContaining('DOCUMENTS_UNVERIFIED'), findsNothing);
      expect(find.textContaining('MYSTERY_CODE'), findsNothing);
    });

    // Every action button must fit its label. A remedy row that overflows at
    // a normal text scale turns the one screen that explains the problem into
    // the screen that crashes.
    testWidgets('does not overflow at a large text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_wrap(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
        child: const PublishReadinessBanner(
          readiness: ProviderReadiness(
            reasons: [
              'DOCUMENTS_UNVERIFIED',
              'ACTIVATION_FEE_UNPAID',
              'WALLET_EMPTY',
            ],
            checked: true,
          ),
        ),
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Finish these before you can publish'), findsOneWidget);
    });
  });
}
