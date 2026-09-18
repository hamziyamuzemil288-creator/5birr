import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/favorites_service.dart';
import '../../core/services/review_service.dart';
import '../../core/models/product.dart';
import '../../core/widgets/provider_trust_section.dart';

class UserProviderDetailScreen extends StatefulWidget {
  final String providerId;
  const UserProviderDetailScreen({super.key, required this.providerId});
  @override
  State<UserProviderDetailScreen> createState() => _State();
}

class _State extends State<UserProviderDetailScreen> {
  Map<String, dynamic>? _provider;
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _reviews = [];
  ProviderTrustStats? _trust;
  bool _loading = true;
  bool _fav = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final prov = await client
          .from('provider_profiles')
          .select()
          .eq('id', widget.providerId)
          .single();
      final prods = await client
          .from('products')
          .select('*, product_images(*)')
          .eq('provider_id', widget.providerId)
          .eq('is_active', true)
          .order('created_at', ascending: false)
          .limit(50);
      final fav = await FavoritesService.instance
          .isFavorited('PROVIDER', widget.providerId);
      List<Map<String, dynamic>> reviews = [];
      try {
        reviews = await ReviewService.instance
            .getReviewsForProvider(widget.providerId);
      } catch (_) {}
      // Trust stats come from the provider_trust_stats view (real,
      // aggregated data; view read is non-fatal if unavailable).
      final trust = await ProviderTrustStats.fetch(widget.providerId);
      if (mounted) {
        setState(() {
          _provider = prov;
          _products = List<Map<String, dynamic>>.from(prods as List);
          _reviews = reviews;
          _trust = trust;
          _fav = fav;
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
    if (_provider == null) {
      return Scaffold(
          appBar: AppBar(title: const Text('Provider')),
          body: const Center(child: Text('Provider not found')));
    }
    final p = _provider!;

    return Scaffold(
      appBar: AppBar(
        title: Text(p['business_name'] ?? ''),
        actions: [
          IconButton(
            icon: Icon(_fav ? Icons.favorite : Icons.favorite_border,
                color: _fav ? AppTheme.error : null),
            onPressed: () async {
              final now = await FavoritesService.instance
                  .toggle('PROVIDER', widget.providerId);
              if (mounted) setState(() => _fav = now);
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                    colors: [AppTheme.teal, Color(0xFF00695C)]),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p['business_name'] ?? '',
                      style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                  const SizedBox(height: 4),
                  Text(p['address_text'] ?? 'Location not set',
                      style: TextStyle(
                          fontSize: 13, color: Colors.white.withOpacity(0.8))),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.star, color: AppTheme.gold, size: 16),
                      const SizedBox(width: 4),
                      Text(
                          _trust != null
                              ? _trust!.avgRating.toStringAsFixed(1)
                              : '0.0',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                      const SizedBox(width: 12),
                      Text('${_products.length} products',
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
            // Trust & quality summary — real aggregated stats
            ProviderTrustSection(stats: _trust),
            // Products
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text('Products (${_products.length})',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            if (_products.isEmpty)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                    child: Text('No products yet',
                        style: TextStyle(color: AppTheme.textMuted))),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _products.length,
                itemBuilder: (_, i) {
                  final prod = _products[i];
                  return ListTile(
                    onTap: () =>
                        context.push('/user/product/${prod['id']}'),
                    leading: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                          color: AppTheme.creamDark,
                          borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.inventory_2_outlined,
                          color: AppTheme.textMuted),
                    ),
                    title: Text(prod['name'] ?? '',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${prod['price']} ${prod['currency'] ?? 'ETB'}',
                        style: const TextStyle(
                            color: AppTheme.primaryGreen,
                            fontWeight: FontWeight.w600)),
                  );
                },
              ),
            const SizedBox(height: 20),
            _reviewsSection(),
          ],
        ),
      ),
    );
  }

  Widget _reviewsSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      child: Column(
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
      ),
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
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textMuted)),
          if (r['comment'] != null && (r['comment'] as String).isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(r['comment'] as String,
                style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.textSecondary,
                    height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _stars(int rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
            i < rating ? Icons.star : Icons.star_border,
            size: 14,
            color: AppTheme.gold,
          )),
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
