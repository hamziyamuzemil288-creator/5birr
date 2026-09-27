import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'rank_badge.dart';

/// Immutable snapshot of one provider's trust stats, read from the
/// `provider_trust_stats` view (migration 0027).
class ProviderTrustStats {
  /// The provider profile these stats belong to, so the section can also show
  /// the provider's rank badge without the caller having to pass it twice.
  final String? providerId;
  final double avgRating;
  final int reviewCount;
  final int completedCount;
  final int? completionRate; // percent, null when no resolved orders yet
  final double? avgResponseMinutes; // null until first provider acceptance
  final bool isVerified;
  final DateTime? memberSince;

  const ProviderTrustStats({
    this.providerId,
    required this.avgRating,
    required this.reviewCount,
    required this.completedCount,
    this.completionRate,
    this.avgResponseMinutes,
    required this.isVerified,
    this.memberSince,
  });

  static ProviderTrustStats? fromMap(Map<String, dynamic> m) {
    final providerId = m['provider_id'];
    if (providerId == null) return null;
    return ProviderTrustStats(
      providerId: providerId as String?,
      avgRating: (m['avg_rating'] as num?)?.toDouble() ?? 0,
      reviewCount: (m['review_count'] as num?)?.toInt() ?? 0,
      completedCount: (m['completed_count'] as num?)?.toInt() ?? 0,
      completionRate: (m['completion_rate'] as num?)?.toInt(),
      avgResponseMinutes: (m['avg_response_minutes'] as num?)?.toDouble(),
      isVerified: m['is_verified'] == true,
      memberSince: m['member_since'] != null
          ? DateTime.parse(m['member_since'] as String)
          : null,
    );
  }

  /// Fetch live stats for one provider from the aggregate view.
  static Future<ProviderTrustStats?> fetch(String providerId) async {
    try {
      final row = await Supabase.instance.client
          .from('provider_trust_stats')
          .select()
          .eq('provider_id', providerId)
          .maybeSingle();
      if (row == null) return null;
      return fromMap(Map<String, dynamic>.from(row));
    } catch (_) {
      return null;
    }
  }
}

/// Trust/quality summary shown at the top of provider profiles.
/// Shows only REAL, aggregated data — nothing is fabricated: a provider
/// with no reviews/trades renders as "New provider".
class ProviderTrustSection extends StatelessWidget {
  final ProviderTrustStats? stats;

  const ProviderTrustSection({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: verification badge + rating
          Row(
            children: [
              Text('Trust & Quality',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary)),
              const Spacer(),
              // The provider's rank badge, beside the verification pill it
              // belongs with. Both are trust signals; neither unlocks
              // anything.
              RankBadge(providerId: s.providerId, compact: false),
              if (s.isVerified) const SizedBox(width: 6),
              if (s.isVerified)
                _pill(
                  icon: Icons.verified_rounded,
                  label: 'Verified',
                  color: AppTheme.primaryGreen,
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Rating row
          Row(
            children: [
              if (s.reviewCount > 0) ...[
                _stars(s.avgRating),
                const SizedBox(width: 6),
                Text('${s.avgRating.toStringAsFixed(1)}',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
                const SizedBox(width: 4),
                Text('(${s.reviewCount} review${s.reviewCount == 1 ? '' : 's'})',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textMuted)),
              ] else
                Text('No reviews yet',
                    style:
                        TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          // Stats grid
          Row(
            children: [
              Expanded(
                child: _stat(
                  icon: Icons.check_circle_outline,
                  label: 'Completed',
                  value: '${s.completedCount}',
                  color: AppTheme.success,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _stat(
                  icon: Icons.task_alt,
                  label: 'Completion',
                  value: s.completionRate != null
                      ? '${s.completionRate}%'
                      : 'New',
                  color: AppTheme.teal,
                ),
              ),
              if (s.avgResponseMinutes != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: _stat(
                    icon: Icons.schedule,
                    label: 'Avg response',
                    value: _fmtResponse(s.avgResponseMinutes!),
                    color: AppTheme.info,
                  ),
                ),
              ],
            ],
          ),
          if (s.memberSince != null) ...[
            const SizedBox(height: 10),
            Text(
              'Member since ${DateFormat('MMM yyyy').format(s.memberSince!)}',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtResponse(double minutes) {
    if (minutes < 60) return '${minutes.round()}m';
    final hours = minutes / 60;
    if (hours < 24) return '${hours.toStringAsFixed(1)}h';
    return '${(hours / 24).toStringAsFixed(1)}d';
  }

  Widget _stat({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          Text(label,
              style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
        ],
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ],
      ),
    );
  }

  Widget _stars(double rating) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = i < rating.round();
        return Icon(
          filled ? Icons.star : Icons.star_border,
          size: 15,
          color: AppTheme.gold,
        );
      }),
    );
  }
}
