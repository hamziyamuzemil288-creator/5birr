import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';

class AdminNotificationSendScreen extends StatefulWidget {
  const AdminNotificationSendScreen({super.key});
  @override
  State<AdminNotificationSendScreen> createState() => _AdminNotificationSendScreenState();
}

class _AdminNotificationSendScreenState extends State<AdminNotificationSendScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  String _targetType = 'ALL'; // ALL, ROLE, SPECIFIC
  String _targetRole = 'USER';
  String _targetUserId = '';
  bool _sending = false;
  List<Map<String, dynamic>> _recentNotifications = [];
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final data = await Supabase.instance.client
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(20);
      _recentNotifications = List<Map<String, dynamic>>.from(data as List);
    } catch (_) {}
    if (mounted) setState(() => _loadingHistory = false);
  }

  Future<void> _send() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _sending = true);
    try {
      final client = Supabase.instance.client;

      if (_targetType == 'ALL') {
        // Broadcast: insert one notification per user
        final users = await client.from('profiles').select('id');
        final userIds = (users as List).map((u) => u['id'] as String).toList();

        final notifications = userIds.map((uid) => {
          'user_id': uid,
          'title': _titleCtrl.text.trim(),
          'body': _bodyCtrl.text.trim(),
          'type': 'ADMIN_ANNOUNCEMENT',
        }).toList();

        // Batch insert (Supabase supports array insert)
        if (notifications.isNotEmpty) {
          await client.from('notifications').insert(notifications);
        }
      } else if (_targetType == 'ROLE') {
        // Role-based: roles live in user_roles (Task 7 fix — the old query
        // filtered profiles.role, a column that does not exist, so every
        // role-targeted broadcast silently sent to nobody).
        final users = await client
            .from('user_roles')
            .select('user_id')
            .eq('role', _targetRole);
        final userIds = (users as List).map((u) => u['user_id'] as String).toList();

        final notifications = userIds.map((uid) => {
          'user_id': uid,
          'title': _titleCtrl.text.trim(),
          'body': _bodyCtrl.text.trim(),
          'type': 'ADMIN_ANNOUNCEMENT',
        }).toList();

        if (notifications.isNotEmpty) {
          await client.from('notifications').insert(notifications);
        }

        // Broadcast bookkeeping (admin_notification_broadcasts, 0024).
        try {
          await client.from('admin_notification_broadcasts').insert({
            'admin_id': client.auth.currentUser!.id,
            'title': _titleCtrl.text.trim(),
            'body': _bodyCtrl.text.trim(),
            'target_type': 'ROLE',
            'target_role': _targetRole,
            'delivered_count': notifications.length,
          });
        } catch (_) {
          // Audit row is best-effort; delivery already succeeded.
        }
      } else {
        // Direct to specific user
        await client.from('notifications').insert({
          'user_id': _targetUserId,
          'title': _titleCtrl.text.trim(),
          'body': _bodyCtrl.text.trim(),
          'type': 'ADMIN_DIRECT',
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notification sent!'), backgroundColor: AppTheme.success),
        );
        _titleCtrl.clear();
        _bodyCtrl.clear();
        _loadHistory();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send Notifications')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Form
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Compose Notification',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
                    const SizedBox(height: 12),

                    // Target selector
                    const Text('Send to', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                    const SizedBox(height: 6),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'ALL', label: Text('All Users', style: TextStyle(fontSize: 11))),
                        ButtonSegment(value: 'ROLE', label: Text('By Role', style: TextStyle(fontSize: 11))),
                        ButtonSegment(value: 'SPECIFIC', label: Text('Direct', style: TextStyle(fontSize: 11))),
                      ],
                      selected: {_targetType},
                      onSelectionChanged: (s) => setState(() => _targetType = s.first),
                      style: SegmentedButton.styleFrom(
                        selectedBackgroundColor: AppTheme.primaryGreen,
                        selectedForegroundColor: Colors.white,
                      ),
                    ),

                    if (_targetType == 'ROLE') ...[
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(value: 'USER', label: Text('Users', style: TextStyle(fontSize: 11))),
                          ButtonSegment(value: 'SERVICE_PROVIDER', label: Text('Service', style: TextStyle(fontSize: 11))),
                          ButtonSegment(value: 'VEHICLE_PROVIDER', label: Text('Vehicle', style: TextStyle(fontSize: 11))),
                        ],
                        selected: {_targetRole},
                        onSelectionChanged: (s) => setState(() => _targetRole = s.first),
                        style: SegmentedButton.styleFrom(
                          selectedBackgroundColor: AppTheme.primaryGreen,
                          selectedForegroundColor: Colors.white,
                        ),
                      ),
                    ],

                    if (_targetType == 'SPECIFIC') ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        decoration: const InputDecoration(
                          labelText: 'User ID',
                          border: OutlineInputBorder(),
                          hintText: 'Enter user UUID',
                        ),
                        onChanged: (v) => _targetUserId = v.trim(),
                        validator: (v) => _targetType == 'SPECIFIC' && (v == null || v.isEmpty) ? 'Required' : null,
                      ),
                    ],

                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _titleCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Title',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _bodyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Message body',
                        border: OutlineInputBorder(),
                        alignLabelWithHint: true,
                      ),
                      maxLines: 4,
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _sending ? null : _send,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryGreen,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _sending
                            ? const SizedBox(
                                width: 20, height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Send Notification'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Recent notifications
          const Text('Recent Notifications',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textPrimary)),
          const SizedBox(height: 8),
          if (_loadingHistory)
            const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          else if (_recentNotifications.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No notifications sent yet', style: TextStyle(color: AppTheme.textMuted)),
              ),
            )
          else
            ..._recentNotifications.map((n) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.primaryGreen.withOpacity(0.1),
                      child: const Icon(Icons.notifications, size: 18, color: AppTheme.primaryGreen),
                    ),
                    title: Text(n['title'] ?? '',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    subtitle: Text(n['body'] ?? '',
                        style: const TextStyle(fontSize: 11, color: AppTheme.textMuted), maxLines: 2),
                    trailing: Text(
                      (n['type'] ?? '').toString().replaceAll('_', ' '),
                      style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
                    ),
                  ),
                )),
        ],
      ),
    );
  }
}
