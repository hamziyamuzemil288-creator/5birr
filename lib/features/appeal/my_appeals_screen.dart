import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';

/// Both sides of an appeal, in one place.
///
/// Tab 1 — "Filed by me": every case this account submitted, its live status
/// (OPEN / RESOLVED / CLOSED), the resolution note, and the respondent's
/// answer if one came in. Previously the only feedback was the one-shot
/// success screen shown at submission time.
///
/// Tab 2 — "Filed against me": cases that named this account as respondent,
/// with the evidence photo and a Respond action that writes through
/// respond_to_appeal_case() — the only write path for a response.
class MyAppealsScreen extends StatefulWidget {
  const MyAppealsScreen({super.key});

  @override
  State<MyAppealsScreen> createState() => _MyAppealsScreenState();
}

class _MyAppealsScreenState extends State<MyAppealsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _mine = const [];
  List<Map<String, dynamic>> _against = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final mine = await client.rpc('my_appeal_cases');
      final against = await client.rpc('appeals_against_me');
      if (!mounted) return;
      setState(() {
        _mine = (mine as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _against = (against as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your appeals');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('My Appeals', style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            Tab(text: 'Filed by me (${_mine.length})'),
            Tab(text: 'Against me (${_against.length})'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/appeal'),
        backgroundColor: AppTheme.primaryGreenDark,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.outlined_flag),
        label: const Text('File a new appeal'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? _errorView()
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _caseList(_mine, respondentView: false),
                    _caseList(_against, respondentView: true),
                  ],
                ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _caseList(List<Map<String, dynamic>> cases,
      {required bool respondentView}) {
    if (cases.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            const SizedBox(height: 120),
            Center(
              child: Text(
                respondentView
                    ? 'No appeals have been filed against you'
                    : 'You have not filed any appeals yet',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
        itemCount: cases.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _caseCard(cases[i], respondentView: respondentView),
      ),
    );
  }

  Widget _caseCard(Map<String, dynamic> c, {required bool respondentView}) {
    final status = (c['status'] as String?) ?? 'OPEN';
    final statusColor = _statusColor(status);
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');
    final otherName = ((respondentView ? c['submitter_name'] : c['respondent_name'])
            as String?) ??
        (respondentView ? 'Aliob user' : 'General report');
    final responded = c['responded_at'] != null;
    final resolution = (c['resolution_note'] as String?)?.trim();

    return Card(
      color: AppTheme.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(c, respondentView: respondentView),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      otherName,
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
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (createdAt != null)
                    Text(
                      DateFormat('d MMM yyyy, HH:mm').format(createdAt),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textSecondary),
                    ),
                  const Spacer(),
                  if (responded)
                    const Text('Response sent',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primaryGreen)),
                  if (!respondentView &&
                      status != 'OPEN' &&
                      (resolution?.isNotEmpty ?? false))
                    const Text(' · Resolved',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
        'OPEN' => AppTheme.warning,
        'RESOLVED' => AppTheme.primaryGreen,
        _ => AppTheme.textSecondary,
      };

  // ── Detail ──────────────────────────────────────────────────────────────

  void _openDetail(Map<String, dynamic> c, {required bool respondentView}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _AppealDetailSheet(
        caseData: c,
        respondentView: respondentView,
        onResponded: _load,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Detail sheet
// ─────────────────────────────────────────────────────────────────────────

class _AppealDetailSheet extends StatefulWidget {
  final Map<String, dynamic> caseData;
  final bool respondentView;
  final VoidCallback onResponded;

  const _AppealDetailSheet({
    required this.caseData,
    required this.respondentView,
    required this.onResponded,
  });

  @override
  State<_AppealDetailSheet> createState() => _AppealDetailSheetState();
}

class _AppealDetailSheetState extends State<_AppealDetailSheet> {
  String? _photoUrl;
  String? _responsePhotoUrl;
  bool _loadingPhotos = true;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final client = Supabase.instance.client;
    final photoPath = widget.caseData['photo_path'] as String?;
    final responsePath = widget.caseData['response_photo_path'] as String?;
    String? photoUrl;
    String? responseUrl;
    if (photoPath != null && photoPath.isNotEmpty) {
      try {
        photoUrl = await client.storage
            .from('user-documents')
            .createSignedUrl(photoPath, 60 * 60);
      } catch (_) {
        // Readable-when-open vs private: the card still stands without it.
      }
    }
    if (responsePath != null && responsePath.isNotEmpty) {
      try {
        responseUrl = await client.storage
            .from('user-documents')
            .createSignedUrl(responsePath, 60 * 60);
      } catch (_) {
        // Same as above — a missing photo must not blank the sheet.
      }
    }
    if (!mounted) return;
    setState(() {
      _photoUrl = photoUrl;
      _responsePhotoUrl = responseUrl;
      _loadingPhotos = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.caseData;
    final status = (c['status'] as String?) ?? 'OPEN';
    final createdAt = DateTime.tryParse((c['created_at'] as String?) ?? '');
    final respondedAt = DateTime.tryParse((c['responded_at'] as String?) ?? '');
    final resolvedAt = DateTime.tryParse((c['resolved_at'] as String?) ?? '');
    final otherName = ((widget.respondentView
            ? c['submitter_name']
            : c['respondent_name']) as String?) ??
        (widget.respondentView ? 'Aliob user' : 'General report');
    final resolution = (c['resolution_note'] as String?)?.trim();
    final responseText = (c['response_text'] as String?)?.trim();
    final canRespond = widget.respondentView &&
        status == 'OPEN' &&
        c['responded_at'] == null;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
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
                    otherName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(status,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _statusColor(status))),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.respondentView
                  ? 'Filed against you'
                  : 'Filed by you  ·  ${createdAt != null ? DateFormat('d MMM yyyy, HH:mm').format(createdAt) : ''}',
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            Text('What was reported',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text((c['description'] as String?) ?? '',
                style: const TextStyle(fontSize: 14, height: 1.45)),
            const SizedBox(height: 12),
            _evidenceBlock('Evidence photo', _photoUrl, _loadingPhotos),
            if (responseText != null && responseText.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Response',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(responseText,
                  style: const TextStyle(fontSize: 14, height: 1.45)),
              if (respondedAt != null)
                Text(
                  'Sent ${DateFormat('d MMM yyyy, HH:mm').format(respondedAt)}',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                ),
              _evidenceBlock(
                  'Response evidence', _responsePhotoUrl, _loadingPhotos),
            ],
            if (status != 'OPEN') ...[
              const SizedBox(height: 16),
              Text('Outcome',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 6),
              Text(
                status == 'RESOLVED' ? 'Resolved' : 'Closed',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppTheme.primaryGreen),
              ),
              if (resolution != null && resolution.isNotEmpty)
                Text(resolution,
                    style: const TextStyle(fontSize: 14, height: 1.45)),
              if (resolvedAt != null)
                Text(
                  DateFormat('d MMM yyyy, HH:mm').format(resolvedAt),
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                ),
            ],
            const SizedBox(height: 20),
            if (canRespond)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryGreenDark,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => _respond(c),
                  child: const Text('Respond to this report',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _respond(Map<String, dynamic> c) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: _RespondSheet(caseData: c),
      ),
    );
    if (ok == true && mounted) {
      widget.onResponded();
      Navigator.pop(context); // close the detail sheet after a successful reply
    }
  }

  Widget _evidenceBlock(String label, String? url, bool loading) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: LinearProgressIndicator(color: AppTheme.primaryGreen),
      );
    }
    if (url == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              url,
              height: 180,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Text('Photo unavailable',
                  style:
                      TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }

  Color _statusColor(String status) => switch (status) {
        'OPEN' => AppTheme.warning,
        'RESOLVED' => AppTheme.primaryGreen,
        _ => AppTheme.textSecondary,
      };
}

// ─────────────────────────────────────────────────────────────────────────
// Respond sheet — the write path
// ─────────────────────────────────────────────────────────────────────────

class _RespondSheet extends StatefulWidget {
  final Map<String, dynamic> caseData;

  const _RespondSheet({required this.caseData});

  @override
  State<_RespondSheet> createState() => _RespondSheetState();
}

class _RespondSheetState extends State<_RespondSheet> {
  final _formKey = GlobalKey<FormState>();
  final _textCtrl = TextEditingController();
  XFile? _photo;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final fromCamera =
          await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 70, maxWidth: 1600);
      if (fromCamera != null) {
        setState(() => _photo = fromCamera);
        return;
      }
      final fromGallery =
          await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1600);
      if (fromGallery != null) setState(() => _photo = fromGallery);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              friendlyError(e, context: 'Could not open the camera'))));
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      setState(() => _error = 'You need to be signed in to respond.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      String? photoPath;
      if (_photo != null) {
        photoPath =
            '${user.id}/appeal_response_${DateTime.now().millisecondsSinceEpoch}.jpg';
        await client.storage.from('user-documents').upload(
              photoPath,
              File(_photo!.path),
              fileOptions: const FileOptions(upsert: true),
            );
      }
      await client.rpc('respond_to_appeal_case', params: {
        'p_case_id': widget.caseData['id'],
        'p_response_text': _textCtrl.text.trim(),
        if (photoPath != null) 'p_response_photo_path': photoPath,
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = friendlyError(e, context: 'Could not send your response');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
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
            const Text('Your response',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            const Text(
              'Staff review your reply alongside the original report. '
              'You can attach a photo as evidence.',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _textCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Explain your side of what happened',
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Please write a response'
                  : null,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _submitting ? null : _pickPhoto,
              icon: const Icon(Icons.add_a_photo_outlined, size: 18),
              label: Text(_photo == null
                  ? 'Attach a photo (optional)'
                  : 'Photo attached — tap to change'),
            ),
            if (_photo != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(_photo!.path),
                      height: 140, width: double.infinity, fit: BoxFit.cover),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_error!,
                    style:
                        const TextStyle(color: AppTheme.error, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreenDark,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Send response',
                        style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
