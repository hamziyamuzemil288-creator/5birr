import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/city_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/product_card.dart';
import '../../core/widgets/subcategory_chip.dart';

class UserCategoryScreen extends StatefulWidget {
  final String categoryId;
  const UserCategoryScreen({super.key, required this.categoryId});

  @override
  State<UserCategoryScreen> createState() => _UserCategoryScreenState();
}

class _UserCategoryScreenState extends State<UserCategoryScreen> {
  Map<String, dynamic>? _category;
  List<Map<String, dynamic>> _subcategories = [];
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _providers = [];
  bool _loading = true;
  String? _error;

  /// The browse city this screen's product list was fetched for. The list is
  /// held in [_products], so a category page opened before the user changed
  /// city would keep rendering the previous city's products until it was
  /// reopened. Subscribing to [CityService] re-queries instead, which is what
  /// "city-selected listing" is supposed to mean.
  final CityService _cityService = CityService.instance;

  @override
  void initState() {
    super.initState();
    _cityService.addListener(_onBrowseCityChanged);
    _load();
  }

  void _onBrowseCityChanged() {
    if (!mounted) return;
    _load();
  }

  @override
  void dispose() {
    _cityService.removeListener(_onBrowseCityChanged);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final cat =
          await client.from('categories').select().eq('id', widget.categoryId).single();
      final subs = await client
          .from('categories')
          .select()
          .eq('parent_id', widget.categoryId)
          .eq('is_active', true)
          .order('sort_order');
      final city = CityService.instance.activeCity;
      // User-visible image column. A provider sets it on the business profile
      // edit sheet; when it is missing the listing still loads, but the tile
      // renders a green placeholder so the panel never shows a broken image.
      //
      // An empty browse city is "All cities" and is sent as NULL; the function
      // treats an empty/NULL city as "do not filter" (20261010000002).
      final prods = await client.rpc('visible_products_for_city', params: {
        'p_city': city.isEmpty ? null : city,
        'p_category_id': widget.categoryId,
      });
      final prodsRaw = List<Map<String, dynamic>>.from(prods as List);
      final providers = await client.rpc('ranked_providers', params: {
        'p_category_id': widget.categoryId,
        'p_limit': 10,
      });
      final ranked = List<Map<String, dynamic>>.from(providers as List);

      // Hydrate images. The RPC returns the listing row; the image is attached
      // from `product_images` so the tile can show the photo, and a
      // location-less listing still carries its image even though it will be
      // ranked below located rows.
      final imgs = prodsRaw.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await client
              .from('product_images')
              .select()
              .inFilter(
                'product_id',
                prodsRaw.map((p) => p['id'] as String).toList(),
              ));
      final imagesByProduct = <String, List<Map<String, dynamic>>>{};
      for (final im in imgs) {
        (imagesByProduct[im['product_id'] as String] ??= []).add(im);
      }
      if (mounted) {
        setState(() {
          _category = cat;
          _subcategories = List<Map<String, dynamic>>.from(subs as List);
          _products = prodsRaw
              .map<Map<String, dynamic>>((p) => {
                    ...p,
                    'image': imagesByProduct[p['id'] as String] ??
                        const <Map<String, dynamic>>[],
                  })
              .toList();
          _providers = ranked;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load this category');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_category?['name'] ?? 'Category'),
        actions: const [CartIconButton()],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Subcategories
                      if (_subcategories.isNotEmpty) ...[
                        const Text('Subcategories',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _subcategories
                              .map((s) => SubcategoryChip(
                                    label: s['name'] ?? '',
                                    onTap: () =>
                                        context.go('/user/category/${s['id']}'),
                                  ))
                              .toList(),
                        ),
                      ],
                      const SizedBox(height: 20),
                      // The people, ranked by completed work.
                      if (_providers.isNotEmpty) ...[
                        const Text('Top providers',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        ..._providers.map((p) {
                          final jobs =
                              (p['completed_transactions'] as num?)?.toInt() ?? 0;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            onTap: () =>
                                context.push('/user/provider/${p['id']}'),
                            leading: CircleAvatar(
                              backgroundColor: AppTheme.primaryGreen,
                              child: Text(
                                '#${p['rank_position']}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ),
                            title: Text(p['business_name']?.toString() ?? ''),
                            subtitle: Text(
                              jobs > 0
                                  ? '$jobs completed job${jobs == 1 ? '' : 's'}'
                                  : ((p['city'] as String?) ?? ''),
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: AppTheme.textMuted),
                            ),
                            trailing: (p['price_range'] as String?)?.isNotEmpty ==
                                    true
                                ? Text(p['price_range'] as String,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primaryGreen))
                                : null,
                          );
                        }),
                        const SizedBox(height: 20),
                      ],
                      // Products — the SAME card the home feed uses.
                      //
                      // This screen used to hand-roll its own listing tile: a
                      // photo, a name and a price with no way to act on any of
                      // it, so a listing a buyer could buy in two taps from the
                      // home rail was a dead end on its own category page. The
                      // shared card carries the photo, the price AND the
                      // BUY button together, which is what makes that class of
                      // inconsistency impossible to reintroduce one screen at a
                      // time.
                      Text('Products (${_products.length})',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      if (_products.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(30),
                          child: Center(
                              child: Text('No products in this category',
                                  style: TextStyle(
                                      color: AppTheme.textMuted))))
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: EdgeInsets.zero,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            // The home feed's own ratio, so one listing is the
                            // same size wherever a buyer meets it.
                            childAspectRatio: 0.66,
                          ),
                          itemCount: _products.length,
                          itemBuilder: (_, i) {
                            final p = _products[i];
                            // User-visible image column. A provider sets it on
                            // the product form and this screen hydrates it from
                            // `product_images`, so the card always leads with
                            // the photo the provider picked; `listingCoverUrl`
                            // reads the same row the feed's card does.
                            final unitPrice =
                                (p['price_per_unit'] as num?)?.toDouble() ?? 0;
                            return ProductCard.listing(
                              productId: (p['id'] ?? '') as String,
                              providerId: (p['provider_id'] ?? '') as String,
                              title: (p['name'] ?? '') as String,
                              priceLabel: listingPriceLabel(p),
                              imageUrl: listingCoverUrl(
                                  (p['image'] as List?) ?? const []),
                              // The per-unit price leads when there is one (the
                              // number a buyer weighs against a fixed price),
                              // otherwise the listing's own words.
                              caption: unitPrice > 0
                                  ? '${p['price_per_unit']} ${p['unit'] ?? 'kg'} each'
                                  : ((p['description'] ?? '') as String),
                              rating: (p['rating'] as num?)?.toDouble() ?? 0,
                              likeCount:
                                  (p['like_count'] as num?)?.toInt() ?? 0,
                              isAvailable: p['is_available'] != false,
                              onTap: () =>
                                  context.push('/user/product/${p['id']}'),
                            );
                          },
                        ),
                    ],
                  ),
                ),
    );
  }
}
