import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A single cart line: one product + quantity, joined with product data.
class CartItem {
  final String id; // cart_items.id
  final String productId;
  final String providerId;
  final String? providerName;
  final String name;
  final double price;
  final String currency;
  final double
      quantity; // decimal allowed: unit-priced items are sold per kg/liter
  final String? unit; // 'KG' | 'LTR' | null (fixed-price listing)
  final String? imagePath; // primary listing image storage path
  final DateTime addedAt;

  const CartItem({
    required this.id,
    required this.productId,
    required this.providerId,
    this.providerName,
    required this.name,
    required this.price,
    this.currency = 'ETB',
    required this.quantity,
    this.unit,
    this.imagePath,
    required this.addedAt,
  });

  double get lineTotal => price * quantity;

  /// Human unit for quantity steppers and totals: 'kg', 'liter', or 'pc'.
  String get unitLabel => unit == 'KG'
      ? 'kg'
      : unit == 'LTR'
          ? 'liter'
          : 'pc';
}

/// Persistent cart backed by the `cart_items` table (migration 0005).
/// Unique on (user_id, product_id) — re-adding a product increases quantity.
class CartService {
  CartService._();
  static final instance = CartService._();
  final _client = Supabase.instance.client;

  /// Add a product to the current user's cart, increasing quantity if present.
  Future<void> addToCart({
    required String productId,
    required double quantity,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final existing = await _client
        .from('cart_items')
        .select('id, quantity')
        .eq('user_id', userId)
        .eq('product_id', productId)
        .maybeSingle();

    if (existing != null) {
      await _client.from('cart_items').update({
        'quantity': (existing['quantity'] as num).toDouble() + quantity,
      }).eq('id', existing['id']);
    } else {
      await _client.from('cart_items').insert({
        'user_id': userId,
        'product_id': productId,
        'quantity': quantity,
      });
    }
  }

  /// Fetch the current user's cart items joined with product details.
  Future<List<CartItem>> getCart() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];

    final data = await _client
        .from('cart_items')
        .select(
            'id, quantity, added_at, products(id, provider_id, name, price, currency, unit, product_images(*), provider_profiles(business_name))')
        .eq('user_id', userId)
        .order('added_at');

    final items = <CartItem>[];
    for (final row in data as List) {
      final product = (row['products'] as Map<String, dynamic>?) ?? const {};
      final provider =
          (product['provider_profiles'] as Map<String, dynamic>?) ?? const {};
      items.add(CartItem(
        id: row['id'] as String,
        productId: product['id'] as String,
        providerId: product['provider_id'] as String,
        providerName: provider['business_name'] as String?,
        name: product['name'] as String? ?? '',
        price: (product['price'] as num?)?.toDouble() ?? 0,
        currency: product['currency'] as String? ?? 'ETB',
        quantity: (row['quantity'] as num?)?.toDouble() ?? 1,
        unit: product['unit'] as String?,
        imagePath: _primaryImagePath(product),
        addedAt: DateTime.parse(row['added_at'] as String),
      ));
    }
    return items;
  }

  /// Update a cart line's quantity; quantity <= 0 removes the line.
  Future<void> updateQuantity({
    required String productId,
    required double quantity,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    if (quantity <= 0) {
      await removeFromCart(productId);
      return;
    }
    await _client
        .from('cart_items')
        .update({'quantity': quantity})
        .eq('user_id', userId)
        .eq('product_id', productId);
  }

  /// Remove a product from the current user's cart.
  Future<void> removeFromCart(String productId) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    await _client
        .from('cart_items')
        .delete()
        .eq('user_id', userId)
        .eq('product_id', productId);
  }

  /// Remove all items from the current user's cart.
  Future<void> clearCart() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    await _client.from('cart_items').delete().eq('user_id', userId);
  }

  /// Total number of cart lines for the current user (for nav badges).
  Future<int> getCartItemCount() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return 0;
    final data =
        await _client.from('cart_items').select('id').eq('user_id', userId);
    return (data as List).length;
  }

  String? _primaryImagePath(Map<String, dynamic> product) {
    final imgs = (product['product_images'] as List?) ?? const [];
    if (imgs.isEmpty) return null;
    final primary = imgs.firstWhere(
      (i) => i['is_primary'] == true,
      orElse: () => imgs.first,
    );
    return (primary as Map<String, dynamic>)['storage_path'] as String?;
  }
}

/// Reactive cart item count for badges; invalidate after cart mutations.
final cartCountProvider = FutureProvider<int>((ref) async {
  return CartService.instance.getCartItemCount();
});
