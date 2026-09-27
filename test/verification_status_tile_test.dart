// Regression tests for VerificationStatusTile.
//
// The bug being guarded: the profile menu reported a fixed "Verified" for every
// account, so a user who had uploaded nothing, a user whose ID was sitting
// unread in the review queue, and a user an admin had actually approved all
// looked identical. Two edits could restore that silently — collapsing two
// states back into the same visuals, or wiring the tile to the GATING status
// (DocCheckStatus) again, which is generous on purpose and says "you may work",
// not "you are verified".
//
// The first two tests therefore assert the properties, not just the copy: the
// states are mutually distinct, and "in review" is not "verified".
//
// The loader and the tap action are injected because the real ones go through
// ProviderDocGate, which needs a live Supabase client.

import 'dart:async';

import 'package:birr5/core/services/provider_doc_gate.dart';
import 'package:birr5/core/widgets/verification_status_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

const _titles = {
  'Verification',
  'Identity verified',
  'ID awaiting review',
  'ID not accepted',
  'ID under investigation',
  'Verify your identity',
  'Verification status unknown',
};

/// The visible label text of a pumped tile, used to compare states.
String _titleOf(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data)
      .whereType<String>();
  // Titles are the longest-lived strings in the layout; take the one that is
  // not the subtitle/chip of a known state.
  return texts.firstWhere(_titles.contains, orElse: () => '<none>');
}

void main() {
  testWidgets('verified state is visually distinct and says so',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => DocReviewState.verified,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Identity verified'), findsOneWidget);
    expect(find.text('Verified'), findsOneWidget);
    // Must NOT read like the unverified state.
    expect(find.text('Not verified'), findsNothing);
    expect(find.text('Verify your identity'), findsNothing);
  });

  testWidgets('a document nobody has reviewed is NOT shown as verified',
      (tester) async {
    // THE reported bug. MANUAL_REVIEW satisfies the GATING check, so wiring
    // the tile to DocCheckStatus.satisfied rendered the green "Verified" chip
    // for an ID that was still sitting unread in the queue.
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => DocReviewState.pending,
    )));
    await tester.pumpAndSettle();

    expect(find.text('ID awaiting review'), findsOneWidget);
    expect(find.text('In review'), findsOneWidget);
    expect(find.text('Identity verified'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('unverified state is visually distinct and says so',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => DocReviewState.none,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Verify your identity'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
    expect(find.text('Identity verified'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('a rejected document says so instead of reading as unverified',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => DocReviewState.rejected,
    )));
    await tester.pumpAndSettle();

    expect(find.text('ID not accepted'), findsOneWidget);
    expect(find.text('Rejected'), findsOneWidget);
    expect(find.text('Identity verified'), findsNothing);
  });

  testWidgets('failed check is its own state — not "not verified"',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => DocReviewState.unknown,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Verification status unknown'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // A failed check must not claim the user is unverified: we do not know.
    expect(find.text('Not verified'), findsNothing);
    expect(find.text('Verified'), findsNothing);
  });

  testWidgets('the six states never render the same headline',
      (tester) async {
    final seen = <String>{};
    for (final status in DocReviewState.values) {
      // Distinct keys force a fresh State each pass. Without them the element
      // is reused, initState does not re-run, and the tile would keep showing
      // the first status.
      await tester.pumpWidget(_host(VerificationStatusTile(
        key: ValueKey(status),
        reviewLoader: () async => status,
      )));
      await tester.pumpAndSettle();
      seen.add(_titleOf(tester));
    }
    expect(seen.length, DocReviewState.values.length,
        reason: 'every review state must look different — that is the '
            'entire point of this widget');
  });

  testWidgets('loads before deciding, so it never flashes a wrong state',
      (tester) async {
    final completer = Completer<DocReviewState>();
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () => completer.future,
    )));
    await tester.pump();

    expect(find.text('Checking your documents…'), findsOneWidget);
    expect(find.text('Not verified'), findsNothing);
    // Especially not the green one.
    expect(find.text('Verified'), findsNothing);

    completer.complete(DocReviewState.verified);
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
      reviewLoader: () async {
        calls++;
        return calls == 1 ? DocReviewState.none : DocReviewState.pending;
      },
      onTapAction: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Verify your identity'), findsOneWidget);

    await tester.tap(find.byType(VerificationStatusTile));
    await tester.pumpAndSettle();

    expect(find.text('ID awaiting review'), findsOneWidget);
    expect(calls, 2, reason: 'the tap must re-read the status');
  });

  testWidgets('survives a throwing loader without blanking or crashing',
      (tester) async {
    await tester.pumpWidget(_host(VerificationStatusTile(
      reviewLoader: () async => throw StateError('boom'),
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

    // Each combination is checked and its exception CONSUMED, so a failure
    // names the exact state and scale. Letting the first one escape reported
    // only "a RenderFlex overflowed by 10.0 pixels" against a line number,
    // which is no way to find the culprit among six states x four scales.
    //
    // The tile is pumped the way user_profile_screen.dart actually renders it:
    // a row inside a scrollable Column. Pumping it straight into a Scaffold
    // body hands the row a TIGHT 480px height, so any state whose text needs
    // more than that reports an overflow that the user never sees, because in
    // the app the parent scrolls. That is not a hypothetical — the "Not
    // verified" row, whose copy has not changed in either direction, failed
    // that way at a 2.0 scale. The guard that matters is still live: a chip
    // that steals the row's width squeezes the text to a few pixels per line
    // and blows up here just as loudly.
    for (final scale in [1.0, 1.3, 1.8, 2.0]) {
      for (final status in DocReviewState.values) {
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    VerificationStatusTile(
                      reviewLoader: () async => status,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        final overflow = tester.takeException();
        expect(overflow, isNull,
            reason: 'the tile overflows at text scale $scale in state '
                '$status (title "${_titleFor(status)}")');
      }
    }
  });
}

/// The headline a given state renders, for failure messages.
String _titleFor(DocReviewState state) {
  switch (state) {
    case DocReviewState.verified:
      return 'Identity verified';
    case DocReviewState.pending:
      return 'ID awaiting review';
    case DocReviewState.rejected:
      return 'ID not accepted';
    case DocReviewState.flagged:
      return 'ID under investigation';
    case DocReviewState.none:
      return 'Verify your identity';
    case DocReviewState.unknown:
      return 'Verification status unknown';
  }
}
