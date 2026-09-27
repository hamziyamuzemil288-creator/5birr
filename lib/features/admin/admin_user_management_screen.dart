import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/points_service.dart';
import '../../core/utils/friendly_error.dart';

class AdminUserManagementScreen extends StatefulWidget {
  const AdminUserManagementScreen({super.key});
  @override
  State<AdminUserManagementScreen> createState() => _State();
}

class _State extends State<AdminUserManagementScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String _filter = 'PENDING_APPROVAL';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('*, user_documents(id, document_type, storage_path, verification_status, agent_verdict)')
          .eq('status', _filter)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _users = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load users');
        });
      }
    }
  }

  Future<String?> _getSignedUrl(String path) async {
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(path, 300); // 5 min expiry
      return url;
    } catch (e) {
      return null;
    }
  }

  Future<void> _approve(String userId) async {
    try {
      await Supabase.instance.client.rpc('approve_user', params: {
        'p_user_id': userId,
        'p_admin_id': Supabase.instance.client.auth.currentUser!.id,
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  Future<void> _reject(String userId) async {
    final reason = await _showReasonDialog('Reject Reason');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('reject_user', params: {
        'p_user_id': userId,
        'p_admin_id': Supabase.instance.client.auth.currentUser!.id,
        'p_reason': reason,
      });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not complete that action'))));
      }
    }
  }

  Future<String?> _showReasonDialog(String title) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Enter reason...'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, ctrl.text),
              child: const Text('Submit')),
        ],
      ),
    );
  }

  void _showDocumentDialog(Map<String, dynamic> user) {
    final docs = (user['user_documents'] as List?) ?? [];
    final nationalIdDoc = docs.cast<Map<String, dynamic>?>().firstWhere(
          (d) => d != null &&
              (d['document_type'] == 'NATIONAL_ID' ||
                  d['document_type'] == 'DRIVING_LICENSE_ID' ||
                  d['document_type'] == 'PASSPORT' ||
                  d['document_type'] == 'OTHER'),
          orElse: () => null,
        );

    if (nationalIdDoc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No ID document uploaded')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => _DocumentPreviewDialog(
        documentId: nationalIdDoc['id'] as String?,
        storagePath: nationalIdDoc['storage_path'] as String,
        userName: user['full_name'] ?? 'Unknown',
        docType: nationalIdDoc['document_type'] as String?,
        verificationStatus:
            nationalIdDoc['verification_status'] as String?,
        agentVerdict: nationalIdDoc['agent_verdict'] as Map<String, dynamic>?,
      ),
    ).then((_) {
      // A verdict changes what the user sees on their own profile, so the row
      // behind the dialog is stale the moment one is written.
      if (mounted) _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User Management')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('PENDING_APPROVAL', 'Pending'),
                  _chip('APPROVED', 'Approved'),
                  _chip('REJECTED', 'Rejected'),
                ],
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: AppTheme.primaryGreen))
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline,
                                color: AppTheme.error, size: 40),
                            const SizedBox(height: 12),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 24),
                              child: Text(
                                _error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 13, color: AppTheme.error),
                              ),
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _load,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _users.isEmpty
                        ? const Center(
                            child: Text('No users found',
                                style: TextStyle(color: AppTheme.textMuted)))
                        : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _users.length,
                          itemBuilder: (_, i) {
                            final u = _users[i];
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                              u['full_name'] ?? '',
                                              style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                        ),
                                        Container(
                                          padding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 8,
                                                  vertical: 3),
                                          decoration: BoxDecoration(
                                            color: AppTheme.primaryGreen
                                                .withOpacity(0.1),
                                            borderRadius:
                                                BorderRadius.circular(12),
                                          ),
                                          child: const Text('USER',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      AppTheme.primaryGreen)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(u['phone'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.textSecondary)),
                                    const SizedBox(height: 6),
                                    _PointsLine(
                                        userId: u['id'] as String),
                                    if (u['national_id'] != null &&
                                        (u['national_id'] as String)
                                            .isNotEmpty)
                                      Text('ID: ${u['national_id']}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.textMuted)),
                                    const SizedBox(height: 8),
                                    const SizedBox(height: 8),
                                    // View National ID button
                                    OutlinedButton.icon(
                                      onPressed: () =>
                                          _showDocumentDialog(u),
                                      icon: const Icon(Icons.visibility,
                                          size: 16),
                                      label: const Text('View National ID',
                                          style: TextStyle(fontSize: 12)),
                                      style: OutlinedButton.styleFrom(
                                        padding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 6),
                                      ),
                                    ),
                                    if (_filter == 'PENDING_APPROVAL') ...[
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () =>
                                                  _approve(u['id']),
                                              style:
                                                  ElevatedButton.styleFrom(
                                                backgroundColor:
                                                    AppTheme.success,
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text('Approve',
                                                  style: TextStyle(
                                                      fontSize: 13)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _reject(u['id']),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                side: const BorderSide(
                                                    color:
                                                        AppTheme.error),
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text('Reject',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color: AppTheme
                                                          .error)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String value, String label) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _filter = value);
          _load();
        },
        selectedColor: AppTheme.primaryGreen,
        labelStyle: TextStyle(
            color: selected ? Colors.white : AppTheme.textPrimary,
            fontSize: 13),
      ),
    );
  }
}

