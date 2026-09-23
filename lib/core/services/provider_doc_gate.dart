import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import 'document_upload_service.dart';

/// Document-verification gate (Task 7 item 3): providers no longer upload
/// documents at signup. Instead the FIRST protected action — uploading a
/// product/vehicle, or claiming/accepting an order — requires the docs.
/// By then the provider has recharged their wallet (the activation gate
/// already sits on the same screens), matching the intended business flow:
/// signup → recharge → documents → sell.
class ProviderDocGate {
  ProviderDocGate._();
  static final ProviderDocGate instance = ProviderDocGate._();

  SupabaseClient get _client => Supabase.instance.client;

  /// True when the signed-in provider has no documents missing. Everything
  /// except SUSPECTED_FRAUD counts: AUTO_APPROVED (QR agent) and
  /// MANUAL_REVIEW (queued for admin) both satisfy the gate — a document
  /// awaiting review must not block the provider from working.
  static const _required = ['NATIONAL_ID', 'DRIVING_LICENSE'];

  Future<bool> isSatisfied({String? userId}) async {
    final uid = userId ?? _client.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      final rows = await _client
          .from('user_documents')
          .select('document_type, verification_status')
          .eq('user_id', uid);
      final have = <String>{};
      for (final r in rows as List) {
        final status = (r['verification_status'] as String?) ?? 'MANUAL_REVIEW';
        if (status == 'SUSPECTED_FRAUD') continue;
        have.add(r['document_type'] as String);
      }
      return _required.every(have.contains);
    } catch (_) {
      // A failed check must not permanently lock the provider out: fail
      // open here, the server-side RPC provider_docs_satisfied() re-checks
      // on protected writes.
      return true;
    }
  }

  /// Blocking reason shown before opening the upload sheet.
  static const blockingMessage =
      'Verify your identity documents to continue. Your wallet is safe — '
      'this is a one-time ID check (National ID + Driving License).';

  /// Runs the upload + QR-verification flow inline. Returns true when the
  /// gate is satisfied (either already, or after successful uploads).
  ///
  /// Reuses the exact signup pipeline: DocumentUploadService.uploadAndRecord
  /// (private user-documents bucket + user_documents row), then the
  /// document-verify Edge Function for QR-capable ID types.
  Future<bool> ensureDocuments(BuildContext context) async {
    if (await isSatisfied()) return true;

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DocUploadSheet(),
    );
    return ok == true;
  }
}

class _DocUploadSheet extends StatefulWidget {
  const _DocUploadSheet();

  @override
  State<_DocUploadSheet> createState() => _DocUploadSheetState();
}

class _DocUploadSheetState extends State<_DocUploadSheet> {
  File? _nationalId;
  File? _license;
  bool _uploading = false;
  String? _error;
  String? _outcome;

  final _picker = ImagePicker();

  Future<void> _pick(bool isNationalId) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() {
      if (isNationalId) {
        _nationalId = File(picked.path);
      } else {
        _license = File(picked.path);
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_nationalId == null || _license == null) {
      setState(() => _error = 'Both documents are required.');
      return;
    }
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser!.id;

      await DocumentUploadService.instance.uploadAndRecord(
        file: _nationalId!,
        userId: userId,
        documentType: 'NATIONAL_ID',
      );
      await DocumentUploadService.instance.uploadAndRecord(
        file: _license!,
        userId: userId,
        documentType: 'DRIVING_LICENSE',
      );

      // QR verification agent (Task 4) on the National ID. Best-effort:
      // any failure keeps the MANUAL_REVIEW default — never blocks.
      String? outcome;
      try {
        final docs = await client
            .from('user_documents')
            .select('id')
            .eq('user_id', userId)
            .eq('document_type', 'NATIONAL_ID')
            .order('uploaded_at', ascending: false)
            .limit(1);
        if ((docs as List?)?.isNotEmpty ?? false) {
          final docId = (docs as List).first['id'] as String;
          final res = await client.functions
              .invoke('document-verify', body: {'document_id': docId});
          final status = (res.data as Map<String, dynamic>?)?['status'];
          if (status == 'AUTO_APPROVED') {
            outcome = 'ID verified automatically — you are all set.';
          } else if (status == 'SUSPECTED_FRAUD') {
            outcome =
                'We could not verify your document automatically. It was '
                'flagged for a manual check — our team will review it shortly.';
          } else {
            outcome =
                'No readable QR found. Sent to our team for a manual check '
                'instead — nothing is blocked.';
          }
        }
      } catch (_) {
        // Agent unreachable → manual review (default state).
      }

      if (!mounted) return;
      setState(() {
        _uploading = false;
        _outcome = outcome ?? 'Documents received. You can continue.';
      });
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _error = 'Upload failed: ${e.toString().split('\n').first}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Verify your documents'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(ProviderDocGate.blockingMessage),
            const SizedBox(height: 16),
            _slot('National ID (with QR side)', _nationalId, true),
            const SizedBox(height: 12),
            _slot('Driving License', _license, false),
            if (_outcome != null) ...[
              const SizedBox(height: 12),
              Text(_outcome!,
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.success)),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  style: const TextStyle(fontSize: 13, color: AppTheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _uploading ? null : () => Navigator.pop(context, false),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: (_uploading || _nationalId == null || _license == null)
              ? null
              : _submit,
          child: Text(_uploading ? 'Uploading…' : 'Upload & verify'),
        ),
      ],
    );
  }

  Widget _slot(String label, File? file, bool isNationalId) {
    return InkWell(
      onTap: _uploading ? null : () => _pick(isNationalId),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.cardBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              file == null ? Icons.add_a_photo_outlined : Icons.check_circle,
              color: file == null ? AppTheme.textMuted : AppTheme.success,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                file == null ? label : 'Selected ✓',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
