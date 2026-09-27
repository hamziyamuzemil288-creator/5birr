import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class UserNotificationsScreen extends StatefulWidget {
  const UserNotificationsScreen({super.key});
  @override
  State<UserNotificationsScreen> createState() =>
      _UserNotificationsScreenState();
}

class _UserNotificationsScreenState extends State<UserNotificationsScreen> {
  List<Map<String, dynamic>> _notifications = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(50);
      if (mounted) {
        setState(() {
          _notifications = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your notifications');
        });
      }
    }
  }

  Color _iconColor(String type) {
    if (type.contains('ORDER')) return AppTheme.info;
    if (type.contains('APPROVAL') || type.contains('APPROVE'))
      return AppTheme.success;
    if (type.contains('REJECT')) return AppTheme.error;
    if (type.contains('WALLET')) return AppTheme.gold;
    if (type.contains('RIDE')) return AppTheme.teal;
    return AppTheme.primaryGreen;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? _buildLoadingSkeleton()
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : _notifications.isEmpty
              ? _buildEmptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _notifications.length,
                    itemBuilder: (_, i) {
                      final n = _notifications[i];
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
                                maxLines: 2,
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

  Widget _buildLoadingSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (_, i) => Container(
        height: 64,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppTheme.creamDark.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
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
    return Icons.notifications_outlined;
  }
}
