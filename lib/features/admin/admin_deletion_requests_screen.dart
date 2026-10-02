import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/utils/friendly_error.dart';

/// The deletion queue: pending requests, oldest first, with the reason and the
/// person behind it.
///
/// Approve runs the whole flow through account-deletion-gateway, which records
/// the decision, deletes the personal data and removes the login. Reject asks
/// for a note first, because a decline with no explanation is not something
/// the person can act on.
class AdminDeletionRequestsScreen extends StatefulWidget {
  const AdminDeletionRequestsScreen({super.key});

  @override
  State<AdminDeletionRequestsScreen> createState() =>
      _AdminDeletionRequestsScreenState();
}

class _AdminDeletionRequestsScreenState
    extends State<AdminDeletionRequestsScreen> {
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = true;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  SupabaseClient get _client => Supabase.instance.client;

  Future<void> _load() async {
    try {
      final data = await _client.rpc('pending_account_deletion_requests');
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(data as List);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load requests');
      });
    }
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    final note = await _askForNote(
      title: 'Approve deletion',
      body:
          'This permanently removes ${_name(row)}’s profile, documents and '
          'login. Their orders and wallet records are kept for accounting but '
          'detached from them.\n\nThis cannot be undone.',
      confirmLabel: 'DELETE ACCOUNT',
      destructive: true,
    );
    if (note == null || !mounted) return;

    setState(() => _working = true);
    try {
      final res = await _client.functions.invoke('account-deletion-gateway',
          body: {'request_id': row['id'], 'note': _nullIfEmpty(note)});
      final data = res.data is Map ? res.data as Map : const {};
      if (res.status != 200) {
        _toast(_messageFor(data['error']?.toString() ?? 'Request failed'));
        return;
      }
      final deleted = data['deleted'];
      await _load();
      if (!mounted) return;
      final kept = deleted is Map ? deleted['orders_retained'] : null;
      // The number of files that went with it. Reported because it is the
      // half of the deletion a staff member cannot otherwise see: the rows
      // are gone either way, and the uploaded scans and photos are what
      // actually leave the platform's storage.
      final files = deleted is Map
          ? (deleted['storage_objects_removed'] as num?)?.toInt()
          : null;
      _toast('${_name(row)}’s account was deleted'
          '${kept == null ? '' : ' ($kept orders kept for accounting)'},'
          '${files == null ? '' : ' $files uploaded files removed'}.');
    } catch (e) {
      if (mounted) _toast(friendlyError(e, context: 'Could not approve'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _reject(Map<String, dynamic> row) async {
    final note = await _askForNote(
      title: 'Decline deletion',
      body:
          'Tell ${_name(row)} why. The note is sent to them with the decision, '
          'so it should be something they can act on.',
      confirmLabel: 'DECLINE',
      destructive: false,
      required: true,
    );
    if (note == null || !mounted) return;

    setState(() => _working = true);
    try {
      await _client.rpc('reject_account_deletion', params: {
        'p_request_id': row['id'],
        'p_actor_id': _client.auth.currentUser?.id,
        'p_note': note,
      });
      await _load();
      if (mounted) _toast('Request declined and the reason was sent.');
    } catch (e) {
      if (mounted) _toast(friendlyError(e, context: 'Could not decline'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  static String? _nullIfEmpty(String s) =>
      s.trim().isEmpty ? null : s.trim();

  String _name(Map<String, dynamic> row) {
    final n = (row['full_name'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    final e = (row['email'] as String?)?.trim();
    if (e != null && e.isNotEmpty) return e;
    return 'this user';
  }

  String _messageFor(String raw) {
    if (raw.contains('only_staff_with_permission')) {
      return 'You do not have the account deletion permission.';
    }
    if (raw.contains('cannot_delete_ceo')) {
      return 'The CEO account cannot be deleted.';
    }
    if (raw.contains('already_decided')) {
      return 'Someone else already decided this request.';
    }
    if (raw.contains('auth_user_delete_failed')) {
      return 'Data was deleted but the login could not be removed. Please '
          'clean up the leftover login from the Supabase dashboard.';
    }
    return 'Could not complete that. Nothing was changed.';
  }

  Future<String?> _askForNote({
    required String title,
    required String body,
    required String confirmLabel,
    required bool destructive,
    bool required = false,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body, style: const TextStyle(fontSize: 13, height: 1.4)),
            const SizedBox(height: 14),
            BirrTextField(
              label: required ? 'Reason (required)' : 'Note (optional)',
              controller: ctrl,
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (required && v.isEmpty) return;
              Navigator.of(dialogContext).pop(v);
            },
            child: Text(
              confirmLabel,
              style: TextStyle(
                  color: destructive ? AppTheme.error : AppTheme.primaryGreen,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account Deletions')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : RefreshIndicator(
              onRefresh: _load,
              // An error is shown instead of the empty state, not underneath
              // it: "no requests" and "we could not read the queue" are very
              // different things to tell a person deciding on a deletion.
              child: _error != null
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      const Icon(Icons.cloud_off, size: 48, color: AppTheme.error),
                      const SizedBox(height: 12),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(_error!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: AppTheme.error, fontSize: 13)),
                        ),
                      ),
                    ])
                  : _rows.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 120),
                          Icon(Icons.inbox_outlined,
                              size: 48, color: AppTheme.textMuted),
                          SizedBox(height: 12),
                          Center(
                            child: Text('No pending deletion requests',
                                style: TextStyle(
                                    color: AppTheme.textSecondary)),
                          ),
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _rows.length,
                          itemBuilder: (context, i) {
                            final row = _rows[i];
                            return _RequestTile(
                              row: row,
                              busy: _working,
                              onApprove: () => _approve(row),
                              onReject: () => _reject(row),
                            );
                          },
                        ),
            ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  const _RequestTile({
    required this.row,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final at = DateTime.tryParse('${row['created_at']}');
    final orders = (row['order_count'] as num?)?.toInt() ?? 0;
    final providers = (row['provider_count'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${row['full_name'] ?? row['email'] ?? 'Unknown user'}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (at != null)
                Text('${at.day}/${at.month}/${at.year}',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              if (row['email'] != null) '${row['email']}',
              if (row['phone'] != null) '${row['phone']}',
            ].join(' · '),
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 10),
          // What the decider needs before deciding: why, and what goes with it.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Tag('$orders order${orders == 1 ? '' : 's'}'),
              if (providers > 0) _Tag('$providers provider profile(s)'),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('“${row['reason'] ?? ''}”',
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary, height: 1.4)),
          ),
          if ((row['supporting_info'] as String?)?.trim().isNotEmpty == true) ...[
            const SizedBox(height: 8),
            Text('Extra: ${row['supporting_info']}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary, height: 1.4)),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onReject,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.textMuted),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Decline',
                      style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PrimaryButton(
                  label: 'APPROVE',
                  isLoading: busy,
                  onPressed: onApprove,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
    );
  }
}
