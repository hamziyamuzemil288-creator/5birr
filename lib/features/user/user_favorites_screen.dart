import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/widgets/load_error_view.dart';

class UserFavoritesScreen extends StatefulWidget {
  const UserFavoritesScreen({super.key});
  @override
  State<UserFavoritesScreen> createState() => _State();
}

class _State extends State<UserFavoritesScreen> {
  List<Map<String, dynamic>> _favorites = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;
      final data = await Supabase.instance.client
          .from('favorites')
          .select()
          .eq('user_id', userId)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _favorites = List<Map<String, dynamic>>.from(data as List);
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
                  itemBuilder: (_, i) {
                    final f = _favorites[i];
                    final type = f['target_type'];
                    final id = f['target_id'];
                    return ListTile(
                      onTap: () {
                        if (type == 'PRODUCT') {
                          context.push('/user/product/$id');
                        } else if (type == 'PROVIDER') {
                          context.push('/user/provider/$id');
                        }
                      },
                      leading: Icon(
                        type == 'PRODUCT'
                            ? Icons.inventory_2_outlined
                            : Icons.store_outlined,
                        color: AppTheme.primaryGreen,
                      ),
                      title: Text('$type',
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    );
                  },
                ),
    );
  }
}
