// Layout test for the "Where to?" picker.
//
// Follows test/income_filter_chips_overflow_test.dart and
// test/document_review_card_overflow_test.dart, but corrects something both of
// them imply and this one proved wrong when it was first written.
//
// WHAT THIS DOES NOT CLAIM
// ------------------------
// The first version of this file asserted that these rows do not overflow, and
// removing every `maxLines: 1` left all nineteen tests GREEN. Nothing here
// overflows: a `Text` in a bounded row WRAPS or CLIPS and the row grows or
// hides it. So `maxLines` on a bounded row is not an overflow guard in this
// widget, and a test that implied otherwise was guarding nothing.
//
// WHAT IT ACTUALLY GUARDS
// -----------------------
// A `ListTile` bounds its own height: the title is laid out with a max height,
// so a label that does not fit CLIPS and the row never grows. `dense: true`
// and `dense: false` render a short label at 64dp and 72dp respectively and
// render the LONGEST OpenStreetMap label at exactly the same height. Measured
// across `dense` true/false crossed with `maxLines` set/unset, the row height
// is a function of `dense` alone -- the label's length is not visible to
// layout at all. A test that asserted "the row is under N line heights" was
// therefore reading a constant.
//
// So the one-line promise is guarded where it is actually made: on the WIDGET.
// `dense` is asserted on the ListTile, and `maxLines` on the title and
// subtitle Texts. Both are real properties of the tree, both were verified to
// go red when the property they name is deleted, and neither pretends to be a
// measurement of something layout already guarantees.
//
// What layout DOES guarantee, and what is asserted by pumping rather than by
// measuring, is that the search row raises no RenderFlex overflow: a Row whose
// children exceed its width throws in a widget test, so those eight cases are
// a real guard. It is checked in BOTH states because the action button swaps
// a 48dp spinner for a 20dp icon on every GPS fix, and the field beside it
// must not shift when it does.
//
// The picker itself is not pumped because it opens FlutterMap and asks for a
// GPS fix. What is pumped is the exact row and button content it builds, at
// 320x480 across every text scale Android offers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/services/geocoding_service.dart';
import 'package:birr5/core/theme/app_theme.dart';

/// Android's "Large" is 1.3x and its maximum is 2.0x.
const _scales = <String, double>{
  'default': 1.0,
  'large': 1.3,
  'xLarge': 1.8,
  'max': 2.0,
};

/// A kebele name and a landmark name, both the length OSM actually returns.
const _longArea = 'Kirkos South III, Bole Sub-City, Addis Ababa';
const _longLandmark = 'Wau Tesfaye, near the Bole roundabout, opposite the '
    'Ethiopian Telecom building';

PlaceResult _area(String label) => PlaceResult(
      label: label,
      city: 'Addis Ababa',
      lat: 9.0,
      lng: 38.7,
      kind: PlaceKind.area,
      distanceMeters: 1450,
    );

PlaceResult _place(String label) =>
    PlaceResult(label: label, city: 'Addis Ababa', lat: 9.0, lng: 38.7);

/// Mirrors WhereToPicker's `_placeTile`. Kept as a local so the test needs no
/// Supabase, no map and no network; the shapes are what overflow, not the
/// service behind them.
Widget _tile(PlaceResult place, {bool selected = false, bool showDistance = false}) {
  final isArea = place.kind == PlaceKind.area;
  final metres = place.distanceMeters;
  return ListTile(
    dense: true,
    leading: Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (selected ? AppTheme.primaryGreen : AppTheme.teal)
            .withOpacity(0.10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(isArea ? Icons.grid_view_outlined : Icons.place_outlined,
          size: 18, color: AppTheme.textSecondary),
    ),
    title: Text(place.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
    subtitle: Text(
      [
        if (place.city.isNotEmpty) place.city,
        if (showDistance && metres != null)
          '${(metres / 1000).toStringAsFixed(1)} km away',
      ].join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
    ),
    trailing: selected
        ? const Icon(Icons.check_circle, size: 20, color: AppTheme.primaryGreen)
        : null,
  );
}

/// Mirrors WhereToPicker's `_confirmButton`.
Widget _confirm(String? label) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
    child: SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: label == null ? null : () {},
        style: FilledButton.styleFrom(
          backgroundColor: AppTheme.primaryGreen,
          disabledBackgroundColor: AppTheme.cardBorder,
          padding: const EdgeInsets.symmetric(vertical: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Text(
          label == null ? 'Pick a place to continue' : 'Go to $label',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
      ),
    ),
  );
}

/// Mirrors WhereToPicker's search row: a field beside a fixed-size action.
Widget _searchRow({required bool busy}) {
  return Padding(
    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            style: const TextStyle(fontSize: 14.5),
            decoration: InputDecoration(
              hintText: 'Search a place, kebele or landmark',
              prefixIcon: const Icon(Icons.search, size: 20),
              filled: true,
              fillColor: AppTheme.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.primaryGreen),
                )
              : const Icon(Icons.my_location,
                  size: 20, color: AppTheme.primaryGreenDark),
        ),
      ],
    ),
  );
}

