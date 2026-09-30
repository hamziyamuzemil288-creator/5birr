// Regression test for the "RenderFlex overflowed by N pixels" banner on the
// admin income summary screen's fee-category filter row.
//
// The row used to be four `FilterChip`s in a plain `Row`, inside a `Card`,
// inside `ListView(padding: EdgeInsets.all(16))`. Every Card in this theme
// carries `margin: EdgeInsets.symmetric(horizontal: 16)` (app_theme.dart), so on
// a 360dp phone the chips get 360 - 32 (list padding) - 32 (card margin) - 24
// (card padding) = 272dp, not 360dp. Four inflexible chips need roughly 226dp at
// the default text scale and ~294dp at 1.3x, which is the "Large" font size
// setting on many Android devices. A `Row` cannot absorb that: it reports
// overflow and clips the last chip. `Wrap` moves the row onto a second line.
//
// Like typed_confirm_dialog_overflow_test.dart, the guard IS the pump: an
// overflow during layout is reported as a FlutterError and fails the test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/theme/app_theme.dart';
import 'package:birr5/features/admin/admin_income_summary_screen.dart';

/// A small phone, and the text scales a user can actually have set: Android's
/// "Large" is 1.3x, and 2.0x is its maximum.
const _scales = <String, double>{
  'default': 1.0,
  'large': 1.3,
  'xLarge': 1.8,
  'max': 2.0,
};

/// The chips exactly as the screen mounts them: inside the real theme's Card,
/// inside the same ListView padding. Testing the bare `Wrap` would not exercise
/// the 16dp card margin that caused the overflow.
Future<void> _pump(WidgetTester tester, double scale, String selected,
    {ValueChanged<String>? onChanged}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: MediaQuery(
        // fromView, not a bare MediaQueryData: this keeps the real view metrics
        // and only overrides the text scale, so the layout under test is laid
        // out at the size the test asked for.
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IncomeFilterChips(
                    value: selected,
                    onChanged: onChanged ?? (_) {},
                  ),
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
  group('the income filter row lays out without overflow', () {
    for (final entry in _scales.entries) {
      testWidgets('at text scale ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(320 * 3, 480 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await _pump(tester, entry.value, 'ALL');

        // Every category must still be reachable at the smallest width and the
        // largest text scale -- an overflow fix that hides a chip behind the
        // edge of the card is not a fix.
        for (final label in IncomeFilterChips.labels.values) {
          expect(find.text(label), findsOneWidget,
              reason: '$label is not laid out at text scale ${entry.key}');
        }
      });
    }
  });

  group('the income filter row still behaves', () {
    testWidgets('tapping a category reports the ledger type, not the label',
        (tester) async {
      String? picked;
      await _pump(tester, 1.0, 'ALL', onChanged: (v) => picked = v);

      await tester.tap(find.text('Activation Fees'));
      await tester.pumpAndSettle();

      // The key drives the query (`transaction_type`), so a regression that
      // reported the display label would silently filter on a value the
      // database does not have.
      expect(picked, 'REGISTRATION_FEE');
    });

    testWidgets('only the category passed in is selected', (tester) async {
      await _pump(tester, 1.0, 'SUBSCRIPTION_FEE');

      final selected = tester
          .widgetList<FilterChip>(find.byType(FilterChip))
          .where((chip) => chip.selected)
          .map((chip) => (chip.label as Text).data)
          .toList();

      expect(selected, ['5birr Fees']);
    });
  });
}
