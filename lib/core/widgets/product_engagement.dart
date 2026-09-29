import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../services/product_like_service.dart';
import '../services/provider_name_service.dart';
import '../services/trending_settings.dart';
import '../theme/app_theme.dart';
import '../utils/friendly_error.dart';

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
          //
          // The future is awaited so a rejected write says why. It used to be
          // ignored, and the service's own `catch (_)` rolled the heart back
          // silently -- a like that filled and emptied with no explanation.
          onTap: () => _react(context, liked),
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

  Future<void> _react(BuildContext context, bool liked) async {
    final service = ProductLikeService.instance;
    final failure = await service.toggleLike(
      widget.productId,
      currentCount: service.likeCount(widget.productId, widget.fallbackCount),
    );
    if (failure == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(friendlyError(failure,
          context: liked ? 'Removing your like failed' : 'Your like was not saved')),
    ));
  }
}

/// The thumb-down beside the heart.
///
/// A reaction, not a rating: it says "not for me", and it is deliberately
/// undisplayed in aggregate. `products.dislike_count` is maintained by the
/// database and feeds the trending score through a CEO-tunable weight, but no
/// number is shown anywhere, on any card or detail screen. The reasoning is
/// recorded in migration 20260927000076; in short, a public dislike count on a
/// marketplace with few buyers per listing reads as a death mark and tells a
/// buyer nothing true.
///
/// Like and dislike are mutually exclusive, and the server is what enforces
/// it: liking something already disliked replaces the dislike. This only
/// states the intent, and the count it would show is the like count, which
/// falls by one when a like becomes a dislike.
class DislikeButton extends StatefulWidget {
  final String productId;
  final int fallbackCount;
  final bool large;

  const DislikeButton({
    super.key,
    required this.productId,
    this.fallbackCount = 0,
    this.large = false,
  });

  @override
  State<DislikeButton> createState() => _DislikeButtonState();
}

class _DislikeButtonState extends State<DislikeButton> {
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ProductLikeService.instance,
      builder: (context, _) {
        final service = ProductLikeService.instance;
        final disliked = service.isDisliked(widget.productId);
        final size = widget.large ? 20.0 : 15.0;

        return InkWell(
          onTap: () => _react(context),
          borderRadius: BorderRadius.circular(20),
          child: Tooltip(
            message: disliked ? 'Remove your dislike' : 'Not for me',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              // No count, deliberately. The icon carries the state on its own,
              // which is why it is an outline until chosen and filled after.
              child: Icon(
                disliked
                    ? Icons.thumb_down
                    : Icons.thumb_down_outlined,
                size: size,
                // Text-secondary rather than the like button's error red: a
                // dislike is a neutral "not for me", not a complaint, and
                // colouring it as one invites the reading the feature is
                // deliberately not making.
                color: disliked ? AppTheme.textPrimary : AppTheme.textMuted,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _react(BuildContext context) async {
    final service = ProductLikeService.instance;
    final failure = await service.toggleDislike(
      widget.productId,
      currentCount: service.likeCount(widget.productId, widget.fallbackCount),
    );
    if (failure == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(friendlyError(failure, context: 'That did not save')),
    ));
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
