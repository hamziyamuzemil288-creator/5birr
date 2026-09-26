import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/points_service.dart';

class AdminProviderManagementScreen extends StatefulWidget {
  const AdminProviderManagementScreen({super.key});
  @override
  State<AdminProviderManagementScreen> createState() => _State();
}

class _State extends State<AdminProviderManagementScreen> {
  List<Map<String, dynamic>> _providers = [];
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
      // Providers + their profile embed. user_documents CANNOT be embedded
      // here: user_documents.user_id references auth.users(id) (0001) and
      // profiles(id) (0031), never provider_profiles — PostgREST resolves
      // embeds only through declared FKs, so the old embed failed with
      // PGRST200 and killed the whole query. Documents are fetched
      // separately below and grouped per provider in Dart.
      final data = await Supabase.instance.client
          .from('provider_profiles')
          .select('*, profiles(full_name, phone)')
          .eq('status', _filter)
          .order('created_at', ascending: false);
      final providers = List<Map<String, dynamic>>.from(data as List);

      // Second query: documents for all listed providers' auth user ids.
      final userIds = providers
          .map((p) => p['user_id'])
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, List<Map<String, dynamic>>> docsByUser = {};
      if (userIds.isNotEmpty) {
        final docs = await Supabase.instance.client
            .from('user_documents')
            .select('id, user_id, document_type, storage_path, uploaded_at')
            .inFilter('user_id', userIds);
        for (final d in (docs as List).whereType<Map<String, dynamic>>()) {
          docsByUser.putIfAbsent(d['user_id'] as String, () => []).add(d);
        }
      }
      for (final p in providers) {
        p['user_documents'] = docsByUser[p['user_id']] ?? const [];
      }