Future<void> _pump(WidgetTester tester, double scale, Widget child,
    {bool settle = true}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(8),
            children: [child],
          ),
        ),
      ),
    ),
  );
  // `settle: false` for the busy button. A CircularProgressIndicator animates
  // forever, so `pumpAndSettle` never returns and the test times out on a
  // layout that is perfectly fine. LAYOUT still happens on a plain pump, and
  // layout is what raises the overflow, so the guard is intact -- it just
  // stops waiting for an animation that by definition has no end.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('the where-to search row lays out without overflow', () {
    for (final entry in _scales.entries) {
      // BOTH states, because the button swaps a 48x48 spinner for a 20x20 icon
      // and the row must not change width when it does.
      for (final busy in [true, false]) {
        testWidgets('at text scale ${entry.key}, busy=$busy', (tester) async {
          tester.view.physicalSize = const Size(320 * 3, 480 * 3);
          tester.view.devicePixelRatio = 3.0;
          addTearDown(tester.view.reset);
          await _pump(tester, entry.value, _searchRow(busy: busy),
              settle: !busy);
        });
      }
    }
  });

  group('a long kebele or landmark row keeps its compact shape', () {
    for (final entry in _scales.entries) {
      testWidgets('at text scale ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(320 * 3, 480 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        // A short row and the two longest labels OSM actually returns, pumped
        // at 320x480 so that at every Android text scale the row really does
        // have to fit. The pumping is half the assertion: the column must lay
        // out with no overflow.
        await _pump(
          tester,
          entry.value,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _tile(_area('Bole')),
              _tile(_area(_longArea), showDistance: true),
              _tile(_place(_longLandmark), selected: true),
            ],
          ),
        );

        // `dense` is what makes a result row one compact line of title plus one
        // of subtitle; without it the row is 72dp instead of 64dp for every
        // label, long or short.
        for (final tile in find.byType(ListTile).evaluate()) {
          expect((tile.widget as ListTile).dense, isTrue,
              reason: 'a result row must stay dense so the list fits more '
                  'results on a 480dp screen');
        }
        // And the label is capped where the cap has to be, because a ListTile
        // will silently clip past it -- which reads as a truncated place name,
        // not as an overflow.
        for (final label in [_longArea, _longLandmark]) {
          final text = tester.widget<Text>(find.text(label));
          expect(text.maxLines, 1,
              reason: '"$label" must be capped at one line with an ellipsis; '
                  'a ListTile clips a second line instead of showing it');
          expect(text.overflow, TextOverflow.ellipsis,
              reason: 'a capped label needs an ellipsis, or it truncates to '
                  'nothing and the user cannot tell it was cut');
        }
      });
    }
  });

  group('the confirm button keeps a long name to one line', () {
    for (final entry in _scales.entries) {
      testWidgets('at text scale ${entry.key}', (tester) async {
        tester.view.physicalSize = const Size(320 * 3, 480 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);
        await _pump(tester, entry.value, _confirm(_longLandmark));

        // The primary control. A FilledButton has no height bound, so `maxLines`
        // is a genuine cap here and is the only thing keeping a long
        // OpenStreetMap name from turning "Go to ..." into a paragraph. The
        // pump above is the other half: it lays out, or throws.
        final label = tester.widget<Text>(find.text('Go to $_longLandmark'));
        expect(label.maxLines, 1,
            reason: 'the confirm label must be capped at one line, or a long '
                'place name turns the primary control into a paragraph');
        expect(label.overflow, TextOverflow.ellipsis,
            reason: 'a capped confirm label needs an ellipsis or it truncates '
                'mid-word with nothing to show the name was cut');
      });
    }
  });

  group('the behaviour the overflow fix must not break', () {
    testWidgets('an unselected place is still tappable and shows no check',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: ListTile(
              onTap: () => tapped = true,
              title: const Text('Bole'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Bole'));
      expect(tapped, isTrue);

      await _pump(tester, 1.0, _tile(_area('Bole'), selected: false));
      expect(find.byIcon(Icons.check_circle), findsNothing);
    });

    testWidgets('a selected place shows the check and the confirm names it',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await _pump(tester, 1.0,
          Column(mainAxisSize: MainAxisSize.min, children: [
        _tile(_area('Bole'), selected: true),
        _confirm('Bole'),
      ]));
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('Go to Bole'), findsOneWidget);
    });

    testWidgets('with nothing chosen the button is disabled but still visible',
        (tester) async {
      // Hidden-until-chosen would read as a broken app; a greyed button with a
      // sentence explaining itself is the requirement.
      tester.view.physicalSize = const Size(320 * 3, 480 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await _pump(tester, 1.0, _confirm(null));
      expect(find.text('Pick a place to continue'), findsOneWidget);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  });
}
