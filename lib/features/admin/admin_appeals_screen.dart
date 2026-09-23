import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';

/// Admin queue for appeal / spam-report cases submitted from the user-side
/// appeal form (`appeal_cases`). Read + resolve: an admin (or support staff)
/// opens a case, views the evidence photo via a signed URL, and marks it
/// RESOLVED or CLOSED with an optional note. Resolutions are audited by the
/// `trg_appeal_case_resolved` trigger (admin_actions).
class AdminAppealsScreen extends StatefulWidget {
  const AdminAppealsScreen({super.key});

  @override
  State<AdminAppealsScreen> createState() => _AdminAppealsScreenState();
}

class _AdminAppealsScreenState extends State<AdminAppealsScreen> {
  static const _statuses = ['OPEN', 'RESOLVED', 'CLOSED', 'ALL'];

  String _filter = 'OPEN';
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _cases = [];

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
      final client = Supabase.instance.client;
      // appeal_cases.user_id references auth.users(id) — no FK to profiles,
      // so reporter names are joined in Dart (same pattern as tickets).
      var query = client.from('appeal_cases').select('*');
      if (_filter != 'ALL') query = query.eq('status', _filter);
      final rows = await query.order('created_at', ascending: false).limit(200);
      final cases = (rows as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      final userIds = cases
          .map((c) => c['user_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      final Map<String, Map<String, dynamic>> profilesById = {};
      if (userIds.isNotEmpty) {
        final profiles = await client
            .from('profiles')
            .select('id, full_name, phone')
            .inFilter('id', userIds);
        for (final p in (profiles as List)) {
          final pm = Map<String, dynamic>.from(p as Map);
          profilesById[pm['id'] as String] = pm;
        }
      }
      for (final c in cases) {
        c['reporter'] = profilesById[c['user_id']];
      }

      if (!mounted) return;
      setState(() {
        _cases = cases;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load appeals: $e';
      });
    }
  }

  Future<void> _updateStatus(Map<String, dynamic> appealCase, String status,
      {String? note}) async {
    try {
      await Supabase.instance.client.from('appeal_cases').update({
        'status': status,
        'resolved_by': Supabase.instance.client.auth.currentUser?.id,
        'resolved_at': DateTime.now().toIso8601String(),
        if (note != null && note.isNotEmpty) 'resolution_note': note,
      }).eq('id', appealCase['id'] as String);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Appeal marked $status')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e')));
    }
  }

  Future<void> _resolveWithNote(Map<String, dynamic> appealCase, String status) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Mark ${status.toLowerCase()}'),
        content: TextField(
          controller: ctrl,
          maxLines: 3,
          autofocus: true,
          decoration: const InputDecoration(
              hintText: 'Optional note: what was decided or done?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(status == 'RESOLVED' ? 'Resolve' : 'Close')),
        ],
      ),
    );
    if (ok != true) return;
    await _updateStatus(appealCase, status, note: ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Appeals',
            style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          // Status filter chips
          Container(
            width: double.infinity,
            color: AppTheme.primaryGreenDark,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _statuses
                    .map((s) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(s),
                            selected: _filter == s,
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _filter == s
                                  ? AppTheme.primaryGreenDark
                                  : Colors.white,
                            ),
                            selectedColor: Colors.white,
                            backgroundColor: Colors.white.withOpacity(0.15),
                            side: BorderSide.none,
                            onSelected: (_) {
                              setState(() => _filter = s);
                              _load();
                            },
                          ),
                        ))
                    .toList(),
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
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: AppTheme.error)),
                              const SizedBox(height: 12),
                              FilledButton(
                                  onPressed: _load, child: const Text('Retry')),
                            ],
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _cases.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 120),
                                  Center(
                                    child: Text(
                                      'No appeals here',
                                      style: TextStyle(
                                          color: AppTheme.textSecondary),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(12),
                                itemCount: _cases.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, i) =>
                                    _buildCard(_cases[i]),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> c) {
    final reporter = c['reporter'] as Map<String, dynamic>?;
    final status = (c['status'] as String?) ?? 'OPEN';
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');
    final statusColor = switch (status) {
      'OPEN' => AppTheme.warning,
      'RESOLVED' => AppTheme.primaryGreen,
      _ => AppTheme.textSecondary,
    };

    return Card(
      color: AppTheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(c),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (reporter?['full_name'] as String?) ?? 'Unknown reporter',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(status,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: statusColor)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                (c['description'] as String?) ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Text(
                createdAt != null
                    ? DateFormat('d MMM yyyy, HH:mm').format(createdAt)
                    : '',
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openDetail(Map<String, dynamic> c) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AppealDetailSheet(caseData: c, onStatus: _updateStatus),
    );
  }
}

