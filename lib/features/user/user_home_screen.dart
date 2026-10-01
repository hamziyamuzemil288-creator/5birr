import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/category.dart';
import '../../core/models/category_tabs.dart';
import '../../core/models/product.dart';
import '../../core/providers/auth_provider.dart' show cityProvider;
import '../../core/resilience/app_failure.dart';
import '../../core/resilience/safe_call.dart';
import '../../core/services/ride_service.dart';
import '../../core/services/product_like_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/async_view.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/quick_action_pill.dart';
import '../../core/widgets/shimmer_effect.dart';
import 'city_switcher_sheet.dart';

/// The user home, rebuilt to the founder's sketch:
///
/// ```
///   [city]  All-in-One Business Center        [bell] [cart] [search]
///   All | Booking | Vehicles | Shops
///   <filtered content>
/// ```
///
/// ## Why the tabs are derived, not a Dart list
///
/// The founder's sketch names the tabs; it does not say what fills them. If
/// the mapping lives here as a hardcoded list it goes stale the first time
/// someone seeds a category from the admin panel, and the new category is
/// invisible. So the tab set, the contents of each tab, and the per-tab empty
/// copy are all computed from the `categories` rows at load time — see
/// `category_tabs.dart` for the column-level mapping and its test.
///
/// ## What did not change
///
/// Queries, routes and the screens behind the tiles are all the existing ones.
/// `/user/category/:id` still resolves a category and its listings, so the
/// tiles here are pure navigation. The only behavioural change is the removal
/// of the Shop/Ride two-segment toggle: the sketch's tab row replaces it, and
/// keeping both would have been two controls for one decision.
class UserHomeScreen extends ConsumerStatefulWidget {
  const UserHomeScreen({super.key});

