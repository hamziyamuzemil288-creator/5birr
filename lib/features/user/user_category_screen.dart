import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/city_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
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
      final prods = await client.rpc('visible_products_for_category',
          params: {'p_city': city, 'p_category_id': widget.categoryId});
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
          _products = prodsRaw;
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
                      // Products
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
                                      color: AppTheme.textMuted)))),
                      else
                        ..._products.map((p) {
                          // User-visible image column. A provider sets it on the
                          // product form and the listing embeds `product_images(*)`,
                          // so this tile always renders a photo, its caption, and
                          // the price tag.
                          final img = (p['image'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k.toString(), v))?.toList() ?? [];
                          final photoPath =
                              (img is List && (img[0] as Map<String, dynamic>?)?['storage_path'] as String?)?.trim() ?? '';
                          final caption = (img is List && (img[0] as Map<String, dynamic>?)?['caption'] as String?)?.trim() ?? '';
                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            child: InkWell(
                              onTap: () =>
                                  context.push('/user/product/${p['id']}'),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Image: show the photo, fall back to a green
                                  // placeholder. A location-less listing still
                                  // keeps its photo.
                                  Container(
                                    width: double.infinity,
                                    height: 110,
                                    decoration: BoxDecoration(
                                      borderRadius:
                                          const BorderRadius.vertical(
                                              top: Radius.circular(12)),
                                      color: AppTheme.creamDark,
                                    ),
                                    child: photoPath.isNotEmpty
                                        ? CachedNetworkImage(
                                            imageUrl: photoPath,
                                            fit: BoxFit.cover,
                                            placeholder: (_, __) =>
                                                const Center(
                                                    child:
                                                        CircularProgressIndicator(
                                                            strokeWidth: 2)),
                                            errorWidget: (_, __, ___) =>
                                                const Center(
                                                    child: Icon(
                                                        Icons.image_outlined,
                                                        color:
                                                            AppTheme.textMuted,
                                                    )),
                                          )
                                        : const Center(
                                            child: Icon(
                                                Icons.image_outlined,
                                                color: AppTheme.textMuted,
                                                size: 32)),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        12, 10, 12, 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p['name'] ?? '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                              color: AppTheme.textPrimary),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          p['description'] ?? '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                              fontSize: 11.5,
                                              height: 1.3,
                                              color: AppTheme.textSecondary),
                                        ),
                                        const SizedBox(height: 5),
                                        Row(
                                          children: [
                                            if (p['price'] != null ||
                                                p['price_per_unit'] != null)
                                              Expanded(
                                                child: Text(
                                                  p['price'] != null
                                                      ? '${p['price']} ${p['currency'] ?? 'ETB'}'
                                                      : '',
                                                  style: const TextStyle(
                                                      fontSize: 12.5,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color:
                                                          AppTheme.primaryGreen),
                                                ),
                                              ),
                                            if (p['price_per_unit'] != null)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.only(
                                                        left: 6),
                                                child: Text(
                                                  '${p['price_per_unit'].toDouble()} ${p['unit'] ?? 'kg'}',
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color: AppTheme
                                                          .textSecondary),
                                                ),
                                              ),
                                          ],
                                        ),
                                        if (caption.isNotEmpty) ...[
                                          const SizedBox(height: 3),
                                          Text(
                                            caption,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: AppTheme.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }),
                    ],
                  ),
                ),
    );
  }
}