class _AppealDetailSheet extends StatefulWidget {
  final Map<String, dynamic> caseData;
  final Future<void> Function(Map<String, dynamic>, String, {String? note}) onStatus;

  const _AppealDetailSheet({required this.caseData, required this.onStatus});

  @override
  State<_AppealDetailSheet> createState() => _AppealDetailSheetState();
}

class _AppealDetailSheetState extends State<_AppealDetailSheet> {
  String? _photoUrl;
  bool _photoLoading = true;
  String? _photoError;

  @override
  void initState() {
    super.initState();
    _loadPhoto();
  }

  Future<void> _loadPhoto() async {
    try {
      final url = await Supabase.instance.client.storage
          .from('user-documents')
          .createSignedUrl(
              widget.caseData['photo_path'] as String, 60 * 60);
      if (!mounted) return;
      setState(() {
        _photoUrl = url;
        _photoLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _photoError = 'Photo unavailable';
        _photoLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.caseData;
    final reporter = c['reporter'] as Map<String, dynamic>?;
    final status = (c['status'] as String?) ?? 'OPEN';
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtrl) => SingleChildScrollView(
        controller: scrollCtrl,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    (reporter?['full_name'] as String?) ?? 'Unknown reporter',
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: (status == 'OPEN'
                            ? AppTheme.warning
                            : status == 'RESOLVED'
                                ? AppTheme.primaryGreen
                                : AppTheme.textSecondary)
                        .withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: status == 'OPEN'
                              ? AppTheme.warning
                              : status == 'RESOLVED'
                                  ? AppTheme.primaryGreen
                                  : AppTheme.textSecondary)),
                ),
              ],
            ),
            if (createdAt != null) ...[
              const SizedBox(height: 4),
              Text(DateFormat('d MMM yyyy, HH:mm').format(createdAt),
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textSecondary)),
            ],
            const SizedBox(height: 16),

            // Evidence photo (private bucket → signed URL)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 220,
                width: double.infinity,
                child: _photoLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppTheme.primaryGreen))
                    : _photoError != null
                        ? Container(
                            color: AppTheme.surface,
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.broken_image_outlined,
                                      color: AppTheme.textSecondary),
                                  const SizedBox(height: 6),
                                  Text(_photoError!,
                                      style: const TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 12)),
                                ],
                              ),
                            ),
                          )
                        : Image.network(_photoUrl!, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(height: 16),

            const Text('Report',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            SelectableText(
              (c['description'] as String?) ?? '',
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
            ),
            const SizedBox(height: 16),

            const Text('Contact',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            _contactRow(Icons.phone, (c['phone'] as String?) ?? '—'),
            if (((c['email'] as String?) ?? '').isNotEmpty)
              _contactRow(Icons.email_outlined, c['email'] as String),
            _contactRow(Icons.badge_outlined,
                (reporter?['phone'] as String?) ?? '—',
                label: 'Account phone'),

            const SizedBox(height: 16),
            if (((c['resolution_note'] as String?) ?? '').isNotEmpty) ...[
              const Text('Resolution note',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  c['resolution_note'] as String,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
            ],

            if (status == 'OPEN') ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onStatus(c, 'CLOSED');
                      },
                      child: const Text('Close case'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.primaryGreenDark),
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onStatus(c, 'RESOLVED');
                      },
                      child: const Text('Resolve'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _contactRow(IconData icon, String value, {String? label}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(label != null ? '$label: ' : '',
              style: const TextStyle(
                  fontSize: 13, color: AppTheme.textSecondary)),
          Expanded(
            child: SelectableText(value,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textPrimary)),
          ),
        ],
      ),
    );
  }
}
