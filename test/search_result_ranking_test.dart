// Pins the search ranking rule that keeps unlocatable listings from
// masquerading as nearby results.
//
// search_products returns distance_km = NULL for any row whose products
// location is NULL, and its ST_DWithin predicate short-circuits on
// `p.location IS NULL` — so the radius filter never runs and every
// location-less listing is returned to every searcher regardless of distance.
// That is what produced results with unfamiliar provider names from other
// areas. A listing that cannot be located must therefore never outrank one
// that can.
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/features/user/user_search_screen.dart';

Map<String, dynamic> row(String name, Object? distance) =>
    {'name': name, 'distance_km': distance};

void main() {
  group('rankLocationLessLast', () {
    test('demotes rows with a null distance', () {
      final out = rankLocationLessLast([
        row('unlocated-a', null),
        row('near', 1.2),
        row('unlocated-b', null),
        row('far', 20.0),
      ]);
      expect(out.map((r) => r['name']),
          ['near', 'far', 'unlocated-a', 'unlocated-b']);
    });

    test('preserves server order within the located group', () {
      // The server sorted these by distance; the client must not reshuffle
      // them, only move the unlocatable tail out of the way.
      final out = rankLocationLessLast([
        row('a', 0.4),
        row('b', 3.1),
        row('c', 9.9),
      ]);
      expect(out.map((r) => r['name']), ['a', 'b', 'c']);
    });

    test('preserves server order within the unlocated group', () {
      final out = rankLocationLessLast([
        row('u1', null),
        row('near', 2.0),
        row('u2', null),
        row('u3', null),
      ]);
      expect(out.map((r) => r['name']), ['near', 'u1', 'u2', 'u3']);
    });

    test('treats a zero distance as located, not missing', () {
      // 0 is a real distance (you are standing on it). A naive
      // truthiness check would demote it and lose the best possible hit.
      final out = rankLocationLessLast([
        row('here', 0),
        row('unlocated', null),
      ]);
      expect(out.map((r) => r['name']), ['here', 'unlocated']);
    });

    test('handles an int distance from the JSON decoder', () {
      // PostgREST returns JSON numbers; a whole number decodes to int, so a
      // `d is double` check would wrongly demote real hits.
      final out = rankLocationLessLast([
        row('unlocated', null),
        row('near', 3),
      ]);
      expect(out.map((r) => r['name']), ['near', 'unlocated']);
    });

    test('is a no-op on an all-located result set', () {
      final input = [row('a', 1.0), row('b', 2.0)];
      expect(rankLocationLessLast(input).map((r) => r['name']), ['a', 'b']);
    });

    test('handles an empty result set', () {
      expect(rankLocationLessLast([]), isEmpty);
    });

    test('handles an all-unlocated result set', () {
      final out = rankLocationLessLast([row('a', null), row('b', null)]);
      expect(out.map((r) => r['name']), ['a', 'b']);
    });

    test('does not mutate the input list', () {
      final input = [row('unlocated', null), row('near', 1.0)];
      rankLocationLessLast(input);
      expect(input.first['name'], 'unlocated',
          reason: 'rebuilding the list must not reorder the caller\'s data');
    });
  });
}