/// Live points total for one user row (Feature 3 admin view).
class _PointsLine extends StatefulWidget {
  final String userId;
  const _PointsLine({required this.userId});
  @override
  State<_PointsLine> createState() => _PointsLineState();
}

class _PointsLineState extends State<_PointsLine> {
  int? _points;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final map = await PointsService.instance.getUserPointsBulk([widget.userId]);
      if (mounted) setState(() => _points = map[widget.userId] ?? 0);
    } catch (_) {
      if (mounted) setState(() => _points = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.stars_rounded,
            size: 15, color: AppTheme.primaryGreen),
        const SizedBox(width: 5),
        Text('Points: ${_points ?? "…"}',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary)),
      ],
    );
  }
}

class _DocumentPreviewDialog extends StatefulWidget {
  final String? documentId;
  final String storagePath;
  final String userName;
  final String? docType;
  final String? verificationStatus;
  final Map<String, dynamic>? agentVerdict;

  const _DocumentPreviewDialog({
    required this.storagePath,
    required this.userName,
    this.documentId,
    this.docType,
    this.verificationStatus,
    this.agentVerdict,
  });

  @override
  State<_DocumentPreviewDialog> createState() => _DocumentPreviewDialogState();
}

class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog> {
  String? _signedUrl;
  bool _loading = true;
  bool _reviewing = false;
  String? _reviewError;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  /// Writes the administrator's decision.
  ///
  /// This has to go through review_user_document() and never through a direct
  /// UPDATE of the column: until migration 20260927000030 the status enum had
  /// no VERIFIED value at all, and prevent_document_verification_forgery()
  /// refuses a client that changes the column without is_admin() — so an
  /// approval written by hand either failed outright or, had the enum allowed
  /// it, would have bypassed the audit trail. The RPC is admin-only server-side
  /// and writes an admin_history row plus a notification for the user.
  Future<void> _review(String decision) async {
    final id = widget.documentId;
    if (id == null || _reviewing) return;

    String? note;
    if (decision == 'REJECTED') {
      // A refusal with no reason is not actionable for the user, who is told
      // only that the document was not accepted.
      note = await showDialog<String>(
        context: context,
        builder: (_) => const _RejectReasonDialog(),
      );
      if (note == null || !mounted) return;
    }

    setState(() {
      _reviewing = true;
      _reviewError = null;
    });
    try {
      await Supabase.instance.client.rpc(
        'review_user_document',
        params: {'p_document_id': id, 'p_decision': decision, 'p_note': note},
      );
      if (!mounted) return;
      // Captured BEFORE the pop: this dialog's context is unmounted the moment
      // Navigator.pop runs, and looking a Messenger up from it afterwards
      // throws — which turned a successful approval into a crash and left the
      // verdict written with no confirmation on screen.
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        content: Text(decision == 'VERIFIED'
            ? '${widget.userName} is now verified'
            : 'Document rejected — ${widget.userName} was notified'),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _reviewing = false;
          _reviewError = friendlyError(e, context: 'Could not save the decision');
        });
      }
    }
  }

  Future<void> _loadImage() async {
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(widget.storagePath, 300);
      if (mounted) {
        setState(() {
          _signedUrl = url;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _signedUrl = null;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              title: Text('${widget.userName} — ${widget.docType ?? 'ID'}'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            // QR agent verdict (Task 4) OR the administrator's own decision.
            if (widget.verificationStatus != null)
              Container(
                width: double.infinity,
                color: _statusColor(widget.verificationStatus!)
                    .withOpacity(0.10),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(_statusIcon(widget.verificationStatus!),
                        size: 18, color: _statusColor(widget.verificationStatus!)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusLabel(widget.verificationStatus!),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: AppTheme.primaryGreen))
                  : _signedUrl != null
                      ? InteractiveViewer(
                          minScale: 0.5,
                          maxScale: 3.0,
                          child: Image.network(
                            _signedUrl!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                              child: Text('Failed to load image'),
                            ),
                          ),
                        )
                      : const Center(
                          child: Text('Document not available')),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_reviewError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        _reviewError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.error),
                      ),
                    ),
                  // The decision itself. This row did not exist: there was no
                  // admin action to take, because the status enum had no
                  // VERIFIED value — so an ID could be looked at and never
                  // approved, and the user was told "verified" regardless.
                  if (widget.documentId != null)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed:
                                _reviewing ? null : () => _review('REJECTED'),
                            icon: const Icon(Icons.close, size: 16,
                                color: AppTheme.error),
                            label: const Text('Reject',
                                style: TextStyle(
                                    fontSize: 13, color: AppTheme.error)),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                  color: AppTheme.error, width: 1.2),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed:
                                _reviewing ? null : () => _review('VERIFIED'),
                            icon: _reviewing
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white),
                                  )
                                : const Icon(Icons.verified_outlined,
                                    size: 16),
                            label: Text(_reviewing ? 'Saving…' : 'Verify',
                                style: const TextStyle(fontSize: 13)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryGreen,
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Signed URL expires in 5 minutes',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
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

/// Asks the administrator why a document was refused, and returns the reason.
///
/// Its own widget rather than a builder closure so the TextEditingController
/// has an owner that disposes it — a controller created inside a `builder:`
/// is never disposed and leaks for the life of the screen.
class _RejectReasonDialog extends StatefulWidget {
  const _RejectReasonDialog();

  @override
  State<_RejectReasonDialog> createState() => _RejectReasonDialogState();
}

class _RejectReasonDialogState extends State<_RejectReasonDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Why was this rejected?'),
      content: TextField(
        controller: _ctrl,
        maxLines: 3,
        autofocus: true,
        decoration: const InputDecoration(
            hintText: 'e.g. the photo is too dark to read the ID number'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
            onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
            child: const Text('Reject')),
      ],
    );
  }
}