  @override
  ConsumerState<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends ConsumerState<UserHomeScreen> {
  HomeTab _tab = HomeTab.all;

  // Sub-tab: which category within the active tab is selected, or null for
  // "show them all". The sketch's sub-tab row ("Hotels, Beauty, Events") is
  // exactly this, so it is a horizontal rail of the active tab's categories.
  String? _subCategoryId;

  List<AppCategory> _categories = const [];
  List<AppCategory> _children = const [];
  List<Product> _products = const [];
  Map<String, dynamic>? _activeRide;

  /// Approved providers, for the gallery section. Read from
  /// `public_provider_profiles`, which already filters to `APPROVED` and is
  /// granted to anon + authenticated, so this needs no RLS change and no
  /// migration.
  ///
  /// Best-effort: an empty list renders no section at all rather than an
  /// error, because the feed is still fully usable without it.
  List<Map<String, dynamic>> _galleryProviders = const [];

  bool _loading = true;
  String? _error;

  /// Categories change rarely, so a short cache keeps tab switching instant
  /// without letting a genuine admin change sit invisible for the session.
  static List<AppCategory>? _cachedCategories;
  static DateTime? _categoriesFetchedAt;
  static const _categoryCacheTtl = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // withRetry, not a bare await: this is the app's first screen and the
      // one most likely to be opened on a weak connection. A transient blip
      // should cost a moment, not an error page.
      final data = await withRetry<Map<String, dynamic>>(
        _fetchAll,
        context: 'loading the home feed',
      );
      if (!mounted) return;
      setState(() {
        _categories = data['categories'] as List<AppCategory>;
        _children = data['children'] as List<AppCategory>;
        _products = data['products'] as List<Product>;
        _activeRide = data['activeRide'] as Map<String, dynamic>?;
        _galleryProviders = data['providers'] as List<Map<String, dynamic>>;
        _loading = false;
        _error = null;
        // Who liked what. A grid of cards must cost one query, not one per
        // card, and the like state is a separate question from the product
        // row -- reading it is what stops a tap on an already-liked product
        // from toggling the server's row off.
        _hydrateReactions(_products);
        // If the selected tab or sub-tab vanished (category deactivated, or
        // the deployment's data no longer fills it), fall back rather than
        // showing a tab with nothing in it.
        _reconcileSelection();
      });
    } on AppFailure catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  /// One round trip for the whole feed, so the tabs never render against
  /// half-loaded data.
  Future<Map<String, dynamic>> _fetchAll() async {
    final client = Supabase.instance.client;
    final cityService = ref.read(cityProvider);
    if (!cityService.isLoaded) await cityService.loadSavedCity();
    final city = cityService.activeCity;

    // 1. Top-level categories, cached.
    List<AppCategory> categories;
    final cacheFresh = _cachedCategories != null &&
        _categoriesFetchedAt != null &&
        DateTime.now().difference(_categoriesFetchedAt!) < _categoryCacheTtl;
    if (cacheFresh) {
      categories = _cachedCategories!;
    } else {
      final catData = await client
          .from('categories')
          .select()
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('sort_order')
          .limit(40);
      categories = (catData as List).map((j) => AppCategory.fromJson(j)).toList();
      // Rank the rail by how much trade actually happens under each category,
      // from the most to the least, so the busiest trade leads instead of
      // whichever row an administrator happened to type first. Non-fatal: a
      // failed ranking leaves the sort_order the query already returned, which
      // is the order this screen shipped with.
      try {
        final ranked = await client.rpc('ranked_categories', params: {
          'p_limit': 100,
          'p_offset': 0,
        });
        final order = <String, int>{};
        var i = 0;
        for (final row in List<Map<String, dynamic>>.from(ranked as List)) {
          final id = row['category_id'];
          if (id is String) order[id] = i++;
        }
        if (order.isNotEmpty) {
          categories.sort((a, b) =>
              (order[a.id] ?? 1 << 30).compareTo(order[b.id] ?? 1 << 30));
        }
      } catch (_) {
        // Keep the sort_order the categories query already gave us.
      }
      _cachedCategories = categories;
      _categoriesFetchedAt = DateTime.now();
    }

    // 2. Their children, in one query rather than N. The old screen never
    //    needed these; the sub-tab rail does.
    final children = <AppCategory>[];
    if (categories.isNotEmpty) {
      final childData = await client
          .from('categories')
          .select()
          .inFilter('parent_id', categories.map((c) => c.id).toList())
          .eq('is_active', true)
          .order('sort_order')
          .limit(200);
      children
          .addAll((childData as List).map((j) => AppCategory.fromJson(j)));
    }

    // 3. The ranked city-scoped product rail.
    final prodData = await client
        .from('products')
        .select('*, product_images(*)')
        .eq('is_active', true)
        .or('city.eq.$city,city.is.null')
        .order('sales_count', ascending: false, nullsFirst: false)
        .order('created_at', ascending: false)
        .limit(20);

    // 4. Active ride, best-effort. A failed lookup here must not take the
    //    whole feed down — the feed is still useful without the banner.
    Map<String, dynamic>? activeRide;
    try {
      activeRide = await RideService.instance.getMyActiveRide();
    } catch (_) {
      activeRide = null;
    }

    // 5. Approved providers for the gallery section, best-effort for the same
    //    reason as the ride banner. Bounded (12) because this is a rail, not
    //    a directory — the full list is behind the "All providers" pill.
    List<Map<String, dynamic>> providers = const [];
    try {
      // Ranked by completed transactions, not by who signed up last. Read
      // through the server so the rail, the "All providers" sheet and the
      // category screen cannot disagree about the order.
      final provData = await client.rpc('ranked_providers', params: {
        'p_limit': 12,
        'p_offset': 0,
      });
      providers = List<Map<String, dynamic>>.from(provData as List);
    } catch (_) {
      // No gallery section. The feed below it is unaffected.
    }

    return {
      'categories': categories,
      'children': children,
      'products': _toProducts(prodData as List),
      'activeRide': activeRide,
      'providers': providers,
    };
  }

  /// How many photos the feed already holds for each provider, counted from
  /// `_products` rather than queried. The products query above embeds
  /// `product_images(*)`, so this number is free, and it is the number the
  /// customer actually cares about: "how much of this provider can I see".
  Map<String, int> get _photoCountsByProvider {
    final counts = <String, int>{};
    for (final p in _products) {
      final n = p.images.length;
      if (n == 0) continue;
      counts[p.providerId] = (counts[p.providerId] ?? 0) + n;
    }
    return counts;
  }

  /// Tell the like service what this feed holds, in one batched read.
  ///
  /// Fire-and-forget and deliberately not awaited: the feed is already on
  /// screen, and the buttons render their unknown state until this lands.
  /// A failure here leaves them unknown, which is honest, rather than
  /// asserting a reaction the server has not confirmed.
  void _hydrateReactions(List<Product> products) {
    if (products.isEmpty) return;
    final counts = {for (final p in products) p.id: p.likeCount};
    ProductLikeService.instance.ensureLoaded(
      products.map((p) => p.id),
      likeCountOf: (id) => counts[id] ?? 0,
    );
  }

