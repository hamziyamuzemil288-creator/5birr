import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../models/product.dart';

class ProductCard extends StatelessWidget {
  final Product product;
  final VoidCallback? onTap;
  final String? imageUrl;

  const ProductCard({
    super.key,
    required this.product,
    this.onTap,
    this.imageUrl,
  });

  @override
  Widget build(BuildContext context) {
    final img = imageUrl ??
        (product.images.isNotEmpty
            ? Supabase.instance.client.storage
                .from('product-images')
                .getPublicUrl(product.images.first.storagePath)
            : null);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image — Expanded (not a fixed 1:1 AspectRatio) so the card
            // always fills its grid slot: the text block keeps its intrinsic
            // height and the image absorbs whatever remains. A fixed square
            // image + fixed text scaled as width + ~80dp while the slot scaled
            // as width / childAspectRatio, which overflowed by a few pixels on
            // some device widths (BOTTOM OVERFLOWED BY 4.1 PIXELS).
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.creamDark,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: img != null
                    ? ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        child: CachedNetworkImage(
                          imageUrl: img,
                          fit: BoxFit.cover,
                          placeholder: (_, __) => const Center(
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          errorWidget: (_, __, ___) => const Center(
                            child: Icon(Icons.image_outlined,
                                color: AppTheme.textMuted, size: 40),
                          ),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.inventory_2_outlined,
                            color: AppTheme.textMuted, size: 40)),
              ),
            ),
            // Info
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(product.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(product.formattedDisplayPrice,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryGreen)),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (product.rating > 0) ...[
                        const Icon(Icons.star, color: AppTheme.gold, size: 14),
                        const SizedBox(width: 2),
                        Text('${product.rating.toStringAsFixed(1)}',
                            style: const TextStyle(
                                fontSize: 11, color: AppTheme.textSecondary)),
                        const SizedBox(width: 4),
                      ],
                      if (!product.isAvailable)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.error.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Unavailable',
                              style: TextStyle(
                                  fontSize: 10, color: AppTheme.error)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
