import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';

class AdminUserManagementScreen extends StatefulWidget {
  const AdminUserManagementScreen({super.key});
  @override
  State<AdminUserManagementScreen> createState() => _State();
}

class _State extends State<AdminUserManagementScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  String _filter = 'PENDING_APPROVAL';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('*, user_documents(document_type, storage_path)')
          .eq('status', _filter)
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _users = List<Map<String, dynamic>>.from(data as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
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
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
          (d) => d != null && d['document_type'] == 'NATIONAL_ID',
          orElse: () => null,
        );

    if (nationalIdDoc == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No National ID document uploaded')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (_) => _DocumentPreviewDialog(
        storagePath: nationalIdDoc['storage_path'] as String,
        userName: user['full_name'] ?? 'Unknown',
      ),
    );
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
                                    if (u['national_id'] != null &&
                                        (u['national_id'] as String)
                                            .isNotEmpty)
                                      Text('ID: ${u['national_id']}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.textMuted)),
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

class _DocumentPreviewDialog extends StatefulWidget {
  final String storagePath;
  final String userName;

  const _DocumentPreviewDialog({
    required this.storagePath,
    required this.userName,
  });

  @override
  State<_DocumentPreviewDialog> createState() => _DocumentPreviewDialogState();
}

class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog> {
  String? _signedUrl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
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
              title: Text('${widget.userName} — National ID'),
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
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
              child: const Text(
                'Signed URL expires in 5 minutes',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