  static List<Product> _toProducts(List rows) {
    return rows.map((j) {
      final imgs = (j['product_images'] as List?)
              ?.map((i) => ListingImage.fromJson(i))
              .toList() ??
          [];
      return Product(
        id: j['id'],
        providerId: j['provider_id'],
        categoryId: j['category_id'],
        name: j['name'],
        description: j['description'],
        price: (j['price'] as num).toDouble(),
        currency: j['currency'] ?? 'ETB',
        quantity: j['quantity'],
        isAvailable: j['is_available'] ?? true,
        isActive: j['is_active'] ?? true,
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        reviewCount: j['review_count'] ?? 0,
        salesCount: j['sales_count'] ?? 0,
        // The count next to the heart comes from the feed, not from a second
        // query per card. It was missing here, so every card on this screen
        // showed "0" no matter how many likes the product had.
        likeCount: (j['like_count'] as num?)?.toInt() ?? 0,
        requiresAvailabilityConfirmation:
            j['requires_availability_confirmation'] ?? false,
        createdAt: DateTime.parse(j['created_at']),
        updatedAt: DateTime.parse(j['updated_at']),
        images: imgs,
      );
    }).toList();
  }

  /// Drop a selection that no longer resolves, so a tab can never be stuck on
  /// content that is not there.
  void _reconcileSelection() {
    final tabs = availableTabs(_categories);
    if (!tabs.contains(_tab)) _tab = HomeTab.all;
    if (_subCategoryId != null) {
      final stillThere =
          _children.any((c) => c.id == _subCategoryId) ||
              _categories.any((c) => c.id == _subCategoryId);
      if (!stillThere) _subCategoryId = null;
    }
  }

  List<AppCategory> get _tabCategories {
    final grouped = groupByTab(_categories);
    return grouped[_tab] ?? const [];
  }

  List<AppCategory> _childrenOf(String parentId) =>
      _children.where((c) => c.parentId == parentId).toList();

