import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'location_service.dart';

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

  /// One liveness fix is shared by every document in the same upload burst.
  /// Re-asking the OS per file would re-trigger the permission dialog and add
  /// a GPS cold-start to each document in a multi-document submission, for a
  /// position that is the same place within seconds.
  static const _fixReuseWindow = Duration(minutes: 2);

  Map<String, dynamic>? _cachedLiveness;
  DateTime? _cachedLivenessAt;

  SupabaseClient get _client => Supabase.instance.client;

  /// The columns written alongside every document row: where the device was
  /// when the document was submitted.
  ///
  /// This is a liveness SIGNAL, not a requirement. GPS off, permission
  /// denied, or a slow fix records UNAVAILABLE and the upload goes through —
  /// blocking ID submission on a location fix would lock out exactly the
  /// users on poor signal, and would break verification outright for them.
  /// Nothing server-side gates on it either.
  Future<Map<String, dynamic>> _captureLiveness() async {
    final cached = _cachedLiveness;
    final at = _cachedLivenessAt;
    if (cached != null &&
        at != null &&
        DateTime.now().difference(at) < _fixReuseWindow) {
      return cached;
    }

    Map<String, dynamic> signal;
    try {
      final result = await LocationService.instance.getCurrentPositionDetailed();
      final position = result.success ? result.position : null;
      if (position == null) {
        signal = const {'location_capture_status': 'UNAVAILABLE'};
      } else {
        signal = {
          'location_capture_status': 'CAPTURED',
          'gps_lat': position.latitude,
          'gps_lng': position.longitude,
          'gps_accuracy_m': position.accuracy,
          'gps_captured_at': DateTime.now().toUtc().toIso8601String(),
          'gps_is_last_known': result.isLastKnown,
        };
      }
    } catch (_) {
      // getCurrentPositionDetailed never throws, but a capture must not be
      // able to fail an upload even if it somehow does.
      signal = const {'location_capture_status': 'UNAVAILABLE'};
    }

    _cachedLiveness = signal;
    _cachedLivenessAt = DateTime.now();
    return signal;
  }

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

    // Taken once the photo is stored, so the timestamp reads as "where they
    // were when they submitted this", not "when they opened the form".
    final liveness = await _captureLiveness();
    final row = <String, dynamic>{
      'user_id': userId,
      'document_type': documentType,
      'storage_path': path,
      ...liveness,
    };

    try {
      await _client.from('user_documents').insert(row);
    } catch (e) {
      // One retry covers a transient failure before the error surfaces.
      await _client.from('user_documents').insert(row);
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
