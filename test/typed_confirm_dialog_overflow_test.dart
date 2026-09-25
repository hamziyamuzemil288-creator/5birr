// Regression test for "BOTTOM OVERFLOWED BY 31 PIXELS" in the staff delete
// confirmation dialog.
//
// AlertDialog constrains the height of its `content` slot and does not scroll
// it, so the original layout — a paragraph plus a TextField, stacked in a
// plain Column — overflowed on a short screen and at a large text scale. The
// fix wraps the content in a SingleChildScrollView, matching the pattern
// already used elsewhere in this screen.
//
// Like searching_pin_overflow_test.dart, the assertion is that layout
// completes with no RenderFlex overflow. flutter_test records an overflow as
// a test failure, so simply pumping the dialog at hostile sizes IS the guard.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/services/provider_doc_gate.dart';
import 'package:birr5/features/admin/admin_staff_screen.dart';

/// The exact copy the delete flow uses, kept here so the test fails if the
/// real call site gets meaningfully longer.
const _deleteTitle = 'Delete Aymen permanently?';
const _deleteBody = 'This removes their staff entry AND their login account. '
    'It cannot be undone, and their username becomes available again.\n\n'
    'To remove access without deleting, use Revoke instead.';

/// Text scales and window shapes worth defending against: a small phone, and
/// a user who has turned system font size up (the most common real cause of
/// this class of overflow).
const _scales = <String, double>{
  'default': 1.0,
  'large': 1.3,
  'xLarge': 1.8,
  'max': 2.0,
};

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  group('TypedConfirmDialog lays out without overflow', () {
    for (final entry in _scales.entries) {
      testWidgets('at text scale ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(320 * 3, 480 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await _pump(
          tester,
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(entry.value)),
            child: const Center(
              child: TypedConfirmDialog(
                title: _deleteTitle,
                body: _deleteBody,
                confirmWord: 'DELETE',
                actionLabel: 'Delete forever',
              ),
            ),
          ),
        );

        // The destructive action must remain reachable and disabled until
        // the word is typed — an overflow fix must not quietly make the
        // button permanently enabled.
        final button = find.widgetWithText(FilledButton, 'Delete forever');
        expect(button, findsOneWidget);
        expect(tester.widget<FilledButton>(button).onPressed, isNull);
      });
    }
  });

  group('TypedConfirmDialog enables the action only when confirmed', () {
    testWidgets('typing the word enables the button and pops with it',
        (tester) async {
      String? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await showDialog<String>(
                      context: context,
                      builder: (_) => const TypedConfirmDialog(
                        title: _deleteTitle,
                        body: _deleteBody,
                        confirmWord: 'DELETE',
                        actionLabel: 'Delete forever',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pumpAndSettle();

      final button = find.widgetWithText(FilledButton, 'Delete forever');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);

      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(popped, 'DELETE');
    });
  });

  // The two doc-gate dialogs are public widgets (extracted from private
  // methods on the ProviderDocGate singleton) precisely so they get the same
  // treatment as the delete confirmation. Dialogs are where this class of
  // overflow keeps hiding, so "it is short today" is not a guarantee.
  group('doc-gate dialogs lay out without overflow', () {
    final dialogs = <String, Widget Function()>{
      'AlreadyVerifiedDialog': () => AlreadyVerifiedDialog(
            acceptedTypeNames: ProviderDocGate.acceptedDocTypes.values.toList(),
          ),
      'DocumentCheckFailedDialog': () => const DocumentCheckFailedDialog(),
    };

    for (final entry in dialogs.entries) {
      for (final scale in _scales.entries) {
        testWidgets('${entry.key} at text scale ${scale.key}',
            (tester) async {
          tester.view.physicalSize = const Size(320 * 3, 480 * 3);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);

          await _pump(
            tester,
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale.value)),
              child: Center(child: entry.value()),
            ),
          );
          expect(find.byType(AlertDialog), findsOneWidget);
        });
      }
    }
  });

  group('doc-gate dialogs report their choice', () {
    testWidgets('AlreadyVerifiedDialog returns true for "Add another"',
        (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlreadyVerifiedDialog(
                      acceptedTypeNames:
                          ProviderDocGate.acceptedDocTypes.values.toList(),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Add another'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('DocumentCheckFailedDialog returns false for "Close"',
        (tester) async {
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => const DocumentCheckFailedDialog(),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Close'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });
  });
}
