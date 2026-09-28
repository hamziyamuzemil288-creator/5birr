/// Which top tab a category belongs to, derived from the `categories` table.
///
/// ## Why the mapping is not simply `service_group`
///
/// The obvious implementation is `service_group = 'BOOKING_BASED'` -> Booking
/// and `PRODUCT_BASED` -> Shops. That is wrong, and wrong in a way that looks
/// right until you run it:
///
/// * Migration 20260923000004 set `service_group = 'BOOKING_BASED'` for
///   **every** `sector = 'VEHICLE'` row, because rides are booked. So every
///   one of Ride/Taxi, Bus, Truck, Ambulance, Tour & Travel and the rest
///   reads as BOOKING_BASED.
/// * That same migration set **every** `sector = 'SERVICE'` row to
///   PRODUCT_BASED.
///
/// `service_group` on its own therefore yields one enormous Booking tab
/// containing every vehicle and a Shops tab containing everything else, with
/// no way to tell a taxi from a hotel. It cannot separate the tabs the sketch
/// asks for, so it is not used as the primary key.
///
/// ## The mapping actually used
///
/// In precedence order:
///
/// 1. `sector = 'VEHICLE'` -> **Vehicles**. A taxi and a truck are both
///    things you summon and pay per trip; grouping them is what the founder
///    means by "Vehicles".
/// 2. `marketplace_sector` is one of ACCOMMODATION or SERVICES -> **Booking**.
///    This is the real booking/ordering distinction in the data: a hotel room
///    or a barber appointment is reserved for a time slot and cannot be
///    bought off a shelf, while groceries and clothing are ordered. Both of
///    those `marketplace_sector` values are already set by migration 0016, so
///    this reads real data rather than inventing a list here.
/// 3. `marketplace_sector` is FOOD, RETAIL or OTHER -> **Shops**.
/// 4. `service_group = 'BOOKING_BASED'` on a non-vehicle row -> **Booking**,
///    as a fallback for a row added after this was written whose sector has
///    not been classified.
/// 5. Anything else -> **All** only. A category that fits no tab still has to
///    be reachable; hiding it would be worse than showing it in one place.
///
/// The ordering matters: step 1 precedes step 4 precisely so a vehicle row
/// carrying BOOKING_BASED lands in Vehicles rather than Booking.
///
/// ## Why not fix the data instead
///
/// Re-seeding `service_group` would be cleaner, but `service_group` is read by
/// live product and provider queries and by the checkout flow. Changing its
/// meaning is a data migration with real blast radius, and the brief scopes
/// this work to navigation and presentation. The mapping below reads the
/// existing columns as they are, so it is correct against today's data and
/// degrades sensibly against tomorrow's.
library;

import 'category.dart';

/// The four top tabs, in the founder's order.
enum HomeTab {
  all('All'),
  booking('Booking'),
  vehicles('Vehicles'),
  shops('Shops');

  const HomeTab(this.label);
  final String label;
}

/// A top-level category plus the sub-categories shown beneath it in the grid.
class TabCategory {
  const TabCategory({
    required this.category,
    this.children = const [],
    this.productCount = 0,
  });

  final AppCategory category;
  final List<AppCategory> children;

  /// How many live listings sit under this category (self + children).
  /// Only used to decide whether a tab deserves a product rail.
  final int productCount;

  String get name => category.name;
  String get slug => category.slug;
  String get id => category.id;
  HomeTab get tab => categoryTabFor(category);
}

/// The tab [category] belongs to. See the library docs for the precedence.
HomeTab categoryTabFor(AppCategory category) {
  // 1. Vehicles win outright, whatever service_group says.
  if (category.sector == 'VEHICLE') return HomeTab.vehicles;

  // 2/3. marketplace_sector is the actual book-vs-order signal.
  switch (category.marketplaceSector) {
    case 'ACCOMMODATION':
    case 'SERVICES':
      return HomeTab.booking;
    case 'FOOD':
    case 'RETAIL':
    case 'OTHER':
      return HomeTab.shops;
  }

  // 4. Fallback for a row whose sector has not been classified.
  if (category.serviceGroup == 'BOOKING_BASED') return HomeTab.booking;
  if (category.serviceGroup == 'PRODUCT_BASED') return HomeTab.shops;

  // 5. Unclassified. Reachable under All only — see the library docs.
  return HomeTab.all;
}

/// The tabs that actually have content, in founder order.
///
/// A tab with nothing in it is dropped rather than shown empty. The founder
/// asked for a specific set; showing a permanently-empty "Booking" tab on a
/// deployment where nothing is bookable is worse than not showing it, and the
/// empty state is still reachable per-category inside a populated tab.
List<HomeTab> availableTabs(List<AppCategory> categories) {
  final present = categories.map(categoryTabFor).toSet();
  return HomeTab.values
      .where((t) => t == HomeTab.all || present.contains(t))
      .toList();
}

/// Group [categories] by tab, preserving `sort_order` within each tab.
///
/// [HomeTab.all] is the union of everything, not a fifth bucket. Seeding it
/// with an empty list and then appending each category only to its own tab
/// leaves All permanently empty, which reads as "the All tab is broken"
/// rather than "the All tab shows everything" — so it is built explicitly
/// here.
Map<HomeTab, List<AppCategory>> groupByTab(List<AppCategory> categories) {
  final sorted = [...categories]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  final out = <HomeTab, List<AppCategory>>{};
  for (final c in sorted) {
    out.putIfAbsent(categoryTabFor(c), () => <AppCategory>[]).add(c);
  }
  // Every category, in the same order, whatever tab it also belongs to.
  out[HomeTab.all] = [...sorted];
  return out;
}

/// Group sub-categories by tab.
///
/// Sub-categories inherit their parent's tab. They carry their own
/// `marketplace_sector` in some rows (migration 0016 sets it on the leaves it
/// inserted), so the parent's tab is the authority: a leaf under
/// `hotels-lodging` is a Booking item no matter what its own column says.
Map<HomeTab, List<AppCategory>> groupChildrenByTab(
    List<AppCategory> children, HomeTab parentTab) {
  final sorted = [...children]
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  return {parentTab: sorted};
}
