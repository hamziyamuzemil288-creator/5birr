import 'package:supabase_flutter/supabase_flutter.dart';

/// The one way an administrator deletes an image.
///
/// The file cannot be removed by an RPC: Supabase refuses a direct
/// `DELETE FROM storage.objects` for every role, and the image buckets' delete
/// policies are owner-scoped, so an administrator cannot remove another
/// account's object from the client either. The `admin-image-delete` Edge
/// Function is the only path — it calls `admin_moderate_image` with the
/// caller's own JWT for the row and the audit record, then removes the file
/// through the Storage API with its service-role key.
///
/// Every admin delete call site goes through here, so the ordering (row first,
/// file second) and the error codes exist in exactly one place.
class AdminImageDeleteService {
  const AdminImageDeleteService._();

  /// Remove [path] from [bucket]. [reason] is required by the server and
  /// recorded permanently.
  ///
  /// Returns the server's human-readable sentence on success. Throws an
  /// [Exception] whose text carries the server's own refusal code, which
  /// [friendlyErrorWithCode] then renders for the moderator:
  /// `NO_ROW_REFERENCES_THAT_IMAGE`, `THAT_BUCKET_IS_NOT_MODERABLE`, or
  /// `IMAGE_MODERATION_FAILED` for anything else.
  static Future<String> delete({
    required String bucket,
    required String path,
    required String reason,
    String severity = 'SERIOUS',
  }) async {
    final res = await Supabase.instance.client.functions.invoke(
      'admin-image-delete',
      body: {
        'bucket': bucket,
        'path': path,
        'reason': reason,
        'severity': severity,
      },
    );

    final data = res.data;
    final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

    // A non-2xx status can still carry the server's code in the body; prefer
    // that over a generic sentence, because the code is the thing the moderator
    // needs to see.
    final serverError = (map['error'] ?? map['message'])?.toString().trim() ?? '';
    if (res.status >= 400) {
      throw Exception(serverError.isEmpty ? 'IMAGE_MODERATION_FAILED' : serverError);
    }
    if (map['error'] != null) {
      throw Exception(map['error'].toString());
    }

    return (map['message'] ?? 'Image removed.').toString();
  }
}
