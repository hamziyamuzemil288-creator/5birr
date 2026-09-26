import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/favorites_service.dart';
import '../../core/services/cart_service.dart';
import '../../core/services/review_service.dart';
import '../../core/widgets/cart_icon_button.dart';
import '../../core/utils/friendly_error.dart';

class UserProductDetailScreen extends ConsumerStatefulWidget {
  final String productId;
  const UserProductDetailScreen({super.key, required this.productId});
  @override
  ConsumerState<UserProductDetailScreen> createState() => _State();
}

class _State extends ConsumerState<UserProductDetailScreen> {
  Map<String, dynamic>? _product;
  List<Map<String, dynamic>> _reviews = [];
  bool _loading = true;
  bool _fav = false;
  bool _adding = false;
  // Unit-priced items (per kg / liter) are bought in decimal amounts.
  final _qtyCtrl = TextEditingController();

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('products')
          .select('*, product_images(*), provider_profiles(id,business_name)')
          .eq('id', widget.productId)
          .single();
      final fav = await FavoritesService.instance
          .isFavorited('PRODUCT', widget.productId);
      List<Map<String, dynamic>> reviews = [];
      try {
        reviews =
            await ReviewService.instance.getReviewsForProduct(widget.productId);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _product = data;
          _fav = fav;
          _reviews = reviews;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
          body: const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen)));
    }
    if (_product == null) {
      return Scaffold(
          appBar: AppBar(title: const Text('Product')),
          body: const Center(child: Text('Product not found')));
    }
    final p = _product!;
    final imgs = (p['product_images'] as List?) ?? [];
    final provider = p['provider_profiles'] as Map<String, dynamic>?;
    final unit = p['unit'] as String?;
    final isUnitPriced = unit == 'KG' || unit == 'LTR';
    final unitWord = unit == 'KG' ? 'kg' : 'liter';

    return Scaffold(
      appBar: AppBar(
        title: Text(p['name'] ?? ''),
        actions: [
          const CartIconButton(),
          IconButton(
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                color: _fav ? AppTheme.error : null),
            onPressed: () async {
              final now = await FavoritesService.instance
                  .toggle('PRODUCT', widget.productId);
              if (mounted) setState(() => _fav = now);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image gallery
            if (imgs.isNotEmpty)
              SizedBox(
                height: 250,
                child: PageView.builder(
                  itemCount: imgs.length,
                  itemBuilder: (_, i) {
                    final storagePath = imgs[i]['storage_path'] as String?;
                    final imageUrl = storagePath != null
                        ? Supabase.instance.client.storage
                            .from('product-images')
                            .getPublicUrl(storagePath)
                        : null;
                    return imageUrl != null
                        ? CachedNetworkImage(
                            imageUrl: imageUrl,
                            fit: BoxFit.cover,
                            placeholder: (_, __) => const Center(
                                child: CircularProgressIndicator(
                                    color: AppTheme.primaryGreen)),
                            errorWidget: (_, __, ___) => Container(
                              color: AppTheme.creamDark,
                              child: const Center(
                                child: Icon(Icons.image_outlined,
                                    size: 64, color: AppTheme.textMuted),
                              ),
                            ),
                          )
                        : Container(
                            color: AppTheme.creamDark,
                            child: const Center(
                              child: Icon(Icons.image_outlined,
                                  size: 64, color: AppTheme.textMuted),
                            ),
                          );
                  },
                ),
              )
            else
              Container(
                height: 200,
                color: AppTheme.creamDark,
                child: const Center(
                    child: Icon(Icons.inventory_2_outlined,
                        size: 64, color: AppTheme.textMuted)),
              ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p['name'] ?? '',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 8),
                  Text(
                      isUnitPriced
                          ? '${_fmtNum((p['price'] as num?)?.toDouble() ?? 0)} ${p['currency'] ?? 'ETB'}/$unitWord'
                          : '${p['price']} ${p['currency'] ?? 'ETB'}',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryGreen)),
                  const SizedBox(height: 12),
                  if (p['rating'] != null && (p['rating'] as num) > 0)
                    Row(
                      children: [
                        const Icon(Icons.star, color: AppTheme.gold, size: 18),
                        const SizedBox(width: 4),
                        Text('${p['rating']}',
                            style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 8),
                        Text('${p['review_count'] ?? 0} reviews',
                            style: const TextStyle(
                                fontSize: 13, color: AppTheme.textSecondary)),
                      ],
                    ),
                  const SizedBox(height: 16),
                  if (provider != null)
                    GestureDetector(
                      onTap: () =>
                          context.go('/user/provider/${provider['id']}'),
                      child: Row(
                        children: [
                          const Icon(Icons.store_outlined,
                              size: 18, color: AppTheme.teal),
                          const SizedBox(width: 6),
                          Text(provider['business_name'] ?? '',
                              style: const TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.teal,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (p['description'] != null) ...[
                    const Text('Description',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(p['description'],
                        style: const TextStyle(
                            fontSize: 14,
                            color: AppTheme.textSecondary,
                            height: 1.5)),
                  ],
                  const SizedBox(height: 24),
                  _reviewsSection(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 12,
                offset: const Offset(0, -2)),
          ],
        ),
        child: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _adding ? null : _addToCart,
                  child: const Text('ADD TO CART'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _adding ? null : _buyNow,
                  child: Text(_adding ? 'PLEASE WAIT…' : 'BUY NOW'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reviewsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Reviews',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        if (_reviews.isEmpty)
          const Text('No reviews yet',
              style: TextStyle(color: AppTheme.textMuted))
        else
          ..._reviews.map((r) => _reviewTile(r)),
      ],
    );
  }

  Widget _reviewTile(Map<String, dynamic> r) {
    final rating = (r['rating'] as num).toInt();
    final when = r['created_at'] != null
        ? _fmtDate(DateTime.parse(r['created_at'] as String))
        : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(r['reviewer_name'] ?? 'Anonymous',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              _stars(rating),
            ],
          ),
          if (when.isNotEmpty)
            Text(when,
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          if (r['comment'] != null && (r['comment'] as String).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r['comment'] as String,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary, height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
          5,
          (i) => Icon(
                i < rating ? Icons.star : Icons.star_border,
                size: 14,
                color: AppTheme.gold,
              )),
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  static String _fmtNum(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  Future<void> _addToCart() async {
    final isUnitPriced =
        _product != null && (_product!['unit'] as String?) != null;
    double qty = 1;
    if (isUnitPriced) {
      // Ask for the amount in kg / liters (decimals allowed: 0.5 kg, 1.25 L…).
      final entered = await _promptQuantity();
      if (entered == null) return; // user cancelled
      qty = entered;
    }
    setState(() => _adding = true);
    try {
      await CartService.instance
          .addToCart(productId: widget.productId, quantity: qty);
      ref.invalidate(cartCountProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Added ${_fmtNum(qty)} ${isUnitPriced ? (_product!['unit'] == 'KG' ? 'kg' : 'liter') : 'pc'} to cart')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not add this to your cart'))));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// Decimal amount prompt for unit-priced items (kg / liter).
  Future<double?> _promptQuantity() async {
    final ctrl = TextEditingController(
        text: _qtyCtrl.text.isEmpty ? '1' : _qtyCtrl.text);
    final unitWord = _product!['unit'] == 'KG' ? 'kg' : 'liter';
    return showDialog<double>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('Amount ($unitWord)'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'How many $unitWord?',
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
            child: const Text('ADD'),
          ),
        ],
      ),
    );
  }

  /// Direct-buy: put the chosen amount in the cart, then jump straight to
  /// checkout for this provider.
  Future<void> _buyNow() async {
    final isUnitPriced =
        _product != null && (_product!['unit'] as String?) != null;
    double qty = 1;
    if (isUnitPriced) {
      final entered = await _promptQuantity();
      if (entered == null) return;
      qty = entered;
    }
    setState(() => _adding = true);
    try {
      await CartService.instance
          .addToCart(productId: widget.productId, quantity: qty);
      ref.invalidate(cartCountProvider);
      if (!mounted) return;
      final providerId = ((_product!['provider_profiles']
          as Map<String, dynamic>?)?['id']) as String?;
      if (providerId != null) {
        context.push('/user/checkout', extra: providerId);
      } else {
        context.push('/user/cart');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(friendlyError(e, context: 'Could not start checkout'))));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }
}
