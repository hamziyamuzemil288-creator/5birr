import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_export.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});
  @override
  State<AdminReportsScreen> createState() => _State();
}

class _State extends State<AdminReportsScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _categories = [];
  Map<String, dynamic> _stats = {};
  String? _error;
  String _selectedSector = 'ALL';
  
  static const _sectors = ['ALL', 'PRODUCT', 'SERVICE', 'VEHICLE'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      
      // Load categories with product/provider counts
      final catData = await client
          .from('categories')
          .select('id, name, sector, parent_id, is_active, sort_order')
          .order('sector')
          .order('sort_order');
      
      // Load summary stats
      final productCount = await client.from('products').select('id').eq('is_active', true);
      final orderCount = await client.from('orders').select('id').eq('payment_status', 'PAID');
      final providerCount = await client.from('provider_profiles').select('id');
      final userCount = await client.from('profiles').select('id');
      
      // Orders by category. orders has no category_id / payment_status
      // columns (0001) — categories live on the order's products, and the
      // closest equivalent to "paid" is a COMPLETED order. A single order
      // can span categories (order_items → products), so an order is
      // counted under every category represented in its items.
      final paidOrders = await client
          .from('orders')
          .select('id, order_items(product_id, products(category_id))')
          .eq('status', 'COMPLETED');

      final categoryIdById = {
        for (final c in (catData as List).whereType<Map<String, dynamic>>())
          c['id'] as String: c,
      };

      // Group completed orders by category via their items' products.
      final Map<String, int> orderCountsByCat = {};
      for (final o in paidOrders as List) {
        final items = (o['order_items'] as List?) ?? const [];
        final catNames = <String>{};
        for (final item in items.whereType<Map<String, dynamic>>()) {
          final product = item['products'] as Map<String, dynamic>?;
          final catId = product?['category_id'] as String?;
          final cat = catId == null ? null : categoryIdById[catId];
          if (cat != null) catNames.add(cat['name'] as String? ?? 'Unknown');
        }
        for (final name in catNames) {
          orderCountsByCat[name] = (orderCountsByCat[name] ?? 0) + 1;
        }
      }

      // Products by category
      final productsByCategory = await client
          .from('products')
          .select('id, category_id, categories(name)')
          .eq('is_active', true);
      
      final Map<String, int> productCountsByCat = {};
      for (final p in productsByCategory as List) {
        final catName = (p['categories'] as Map?)?['name'] as String? ?? 'Unknown';
        productCountsByCat[catName] = (productCountsByCat[catName] ?? 0) + 1;
      }

      if (mounted) {
        setState(() {
          _categories = List<Map<String, dynamic>>.from(catData as List);
          _stats = {
            'total_products': productCount.length,
            'total_orders': orderCount.length,
            'total_providers': providerCount.length,
            'total_users': userCount.length,
            'orders_by_category': orderCountsByCat,
            'products_by_category': productCountsByCat,
          };
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load the reports');
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filteredCategories {
    if (_selectedSector == 'ALL') return _categories;
    return _categories.where((c) => c['sector'] == _selectedSector).toList();
  }

  Future<void> _exportCsv() async {
    final columns = ['Category', 'Sector', 'Products', 'Orders', 'Active'];
    final rows = _filteredCategories.map((c) {
      final name = c['name'] as String? ?? '';
      final orderCount = (_stats['orders_by_category'] as Map<String, int>?)?[name] ?? 0;
      final prodCount = (_stats['products_by_category'] as Map<String, int>?)?[name] ?? 0;
      return {
        'Category': name,
        'Sector': (c['sector'] as String? ?? '').replaceAll('_', ' '),
        'Products': prodCount.toString(),
        'Orders': orderCount.toString(),
        'Active': c['is_active'] == true ? 'Yes' : 'No',
      };
    }).toList();

    await CsvExport.exportAndShare(
      columns: columns,
      rows: rows,
      fileName: 'sector_report_${DateTime.now().millisecondsSinceEpoch}',
      title: 'Sector Report',
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredCats = _filteredCategories;
    final ordersByCat = (_stats['orders_by_category'] as Map<String, int>?) ?? {};
    final productsByCat = (_stats['products_by_category'] as Map<String, int>?) ?? {};
    final totalOrders = ordersByCat.values.fold(0, (s, v) => s + v);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sector Reports'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _exportCsv,
            tooltip: 'Export CSV',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Overview stats
                  Row(
                    children: [
                      _miniStat('Products', _stats['total_products'] ?? 0, AppTheme.primaryGreen),
                      _miniStat('Orders', _stats['total_orders'] ?? 0, AppTheme.info),
                      _miniStat('Providers', _stats['total_providers'] ?? 0, AppTheme.teal),
                      _miniStat('Users', _stats['total_users'] ?? 0, AppTheme.gold),
                    ],
                  ),
                  const SizedBox(height: 16),
                  
                  // Sector filter
                  Row(
                    children: _sectors.map((s) => Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(s == 'ALL' ? 'All Sectors' : s,
                            style: TextStyle(fontSize: 11, color: _selectedSector == s ? Colors.white : AppTheme.textPrimary)),
                        selected: _selectedSector == s,
                        onSelected: (_) => setState(() => _selectedSector = s),
                        selectedColor: AppTheme.primaryGreen,
                        visualDensity: VisualDensity.compact,
                      ),
                    )).toList(),
                  ),
                  const SizedBox(height: 16),
                  
                  // Category breakdown
                  const Text('Categories by Sector',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                  const SizedBox(height: 8),
                  if (filteredCats.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Center(
                          child: Text('No categories found', style: TextStyle(color: AppTheme.textMuted)),
                        ),
                      ),
                    )
                  else
                    ...filteredCats.map((c) {
                      final name = c['name'] as String? ?? '';
                      final orderCount = ordersByCat[name] ?? 0;
                      final prodCount = productsByCat[name] ?? 0;
                      final sectorColor = c['sector'] == 'PRODUCT'
                          ? AppTheme.primaryGreen
                          : c['sector'] == 'SERVICE'
                              ? AppTheme.info
                              : AppTheme.teal;
                      
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: sectorColor.withOpacity(0.1),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      (c['sector'] as String? ?? '').replaceAll('_', ' '),
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: sectorColor),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(name,
                                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                  const Spacer(),
                                  if (c['is_active'] == false)
                                    const Icon(Icons.visibility_off, size: 14, color: AppTheme.textMuted)
                                  else
                                    const Icon(Icons.check_circle, size: 14, color: AppTheme.success),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  _detailBadge('Products', prodCount, AppTheme.primaryGreen),
                                  const SizedBox(width: 8),
                                  _detailBadge('Orders', orderCount, AppTheme.info),
                                  const SizedBox(width: 8),
                                  _detailBadge('Share', totalOrders > 0 ? '${(orderCount / totalOrders * 100).toStringAsFixed(0)}%' : '0%', AppTheme.gold),
                                ],
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

  Widget _miniStat(String label, int count, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Text(count.toString(),
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailBadge(String label, dynamic value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: color),
      ),
    );
  }
}
