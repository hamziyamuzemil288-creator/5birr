import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Result of one recovery upload/record pass.
class DocumentUploadResult {
  final int uploadedCount;
  final int recordedCount;

  const DocumentUploadResult({required this.uploadedCount, required this.recordedCount});

  bool get success => uploadedCount > 0 && uploadedCount == recordedCount;
}

/// Uploads document images to the private `user-documents` bucket and records
/// matching rows in `user_documents`. Shared by signup and the pending-
/// approval recovery flow so the storage path format and the insert payload
/// stay identical in both places.
class DocumentUploadService {
  DocumentUploadService._();
  static final DocumentUploadService instance = DocumentUploadService._();

  static const _bucket = 'user-documents';

  SupabaseClient get _client => Supabase.instance.client;

  /// Uploads [file] under `<uid>/<kind>_<ms>.jpg` and inserts its row.
  /// Throws on failure (the caller surfaces the real error); the insert is
  /// retried once for transient failures.
  Future<void> uploadAndRecord({
    required File file,
    required String userId,
    required String documentType,
  }) async {
    final path = '$userId/${documentType.toLowerCase()}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    await _client.storage.from(_bucket).upload(
          path,
          file,
          fileOptions: const FileOptions(upsert: true),
        );
    try {
      await _client.from('user_documents').insert({
        'user_id': userId,
        'document_type': documentType,
        'storage_path': path,
      });
    } catch (e) {
      // One retry covers a transient failure before the error surfaces.
      await _client.from('user_documents').insert({
        'user_id': userId,
        'document_type': documentType,
        'storage_path': path,
      });
    }
  }

  /// Convenience wrapper that reports how many files made it end-to-end.
  Future<DocumentUploadResult> uploadAllAndRecord({
    required List<(File, String)> files,
    required String userId,
  }) async {
    var uploaded = 0;
    var recorded = 0;
    for (final (file, type) in files) {
      try {
        await uploadAndRecord(file: file, userId: userId, documentType: type);
        uploaded++;
        recorded++;
      } catch (_) {
        // Keep going: record the files that succeeded instead of aborting.
      }
    }
    return DocumentUploadResult(uploadedCount: uploaded, recordedCount: recorded);
  }
}
