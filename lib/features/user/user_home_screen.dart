import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart' show cityProvider;
import 'city_switcher_sheet.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/category_card.dart';
import '../../core/widgets/shimmer_effect.dart';
import '../../core/widgets/retry_widget.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/models/product.dart';
import '../../core/models/category.dart';
import '../../core/services/ride_service.dart';

class UserHomeScreen extends ConsumerStatefulWidget {
  const UserHomeScreen({super.key});
  @override
  ConsumerState<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends ConsumerState<UserHomeScreen> {
  List<AppCategory> _categories = [];
  List<Product> _products = [];
  Map<String, dynamic>? _activeRide; // set when the rider has an active ride
  bool _loading = true;
  String? _error;

  // Simple in-memory cache: categories change rarely, so avoid re-fetching
  // on every pull-to-refresh within a short window.
  static List<AppCategory>? _cachedCategories;
  static DateTime? _categoriesFetchedAt;
  static const _categoryCacheTtl = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      // Phase 1: ensure the saved city is loaded before scoping queries.
      final cityService = ref.read(cityProvider);
      if (!cityService.isLoaded) await cityService.loadSavedCity();
      // Phase 1: scope the feed to the user's active city (travel city in
      // travel mode, saved city otherwise). Listings with no city stay
      // visible everywhere (isFilter city null OR match).
      final city = cityService.activeCity;

      // Use cached categories if fresh enough.
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
            .limit(30);
        categories =
            (catData as List).map((j) => AppCategory.fromJson(j)).toList();
        _cachedCategories = categories;
        _categoriesFetchedAt = DateTime.now();
      }
      // Phase 4: ranked image feed — popularity first, within the city.
      final prodData = await client
          .from('products')
          .select('*, product_images(*)')
          .eq('is_active', true)
          .or('city.eq.$city,city.is.null')
          .order('sales_count', ascending: false, nullsFirst: false)
          .order('created_at', ascending: false)
          .limit(20);
      // Active ride? Surface a live-tracking entry on Home (GPS dashboard).
      Map<String, dynamic>? activeRide;
      try {
        final ride = await RideService.instance.getMyActiveRide();
        if (ride != null && mounted) {
          activeRide = Map<String, dynamic>.from(ride);
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _categories = categories;
          _activeRide = activeRide;
          _products = (prodData as List).map((j) {
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
              createdAt: DateTime.parse(j['created_at']),
              updatedAt: DateTime.parse(j['updated_at']),
              images: imgs,
            );
          }).toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _error =
              'Could not load content. Check your connection and try again.';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return _buildLoadingSkeleton();
    if (_error != null) {
      return RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: RetryWidget(message: _error!, onRetry: _load),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppTheme.primaryGreen,
      child: CustomScrollView(
        slivers: [
          // Header
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
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
                  // Greeting + logo row. The logo opens the quick menu
                  // (Phase 4): settings, categories management entry and
                  // profile.
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _showLogoMenu,
                        child: Image.asset(
                          'assets/images/aliob_logo_mark.png',
                          width: 36,
                          height: 36,
                        ),
                      ),
                      const SizedBox(width: 10),
                      const Text('Aliob',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 1.5)),
                      const Spacer(),
                      const CartIconButton(iconColor: Colors.white),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // City chip + Shop / Service toggle (Phases 1 & 4).
                  Row(
                    children: [
                      Flexible(
                        child: _CityChip(
                          onOpen: () async {
                            final changed = await showModalBottomSheet<bool>(
                              context: context,
                              shape: const RoundedRectangleBorder(
                                borderRadius: BorderRadius.vertical(
                                    top: Radius.circular(20)),
                              ),
                              builder: (_) => const CitySwitcherSheet(),
                            );
                            if (changed == true && mounted) _load();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: _ShopServiceToggle(onChanged: (_) => _load()),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _greeting(),
                    style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withOpacity(0.7),
                        fontWeight: FontWeight.w400),
                  ),
                  const SizedBox(height: 16),
                  // Search bar
                  GestureDetector(
                    onTap: () => context.push('/user/search'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 13),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.search,
                              color: Colors.white.withOpacity(0.7), size: 20),
                          const SizedBox(width: 10),
                          Text('Search products, services...',
                              style: TextStyle(
                                  color: Colors.white.withOpacity(0.6),
                                  fontSize: 14)),
                        ],
                      ),
                    ),
                  ),
                  // Live ride banner: tap to open the GPS tracking map.
                  if (_activeRide != null) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => context.push('/user/ride-active'),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: Colors.white.withOpacity(0.25)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.near_me,
                                color: Colors.white, size: 18),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                  'Ride in progress — track your driver',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                            ),
                            Icon(Icons.chevron_right,
                                color: Colors.white.withOpacity(0.7), size: 20),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // Quick actions row
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => context.push('/user/ride-request'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: AppTheme.teal.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppTheme.teal.withOpacity(0.3)),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.local_taxi,
                                    color: Colors.white, size: 18),
                                SizedBox(width: 8),
                                Text('Ride',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => context.push('/user/search'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(
                              color: AppTheme.gold.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: AppTheme.gold.withOpacity(0.3)),
                            ),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.storefront_outlined,
                                    color: Colors.white, size: 18),
                                SizedBox(width: 8),
                                Text('Shops',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // Categories — two top-level groups (Task 7 item 5):
          // PRODUCT_BASED = the user orders/receives a physical product;
          // BOOKING_BASED = the user books a service/ride/time slot.
          if (_categories.isNotEmpty) ...[
            _categoryGroup('Product-based',
                _categories.where((c) => c.serviceGroup != 'BOOKING_BASED').toList()),
            _categoryGroup('Booking-based',
                _categories.where((c) => c.serviceGroup == 'BOOKING_BASED').toList()),
          ],
          // Products header
          SliverToBoxAdapter(
            child: FadeInWidget(
              delay: const Duration(milliseconds: 400),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Fresh Finds',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary)),
                    ),
                    if (_products.isNotEmpty)
                      GestureDetector(
                        onTap: () => context.push('/user/search'),
                        child: const Text('See all',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.teal)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // Products
          if (_products.isEmpty)
            SliverToBoxAdapter(
              child: FadeInWidget(
                delay: const Duration(milliseconds: 500),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border:
                          Border.all(color: AppTheme.cardBorder, width: 0.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppTheme.gold.withOpacity(0.1),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: AppTheme.gold.withOpacity(0.15),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(Icons.storefront_outlined,
                              color: AppTheme.gold, size: 32),
                        ),
                        const SizedBox(height: 18),
                        const Text('No products yet',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textPrimary)),
                        const SizedBox(height: 8),
                        Text(
                            'Products will appear here once\nproviders start adding them',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: AppTheme.textMuted.withOpacity(0.8))),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else
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
                    product: _products[i],
                    onTap: () =>
                        context.push('/user/product/${_products[i].id}'),
                  ),
                  childCount: _products.length,
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _buildLoadingSkeleton() {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header skeleton with shimmer
          ShimmerEffect(
            child: Container(
              width: double.infinity,
              height: 180,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Categories skeleton with staggered animation
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: List.generate(
                  4,
                  (i) => Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: FadeInWidget(
                          delay: Duration(milliseconds: 100 * i),
                          child: const SkeletonBox(
                            width: 56,
                            height: 56,
                            borderRadius: 14,
                          ),
                        ),
                      )),
            ),
          ),
          const SizedBox(height: 24),
          // Section title skeleton
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: SkeletonBox(
              width: 120,
              height: 18,
              borderRadius: 4,
            ),
          ),
          const SizedBox(height: 16),
          // Products skeleton with staggered animation
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: List.generate(
                  2,
                  (i) => Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(right: i == 0 ? 12 : 0),
                          child: FadeInWidget(
                            delay: Duration(milliseconds: 200 + (150 * i)),
                            child: SkeletonBox(
                              width: double.infinity,
                              height: 220,
                              borderRadius: 14,
                            ),
                          ),
                        ),
                      )),
            ),
          ),
        ],
      ),
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning \u2728';
    if (hour < 17) return 'Good afternoon \u2600\uFE0F';
    return 'Good evening \uD83C\uDF19';
  }

  /// Phase 4: tappable logo menu (Settings, Categories, Profile, Help).
  void _showLogoMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                // Profile/Settings is dashboard tab 4 (no standalone route).
                context.go('/user?tab=4');
              },
            ),
            ListTile(
              leading: const Icon(Icons.search_outlined),
              title: const Text('Search & explore'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go('/user?tab=1');
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('My orders'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go('/user?tab=2');
              },
            ),
            ListTile(
              leading: const Icon(Icons.support_agent_outlined),
              title: const Text('Help & chat'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/help');
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Chatbot'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.push('/help');
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _catIcon(String slug) {
    if (slug.contains('hotel')) return Icons.hotel_outlined;
    if (slug.contains('food') || slug.contains('restaurant'))
      return Icons.restaurant_outlined;
    if (slug.contains('retail') || slug.contains('grocery'))
      return Icons.shopping_cart_outlined;
    if (slug.contains('health') || slug.contains('pharma'))
      return Icons.local_hospital_outlined;
    if (slug.contains('beauty') || slug.contains('barber'))
      return Icons.content_cut;
    if (slug.contains('home') || slug.contains('repair'))
      return Icons.home_repair_service_outlined;
    if (slug.contains('education')) return Icons.school_outlined;
    if (slug.contains('fitness')) return Icons.fitness_center;
    if (slug.contains('real-estate')) return Icons.apartment;
    if (slug.contains('ride') || slug.contains('taxi') || slug.contains('bus') || slug.contains('airport'))
      return Icons.directions_car_outlined;
    if (slug.contains('delivery') || slug.contains('freight') || slug.contains('truck') || slug.contains('moving'))
      return Icons.local_shipping_outlined;
    if (slug.contains('tour') || slug.contains('travel')) return Icons.tour_outlined;
    if (slug.contains('ambulance') || slug.contains('emergency')) return Icons.emergency_outlined;
    if (slug.contains('rental')) return Icons.car_rental_outlined;
    if (slug.contains('motorcycle') || slug.contains('bajaj')) return Icons.two_wheeler_outlined;
    if (slug.contains('special')) return Icons.agriculture_outlined;
    return Icons.category_outlined;
  }

  /// Task 7 item 5: one titled horizontal rail of category cards.
  Widget _categoryGroup(String title, List<AppCategory> cats) {
    if (cats.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
          ),
        ),
        SliverToBoxAdapter(
          child: SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: cats.length,
              separatorBuilder: (_, __) => const SizedBox(width: 16),
              itemBuilder: (_, i) {
                final c = cats[i];
                return CategoryCard(
                  name: c.name,
                  icon: _catIcon(c.slug),
                  onTap: () => context.push('/user/category/${c.id}'),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Phase 1: city chip showing the active city (travel mode highlighted).
class _CityChip extends ConsumerWidget {
  const _CityChip({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final city = ref.watch(cityProvider);
    final label = city.isTravelMode ? '✈ ${city.activeCity}' : city.activeCity;
    return Material(
      color: Colors.white.withOpacity(0.15),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on_outlined,
                  size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
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

/// Phase 4: Shop / Ride-Service feed toggle on the dashboard header.
class _ShopServiceToggle extends StatefulWidget {
  const _ShopServiceToggle({required this.onChanged});

  final ValueChanged<int> onChanged;

  @override
  State<_ShopServiceToggle> createState() => _ShopServiceToggleState();
}

class _ShopServiceToggleState extends State<_ShopServiceToggle> {
  int _index = 0; // 0 = Shop, 1 = Service

  static const _labels = ['Shop', 'Ride / Service'];

  @override
  Widget build(BuildContext context) {
    // Custom two-segment toggle (ToggleButtons removed for good): its
    // internal layout wraps every child in an InkWell + minWidth-64
    // ConstrainedBox inside a min-size Row, so Expanded segments never flex
    // and the row kept overflowing its box on narrow screens. This plain Row
    // mathematically cannot overflow: Expanded divides the bounded container
    // width exactly, and FittedBox only scales labels down when space is
    // genuinely tight. Fixed 34px height (never SizedBox.expand inside the
    // unbounded header).
    return Container(
      width: double.infinity,
      height: 34,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        children: List.generate(_labels.length, (i) {
          final selected = i == _index;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (i == _index) return;
                setState(() => _index = i);
                widget.onChanged(i);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                alignment: Alignment.center,
                margin: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      _labels[i],
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? AppTheme.primaryGreenDark
                            : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
