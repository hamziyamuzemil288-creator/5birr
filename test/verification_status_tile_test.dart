// Regression tests for VerificationStatusTile.
//
// The bug being guarded: a verified and an unverified account rendered the
// SAME entry in the profile menu, so there was no way to see verification
// status and no way to tell whether an upload had worked. A future edit that
// collapses two of these states back into identical visuals would restore that
// bug silently, so the first test asserts the states are mutually distinct
// rather than merely correct one at a time.
//
// The loader and the tap action are injected because the real ones go through
// ProviderDocGate, which needs a live Supabase client.

import 'dart:async';

import 'package:birr5/core/services/provider_doc_gate.dart';
import 'package:birr5/core/widgets/verification_status_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The visible label text of a pumped tile, used to compare states.
String _titleOf(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>();
  // Titles are the longest-lived strings in the layout; take the one that is
  // not the subtitle/chip of a known state.
  const titles = {
    'Verification',
    'Identity verified',
    'Verify your identity',
    'Verification status unknown',
  };
  return texts.firstWhere(titles.contains, orElse: () => '<none>');
}

void main() {
  testWidgets('verified state is visually distinct and says so',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () async => DocCheckStatus.satisfied,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Identity verified'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    // Must NOT read like the unverified state.
    expect(find.text('Not verified'), findsNothing);
    expect(find.text('Verify your identity'), findsNothing);
  });

  testWidgets('unverified state is visually distinct and says so',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () async => DocCheckStatus.required,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Verify your identity'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Identity verified'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('failed check is a third, distinct state — not "not verified"',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () async => DocCheckStatus.checkFailed,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Verification status unknown'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // A failed check must not claim the user is unverified: we do not know.
    expect(find.text('Not verified'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('the three states never render the same headline',
      (tester) async {
    final seen = <String>{};
    for (final status in [
      DocCheckStatus.satisfied,
      DocCheckStatus.required,
      DocCheckStatus.checkFailed,
    ]) {
      // Distinct keys force a fresh State each pass. Without them the element
      // is reused, initState does not re-run, and the tile would keep showing
      // the first status.
      await tester.pumpWidget(_host(VerificationStatusTile(
        key: ValueKey(status),
        statusLoader: () async => status,
      )));
      await tester.pumpAndSettle();
      seen.add(_titleOf(tester));
    }
    expect(seen.length, 3,
        reason: 'verified, unverified and unknown must look different — '
            'that is the entire point of this widget');
  });

  testWidgets('loads before deciding, so it never flashes a wrong state',
      (tester) async {
    final completer = Completer<DocCheckStatus>();
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () => completer.future,
    )));
    await tester.pump();

    expect(find.text('Checking your documents…'), findsOneWidget);
    expect(find.text('Not verified'), findsNothing);

    completer.complete(DocCheckStatus.satisfied);
    await tester.pumpAndSettle();
    expect(find.text('Identity verified'), findsOneWidget);
  });

  testWidgets('refreshes after upload, so a verified user stops looking new',
      (tester) async {
    // First read: unverified. After the flow closes: verified. This is the
    // exact user-visible defect — upload succeeded and the entry still said
    // "Not verified" until an app restart.
    var calls = 0;
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () async {
        calls++;
        return calls == 1 ? DocCheckStatus.required : DocCheckStatus.satisfied;
      },
      onTapAction: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Verify your identity'), findsOneWidget);

    await tester.tap(find.byType(VerificationStatusTile));
    await tester.pumpAndSettle();

    expect(find.text('Identity verified'), findsOneWidget);
    expect(calls, 2, reason: 'the tap must re-read the status');
  });

  testWidgets('survives a throwing loader without blanking or crashing',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      statusLoader: () async => throw StateError('boom'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Verification status unknown'), findsOneWidget);
  });

  testWidgets('does not overflow at large text scales', (tester) async {
    // Same guard as typed_confirm_dialog_overflow_test: this list has already
    // produced one overflow bug, and a wide chip beside long body text is
    // exactly the shape that overflows.
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    for (final scale in [1.0, 1.3, 1.8, 2.0]) {
      for (final status in [
        DocCheckStatus.satisfied,
        DocCheckStatus.required,
        DocCheckStatus.checkFailed,
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: VerificationStatusTile(
                statusLoader: () async => status,
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
      }
    }
  });
}
