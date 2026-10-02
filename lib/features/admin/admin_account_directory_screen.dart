import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import 'admin_staff_screen.dart' show TypedConfirmDialog;

/// The CEO account directory: every registered account in one place, with
/// the one act nobody below the CEO may perform — deleting an account
/// outright.
///
/// WHERE THE DATA COMES FROM
/// -------------------------
/// One RPC, ceo_account_directory(), rather than a profiles scan from the
/// client. RLS on profiles correctly stops at the account's own row plus
/// administrator reads; a client-side scan would have needed that widened to
/// "the CEO may read every phone number", a policy every future migration
/// would then have to remember. The RPC runs definer-side with the CEO check
/// on the caller's auth.uid(), so the sensitive payload only ever exists for
/// a CEO — and a non-CEO who reaches this route (navigation is not security)
/// gets the refusal, not an empty list.
///
/// WHERE THE DELETE GOES
/// ---------------------
/// Through ceo_delete_user_account(), which re-checks CEO authority, refuses
/// self-deletion, requires a reason, records it in admin_actions, and then
/// calls THE shared cascade — delete_user_account(), the same function the
/// account-deletion approval flow runs through account-deletion-gateway.
/// Nothing here deletes anything itself: no second implementation exists to
/// drift from the first.
///
/// WHY THERE IS NO APPROVAL STEP FOR THE CEO
/// -----------------------------------------
/// The request flow exists so a user's deletion is never instant self-service
/// and never one staff member's unreviewed word. The CEO IS the authority
/// those requests wait for; a request written and approved by the same hand
/// would be ceremony, not control. What the flow guarantees beyond the
/// cascade — the traceable decision — is preserved by the typed confirmation,
/// the mandatory reason, and the audit rows both sides write.
class AdminAccountDirectoryScreen extends ConsumerStatefulWidget {
  const AdminAccountDirectoryScreen({super.key});

  @override
  ConsumerState<AdminAccountDirectoryScreen> createState() =>
      _AdminAccountDirectoryScreenState();
}

