import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/rank_service.dart';
import '../theme/app_theme.dart';

/// The small rank pill that sits next to a name.
///
/// Renders nothing at all when the account holds no rank yet or the lookup
/// has not resolved — a badge is a bonus on someone's name, never something
/// that leaves a gap or an error on the line it decorates.
///
/// The lookup is batched and cached by [RankService], so a listing of twelve
/// products costs one round trip rather than twelve.
class RankBadge extends StatefulWidget {
  /// The account, when the name belongs to a user.
  final String? userId;

  /// The provider profile, when the name belongs to a business.
  final String? providerId;

  /// Tighter spacing and text, for lists and table rows.
  final bool compact;

  const RankBadge({
    super.key,
    this.userId,
    this.providerId,
    this.compact = true,
  });

  @override
  State<RankBadge> createState() => _RankBadgeState();
}

class _RankBadgeState extends State<RankBadge> {
  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant RankBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.userId != widget.userId ||
        oldWidget.providerId != widget.providerId) {
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final loaded = widget.userId != null
        ? RankService.instance.hasUserRank(widget.userId)
        : RankService.instance.hasProviderRank(widget.providerId);
    if (loaded) return;

    await RankService.instance.ensure(
      userIds: [widget.userId],
      providerIds: [widget.providerId],
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tier = widget.userId != null
        ? RankService.instance.cachedUserRank(widget.userId)
        : RankService.instance.cachedProviderRank(widget.providerId);
    if (tier == null) return const SizedBox.shrink();

    final fontSize = widget.compact ? 10.0 : 11.0;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 6 : 8,
        vertical: widget.compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: tier.color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tier.color.withOpacity(0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium_rounded,
              size: fontSize + 3, color: tier.color),
          const SizedBox(width: 3),
          Text(
            tier.name,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: tier.color,
            ),
          ),
        ],
      ),
    );
  }
}

/// The signed-in account's own stand on the ladder, with the distance to the
/// next rung.
///
/// Shown on the profile and the provider dashboards. Purely informational:
/// no feature is gated on rank.
class RankProgressCard extends StatelessWidget {
  final int points;
  final RankProgress? progress;
  final bool loading;
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onTap;

  /// Which balance of the two this card is showing, e.g. 'Personal' or
  /// 'Business'. Null when the account only has one.
  final String? subjectLabel;

  const RankProgressCard({
    super.key,
    required this.points,
    this.progress,
    this.loading = false,
    this.failed = false,
    this.onRetry,
    this.onTap,
    this.subjectLabel,
  });

  @override
  Widget build(BuildContext context) {
    final rank = progress;
    final color = rank?.current?.color ?? AppTheme.textMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: loading
              ? const SizedBox(
                  height: 44,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppTheme.primaryGreen),
                    ),
                  ),
                )
              : failed
                  ? Row(
                      children: [
                        const Icon(Icons.refresh,
                            size: 16, color: AppTheme.textMuted),
                        const SizedBox(width: 8),
                        const Text('Could not load your rank',
                            style: TextStyle(
                                fontSize: 13, color: AppTheme.textMuted)),
                        const Spacer(),
                        TextButton(
                          onPressed: onRetry,
                          child: const Text('Retry'),
                        ),
                      ],
                    )
                  : _body(context, rank),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, RankProgress? rank) {
    final tier = rank?.current;
    final color = tier?.color ?? AppTheme.textMuted;
    final next = rank?.next;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.14),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.workspace_premium_rounded,
                  color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          tier?.name ?? 'No rank yet',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: tier == null
                                ? AppTheme.textSecondary
                                : color,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (subjectLabel != null) ...[
                        const SizedBox(width: 6),
                        Text('· $subjectLabel',
                            style: const TextStyle(
                                fontSize: 12, color: AppTheme.textMuted)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${NumberFormat.decimalPattern().format(points)} points',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary),
                  ),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right,
                  color: AppTheme.textMuted, size: 20),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: rank?.fraction ?? 0,
            minHeight: 6,
            backgroundColor: color.withOpacity(0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          next == null
              ? (tier == null
                  ? 'Earn points by completing orders and rides'
                  : 'Top rank reached — Legend status')
              : '${NumberFormat.decimalPattern().format(points)} / '
                  '${NumberFormat.decimalPattern().format(next.minPoints)} '
                  'points to ${next.name}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      ],
    );
  }
}
