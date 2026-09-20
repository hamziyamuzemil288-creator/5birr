import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/cart_service.dart';

class UserCartScreen extends ConsumerStatefulWidget {
  const UserCartScreen({super.key});
  @override
  ConsumerState<UserCartScreen> createState() => _UserCartScreenState();
}

class _UserCartScreenState extends ConsumerState<UserCartScreen> {
  List<CartItem> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await CartService.instance.getCart();
      if (mounted) {
        setState(() {
          _items = items;
          _loading = false;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load your cart';
        });
      }
    }
  }

  Future<void> _updateQuantity(CartItem item, double newQuantity) async {
    try {
      await CartService.instance
          .updateQuantity(productId: item.productId, quantity: newQuantity);
      ref.invalidate(cartCountProvider);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not update quantity')));
      }
    }
  }

  /// Decimal amount prompt for unit-priced items (kg / liter).
  Future<double?> _promptQuantity(CartItem item) async {
    final ctrl = TextEditingController(text: _fmtQty(item.quantity));
    return showDialog<double>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Amount (${item.unitLabel})'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'How many ${item.unitLabel}?',
            hintText: 'e.g. 0.5, 1, 2.25',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', '.'));
              if (v == null || v <= 0) return;
              Navigator.pop(dialogCtx, v);
            },
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
  }

  static String _fmtQty(double v) => v == v.roundToDouble()
      ? v.toStringAsFixed(0)
      : v.toStringAsFixed(v * 10 == v.roundToDouble() ? 1 : 2);

  Future<void> _remove(CartItem item) async {
    try {
      await CartService.instance.removeFromCart(item.productId);
      ref.invalidate(cartCountProvider);
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not remove item')));
      }
    }
  }

  /// Group cart lines by provider so the user can check out one provider
  /// at a time (orders are per-provider in this schema).
  Map<String, List<CartItem>> get _groups {
    final map = <String, List<CartItem>>{};
    for (final item in _items) {
      map.putIfAbsent(item.providerId, () => []).add(item);
    }
    return map;
  }

  double _groupTotal(List<CartItem> group) =>
      group.fold(0.0, (sum, i) => sum + i.lineTotal);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Cart')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _items.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_error != null) _errorBanner(_error!),
                      for (final entry in _groups.entries)
                        _groupSection(entry.key, entry.value),
                    ],
                  ),
                ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shopping_cart_outlined,
              size: 64, color: AppTheme.textMuted),
          const SizedBox(height: 16),
          const Text('Your cart is empty',
              style: TextStyle(color: AppTheme.textMuted)),
          const SizedBox(height: 20),
          PrimaryButton(
            label: 'START SHOPPING',
            isOutlined: true,
            onPressed: () => context.go('/user'),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.error.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(message,
          style: const TextStyle(fontSize: 13, color: AppTheme.error)),
    );
  }

  Widget _groupSection(String providerId, List<CartItem> group) {
    final total = _groupTotal(group);
    final currency = group.first.currency;
    final providerName = group.first.providerName;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.store_outlined, size: 18, color: AppTheme.teal),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  providerName ?? 'Provider',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          ...group.map(_itemTile),
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Total',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              Text(
                '${total.toStringAsFixed(2)} $currency',
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreen),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: PrimaryButton(
              label: 'CHECKOUT',
              icon: Icons.shopping_cart_checkout,
              onPressed: () =>
                  context.push('/user/checkout', extra: providerId),
            ),
          ),
        ],
      ),
    );
  }

  Widget _itemTile(CartItem item) {
    final imageUrl = item.imagePath != null
        ? Supabase.instance.client.storage
            .from('product-images')
            .getPublicUrl(item.imagePath!)
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: imageUrl != null
                  ? CachedNetworkImage(
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: AppTheme.creamDark,
                        child: const Icon(Icons.image_outlined,
                            size: 24, color: AppTheme.textMuted),
                      ),
                    )
                  : Container(
                      color: AppTheme.creamDark,
                      child: const Icon(Icons.image_outlined,
                          size: 24, color: AppTheme.textMuted),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    item.unit != null
                        ? '${_fmtQty(item.price)} ${item.currency}/${item.unitLabel}'
                        : '${item.price.toStringAsFixed(2)} ${item.currency}',
                    style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.primaryGreen,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    'Line total: ${item.lineTotal.toStringAsFixed(2)} ${item.currency}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                onTap: () => _updateQuantity(
                    item,
                    item.unit != null
                        ? item.quantity + 0.5
                        : item.quantity + 1),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.add,
                      size: 16, color: AppTheme.primaryGreen),
                ),
              ),
              GestureDetector(
                // Unit-priced amounts are free-typed (0.25 kg, 1.5 L…).
                onTap: item.unit != null
                    ? () async {
                        final v = await _promptQuantity(item);
                        if (v != null) await _updateQuantity(item, v);
                      }
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                      item.unit != null
                          ? '${_fmtQty(item.quantity)} ${item.unitLabel}'
                          : '${_fmtQty(item.quantity)}',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              InkWell(
                onTap: () => _updateQuantity(
                    item,
                    item.unit != null
                        ? item.quantity - 0.5
                        : item.quantity - 1),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.creamDark,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Icon(Icons.remove,
                      size: 16, color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: () => _remove(item),
            icon: const Icon(Icons.delete_outline,
                size: 20, color: AppTheme.error),
          ),
        ],
      ),
    );
  }
}
