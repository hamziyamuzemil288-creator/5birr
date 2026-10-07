/// Item K: a friendly sentence AND a reference code, together.
///
/// [friendlyError] turns an exception into something a person can read. On its
/// own that is only half a fix: when the failure is genuinely ours, the user
/// has nothing to quote and support has nothing to search. This pairs the two —
/// it logs the failure (to `client_error_logs`, the admin-readable table) and
/// appends the short code the row carries:
///
/// ```dart
/// setState(() => _error = friendlyErrorWithRef(e, context: 'Could not request this ride'));
/// // -> "Could not request this ride. No internet connection. Check your
/// //     network and try again. (Ref AL-3F9C21)"
/// ```
///
/// ## Why the code is always appended, even for an obvious cause
///
/// Deciding client-side which failures "deserve" a code is how a code ends up
/// missing on exactly the incident that mattered. The server's refusals the
/// user can act on (a validation error, APP_UPDATE_REQUIRED) are still logged
/// and still get a code; they are cheap rows and the reference is what makes a
/// screenshot actionable.
///
/// ## Why this is not folded into friendlyError
///
/// `friendly_error.dart` is deliberately dependency-free (dart:core only) so it
/// can be imported from anywhere without an import cycle. Adding an
/// `ErrorLogger` dependency to it would drag Supabase into every screen that
/// wants a sentence. This file is the one that knowingly takes both.
library;

import '../services/error_logger.dart';
import 'friendly_error.dart';

/// The user-facing sentence for [error], with a logged reference code appended.
///
/// Never throws: a failure inside logging is swallowed by [ErrorLogger], and a
/// failure to produce a code simply yields the plain sentence.
String friendlyErrorWithRef(
  Object error, {
  String? context,
  String source = 'screen',
  bool isFatal = false,
}) {
  final sentence = friendlyError(error, context: context);
  try {
    final ref = ErrorLogger.instance.logError(
      error,
      null,
      source: source,
      context: context,
      isFatal: isFatal,
    );
    if (ref == null) return sentence;
    return '$sentence (Ref $ref)';
  } catch (_) {
    return sentence;
  }
}
