import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/resilience/failure_mapper.dart';
import '../../core/widgets/async_view.dart';

class UserNotificationsScreen extends StatefulWidget {
  const UserNotificationsScreen({super.key});
  @override
  State<UserNotificationsScreen> createState() =>
      _UserNotificationsScreenState();
}

class _UserNotificationsScreenState extends State<UserNotificationsScreen> {

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Returns the inbox, or throws a classified [AppFailure].
  ///
  /// AsyncView owns the three states, so this returns data rather than
  /// calling setState: the widget holds the loading/error/empty branches and
  /// keeps the last good list on screen when a refresh fails.
  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw AppFailureMapper.map(e, context: 'loading your notifications');
    }
  }

  Color _iconColor(String type) {
    if (type.contains('ORDER')) return AppTheme.info;
    if (type.contains('APPROVAL') || type.contains('APPROVE'))
      return AppTheme.success;
    if (type.contains('REJECT')) return AppTheme.error;
    if (type.contains('WALLET')) return AppTheme.gold;
    if (type.contains('RIDE')) return AppTheme.teal;
    // Points awards and appeal decisions are their own colours rather than
    // the default green, so the list reads at a glance without a filter.
    if (type.contains('POINTS')) return AppTheme.gold;
    if (type.contains('APPEAL')) return AppTheme.warning;
    return AppTheme.primaryGreen;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: AsyncListView<Map<String, dynamic>>(
          loader: _load,
          errorContext: 'loading your notifications',
          padding: const EdgeInsets.all(16),
          itemBuilder: (_, n, __) {
                      final isRead = n['is_read'] == true;
                      final color = _iconColor(n['type'] ?? '');
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: isRead
                              ? AppTheme.surface
                              : AppTheme.primaryGreen.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: isRead
                                  ? AppTheme.cardBorder
                                  : AppTheme.primaryGreen.withOpacity(0.15),
                              width: 0.5),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 4),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              _iconForType(n['type'] ?? ''),
                              color: color,
                              size: 20,
                            ),
                          ),
                          title: Text(n['title'] ?? '',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isRead
                                      ? FontWeight.w500
                                      : FontWeight.w600)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(n['body'] ?? '',
                                // Three lines, not two. The money notifications
                                // are receipts — "Payment of ETB 12,400.00 for
                                // Order #1841 has been verified. The buyer's
                                // contact details are now available in the
                                // order." — and at two lines on a narrow phone
                                // that ellipsizes before the amount is even
                                // visible, which defeats the point of quoting
                                // it. Status pings are shorter and simply leave
                                // the third line empty.
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                          ),
                          trailing: !isRead
                              ? Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppTheme.primaryGreen,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.primaryGreen
                                            .withOpacity(0.3),
                                        blurRadius: 3,
                                      ),
                                    ],
                                  ))
                              : null,
                        ),
                      );
          },
          emptyBuilder: (context) => _buildEmptyState(),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Decorative icon with animated ring
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.teal.withOpacity(0.12),
                  width: 2,
                ),
              ),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withOpacity(0.06),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.notifications_none_rounded,
                    color: AppTheme.teal, size: 36),
              ),
            ),
            const SizedBox(height: 24),
            const Text('No notifications yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Text(
              "You'll see updates about your orders,\napprovals, and account activity here",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppTheme.textMuted.withOpacity(0.8)),
            ),
          ],
        ),
      ),
    );
  }


  IconData _iconForType(String type) {
    if (type.contains('ORDER')) return Icons.receipt_outlined;
    if (type.contains('APPROVAL') || type.contains('APPROVE'))
      return Icons.check_circle_outline;
    if (type.contains('REJECT')) return Icons.cancel_outlined;
    if (type.contains('WALLET')) return Icons.account_balance_wallet_outlined;
    if (type.contains('RIDE')) return Icons.directions_car_outlined;
    // Points (POINTS_EARNED and POINTS_REDEEMED) were already given a gold
    // tint in _iconColor but had no branch here, so a points-conversion
    // receipt rendered as the generic bell. The two helpers are read together
    // for that reason; a type that is coloured but unlabelled reads as noise.
    if (type.contains('POINTS')) return Icons.stars_rounded;
    if (type.contains('APPEAL')) return Icons.gavel_outlined;
    return Icons.notifications_outlined;
  }
}
