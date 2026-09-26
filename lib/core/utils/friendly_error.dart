/// Turns an exception into a sentence a real person can act on.
///
/// The app used to interpolate the raw exception straight into snackbars
/// (`Text('Error: $e')`) and into full-screen error bodies. On a phone that
/// surfaces things like `PostgrestException(code: PGRST301)` or
/// `HttpException: Connection closed before full header was received`, which
/// tells the user nothing about what to do next and leaks schema detail to
/// anyone who screenshots it.
///
/// Deliberately dependency-free (dart:core only) so it can be imported from
/// any screen without risking an import cycle. The raw error is still sent to
/// the console for debugging — it is only the user-visible text that changes.
library;

/// Default text when nothing more specific is recognised. Never empty, never
/// technical, and always paired with a retry affordance by the caller.
const String _fallback = 'Something went wrong. Please try again.';

/// Map an arbitrary thrown object to calm, actionable user-facing text.
///
/// [context] is an optional short prefix such as 'Could not load your
/// orders' so the sentence still reads naturally in context:
///
/// ```dart
/// SnackBar(content: Text(friendlyError(e, context: 'Could not load your orders')))
/// ```
///
/// Known failure modes are matched in priority order — network problems are
/// the most common and the most actionable, so they win.
String friendlyError(Object error, {String? context}) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  final prefix = (context == null || context.trim().isEmpty) ? '' : '$context. ';

  String message;

  // ── Transport-level failures: the user's own situation, not the app's ──
  if (_any(lower, [
    'socketexception',
    'failed host lookup',
    'connection refused',
    'connection reset',
    'connection closed',
    'connection closed before full header',
    'network is unreachable',
    'no address associated',
    'nodename nor servname',
    'timedout',
    'timeout exception',
    'timeout',
  ])) {
    message = 'No internet connection. Check your network and try again.';
  } else if (_any(lower, [
    'handshakeexception',
    'certificate',
    'ssl',
  ])) {
    message = 'Could not establish a secure connection. Please try again.';
  }
  // ── Auth / session ──
  else if (_any(lower, [
    'jwt',
    'invalid token',
    'token is expired',
    'expired_token',
    'refresh token not found',
    'user not found',
    'invalid login credentials',
    'email not confirmed',
    'new_password',
    'same as the old password',
  ])) {
    message = 'Your session has expired. Please sign in again.';
  } else if (_any(lower, [
    '401',
    'unauthorized',
  ])) {
    message = 'Please sign in again to continue.';
  }
  // ── Authorisation (RLS denials arrive as plain 403s) ──
  else if (_any(lower, [
    '403',
    'forbidden',
    'permission denied',
    'not authorized',
    'row-level security',
    'row level security',
    'pgrst301',
  ])) {
    message = 'You do not have permission to do that.';
  }
  // ── Missing rows / removed records ──
  else if (_any(lower, [
    '404',
    'not found',
    'pgrst202',
    'does not exist',
  ])) {
    message = 'That item could not be found. It may have been removed.';
  }
  // ── Duplicate / constraint violations ──
  else if (_any(lower, [
    '23505',
    'duplicate key',
    'already exists',
    'unique constraint',
  ])) {
    message = 'That already exists. Please choose a different one.';
  } else if (_any(lower, [
    '23503',
    'foreign key',
    'violates foreign key',
  ])) {
    message = 'This cannot be completed while related records still exist.';
  } else if (_any(lower, [
    '23502',
    'not-null',
    'null value in column',
  ])) {
    message = 'Please fill in all the required fields.';
  }
  // ── App-specific sentinels that carry their own user-facing meaning ──
  else if (_any(lower, [
    'ride_already_taken',
    'already claimed',
  ])) {
    message = 'This ride was just taken by another driver.';
  } else if (_any(lower, [
    'captcha',
  ])) {
    message = 'Please complete the security check and try again.';
  } else if (_any(lower, [
    'storage',
    'bucket',
  ])) {
    message = 'We could not process that file. Please try a different one.';
  } else if (_any(lower, [
    'format',
    'parsing',
    'json',
    'type cast',
    'cast ',
    'rangeerror',
    'stateerror',
    'null check operator',
  ])) {
    // Malformed data from the backend. The user did nothing wrong.
    message = 'We received an unexpected response. Please try again.';
  } else {
    message = _fallback;
  }

  return '$prefix$message';
}

/// True when [lower] contains any of [needles].
bool _any(String lower, List<String> needles) {
  for (final n in needles) {
    if (lower.contains(n)) return true;
  }
  return false;
}
