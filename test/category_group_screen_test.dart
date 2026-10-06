// The three big cards on Home and the screen each one opens.
//
// WHY THIS IS A TEST AND NOT A COMMENT
// ------------------------------------
// After the category grid left Home, these three cards are the ONLY category
// navigation on the app's first screen. The grouping is decided by three
// columns (`sector`, `marketplace_sector`, `service_group`) that four
// different migrations wrote months apart, so the failure mode is silent:
// a category that falls into no group simply does not exist anywhere in the
// app, and nothing on screen says so.
//
// Every row below uses the column values the seed data actually has —
// including the VEHICLE rows that migration 20260923000004 tagged
// `BOOKING_BASED`, which is the exact case that would misfile a taxi under
// "Services & Booking" if sector stopped winning.
import 'package:birr5/core/models/category.dart';
import 'package:birr5/features/user/user_category_group_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a category with only the columns the grouping reads.
AppCategory cat({
  required String name,
  required String slug,
  String sector = 'SERVICE',
  String? marketplaceSector,
  String? serviceGroup,
  int sortOrder = 0,
}) {
  return AppCategory(
    id: 'id-$slug',
    name: name,
    sector: sector,
    slug: slug,
    marketplaceSector: marketplaceSector,
    serviceGroup: serviceGroup,
    sortOrder: sortOrder,
    createdAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  group('the three big cards resolve from the route slug', () {
    test('each slug opens exactly one group, with the title Home prints', () {
      expect(CategoryGroup.parse('transport'), CategoryGroup.transport);
      expect(CategoryGroup.parse('shops'), CategoryGroup.shops);
      expect(CategoryGroup.parse('services'), CategoryGroup.services);

      expect(CategoryGroup.transport.title, 'Transport & Rides');
      expect(CategoryGroup.shops.title, 'Shops & Products');
      expect(CategoryGroup.services.title, 'Services & Booking');
    });

    test('an unknown slug is null, so the screen shows its error state', () {
      // A typo'd or hand-edited deep link must not silently render some
      // other group's categories.
      expect(CategoryGroup.parse('hotels'), isNull);
      expect(CategoryGroup.parse(null), isNull);
      expect(CategoryGroup.parse(''), isNull);
    });
  });

  group('every category lands in exactly one group', () {
    final all = [
      cat(name: 'Ride / Taxi', slug: 'ride-taxi', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED',
          sortOrder: 1),
      cat(name: 'Bus', slug: 'bus', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED',
          sortOrder: 6),
      cat(name: 'Food & Restaurants', slug: 'food-restaurants',
          marketplaceSector: 'FOOD', sortOrder: 2),
      cat(name: 'Retail', slug: 'retail', marketplaceSector: 'RETAIL',
          sortOrder: 3),
      cat(name: 'Other Services', slug: 'other-services',
          marketplaceSector: 'OTHER', sortOrder: 50),
      cat(name: 'Hotels & Lodging', slug: 'hotels-lodging',
          marketplaceSector: 'ACCOMMODATION', sortOrder: 4),
      cat(name: 'Beauty & Personal Care', slug: 'beauty',
          marketplaceSector: 'SERVICES', sortOrder: 5),
      cat(name: 'Event Services', slug: 'events',
          marketplaceSector: 'SERVICES', serviceGroup: 'BOOKING_BASED',
          sortOrder: 6),
    ];

    test('VEHICLE wins over a BOOKING_BASED service group', () {
      // The whole reason sector is checked first: a taxi tagged
      // BOOKING_BASED is still a vehicle, and filing it under Services would
      // empty the Transport card.
      final members =
          CategoryGroup.transport.membersOf(all).map((c) => c.slug).toList();
      expect(members, ['ride-taxi', 'bus']);
    });

    test('shops owns FOOD, RETAIL and OTHER, in sort order', () {
      expect(
        CategoryGroup.shops.membersOf(all).map((c) => c.slug),
        ['food-restaurants', 'retail', 'other-services'],
      );
    });

    test('services owns ACCOMMODATION, SERVICES and booking groups', () {
      expect(
        CategoryGroup.services.membersOf(all).map((c) => c.slug),
        ['hotels-lodging', 'beauty', 'events'],
      );
    });

    test('no category appears in two groups, and none is dropped', () {
      final seen = <String>{};
      var covered = 0;
      for (final group in CategoryGroup.values) {
        for (final c in group.membersOf(all)) {
          // Duplicates would make the same card tappable twice with two
          // different screens behind it.
          expect(seen.add(c.id), isTrue,
              reason: '${c.name} is in two groups');
          covered++;
        }
      }
      expect(covered, all.length,
          reason: 'a category in no group is invisible everywhere in the app');
    });

    test('membership is decided by the columns, not by the row order', () {
      final shuffled = [...all].reversed.toList();
      expect(
        CategoryGroup.shops.membersOf(shuffled).map((c) => c.slug),
        ['food-restaurants', 'retail', 'other-services'],
      );
    });
  });
}
