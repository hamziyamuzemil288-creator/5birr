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
  State<UserCategoryScreen> createState() => _State();
}

class _State extends State<UserCategoryScreen> {
  Map<String, dynamic>? _category;
  List<Map<String, dynamic>> _subcategories = [];
  List<Map<String, dynamic>> _products = [];
  /// The busiest APPROVED providers in this category, best to least, straight
  /// from the server. The screen previously listed only products, so the
  /// people a customer is choosing BETWEEN were not on it at all.
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
      // Phase 1+4: shared city-scoped query, ranked by popularity.
      final city = CityService.instance.activeCity;
      final prods = await client.rpc('visible_products_for_city', params: {
        'p_city': city,
        'p_category_id': widget.categoryId,
      });
      final prodsRaw = List<Map<String, dynamic>>.from(prods as List);
      // Non-fatal: the products below are still the reason most customers open
      // this screen, and a failed ranking must not blank it.
      List<Map<String, dynamic>> ranked = const [];
      try {
        ranked = List<Map<String, dynamic>>.from(await client.rpc(
            'ranked_providers',
            params: {'p_category_id': widget.categoryId, 'p_limit': 10}) as List);
      } catch (_) {}
      // Hydrate images (the RPC returns product columns only).
      final imgs = prodsRaw.isEmpty
          ? <Map<String, dynamic>>[]
          : List<Map<String, dynamic>>.from(await client
              .from('product_images')
              .select()
              .inFilter(
                  'product_id', prodsRaw.map((p) => p['id'] as String).toList()));
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
                      // SubcategoryChip states its own green background and
                      // white label, so the name is readable on every
                      // category screen instead of relying on the ambient
                      // chip theme.
                      children: _subcategories
                          .map((s) => SubcategoryChip(
                                label: s['name'] ?? '',
                                onTap: () =>
                                    context.go('/user/category/${s['id']}'),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                  ],
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
                              fontSize: 12, color: AppTheme.textMuted),
                        ),
                        trailing: (p['price_range'] as String?)?.isNotEmpty ==
                                true
                            ? Text(p['price_range'] as String,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
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
                              style: TextStyle(color: AppTheme.textMuted))),
                    )
                  else
                    ..._products.map((p) => ListTile(
                          onTap: () =>
                              context.push('/user/product/${p['id']}'),
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                                color: AppTheme.creamDark,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.inventory_2_outlined,
                                color: AppTheme.textMuted),
                          ),
                          title: Text(p['name'] ?? ''),
                          subtitle: Text(
                              '${p['price']} ${p['currency'] ?? 'ETB'}',
                              style: const TextStyle(
                                  color: AppTheme.primaryGreen,
                                  fontWeight: FontWeight.w600)),
                        )),
                ],
              ),
            ),
    );
  }
}
