// The category -> tab mapping, pinned against the real seeded data.
//
// WHY THIS IS A TEST AND NOT A COMMENT
// -----------------------------------
// The mapping is the load-bearing decision in the home rebuild, and it is
// decided by three columns whose values came out of four different migrations
// written months apart. That is exactly the shape of thing that breaks
// silently: someone seeds a new category, the mapping quietly files it under
// "All only", and it becomes invisible.
//
// Every case below uses a row that ACTUALLY EXISTS in the seed data, with the
// column values it actually has. If a migration changes a sector or a
// marketplace_sector, this test fails rather than the UI quietly emptying a
// tab in production.
import 'package:birr5/core/models/category.dart';
import 'package:birr5/core/models/category_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a category with only the columns the mapping reads.
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
  group('VEHICLE rows go to Vehicles, whatever service_group says', () {
    // This is the case the whole mapping exists for. Migration
    // 20260923000004 set service_group='BOOKING_BASED' on every VEHICLE row,
    // so a naive `service_group` implementation files a taxi under Booking.
    final vehicles = [
      cat(name: 'Ride / Taxi', slug: 'ride-taxi', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 1),
      cat(name: 'Bus', slug: 'bus', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 6),
      cat(name: 'Truck', slug: 'truck', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 8),
      cat(name: 'Ambulance / Emergency Transport', slug: 'ambulance-emergency',
          sector: 'VEHICLE', marketplaceSector: 'TRANSPORT',
          serviceGroup: 'BOOKING_BASED', sortOrder: 13),
      // A vehicle row whose marketplace_sector is somehow SERVICES: sector
      // still wins, because "a vehicle is a vehicle".
      cat(name: 'Odd Vehicle', slug: 'odd-vehicle', sector: 'VEHICLE',
          marketplaceSector: 'SERVICES', serviceGroup: 'BOOKING_BASED'),
    ];
    for (final c in vehicles) {
      test('${c.slug} -> Vehicles', () {
        expect(categoryTabFor(c), HomeTab.vehicles);
      });
    }
  });

  group('ACCOMMODATION and SERVICES go to Booking', () {
    // These are the founder's own examples: "Hotels, Beauty, Events".
    final booking = [
      cat(name: 'Hotels & Lodging', slug: 'hotels-lodging',
          marketplaceSector: 'ACCOMMODATION', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Beauty', slug: 'beauty',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Entertainment', slug: 'entertainment',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Home Services', slug: 'home-services',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Education', slug: 'education',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED'),
    ];
    for (final c in booking) {
      test('${c.slug} -> Booking', () {
        expect(categoryTabFor(c), HomeTab.booking,
            reason: '${c.slug} is a time-slot category, not a shelf');
      });
    }
  });

  group('FOOD, RETAIL and OTHER go to Shops', () {
    final shops = [
      cat(name: 'Food & Restaurants', slug: 'food-restaurants',
          marketplaceSector: 'FOOD', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Retail', slug: 'retail',
          marketplaceSector: 'RETAIL', serviceGroup: 'PRODUCT_BASED'),
      cat(name: 'Other Services', slug: 'other-services',
          marketplaceSector: 'OTHER', serviceGroup: 'PRODUCT_BASED'),
    ];
    for (final c in shops) {
      test('${c.slug} -> Shops', () {
        expect(categoryTabFor(c), HomeTab.shops);
      });
    }
  });

  group('rows with no marketplace_sector still resolve', () {
    test('BOOKING_BASED with no sector marker -> Booking', () {
      expect(
        categoryTabFor(cat(name: 'New', slug: 'new', serviceGroup: 'BOOKING_BASED')),
        HomeTab.booking,
      );
    });

    test('PRODUCT_BASED with no sector marker -> Shops', () {
      expect(
        categoryTabFor(cat(name: 'New', slug: 'new', serviceGroup: 'PRODUCT_BASED')),
        HomeTab.shops,
      );
    });

    test('an entirely unclassified row is All-only, never hidden', () {
      // Better a category in one place than a category nowhere.
      expect(
        categoryTabFor(cat(name: 'Mystery', slug: 'mystery')),
        HomeTab.all,
      );
    });
  });

  group('the real seed data produces a populated set of tabs', () {
    // The whole seeded top-level set, as it exists after 0004 + 0016 + 0022d.
    final seeded = [
      cat(name: 'Hotels & Lodging', slug: 'hotels-lodging',
          marketplaceSector: 'ACCOMMODATION', serviceGroup: 'PRODUCT_BASED', sortOrder: 1),
      cat(name: 'Food & Restaurants', slug: 'food-restaurants',
          marketplaceSector: 'FOOD', serviceGroup: 'PRODUCT_BASED', sortOrder: 2),
      cat(name: 'Retail', slug: 'retail',
          marketplaceSector: 'RETAIL', serviceGroup: 'PRODUCT_BASED', sortOrder: 3),
      cat(name: 'Health', slug: 'health',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 4),
      cat(name: 'Beauty', slug: 'beauty',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 5),
      cat(name: 'Home Services', slug: 'home-services',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 6),
      cat(name: 'Education', slug: 'education',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 7),
      cat(name: 'Professional Services', slug: 'professional-services',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 8),
      cat(name: 'Entertainment', slug: 'entertainment',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 9),
      cat(name: 'Fitness', slug: 'fitness',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 10),
      cat(name: 'Agriculture', slug: 'agriculture',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 11),
      cat(name: 'Real Estate', slug: 'real-estate',
          marketplaceSector: 'SERVICES', serviceGroup: 'PRODUCT_BASED', sortOrder: 12),
      cat(name: 'Ride / Taxi', slug: 'ride-taxi', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 1),
      cat(name: 'Delivery Vehicle', slug: 'delivery-vehicle', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 2),
      cat(name: 'Food Delivery', slug: 'food-delivery', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 3),
      cat(name: 'Motorcycle / Bajaj', slug: 'motorcycle-bajaj', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 4),
      cat(name: 'Car Rental', slug: 'car-rental', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 5),
      cat(name: 'Bus', slug: 'bus', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 6),
      cat(name: 'Minibus', slug: 'minibus', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 7),
      cat(name: 'Truck', slug: 'truck', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 8),
      cat(name: 'Freight / Cargo', slug: 'freight-cargo', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 9),
      cat(name: 'Tour & Travel', slug: 'tour-travel', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 10),
      cat(name: 'Airport Transport', slug: 'airport-transport', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 11),
      cat(name: 'Special Transport', slug: 'special-transport', sector: 'VEHICLE',
          marketplaceSector: 'TRANSPORT', serviceGroup: 'BOOKING_BASED', sortOrder: 12),
      cat(name: 'Ambulance / Emergency Transport', slug: 'ambulance-emergency',
          sector: 'VEHICLE', marketplaceSector: 'TRANSPORT',
          serviceGroup: 'BOOKING_BASED', sortOrder: 13),
      cat(name: 'Other Services', slug: 'other-services',
          marketplaceSector: 'OTHER', serviceGroup: 'PRODUCT_BASED', sortOrder: 50),
    ];

    test('every seeded category resolves to a real tab', () {
      for (final c in seeded) {
        expect(HomeTab.values, contains(categoryTabFor(c)),
            reason: '${c.slug} resolved outside the tab set');
      }
    });

    test('all four tabs are populated by the seed data', () {
      // The specific regression: if service_group were used directly, Booking
      // would hold all 13 vehicles and 0 services, or Shops would hold
      // everything. This asserts neither.
      final groups = groupByTab(seeded);
      for (final tab in HomeTab.values) {
        expect(groups[tab], isNotNull,
            reason: '$tab has no group key at all');
        expect(groups[tab]!.length, greaterThan(0),
            reason: '$tab is empty — the mapping is misfiling rows');
      }
    });

    test('Vehicles holds exactly the 13 VEHICLE rows and nothing else', () {
      final vehicles = groupByTab(seeded)[HomeTab.vehicles]!;
      expect(vehicles.length, 13);
      expect(vehicles.every((c) => c.sector == 'VEHICLE'), isTrue);
    });

    test('Booking holds no vehicles', () {
      final booking = groupByTab(seeded)[HomeTab.booking]!;
      expect(booking.every((c) => c.sector != 'VEHICLE'), isTrue,
          reason: 'a vehicle in Booking is the bug this file exists for');
      expect(booking.map((c) => c.slug), contains('hotels-lodging'));
      expect(booking.map((c) => c.slug), contains('beauty'));
      expect(booking.map((c) => c.slug), contains('entertainment'));
    });

    test('Shops holds the ordered-goods categories', () {
      final shops = groupByTab(seeded)[HomeTab.shops]!;
      expect(shops.map((c) => c.slug), containsAll(['food-restaurants', 'retail']));
    });

    test('All holds every category, exactly once', () {
      final all = groupByTab(seeded)[HomeTab.all]!;
      expect(all.length, seeded.length);
      expect(all.map((c) => c.slug).toSet().length, seeded.length,
          reason: 'a category appeared under All twice');
    });

    test('tabs come back in the founder\'s order, All always present', () {
      expect(availableTabs(seeded), HomeTab.values);
    });

    test('sort_order is respected inside a tab', () {
      // Vehicles 1..13 must stay in order, or the tab reads as random.
      final vehicles = groupByTab(seeded)[HomeTab.vehicles]!;
      final orders = vehicles.map((c) => c.sortOrder).toList();
      expect(orders, [...orders]..sort());
      expect(vehicles.first.slug, 'ride-taxi');
    });

    test('a deployment with no bookable categories drops the Booking tab', () {
      // Better than a permanently empty tab, and the per-tab empty state
      // still covers the in-tab case.
      final shopsOnly = [
        cat(name: 'Retail', slug: 'retail', marketplaceSector: 'RETAIL'),
        cat(name: 'Ride / Taxi', slug: 'ride-taxi', sector: 'VEHICLE',
            marketplaceSector: 'TRANSPORT'),
      ];
      expect(availableTabs(shopsOnly),
          [HomeTab.all, HomeTab.vehicles, HomeTab.shops]);
      expect(availableTabs(shopsOnly), isNot(contains(HomeTab.booking)));
    });
  });

  group('children inherit the parent tab', () {
    test('a hotel leaf stays Booking even if its own sector marker differs', () {
      // Migration 0016 sets marketplace_sector on some leaves; a leaf under
      // hotels-lodging is a booking regardless.
      final parent = cat(name: 'Hotels & Lodging', slug: 'hotels-lodging',
          marketplaceSector: 'ACCOMMODATION', serviceGroup: 'PRODUCT_BASED');
      final child = cat(name: 'Guesthouses', slug: 'guesthouses',
          marketplaceSector: 'OTHER', serviceGroup: 'PRODUCT_BASED');
      final grouped = groupChildrenByTab([child], categoryTabFor(parent));
      expect(grouped[HomeTab.booking]!.map((c) => c.slug), ['guesthouses']);
      expect(grouped[HomeTab.shops], isNull,
          reason: 'a leaf must not re-file itself under a different tab');
    });
  });
}
