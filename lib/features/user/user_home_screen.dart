import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/category_card.dart';
import '../../core/widgets/shimmer_effect.dart';
import '../../core/widgets/retry_widget.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/models/product.dart';
import '../../core/models/category.dart';

class UserHomeScreen extends StatefulWidget {
  const UserHomeScreen({super.key});
  @override
  State<UserHomeScreen> createState() => _UserHomeScreenState();
}

class _UserHomeScreenState extends State<UserHomeScreen> {
  List<AppCategory> _categories = [];
  List<Product> _products = [];
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
            .eq('sector', 'SERVICE')
            .eq('is_active', true)
            .isFilter('parent_id', null)
            .order('sort_order')
            .limit(12);
        categories = (catData as List)
            .map((j) => AppCategory.fromJson(j))
            .toList();
        _cachedCategories = categories;
        _categoriesFetchedAt = DateTime.now();
      }
      final prodData = await client
          .from('products')
          .select('*, product_images(*)')
          .eq('is_active', true)
          .order('created_at', ascending: false)
          .limit(20);
      if (mounted) {
        setState(() {
          _categories = categories;
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
      if (mounted) setState(() {
        _loading = false;
        _error = 'Could not load content. Check your connection and try again.';
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
                        // Greeting + logo row
                        Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Center(
                                child: Text('₅',
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text('5BIRR',
                                style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    letterSpacing: 1.5)),
                            const Spacer(),
                            const CartIconButton(iconColor: Colors.white),
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
                          onTap: () => context.go('/user/search'),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 13),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: Colors.white.withOpacity(0.1)),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.search,
                                    color: Colors.white.withOpacity(0.7),
                                    size: 20),
                                const SizedBox(width: 10),
                                Text('Search products, services...',
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.6),
                                        fontSize: 14)),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        // Quick actions row
                        Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () => context.go('/user/ride-request'),
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
                                onTap: () => context.go('/user/search'),
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
                // Categories
                if (_categories.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
                      child: Text('Browse Categories',
                          style: TextStyle(
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
                        itemCount: _categories.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 16),
                        itemBuilder: (_, i) {
                          final c = _categories[i];
                          return CategoryCard(
                            name: c.name,
                            icon: _catIcon(c.slug),
                            onTap: () =>
                                context.go('/user/category/${c.id}'),
                          );
                        },
                      ),
                    ),
                  ),
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
                              onTap: () => context.go('/user/search'),
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 40),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(32),
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                                color: AppTheme.cardBorder, width: 0.5),
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
                                child: const Icon(
                                    Icons.storefront_outlined,
                                    color: AppTheme.gold,
                                    size: 32),
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
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.72,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (_, i) => ProductCard(
                          product: _products[i],
                          onTap: () =>
                              context.go('/user/product/${_products[i].id}'),
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
    return Icons.category_outlined;
  }
}