// The five document states, spelled out in one place. The three the agent can
// produce and the two an administrator can (migration 20260927000030) must not
// be allowed to converge on the same colour and icon — that is the same class
// of bug as the profile tile, one screen over.
Color _statusColor(String status) {
  switch (status) {
    case 'AUTO_APPROVED':
    case 'VERIFIED':
      return AppTheme.primaryGreen;
    case 'REJECTED':
    case 'SUSPECTED_FRAUD':
      return AppTheme.error;
    default:
      return AppTheme.warning;
  }
}

IconData _statusIcon(String status) {
  switch (status) {
    case 'AUTO_APPROVED':
    case 'VERIFIED':
      return Icons.verified_outlined;
    case 'REJECTED':
      return Icons.gpp_bad_outlined;
    case 'SUSPECTED_FRAUD':
      return Icons.report_problem_outlined;
    default:
      return Icons.pending_outlined;
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'AUTO_APPROVED':
      return 'QR verified — auto-approved';
    case 'VERIFIED':
      return 'Verified by an administrator';
    case 'REJECTED':
      return 'Rejected by an administrator';
    case 'SUSPECTED_FRAUD':
      return 'Flagged: suspected fraud — review manually';
    default:
      return 'Waiting for review — nobody has looked at this yet';
  }
}
