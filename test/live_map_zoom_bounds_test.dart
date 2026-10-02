// test/live_map_zoom_bounds_test.dart
//
// The zoom buttons, pinned down on the one part that is a rule rather than
// paint: where a step actually lands.
//
// The buttons themselves and the camera tween are verified by looking at
// them. This is here because both of the ways this can be wrong are invisible
// to a tap. An unclamped step walks straight past the last zoom OpenStreetMap
// publishes standard tiles for, and the user is left staring at grey squares
// with two buttons that still look live. A clamp applied to `currentZoom`
// before the step rather than to the result refuses the last legitimate step,
// so the user presses "+" at maximum zoom and nothing happens while the
// counter in their head says it should.
//
// Asserted against the real function in lib/core/widgets/live_map.dart, not
// a copy: a copy would keep passing after the production clamp was deleted,
// which is the failure this repository hit repeatedly with hand-rolled
// expectations in the migration checks.

import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/widgets/live_map.dart';

void main() {
  group('a zoom step lands inside the bounds', () {
    test('an ordinary step moves exactly one level', () {
      expect(zoomTarget(15, 1), 16);
      expect(zoomTarget(15, -1), 14);
    });

    test('stepping past the last published tile level stops there', () {
      // 18 is the last zoom standard OpenStreetMap tiles exist for.
      expect(zoomTarget(18, 1), 18);
      expect(zoomTarget(17.5, 4), 18);
    });

    test('stepping past the far end stops there rather than flipping', () {
      expect(zoomTarget(3, -1), 3);
      expect(zoomTarget(3, -9), 3);
    });

    test('the last legitimate step is still allowed', () {
      // The bug an off-by-one clamp introduces: refusing 17 -> 18 would
      // leave a user who never zoomed in unable to reach street level.
      expect(zoomTarget(17, 1), 18);
      expect(zoomTarget(4, -1), 3);
    });

    test('being at a limit is a no-op, not a jump', () {
      expect(zoomTarget(18, 0), 18);
      expect(zoomTarget(18, -1), 17);
    });
  });

  group('the bounds are the ones the widget advertises', () {
    test('defaults match the standard tile range', () {
      expect(zoomTarget(19, 1), 18);
      expect(zoomTarget(2, -1), 3);
    });

    test('a caller can narrow them and the clamp follows', () {
      expect(zoomTarget(16, 1, maxZoom: 16), 16);
      expect(zoomTarget(10, -1, minZoom: 10, maxZoom: 16), 10);
      expect(zoomTarget(14, 1, minZoom: 10, maxZoom: 16), 15);
      // A narrowed range must not swallow a step that still fits inside it:
      // 10 -> 11 is legal in [10, 16], and only the step PAST the bound is
      // refused. Reading this as "10 is the floor, so nothing moves" is the
      // off-by-one the other group is about, one level down.
      expect(zoomTarget(10, 1, minZoom: 10, maxZoom: 16), 11);
    });
  });
}