class _AdminAccountDirectoryScreenState
    extends ConsumerState<AdminAccountDirectoryScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  bool _loading = true;
  bool _isCeoAuthority = false;
  String? _error;
  List<Map<String, dynamic>> _rows = const [];

  final _searchCtrl = TextEditingController();

  /// The deletion reason. Owned by the State rather than created inside the
  /// dialog: a controller disposed the moment showDialog returns is one pop
  /// animation away from being disposed under a TextField that still holds
  /// it, and this one is reused for every deletion.
  final _reasonCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (!_tabs.indexIsChanging) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;

      // Server truth first. The Dart gate below only avoids rendering a
      // workspace that would be refused; is_ceo_authority() (is_ceo() OR
      // is_super_admin()) is the actual boundary, re-derived on every call
      // the screen makes.
      final allowed = await client.rpc('is_ceo_authority');
      if (allowed != true) {
        if (!mounted) return;
        setState(() {
          _isCeoAuthority = false;
          _loading = false;
        });
        return;
      }

      final roleFilter = switch (_tabs.index) {
        1 => 'user',
        2 => 'provider',
        3 => 'staff',
        _ => 'all',
      };
      final res = await client.rpc('ceo_account_directory', params: {
        'p_search': _searchCtrl.text.trim().isEmpty
            ? null
            : _searchCtrl.text.trim(),
        'p_role': roleFilter,
        'p_limit': 200,
      });

      if (!mounted) return;
      setState(() {
        _isCeoAuthority = true;
        _rows = (res as List? ?? const [])
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList(growable: false);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load the directory');
      });
    }
  }

  /// The destructive path. Reason first, typed confirmation last, so the
  /// final gate is the physical act of typing — the same order of intent the
  /// staff deletion uses (TypedConfirmDialog), with the reason the cascade's
  /// audit trail needs collected before it.
  Future<void> _deleteRow(Map<String, dynamic> row) async {
    final name = '${row['full_name'] ?? 'this account'}';
    final userId = row['user_id'] as String;

    // 1. The reason. A deletion with no stated why is unreviewable, and the
    //    RPC refuses anything shorter than ten characters — asking here
    //    means the CEO never meets that refusal with work already typed.
    _reasonCtrl.clear();
    String? reasonError;
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          scrollable: true,
          title: Text('Why delete $name\'s account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Recorded permanently with the deletion. At least ten '
                'characters, so the trail says something.',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonCtrl,
                autofocus: true,
                maxLines: 3,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: 'Reason',
                  errorText: reasonError,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final v = _reasonCtrl.text.trim();
                if (v.length < 10) {
                  setDialogState(() =>
                      reasonError = 'Say a little more — at least ten characters.');
                  return;
                }
                Navigator.of(dialogContext).pop(v);
              },
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;

    // 2. The typed confirmation — the irreversible step gets the irreversible
    //    word, matching the staff-delete pattern exactly.
    final typed = await showDialog<String>(
      context: context,
      builder: (dialogContext) => TypedConfirmDialog(
        title: 'Delete $name permanently?',
        body: 'This removes their login account and everything that belongs '
            'to it: profile, roles, provider profile and listings, documents, '
            'favourites and notifications. Their orders, rides, reviews and '
            'the audit trail remain as records with the person detached.\n\n'
            'It cannot be undone.',
        confirmWord: 'DELETE',
        actionLabel: 'Delete forever',
      ),
    );
    if (typed != 'DELETE' || !mounted) return;

    // 3. Execute through the shared cascade. Every guard is re-checked
    //    server-side; the client errors below only translate the refusals
    //    the CEO can actually trigger.
    try {
      final res = await Supabase.instance.client.rpc('ceo_delete_user_account',
          params: {'p_target_user_id': userId, 'p_reason': reason});
      if (!mounted) return;
      // How many uploaded files went with the account. The server folds it
      // into the same object it already returned, so this costs no extra
      // round trip -- and it is the part of the deletion the operator cannot
      // see any other way, because the rows are gone whether or not the
      // photos are.
      final removed = res is Map
          ? (res['storage_objects_removed'] as num?)?.toInt()
          : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$name\'s account was deleted'
              '${removed == null ? '' : ' — $removed uploaded files removed'}'),
        ),
      );
      _load();
    } catch (e) {
      if (!mounted) return;
      final raw = e.toString();
      String message;
      if (raw.contains('CANNOT_DELETE_CEO')) {
        message =
            'This account holds the CEO authority and cannot be deleted '
            'here. Admin accounts are removed through Staff Assignment.';
      } else if (raw.contains('CANNOT_DELETE_SELF')) {
        message = 'You cannot delete your own account here.';
      } else if (raw.contains('REASON_REQUIRED')) {
        message = 'A reason of at least ten characters is required.';
      } else if (raw.contains('CEO_DELETE_IS_CEO_ONLY')) {
        message = 'Only the CEO can delete accounts.';
      } else {
        message = friendlyError(e, context: 'Could not delete the account');
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);

    // Fast path for a non-CEO: no workspace at all, and no wasted RPC. The
    // server-side check in _load() remains the real gate for everybody else.
    if (!auth.isCeo && !_isCeoAuthority) {
      return Scaffold(
        appBar: AppBar(title: const Text('All Users & Providers')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This directory is for the CEO account only.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('All Users & Providers',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        elevation: 0,
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          indicatorColor: AppTheme.gold,
          tabs: const [
            Tab(text: 'All'),
            Tab(text: 'Users'),
            Tab(text: 'Providers'),
            Tab(text: 'Staff'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _load(),
              decoration: InputDecoration(
                hintText: 'Search name, phone or email',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: 'Search',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _load,
                ),
                filled: true,
                fillColor: AppTheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _error != null
                    ? _ErrorState(message: _error!, onRetry: _load)
                    : _rows.isEmpty
                        ? const Center(
                            child: Text('No accounts match.',
                                style:
                                    TextStyle(color: AppTheme.textSecondary)))
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.separated(
                              itemCount: _rows.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) =>
                                  _DirectoryRow(
                                      row: _rows[i],
                                      onDelete: () => _deleteRow(_rows[i])),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _DirectoryRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onDelete;

  const _DirectoryRow({required this.row, required this.onDelete});

  bool get _isSelf =>
      row['user_id'] == Supabase.instance.client.auth.currentUser?.id;

  bool get _isCeoTarget =>
      (row['roles'] as List? ?? const []).map((e) => e.toString()).contains('CEO');

  @override
  Widget build(BuildContext context) {
    final roles = (row['roles'] as List? ?? const []).map((e) => e.toString()).toList();
    final isProvider = row['is_provider'] == true;
    final status = '${row['status'] ?? ''}';
    final created = '${row['created_at'] ?? ''}'.split('T').first;

    // The CEO's own row: no delete button (the server refuses self-deletion
    // and CEO targets, and offering a button that can only ever refuse is a
    // dead end, not a control). Every other row — admins included, which is
    // the point — offers the deletion, with the real authority enforced
    // server-side.
    final canDelete = !_isSelf && !_isCeoTarget;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: Text('${row['full_name'] ?? 'Unnamed'}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            '${row['phone'] ?? 'no phone'}'
            '${(row['email'] as String?)?.isNotEmpty == true ? ' · ${row['email']}' : ''}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              _chip(_statusLabel(status), _statusColor(status)),
              if (roles.isEmpty)
                _chip('no role', AppTheme.textMuted)
              else
                for (final r in roles) _chip(r, AppTheme.primaryGreen),
              if (isProvider)
                _chip('${row['order_count'] ?? 0} orders', AppTheme.gold),
              if (row['is_staff'] == true) _chip('staff row', AppTheme.teal),
            ],
          ),
          const SizedBox(height: 2),
          Text('Registered $created',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ],
      ),
      trailing: canDelete
          ? IconButton(
              tooltip: 'Delete account',
              icon: const Icon(Icons.person_remove_outlined,
                  color: AppTheme.error),
              onPressed: onDelete,
            )
          : _isSelf
              ? const Tooltip(
                  message: 'This is your account',
                  child: Icon(Icons.person, color: AppTheme.textMuted),
                )
              : const Tooltip(
                  message: 'The CEO account cannot be deleted from the app',
                  child: Icon(Icons.shield_outlined,
                      color: AppTheme.textMuted),
                ),
    );
  }

  String _statusLabel(String s) => switch (s) {
        'PENDING_APPROVAL' => 'pending',
        'APPROVED' => 'approved',
        'REJECTED' => 'rejected',
        'SUSPENDED' => 'suspended',
        'INACTIVE' => 'inactive',
        '' => 'unknown',
        _ => s.toLowerCase(),
      };

  Color _statusColor(String s) => switch (s) {
        'APPROVED' => AppTheme.success,
        'PENDING_APPROVAL' => AppTheme.gold,
        _ => AppTheme.error,
      };

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 10, color: color, fontWeight: FontWeight.w600)),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 40, color: AppTheme.textMuted),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
