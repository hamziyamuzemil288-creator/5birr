import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../models/product.dart';
import 'rank_badge.dart';
import 'product_engagement.dart';
import 'product_buy_button.dart';

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

  /// The photo a card leads with: the listing's primary image — the row
  /// with the lowest `sort_order`, which is what the upload path writes
  /// first — never whatever the storage layer happened to return first.
  ///
  /// This is what made Fresh Finds look broken: `images.first` was raw row
  /// order, so a card could show a secondary screenshot, or a thin band of
  /// one, instead of the photo the provider actually picked. `product_images`
  /// has no `is_primary` column, so sort order is the only truth there is.
  ListingImage? get _cover {
    final images = product.images;
    if (images.isEmpty) return null;
    final sorted = [...images]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return sorted.first;
  }

  @override
  Widget build(BuildContext context) {
    final img = imageUrl ??
        (() {
          final cover = _cover;
          return cover == null
              ? null
              : Supabase.instance.client.storage
                  .from('product-images')
                  .getPublicUrl(cover.storagePath);
        })();

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
                        // Full-bleed cover: the frame is the whole image
                        // area of the card, so a portrait photo is centred
                        // and cropped by the frame rather than floating at
                        // its intrinsic size inside it.
                        child: SizedBox(
                          width: double.infinity,
                          height: double.infinity,
                          child: CachedNetworkImage(
                            imageUrl: img,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.medium,
                            placeholder: (_, __) => const Center(
                                child: CircularProgressIndicator(
                                    strokeWidth: 2)),
                            errorWidget: (_, __, ___) => const Center(
                              child: Icon(Icons.image_outlined,
                                  color: AppTheme.textMuted, size: 40),
                            ),
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(product.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      // Popular is a CEO-tunable social signal, not a claim we
                      // verify here: the threshold lives in system_settings
                      // and the count is maintained by a database trigger.
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: PopularMark(
                            productId: product.id,
                            fallbackCount: product.likeCount),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  // Who is selling it. One tap to their existing detail
                  // screen; it adds no new surface of its own.
                  ProviderNameTag(providerId: product.providerId),
                  const SizedBox(height: 2),
                  // Price and the BUY action share one row: the number the
                  // buyer is deciding on and the button that acts on it read
                  // together, and it costs no extra height on a grid tile.
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(product.formattedDisplayPrice,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryGreen)),
                      ),
                      const SizedBox(width: 6),
                      ProductBuyButton(
                        productId: product.id,
                        providerId: product.providerId,
                        compact: true,
                      ),
                    ],
                  ),
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
                      // The seller's rank, where a buyer is choosing. A trust
                      // signal and nothing more: it gates no product and no
                      // order. Renders nothing until the batched lookup lands,
                      // so a grid of cards costs one round trip, not twelve.
                      const Spacer(),
                      RankBadge(providerId: product.providerId),
                      const SizedBox(width: 4),
                      // Reaction, not rating: the thumb-down says "not for
                      // me" and shows no count, because dislike counts are
                      // deliberately not public (migration 20260927000076).
                      DislikeButton(
                          productId: product.id,
                          fallbackCount: product.likeCount),
                      LikeButton(productId: product.id, fallbackCount: product.likeCount),
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
