import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';

class ProviderProductListScreen extends StatefulWidget {
  const ProviderProductListScreen({super.key});
  @override
  State<ProviderProductListScreen> createState() => _State();
}

class _State extends State<ProviderProductListScreen> {
  List<Map<String, dynamic>> _products = [];
  bool _loading = true;
  String? _providerId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      _providerId = prov['id'];
      final data = await client
          .from('products')
          .select('*, product_images(id,storage_path,sort_order)')
          .eq('provider_id', _providerId!)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _products = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _delete(String id) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Product'),
        content: const Text('This will permanently remove the product.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete',
                  style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client
          .from('products')
          .update({'is_active': false}).eq('id', id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _toggleAvailability(String id, bool current) async {
    try {
      await Supabase.instance.client
          .from('products')
          .update({'is_available': !current}).eq('id', id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Products')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppTheme.primaryGreen,
        onPressed: () => context.push('/provider/products/new'),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _products.isEmpty
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.inventory_2_outlined,
                        size: 64, color: AppTheme.textMuted),
                    const SizedBox(height: 16),
                    const Text('No products yet',
                        style: TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => context.push('/provider/products/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Product'),
                    ),
                  ],
                ))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _products.length,
                    itemBuilder: (_, i) {
                      final p = _products[i];
                      return Card(
                        child: ListTile(
                          leading: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                                color: AppTheme.creamDark,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.inventory_2_outlined,
                                color: AppTheme.textMuted),
                          ),
                          title: Text(p['name'] ?? '',
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Row(
                            children: [
                              Text(
                                  '${p['price']} ${p['currency'] ?? 'ETB'}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.primaryGreen,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: (p['is_available'] ?? true)
                                      ? AppTheme.success.withOpacity(0.1)
                                      : AppTheme.error.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                    (p['is_available'] ?? true)
                                        ? 'Available'
                                        : 'Unavailable',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: (p['is_available'] ?? true)
                                            ? AppTheme.success
                                            : AppTheme.error)),
                              ),
                            ],
                          ),
                          trailing: PopupMenuButton(
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'toggle',
                                child: Text((p['is_available'] ?? true)
                                    ? 'Mark Unavailable'
                                    : 'Mark Available'),
                              ),
                              const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Delete',
                                      style: TextStyle(color: AppTheme.error))),
                            ],
                            onSelected: (v) {
                              if (v == 'edit') {
                                context.push('/provider/products/${p['id']}');
                              } else if (v == 'toggle') {
                                _toggleAvailability(
                                    p['id'], p['is_available'] ?? true);
                              } else if (v == 'delete') {
                                _delete(p['id']);
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