      if (mounted) {
        setState(() {
          _providers = providers;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to load registrations: $e';
        });
      }
    }
  }

  Future<void> _approve(String providerId) async {
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {'provider_id': providerId, 'action': 'APPROVE'});
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _reject(String providerId) async {
    final reason = await _showReasonDialog('Reject Reason');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REJECT',
            'reason': reason,
          });
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _requestCorrection(String providerId) async {
    final reason = await _showReasonDialog('Correction Required');
    if (reason == null || reason.isEmpty) return;
    try {
      await Supabase.instance.client.functions.invoke('provider-approval',
          body: {
            'provider_id': providerId,
            'action': 'REQUEST_CORRECTION',
            'reason': reason,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Management')),
      body: Column(
        children: [
          // Filter chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('PENDING_APPROVAL', 'Pending'),
                  _chip('APPROVED', 'Approved'),
                  _chip('REJECTED', 'Rejected'),
                  _chip('SUSPENDED', 'Suspended'),
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
                    : _providers.isEmpty
                        ? const Center(
                            child: Text('No providers found',
                                style: TextStyle(color: AppTheme.textMuted)))
                        : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _providers.length,
                          itemBuilder: (_, i) {
                            final p = _providers[i];
                            final profile = p['profiles'] as Map<String, dynamic>?;
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
                                              p['business_name'] ?? '',
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
                                          child: Text(
                                              p['provider_type']
                                                  .toString()
                                                  .replaceAll('_', ' '),
                                              style: const TextStyle(
                                                  fontSize: 11,
                                                  color:
                                                      AppTheme.primaryGreen)),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(profile?['full_name'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.textSecondary)),
                                    Text(profile?['phone'] ?? '',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: AppTheme.textMuted)),
                                    const SizedBox(height: 6),
                                    _ProviderPointsLine(
                                        providerId: p['id'] as String),
                                    const SizedBox(height: 8),
                                    _ProviderDocumentsRow(
                                      documents:
                                          (p['user_documents'] as List?) ??
                                              const [],
                                      businessName:
                                          p['business_name']?.toString() ??
                                              '',
                                    ),
                                    if (_filter == 'PENDING_APPROVAL') ...[
                                      const SizedBox(height: 12),
                                      Row(
                                        children: [
                                          Expanded(
                                            child: ElevatedButton(
                                              onPressed: () =>
                                                  _approve(p['id']),
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
                                                  _requestCorrection(
                                                      p['id']),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),
                                              child: const Text(
                                                  'Correction',
                                                  style: TextStyle(
                                                      fontSize: 13)),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: OutlinedButton(
                                              onPressed: () =>
                                                  _reject(p['id']),
                                              style:
                                                  OutlinedButton.styleFrom(
                                                side: const BorderSide(
                                                    color:
                                                        AppTheme.error),
                                                padding:
                                                    const EdgeInsets
                                                        .symmetric(
                                                        vertical: 10),
                                              ),                                              child: const Text(
                                                  'Reject',
                                                  style: TextStyle(
                                                      fontSize: 13,
                                                      color: AppTheme
                                                          .error)),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                    // Entry point to the provider wallet.
                                    // /admin/providers/:id/wallet was routed
                                    // but nothing ever navigated to it, so the
                                    // whole admin wallet/recharge flow was
                                    // unreachable. Shown for approved
                                    // providers only — a pending or rejected
                                    // provider has no earnings to manage.
                                    if (p['status'] == 'APPROVED') ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment:
                                            Alignment.centerLeft,
                                        child:
                                            OutlinedButton.icon(
                                          onPressed: () => context.push(
                                              '/admin/providers/${p['id']}/wallet'),
                                          icon: const Icon(
                                              Icons
                                                  .account_balance_wallet_outlined,
                                              size: 16),
                                          label: const Text(
                                              'Wallet & earnings',
                                              style: TextStyle(
                                                  fontSize: 13)),
                                        ),
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

/// Live points total for one provider row (Feature 3 admin view).
class _ProviderPointsLine extends StatefulWidget {
  final String providerId;
  const _ProviderPointsLine({required this.providerId});
  @override
  State<_ProviderPointsLine> createState() => _ProviderPointsLineState();
}

class _ProviderPointsLineState extends State<_ProviderPointsLine> {
  int? _points;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final map =
          await PointsService.instance.getProviderPointsBulk([widget.providerId]);
      if (mounted) setState(() => _points = map[widget.providerId] ?? 0);
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

/// Documents summary row for one provider: shows what was uploaded and
/// opens a viewer with signed-URL previews (admin can always read the
/// user-documents bucket).
class _ProviderDocumentsRow extends StatelessWidget {
  final List<dynamic> documents;
  final String businessName;
  const _ProviderDocumentsRow({
    required this.documents,
    required this.businessName,
  });

  @override
  Widget build(BuildContext context) {
    final docs = documents
        .whereType<Map<String, dynamic>>()
        .where((d) =>
            (d['storage_path'] as String?)?.isNotEmpty == true)
        .toList();
    return Row(
      children: [
        const Icon(Icons.badge_outlined,
            size: 15, color: AppTheme.textSecondary),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            docs.isEmpty
                ? 'No documents uploaded'
                : docs.map((d) => _shortType(d['document_type'])).join(', '),
            style: const TextStyle(
                fontSize: 12, color: AppTheme.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (docs.isNotEmpty)
          TextButton.icon(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => _ProviderDocumentsDialog(
                docs: docs,
                businessName: businessName,
              ),
            ),
            icon: const Icon(Icons.visibility_outlined, size: 15),
            label: const Text('View', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6)),
          ),
      ],
    );
  }

  static String _shortType(dynamic t) {
    switch (t?.toString()) {
      case 'NATIONAL_ID':
        return 'National ID';
      case 'DRIVING_LICENSE':
        return 'Driving license';
      case 'TRADE_LICENSE':
        return 'Trade license';
      default:
        return (t ?? 'Document').toString();
    }
  }
}

class _ProviderDocumentsDialog extends StatelessWidget {
  final List<Map<String, dynamic>> docs;
  final String businessName;
  const _ProviderDocumentsDialog({required this.docs, required this.businessName});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Documents — $businessName',
          style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in docs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.image_outlined),
                title: Text(_ProviderDocumentsRow._shortType(d['document_type']),
                    style: const TextStyle(fontSize: 14)),
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => _ProviderDocPreview(
                    storagePath: d['storage_path'] as String,
                    docType:
                        _ProviderDocumentsRow._shortType(d['document_type']),
                    businessName: businessName,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}

/// Full-screen-ish preview of one document via a 5-minute signed URL.
class _ProviderDocPreview extends StatefulWidget {
  final String storagePath;
  final String docType;
  final String businessName;
  const _ProviderDocPreview({
    required this.storagePath,
    required this.docType,
    required this.businessName,
  });

  @override
  State<_ProviderDocPreview> createState() => _ProviderDocPreviewState();
}

class _ProviderDocPreviewState extends State<_ProviderDocPreview> {
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
              title: Text('${widget.businessName} — ${widget.docType}',
                  style: const TextStyle(fontSize: 16)),
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
                          child: Text(
                              'Document file is missing from storage.\nAsk the provider to re-upload.',
                              textAlign: TextAlign.center)),
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
