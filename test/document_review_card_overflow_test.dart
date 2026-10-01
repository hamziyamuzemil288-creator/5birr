// Regression test for the bottom-overflow banner on the document verification
// queue's card.
//
// Follows test/income_filter_chips_overflow_test.dart exactly, and for the same
// reason: a RenderFlex overflow is reported as a FlutterError during layout, so
// the pump IS the guard. Nothing here asserts on a pixel count.
//
// The shapes that overflow, and at what scale:
//
//   * the three action buttons (View / Verify / Refuse) in a plain Row. They
//     need roughly 300dp at the default scale inside a card that has 28dp of
//     padding, so on a 320dp phone they do not fit before the text scale is
//     even considered. A Wrap moves them onto a second line;
//   * the status pill beside an Expanded column. "SUSPECTED FRAUD" at fontSize
//     10 is 20px wide per character pair at 2.0x, and the pill is the one
//     fixed-width item competing with the Expanded column for the same space,
//     so it is Flexible rather than fixed;
//   * the account name. A person's name is unbounded, and this queue lists
//     accounts rather than curated rows, so it is one line with an ellipsis.
//
// The card takes plain strings and a thumbnail slot precisely so it can be
// pumped here with a 70-character account name and no Supabase client, no
// network and no credentials. If it were coupled to the screen, this test could
// not exist and the overflow would ship.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/theme/app_theme.dart';
import 'package:birr5/features/admin/admin_document_verification_screen.dart';

/// A small phone, and the text scales a user can actually have set: Android's
/// "Large" is 1.3x, and 2.0x is its maximum.
const _scales = <String, double>{
  'default': 1.0,
  'large': 1.3,
  'xLarge': 1.8,
  'max': 2.0,
};

/// The statuses the queue can show. Each one is a different layout: SUSPECTED
/// FRAUD adds the agent-verdict block, the three terminal ones drop the decision
/// buttons for Reload, and MANUAL_REVIEW is the plain case.
const _statuses = <String>[
  'MANUAL_REVIEW',
  'SUSPECTED_FRAUD',
  'VERIFIED',
  'REJECTED',
  'AUTO_APPROVED',
];

/// A name longer than any Ethiopian full name and longer than any business
/// name, because the database does not constrain it.
const _longName =
    'Tewodros Bekele Abera of Awolsefik Sub-City Kolfe Kerenian';

Future<void> _pump(
  WidgetTester tester,
  double scale, {
  required String status,
  String who = _longName,
  String typeLabel = 'National ID',
  String otherLabel = '',
  String? agentVerdict,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          // The same 16dp list padding the queue uses, so the card is measured
          // at the width it actually gets rather than the width of the screen.
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            children: [
              DocumentReviewCard(
                status: status,
                typeLabel: typeLabel,
                otherLabel: otherLabel,
                who: who,
                uploadedOn: '2026-10-01',
                agentVerdict: agentVerdict,
                decided: const {'VERIFIED', 'REJECTED', 'AUTO_APPROVED'}
                    .contains(status),
                thumbnail: Container(
                  width: 52,
                  height: 52,
                  color: AppTheme.creamDark,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('a document review card lays out without overflow', () {
    for (final entry in _scales.entries) {
      for (final status in _statuses) {
        testWidgets('$status at text scale ${entry.key}', (tester) async {
          tester.view.physicalSize = const Size(320 * 3, 480 * 3);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);

          await _pump(
            tester,
            entry.value,
            status: status,
            agentVerdict: status == 'SUSPECTED_FRAUD'
                ? 'The QR agent could not be read on this scan, and the '
                    'printed national ID number does not match the one in the '
                    'machine-readable zone.'
                : null,
          );
        });
      }
    }
  });

  group('an OTHER document lays out without overflow', () {
    // OTHER carries a free-text label written by the person signing up
    // (user_documents_other_label_check), so the card shows a second line of
    // arbitrary length under the type.
    for (final entry in _scales.entries) {
      testWidgets('at text scale ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(320 * 3, 480 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await _pump(
          tester,
          entry.value,
          status: 'MANUAL_REVIEW',
          typeLabel: 'Other document',
          otherLabel:
              'Residence permit issued by the Addis Ababa city migration '
              'office, renewed last year',
        );
      });
    }
  });

  group('the card still behaves', () {
    testWidgets('a document awaiting a decision offers all three actions',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await _pump(tester, 1.0, status: 'MANUAL_REVIEW');

      // An overflow fix that hid a button behind the edge of the card would not
      // be a fix, so each action must still be laid out and hittable.
      expect(find.text('View'), findsOneWidget);
      expect(find.text('Verify'), findsOneWidget);
      expect(find.text('Refuse'), findsOneWidget);
    });

    testWidgets('a decided document drops the decision buttons',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await _pump(tester, 1.0, status: 'VERIFIED');

      // Offering "Verify" on a document already marked VERIFIED would write a
      // second, contradictory decision through review_user_document().
      expect(find.text('Verify'), findsNothing);
      expect(find.text('Refuse'), findsNothing);
      expect(find.text('View'), findsOneWidget);
    });

    testWidgets('a flagged document shows what the agent thought',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await _pump(tester, 1.0,
          status: 'SUSPECTED_FRAUD', agentVerdict: 'QR zone unreadable');

      expect(find.textContaining('QR zone unreadable'), findsOneWidget);
    });

    testWidgets('tapping the actions reports them, and busy disables all',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DocumentReviewCard(
                  status: 'MANUAL_REVIEW',
                  typeLabel: 'National ID',
                  who: 'A Person',
                  uploadedOn: '2026-10-01',
                  decided: false,
                  onView: () => calls.add('view'),
                  onVerify: () => calls.add('verify'),
                  onRefuse: () => calls.add('refuse'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Verify'));
      await tester.tap(find.text('Refuse'));
      await tester.tap(find.text('View'));
      expect(calls, ['verify', 'refuse', 'view']);

      // While a decision is in flight every action must be inert, or a double
      // tap writes two decisions and two notifications.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                DocumentReviewCard(
                  status: 'MANUAL_REVIEW',
                  typeLabel: 'National ID',
                  who: 'A Person',
                  uploadedOn: '2026-10-01',
                  decided: false,
                  busy: true,
                  onView: () => calls.add('view-again'),
                  onVerify: () => calls.add('verify-again'),
                  onRefuse: () => calls.add('refuse-again'),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Verify'));
      await tester.tap(find.text('Refuse'));
      expect(calls, ['verify', 'refuse', 'view'],
          reason: 'a busy card must not accept a second decision');
    });
  });
}
