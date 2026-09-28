import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';

/// The buyer's saved products and providers.
///
/// WHAT THIS USED TO SHOW, AND WHY THAT WAS A BUG
/// ----------------------------------------------
/// `favorites` holds a `(target_type, target_id)` pair and nothing else, so a
/// list built straight from that table rendered the words "PRODUCT" and a raw
/// UUID: `e3b0c442-98fc-1c14-9afb-f4c8996fb924`. Two favourites were
/// indistinguishable, and a person cannot choose between two rows of machine
/// data. The name lives on the target, so the target has to be read.
///
/// Two batched lookups, one per type, rather than a query per row — a list of
/// favourites is exactly the shape that makes N+1 look fine and then not be.
///
/// A target that cannot be read is reported as gone and is not tappable. That
/// is the honest answer: `products` hides inactive listings and
/// `public_provider_profiles` contains only APPROVED providers, so a row with
/// no name is a favourite that cannot be opened, and tapping it would land the
/// user on a dead detail screen.
class UserFavoritesScreen extends StatefulWidget {
  const UserFavoritesScreen({super.key});
  @override
  State<UserFavoritesScreen> createState() => _State();
}

class _State extends State<UserFavoritesScreen> {
  List<Map<String, dynamic>> _favorites = [];
  /// target_id -> human name, hydrated from the target table.
  Map<String, String> _labels = const {};
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
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final data = await client
          .from('favorites')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      final rows = List<Map<String, dynamic>>.from(data as List);

      final labels = <String, String>{};

      String? nameOf(Map<String, dynamic> r) =>
          (r['name'] as String?) ?? (r['business_name'] as String?);

      final productIds = rows
          .where((r) => r['target_type'] == 'PRODUCT')
          .map((r) => r['target_id'])
          .whereType<String>()
          .toList();
      if (productIds.isNotEmpty) {
        try {
          final products = await client
              .from('products')
              .select('id, name')
              .inFilter('id', productIds);
          for (final r in products as List) {
            final row = Map<String, dynamic>.from(r as Map);
            final n = nameOf(row)?.trim();
            if (n != null && n.isNotEmpty) labels[row['id'] as String] = n;
          }
        } catch (_) {
          // Best-effort: a favourites list that cannot name a row still beats
          // no list at all. The fallback below is honest about it.
        }
      }

      final providerIds = rows
          .where((r) => r['target_type'] == 'PROVIDER')
          .map((r) => r['target_id'])
          .whereType<String>()
          .toList();
      if (providerIds.isNotEmpty) {
        try {
          // The public view, not provider_profiles: it carries only approved
          // providers and only the columns a buyer is allowed to see.
          final providers = await client
              .from('public_provider_profiles')
              .select('id, business_name')
              .inFilter('id', providerIds);
          for (final r in providers as List) {
            final row = Map<String, dynamic>.from(r as Map);
            final n = nameOf(row)?.trim();
            if (n != null && n.isNotEmpty) labels[row['id'] as String] = n;
          }
        } catch (_) {
          // Same as above.
        }
      }

      if (mounted) {
        setState(() {
          _favorites = rows;
          _labels = labels;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your favorites');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorites'),
        actions: const [CartIconButton()],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _favorites.isEmpty
              ? const Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.favorite_border,
                        size: 64, color: AppTheme.textMuted),
                    SizedBox(height: 16),
                    Text('No favorites yet',
                        style: TextStyle(color: AppTheme.textMuted)),
                  ],
                ))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _favorites.length,
                  itemBuilder: (_, i) => _tile(_favorites[i]),
                ),
    );
  }

  Widget _tile(Map<String, dynamic> f) {
    final type = f['target_type'];
    final id = f['target_id'];
    final isProduct = type == 'PRODUCT';
    final label = id is String ? _labels[id] : null;
    // No name means the target is gone or is no longer visible to a buyer.
    final available = label != null;

    return ListTile(
      onTap: !available
          ? null
          : () {
              if (isProduct) {
                context.push('/user/product/$id');
              } else if (type == 'PROVIDER') {
                context.push('/user/provider/$id');
              }
            },
      leading: Icon(
        isProduct ? Icons.inventory_2_outlined : Icons.store_outlined,
        color: available ? AppTheme.primaryGreen : AppTheme.textMuted,
      ),
      title: Text(
        label ?? 'No longer available',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: available ? AppTheme.textPrimary : AppTheme.textMuted,
        ),
      ),
      subtitle: Text(
        available
            ? (isProduct ? 'Product' : 'Provider')
            : 'This favourite was removed or is no longer listed.',
        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: available ? const Icon(Icons.chevron_right) : null,
    );
  }
}