  void _selectTab(HomeTab tab) {
    // A new tab invalidates the sub-tab: the id belonged to the old tab's
    // rail and would show nothing here.
    setState(() {
      _tab = tab;
      _subCategoryId = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _categories.isEmpty) return _buildSkeleton();

    // A first load that failed has nothing to show. A refresh that failed
    // keeps the feed and the banner says so — the same rule as AsyncView,
    // applied to a screen that was not built with it.
    if (_error != null && _categories.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
            _ErrorBlock(message: _error!, onRetry: _load),
          ],
        ),
      );
    }

    final tabs = availableTabs(_categories);
    final tabCategories = _tabCategories;

    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primaryGreen,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _header()),
          if (_error != null)
            SliverToBoxAdapter(
              child: _StaleBanner(
                  message: _error!, onRetry: _load),
            ),
          // The tab row. Sticky so a user who has scrolled into a category
          // list can switch without scrolling back up — that is the whole
          // point of putting navigation at the top of a screen this long.
          SliverPersistentHeader(
            pinned: true,
            delegate: _TabBarHeader(
              tabs: tabs,
              selected: _tab,
              onSelect: _selectTab,
            ),
          ),
          if (tabCategories.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _tabEmptyState(tabs),
            )
          else ...[
            // The ride request screen lost its home entry point when this
            // screen was rebuilt around tabs (the old header had a "Ride"
            // quick-action button next to Search). It is back here, above the
            // grid, so the GPS/map-picker flow is one tap from the top of the
            // feed on every tab rather than only via Profile -> Live map.
            SliverToBoxAdapter(child: _rideQuickAction()),
            SliverToBoxAdapter(child: _gallerySection()),
            SliverToBoxAdapter(child: _subTabRail(tabCategories)),
            SliverToBoxAdapter(child: _categoryGrid(tabCategories)),
            if (_activeRide != null && _tab == HomeTab.vehicles)
              SliverToBoxAdapter(child: _rideBanner(_activeRide!)),
            ..._productRail(),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- header

  Widget _header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // City selector, top-left, per the sketch.
              Flexible(child: _CityChip(onOpen: _openCitySwitcher)),
              const Spacer(),
              // Notifications move to a bell here (they were a bottom-nav
              // tab, and the nav is now Home|Order|Favourite|Account). The
              // existing /admin-notifications route hosts the inbox for every
              // role, so the bell reuses it rather than adding a fifth tab
              // back.
              _HeaderIcon(
                icon: Icons.notifications_none_rounded,
                tooltip: 'Notifications',
                onTap: () => context.push('/admin-notifications'),
              ),
              _HeaderIcon(
                icon: Icons.search_rounded,
                tooltip: 'Search',
                onTap: () => context.push('/user/search'),
              ),
              const CartIconButton(iconColor: Colors.white),
            ],
          ),
          const SizedBox(height: 14),
          const Text(
            'All-in-One Business Center',
            style: TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            _greeting(),
            style: TextStyle(
              fontSize: 12.5,
              color: Colors.white.withOpacity(0.72),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openCitySwitcher() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const CitySwitcherSheet(),
    );
    if (changed == true && mounted) _load();
  }

  // ------------------------------------------------------------ ride action

  /// The "Book a ride" quick action.
  ///
  /// Deliberately one pill and not a second row of buttons: the pre-redesign
  /// screen had "Ride" beside "Search", and Search already survives as a
  /// header icon, so what is missing is only the ride entry itself. It pushes
  /// `/user/ride-request` — the same route the live map's "Request a ride"
  /// drawer tile and the help chat deep link use, so the GPS fix and map
  /// picker in `UserRideRequestScreen` are reached unchanged.
  ///
  /// It is rendered on every tab rather than only the Vehicles tab: the ride
  /// request screen is a top-level action, and hiding it behind a tab means a
  /// user who never thinks to switch tabs cannot start a ride.
  ///
  /// The markup now lives in [QuickActionPill], which the provider dashboards
  /// use for their own shortcuts — one definition of this pattern rather than
  /// one per role. The rendered pill is unchanged.
  Widget _rideQuickAction() {
    return QuickActionPill(
      icon: Icons.local_taxi_rounded,
      label: 'Book a ride',
      onTap: () => context.push('/user/ride-request'),
    );
  }

  // ------------------------------------------------------- provider gallery

  /// Every approved provider's gallery, on the same screen a customer books
  /// a ride from.
  ///
  /// It used to live only in the SERVICE provider's own dashboard, as a
  /// "My Gallery" pill at the top — a provider editing their own photos. A
  /// customer browsing this screen had no equivalent: the only way to see a
  /// provider's photos was to open one product card, then the provider page,
  /// then scroll. So the people who choose a provider could not browse
  /// providers, while the people being chosen could.
  ///
  /// The styling is deliberately the same pill, not a second look: the entry
  /// point is [QuickActionPill] — the one definition of this pattern, already
  /// used by every dashboard — and the tiles reuse its brand green and its
  /// white w700 label. The tiles round to 16 rather than 20 on purpose: a pill
  /// is an action and a photo card is content, and giving the card the pill's
  /// exact geometry is how a screen stops being able to tell the reader which
  /// one is a button. A gallery section that looked like a different product
  /// would be the third button style this repo keeps paying for.
  Widget _gallerySection() {
    if (_galleryProviders.isEmpty) return const SizedBox.shrink();
    final counts = _photoCountsByProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        QuickActionPill(
          icon: Icons.photo_library_outlined,
          label: 'All providers',
          onTap: _openAllProviders,
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _galleryProviders.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final p = _galleryProviders[i];
              return _galleryTile(
                id: (p['id'] ?? '') as String,
                name: ((p['business_name'] as String?) ?? '').trim(),
                city: ((p['city'] as String?) ?? '').trim(),
                photoPath: p['photo_storage_path'] as String?,
                photoCount: counts[(p['id'] ?? '') as String] ?? 0,
                transactions:
                    (p['completed_transactions'] as num?)?.toInt() ?? 0,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _galleryTile({
    required String id,
    required String name,
    required String city,
    required String? photoPath,
    required int photoCount,
    required int transactions,
  }) {
    // An id is the only thing the route needs; a row without one would push a
    // path matching no route at all, so it is dropped rather than rendered
    // as a tile that does nothing when tapped.
    if (id.isEmpty) return const SizedBox.shrink();
    final url = (photoPath == null || photoPath.isEmpty)
        ? null
        : Supabase.instance.client.storage
            .from('provider-photos')
            .getPublicUrl(photoPath);
    // Completed work outranks a photo count as the thing a customer reads on
    // a card that is now ordered by that work -- leading with "3 photos" on
    // the busiest provider in the city says the wrong thing about why it is
    // first. A provider with no completed job keeps the old subtitle.
    final subtitle = transactions > 0
        ? '$transactions completed job${transactions == 1 ? '' : 's'}${
            photoCount > 0 ? ' · $photoCount photo${photoCount == 1 ? '' : 's'}' : ''}'
        : (photoCount > 0
            ? '$photoCount photo${photoCount == 1 ? '' : 's'}'
            : (city.isEmpty ? 'No photos yet' : city));

    return SizedBox(
      width: 152,
      child: Material(
        color: AppTheme.primaryGreen,
        // 16, not the pill's 20. A pill is an ACTION and a photo card is
        // CONTENT; giving the card the pill's exact geometry is how a screen
        // ends up unable to tell the reader which one is a button. The brand
        // green, the white w700 label and the entry-point pill above are what
        // make this read as the same section, and `QuickActionPill` stays the
        // single definition of the action shape.
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/user/provider/$id'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: url == null
                    ? const _GalleryPlaceholder()
                    : Image.network(
                        url,
                        fit: BoxFit.cover,
                        // A public bucket on a provider's own photo: a missing
                        // file must fall back to the placeholder rather than
                        // painting Flutter's red error box into the rail.
                        errorBuilder: (_, __, ___) => const _GalleryPlaceholder(),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? 'Unnamed provider' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.78),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The full directory behind the pill. A modal sheet rather than a new
  /// route: the list is read-only navigation to a screen that already exists
  /// (`/user/provider/:id`), and adding a route for it would put another
  /// entry point to break.
  /// The full provider directory behind the pill.
  ///
  /// Opened FIRST and loaded inside it. Awaiting the query before showing the
  /// sheet left the button dead for the length of the request with no
  /// feedback at all, and made the sheet's own loading branch unreachable.
  ///
  /// `isScrollControlled: true` is required, not cosmetic: without it the
  /// bottom sheet is clamped to a fraction of the screen and a
  /// DraggableScrollableSheet inside it has almost no height to work with.
  Future<void> _openAllProviders() async {
    if (!mounted) return;
    final client = Supabase.instance.client;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        // The future is created once, when the sheet is built. Retry pops the
        // sheet and opens a new one, so it gets a fresh query -- which is why
        // there is no StatefulBuilder here to rebuild: a retry that reuses the
        // same Future would immediately re-show the same error.
        // Ordered the same way the rail is, and by the same server: most
        // transacted first, best to least. Ordering this one by
        // `business_name` was the only reason two lists of the same
        // providers could disagree about who is biggest.
        final future = client
            .rpc('ranked_providers', params: {'p_limit': 200, 'p_offset': 0})
            .then((rows) => List<Map<String, dynamic>>.from(rows as List));
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (_, controller) {
            return FutureBuilder<List<Map<String, dynamic>>>(
                  future: future,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return _ErrorBlock(
                        message: friendlyError(snap.error as Object,
                            context: 'Could not load providers'),
                        // Pop before retrying: re-calling this without popping
                        // stacks a second sheet on the first, and the user is
                        // left tapping a list they cannot get rid of.
                        onRetry: () {
                          Navigator.pop(sheetContext);
                          _openAllProviders();
                        },
                      );
                    }
                    final rows = snap.data ?? const <Map<String, dynamic>>[];
                    if (rows.isEmpty) {
                      return _ErrorBlock(
                        message: 'No providers are available yet.',
                        onRetry: _noopRetry,
                      );
                    }
                    final counts = _photoCountsByProvider;
                    return ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                      itemCount: rows.length + 1,
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text('All providers',
                                style: TextStyle(
                                    fontSize: 17, fontWeight: FontWeight.w800)),
                          );
                        }
                        final row = rows[i - 1];
                        final id = (row['id'] ?? '') as String;
                        if (id.isEmpty) return const SizedBox.shrink();
                        final path = row['photo_storage_path'] as String?;
                        final name =
                            ((row['business_name'] as String?) ?? '').trim();
                        final city = ((row['city'] as String?) ?? '').trim();
                        final count = counts[id] ?? 0;
                        final transactions =
                            (row['completed_transactions'] as num?)?.toInt() ??
                                0;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: AppTheme.primaryGreen,
                            backgroundImage: (path == null || path.isEmpty)
                                ? null
                                : NetworkImage(client.storage
                                    .from('provider-photos')
                                    .getPublicUrl(path)),
                            child: (path == null || path.isEmpty)
                                ? Text(
                                    name.isEmpty
                                        ? '?'
                                        : name.substring(0, 1).toUpperCase(),
                                    style:
                                        const TextStyle(color: Colors.white),
                                  )
                                : null,
                          ),
                          title: Text(name.isEmpty ? 'Unnamed provider' : name),
                          subtitle: Text(transactions > 0
                              ? '$transactions completed job'
                                  '${transactions == 1 ? '' : 's'}${
                                      count > 0 ? ' · $count photo${count == 1 ? '' : 's'}' : ''}'
                              : (count > 0
                                  ? '$count photo${count == 1 ? '' : 's'}'
                                  : (city.isEmpty
                                      ? 'No photos yet'
                                      : city))),
                          onTap: () {
                            // sheetContext, not the State's context: the sheet
                            // is being popped, and using its context afterwards
                            // is the use-after-pop this codebase's own
                            // memory-safety check is about.
                            Navigator.pop(sheetContext);
                            context.push('/user/provider/$id');
                          },
                        );
                      },
                    );
                  },
                );
              },
        );
      },
    );
  }

  /// A no-op retry for a genuinely empty list. There is nothing to reload
  /// into, and re-running the query would just show the same emptiness.
  static void _noopRetry() {}

  // ------------------------------------------------------------- tab rail

  /// The sub-tab row from the sketch: Hotels, Beauty, Events, ... for the
  /// active tab, driven by the categories in it.
  Widget _subTabRail(List<AppCategory> tabCategories) {
    // Under All there is no meaningful "All / Hotels / Beauty" split — that
    // IS the whole list — so the rail is skipped rather than shown with a
    // redundant "All" chip.
    if (_tab == HomeTab.all) return const SizedBox(height: 4);
    return Container(
      height: 46,
      alignment: Alignment.centerLeft,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final c in tabCategories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SubTabChip(
                label: c.name,
                selected: _subCategoryId == c.id,
                onTap: () => setState(() {
                  _subCategoryId = _subCategoryId == c.id ? null : c.id;
                }),
              ),
            ),
        ],
      ),
    );
  }

  // --------------------------------------------------------- category grid

  Widget _categoryGrid(List<AppCategory> tabCategories) {
    // When a sub-tab is picked, show that category's children; otherwise show
    // the tab's categories. Both are the shared 3-up tile grid.
    final subId = _subCategoryId;
    if (subId != null) {
      final parent =
          tabCategories.where((c) => c.id == subId).firstOrNull ??
              _categories.where((c) => c.id == subId).firstOrNull;
      final kids = _childrenOf(subId);
      if (kids.isEmpty) {
        return _inlineEmpty(
          parent?.name ?? 'This category',
          'No sub-categories yet',
          Icons.category_outlined,
        );
      }
      return _grid(kids, emptyLabel: parent?.name ?? 'this category');
    }
    return _grid(tabCategories, emptyLabel: _tab.label);
  }

  Widget _grid(List<AppCategory> items, {required String emptyLabel}) {
    if (items.isEmpty) {
      return _inlineEmpty(emptyLabel, 'Nothing here yet',
          _tab == HomeTab.vehicles
              ? Icons.directions_car_outlined
              : Icons.storefront_outlined);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: items.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          // Three per row, per the sketch.
          //
          // 0.80 (was 0.82) gives a 101x126dp tile on a 360dp screen instead
          // of 101x124. The tile used to need ~121dp for a 2-line label and
          // overflowed with ~1dp to spare, so anything that made the label
          // taller — a word that wrapped onto a third line, a wider text scale
          // — drew the "BOTTOM OVERFLOWED" stripe. The extra height plus the
          // smaller internal padding and the Flexible/FittedBox label in
          // _CategoryTile below give real headroom, and the label shrinks
          // rather than clipping if the headroom is used up anyway.
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.80,
        ),
        itemBuilder: (context, i) => _CategoryTile(
          category: items[i],
          childCount: _childrenOf(items[i].id).length,
          onTap: () => context.push('/user/category/${items[i].id}'),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- products

  List<Widget> _productRail() {
    if (_tab == HomeTab.vehicles) return const [];
    // A sub-category is selected: scope the rail to it so the listings
    // under the chip the user just tapped are the ones that appear.
    final scoped = _subCategoryId == null
        ? _products
        : _products.where((p) => p.categoryId == _subCategoryId).toList();
    if (scoped.isEmpty) return const [];

    final title = _tab == HomeTab.booking ? 'Recommended for you' : 'Fresh Finds';
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => context.push('/user/search'),
                child: const Text(
                  'See all',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.teal,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          delegate: SliverChildBuilderDelegate(
            (_, i) => ProductCard(
              product: scoped[i],
              onTap: () => context.push('/user/product/${scoped[i].id}'),
            ),
            childCount: scoped.length,
          ),
        ),
      ),
    ];
  }

  // ------------------------------------------------------------ ride card

  Widget _rideBanner(Map<String, dynamic> ride) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: GestureDetector(
        onTap: () => context.push('/user/ride-active'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primaryGreen, Color(0xFF2E7D32)],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.near_me, color: Colors.white, size: 19),
              const SizedBox(width: 11),
              const Expanded(
                child: Text(
                  'Ride in progress — track your driver',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.8)),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------ empty/err

  /// Per-tab empty copy. "No hotels yet" tells the user which tab is empty;
  /// one generic message across four tabs does not.
  Widget _tabEmptyState(List<HomeTab> tabs) {
    // The active tab has nothing because it no longer exists in the data.
    if (tabs.length <= 1) {
      return _inlineEmpty(
        'Aliob',
        'No services are available in your city yet.\nWe are adding providers every day.',
        Icons.storefront_outlined,
      );
    }
    return const TabEmptyState(
      icon: Icons.inbox_outlined,
      title: 'Nothing in this tab yet',
      subtitle: 'We are adding categories and providers every day.',
    );
  }

  Widget _inlineEmpty(String label, String message, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: TabEmptyState(
        icon: icon,
        title: 'No ${label.toLowerCase()} yet',
        subtitle: message,
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning \u2728';
    if (hour < 17) return 'Good afternoon \u2600\uFE0F';
    return 'Good evening \uD83C\uDF19';
  }

  Widget _buildSkeleton() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 132,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: List.generate(
                4,
                (i) => Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: ShimmerEffect(
                    child: SkeletonBox(
                      width: 72,
                      height: 34,
                      borderRadius: 17,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ShimmerEffect(
              child: GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                // Matches the real grid's ratio so the skeleton does not
                // resize the layout when the data lands.
                childAspectRatio: 0.80,
                children: List.generate(
                  6,
                  (_) => const SkeletonBox(
                    width: double.infinity,
                    height: double.infinity,
                    borderRadius: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================ header pieces

/// Circular icon button for the header row.
class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white.withOpacity(0.16),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pinned tab row. Kept as a [SliverPersistentHeader] so it stays reachable
/// while scrolling a long category list.
class _TabBarHeader extends SliverPersistentHeaderDelegate {
  const _TabBarHeader({
    required this.tabs,
    required this.selected,
    required this.onSelect,
  });

  final List<HomeTab> tabs;
  final HomeTab selected;
  final ValueChanged<HomeTab> onSelect;

  @override
  double get minExtent => 52;
  @override
  double get maxExtent => 52;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      height: 52,
      color: AppTheme.background,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        itemCount: tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final tab = tabs[i];
          final isSelected = tab == selected;
          return GestureDetector(
            onTap: () => onSelect(tab),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? AppTheme.primaryGreen : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primaryGreen
                      : AppTheme.cardBorder,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: AppTheme.primaryGreen.withOpacity(0.22),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Text(
                tab.label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: isSelected ? Colors.white : AppTheme.textSecondary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _TabBarHeader oldDelegate) =>
      oldDelegate.selected != selected || oldDelegate.tabs != tabs;
}

class _SubTabChip extends StatelessWidget {
  const _SubTabChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AppTheme.gold.withOpacity(0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.gold : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? AppTheme.textPrimary : AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}

/// The tile face for a provider with no cover photo, or one whose photo 404s.
///
/// A provider with no photo is the NORMAL case, not an edge case — a brand new
/// approved business has none, and an approved gallery section that renders
/// those as broken-image boxes looks broken rather than empty. So the fallback
/// is the tile's own brand green with a photo glyph: the row still reads as a
/// provider, it still taps through, and the absence of a photo is honest
/// rather than noisy.
class _GalleryPlaceholder extends StatelessWidget {
  const _GalleryPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.primaryGreenDark,
      alignment: Alignment.center,
      child: Icon(
        Icons.photo_library_outlined,
        color: Colors.white.withOpacity(0.55),
        size: 28,
      ),
    );
  }
}

/// A 3-up category tile: icon, name, and how many sub-categories sit under it.
///
/// The sub-category count is the only new information here, and it earns its
/// place: it is the difference between a user tapping "Beauty" knowing there
/// are 4 things inside and tapping it hoping.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.onTap,
    this.childCount = 0,
  });

  final AppCategory category;
  final VoidCallback onTap;
  final int childCount;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        // Was (vertical: 12, horizontal: 6). The vertical padding is pure
        // slack: the Column is centred, so 10dp looks identical and hands 4dp
        // back to the label.
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _tint.withOpacity(0.1),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(_icon, color: _tint, size: 22),
            ),
            const SizedBox(height: 7),
            // The label is the only part whose height actually varies.
            // Flexible (loose fit) caps it at whatever the icon and the count
            // row left behind, so it can never push the count row off the
            // bottom of the tile; FittedBox then scales the block down to fit
            // if it is still too tall. That is why a short label ("Retail") and
            // a long one ("Motorcycle / Bajaj") both stay inside the tile — the
            // long one is scaled and, only if it is still too tall, ellipsized,
            // instead of drawing an overflow stripe.
            //
            // Loose fit (not Expanded) on purpose: at the normal text size the
            // label keeps its natural two lines and the column stays centred,
            // which is what the grid looked like before.
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: Text(
                  category.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ),
            ),
            if (childCount > 0) ...[
              const SizedBox(height: 2),
              Text(
                '$childCount',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: _tint.withOpacity(0.75),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Tint by tab, so the four tabs are visually distinguishable at a glance
  /// without relying on the tab row being visible.
  Color get _tint => switch (categoryTabFor(category)) {
        HomeTab.booking => AppTheme.teal,
        HomeTab.vehicles => AppTheme.primaryGreen,
        HomeTab.shops => AppTheme.gold,
        HomeTab.all => AppTheme.textMuted,
      };

  /// Icon from the slug, keyword-matched.
  ///
  /// Kept as a switch on slug rather than a lookup table so a newly seeded
  /// category still renders — it falls through to a generic icon instead of
  /// disappearing from the grid.
  IconData get _icon {
    final s = category.slug;
    if (s.contains('hotel') || s.contains('lodge') || s.contains('guest') ||
        s.contains('resort') || s.contains('room') || s.contains('pension') ||
        s.contains('hostel') || s.contains('apartment') || s.contains('vacation')) {
      return Icons.hotel_outlined;
    }
    if (s.contains('food') || s.contains('restaurant') || s.contains('cafe') ||
        s.contains('bakery') || s.contains('juice') || s.contains('coffee') ||
        s.contains('truck') && s.contains('food')) {
      return Icons.restaurant_outlined;
    }
    if (s.contains('retail') || s.contains('grocery') || s.contains('shop') ||
        s.contains('supermarket') || s.contains('clothing') ||
        s.contains('electronic') || s.contains('phone') ||
        s.contains('furniture') || s.contains('cosmetic') ||
        s.contains('wholesaler') || s.contains('stationery') ||
        s.contains('garden') || s.contains('automotive')) {
      return Icons.storefront_outlined;
    }
    if (s.contains('health') || s.contains('pharma') || s.contains('clinic') ||
        s.contains('laborator') || s.contains('dental') || s.contains('medical')) {
      return Icons.local_hospital_outlined;
    }
    if (s.contains('beauty') || s.contains('barber') || s.contains('salon') ||
        s.contains('spa') || s.contains('tattoo') || s.contains('hair')) {
      return Icons.content_cut;
    }
    if (s.contains('home') || s.contains('plumbing') || s.contains('electric') ||
        s.contains('cleaning') || s.contains('construction') ||
        s.contains('repair') || s.contains('maintenance') ||
        s.contains('moving') || s.contains('interior') ||
        s.contains('material')) {
      return Icons.home_repair_service_outlined;
    }
    if (s.contains('education') || s.contains('school') || s.contains('tutor') ||
        s.contains('course') || s.contains('training')) {
      return Icons.school_outlined;
    }
    if (s.contains('fitness') || s.contains('gym') || s.contains('sport') ||
        s.contains('yoga')) {
      return Icons.fitness_center;
    }
    if (s.contains('real-estate') || s.contains('house') || s.contains('land') ||
        s.contains('rental') || s.contains('property')) {
      return Icons.apartment;
    }
    if (s.contains('agricultur') || s.contains('farm') || s.contains('equipment')) {
      return Icons.agriculture_outlined;
    }
    if (s.contains('event') || s.contains('entertainment') ||
        s.contains('recreation') || s.contains('photography')) {
      return Icons.celebration_outlined;
    }
    if (s.contains('professional') || s.contains('accounting') ||
        s.contains('legal') || s.contains('consulting') || s.contains('printing') ||
        s.contains('translation')) {
      return Icons.work_outline;
    }
    // Vehicles.
    if (s.contains('motorcycle') || s.contains('bajaj') || s.contains('bike') ||
        s.contains('two-wheeler')) {
      return Icons.two_wheeler;
    }
    if (s.contains('bus') || s.contains('minibus') || s.contains('coach')) {
      return Icons.directions_bus_outlined;
    }
    if (s.contains('truck') || s.contains('freight') || s.contains('cargo') ||
        s.contains('moving-truck')) {
      return Icons.local_shipping_outlined;
    }
    if (s.contains('ambulance') || s.contains('emergency')) {
      return Icons.emergency_outlined;
    }
    if (s.contains('airport')) return Icons.flight_takeoff;
    if (s.contains('tour') || s.contains('travel') || s.contains('safari')) {
      return Icons.tour_outlined;
    }
    if (s.contains('delivery') || s.contains('freight') || s.contains('courier')) {
      return Icons.local_shipping_outlined;
    }
    if (s.contains('rental')) return Icons.car_rental_outlined;
    if (s.contains('ride') || s.contains('taxi') || s.contains('car') ||
        s.contains('transport') || s.contains('special')) {
      return Icons.directions_car_outlined;
    }
    return Icons.category_outlined;
  }
}

// ============================================================== small views

/// City chip, top-left of the header.
class _CityChip extends ConsumerWidget {
  const _CityChip({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final city = ref.watch(cityProvider);
    final label = city.isTravelMode ? '\u2708 ${city.activeCity}' : city.activeCity;
    return Material(
      color: Colors.white.withOpacity(0.16),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_outlined, size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Icon(Icons.keyboard_arrow_down, size: 16, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Couldn't refresh" strip. Same rule as AsyncView: content stays, the
/// failure is stated quietly and the whole strip is a retry target.
class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.gold.withOpacity(0.14),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined,
                  size: 15, color: AppTheme.textSecondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Couldn\'t refresh — $message',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Retry',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryGreen,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppTheme.error.withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.wifi_off_rounded,
                  size: 34, color: AppTheme.error),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
