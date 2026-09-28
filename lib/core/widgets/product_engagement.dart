import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/product_like_service.dart';
import '../services/provider_name_service.dart';
import '../services/trending_settings.dart';
import '../theme/app_theme.dart';

/// The heart on a product card or detail screen.
///
/// A [StatefulWidget] listening to [ProductLikeService] rather than a plain
/// read: the like state changes optimistically and is then corrected (or
/// rolled back) by the server, and a widget that only read the value at build
/// time would keep showing the stale answer until something else happened to
/// rebuild it.
class LikeButton extends StatefulWidget {
  final String productId;

  /// The count from the product row, used until the service has a live value.
  final int fallbackCount;

  /// Slightly larger for the detail screen, where the like is a real action
  /// rather than a grid affordance.
  final bool large;

  const LikeButton({
    super.key,
    required this.productId,
    this.fallbackCount = 0,
    this.large = false,
  });

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ProductLikeService.instance,
      builder: (context, _) {
        final service = ProductLikeService.instance;
        final liked = service.isLiked(widget.productId);
        final count = service.likeCount(widget.productId, widget.fallbackCount);
        final size = widget.large ? 20.0 : 15.0;

        return InkWell(
          // Taps on the heart must not open the product. Without this the
          // card's GestureDetector swallows the tap and the user's like
          // navigates instead of registering.
          onTap: () =>
              service.toggle(widget.productId, currentCount: count),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  liked ? Icons.favorite : Icons.favorite_border,
                  size: size,
                  color: liked ? AppTheme.error : AppTheme.textSecondary,
                ),
                if (count > 0) ...[
                  const SizedBox(width: 3),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: widget.large ? 13 : 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The small "by <business>" line under a product name.
///
/// Resolves through [ProviderNameService], which batches: a grid of twelve
/// cards costs one round trip, not twelve. Renders nothing at all until the
/// name arrives or until it is known to be absent, so it never leaves a gap
/// or a spinner on the line it decorates.
class ProviderNameTag extends StatefulWidget {
  final String providerId;

  const ProviderNameTag({super.key, required this.providerId});

  @override
  State<ProviderNameTag> createState() => _ProviderNameTagState();
}

class _ProviderNameTagState extends State<ProviderNameTag> {
  @override
  void initState() {
    super.initState();
    ProviderNameService.instance.ensure([widget.providerId]);
  }

  @override
  void didUpdateWidget(covariant ProviderNameTag oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.providerId != widget.providerId) {
      ProviderNameService.instance.ensure([widget.providerId]);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ProviderNameService.instance,
      builder: (context, _) {
        final service = ProviderNameService.instance;
        final name = service.nameOf(widget.providerId);
        // Unknown, or looked up and genuinely empty: show nothing either way.
        if (name == null || name.isEmpty) return const SizedBox.shrink();

        return GestureDetector(
          onTap: () => context.push('/user/provider/${widget.providerId}'),
          child: Text(
            'by $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textMuted,
              decoration: TextDecoration.underline,
              decorationColor: AppTheme.textMuted,
            ),
          ),
        );
      },
    );
  }
}

/// The flame on a product whose likes have reached the CEO's Popular
/// threshold.
///
/// Listens to both the like service and the settings, because either can
/// change the answer: a like crosses the line, or the CEO moves the line.
class PopularMark extends StatefulWidget {
  final String productId;
  final int fallbackCount;

  const PopularMark({
    super.key,
    required this.productId,
    this.fallbackCount = 0,
  });

  @override
  State<PopularMark> createState() => _PopularMarkState();
}

class _PopularMarkState extends State<PopularMark> {
  @override
  void initState() {
    super.initState();
    TrendingSettings.instance.ensure();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        ProductLikeService.instance,
        TrendingSettings.instance,
      ]),
      builder: (context, _) {
        final count = ProductLikeService.instance.likeCount(
            widget.productId, widget.fallbackCount);
        final popular = ProductLikeService.instance.isPopular(
            count, TrendingSettings.instance.popularThreshold);
        if (!popular) return const SizedBox.shrink();
        return const Icon(Icons.local_fire_department,
            size: 14, color: AppTheme.gold);
      },
    );
  }
}
