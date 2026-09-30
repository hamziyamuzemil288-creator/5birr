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

/// Turn the server's `CODE: REASON,REASON` payload into phrases a provider
/// can act on.
///
/// Deliberately tolerant: an unrecognised reason contributes nothing rather
/// than leaking `SOME_NEW_CODE` onto the screen, and a payload with no
/// reasons at all yields an empty list, which the caller turns into a
/// generic-but-useful "open your business profile".
///
/// Kept dependency-free (dart:core only) so friendly_error.dart stays
/// importable from any screen without risking a cycle.
List<String> _fulfilmentReasons(String raw) {
  const phrases = {
    'DOCUMENTS_UNVERIFIED':
        'your identity document is still being reviewed',
    'ACTIVATION_FEE_UNPAID': 'the one-time activation fee is unpaid',
    'WALLET_EMPTY':
        'your wallet is empty, so the platform fee cannot be covered',
    'SUBSCRIPTION_UNPAID':
        'your subscription is unpaid, so your account is suspended',
    'ACCOUNT_NOT_APPROVED': 'your account has not been approved yet',
    'PROVIDER_NOT_FOUND': 'that business no longer exists',
  };
  // Anchored on the code itself rather than on its position. PostgREST wraps
  // the detail in a JSON envelope whose shape differs between the exception's
  // toString() and a raw response body, so "everything after the first colon"
  // matched in one case and not the other. This matches in both.
  final match = RegExp(
    'provider_not_fulfilment_ready\\s*:\\s*([A-Za-z_,\\s]*)',
    caseSensitive: false,
  ).firstMatch(raw);
  if (match == null) return const [];
  final out = <String>[];
  for (final part in (match.group(1) ?? '').split(RegExp(r'[,\s]+'))) {
    // Postgres upper-cases RAISE EXCEPTION text, but the reason list is
    // whatever the transport preserved, so the key is normalised here rather
    // than assuming.
    final phrase = phrases[part.trim().toUpperCase()];
    if (phrase != null && !out.contains(phrase)) out.add(phrase);
  }
  return out;
}

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
  //
  // 'invalid login credentials' and 'email not confirmed' used to sit in this
  // list, which made every one of them render as "Your session has expired."
  // That is actively wrong for a sign-in attempt: a person who has never had
  // a session cannot have an expired one, and a wrong password is not an
  // expiry. Both now say what they are, and the account-shaped failures are
  // checked FIRST because they are the ones with a distinct next action.
  else if (_any(lower, [
    'email not confirmed',
    'user is disabled',
    'user_banned',
    'email_exists',
    'signup is not allowed',
  ])) {
    message = 'That account cannot sign in with a password. Please contact '
        'support.';
  } else if (_any(lower, [
    'invalid login credentials',
  ])) {
    message = 'Invalid email or password.';
  } else if (_any(lower, [
    'jwt',
    'invalid token',
    'token is expired',
    'expired_token',
    'refresh token not found',
    'user not found',
    'new_password',
    'same as the old password',
  ])) {
    message = 'Your session has expired. Please sign in again.';
  } else if (_any(lower, [
    '401',
    'unauthorized',
    // The app's own "no session" refusal, raised by the SECURITY DEFINER
    // functions that must refuse an anonymous caller. Also a 400 from
    // PostgREST, not a 401, so without this it fell through to the generic
    // fallback and told a signed-out user to "try again" — which is exactly
    // what had already failed.
    'auth_required',
  ])) {
    message = 'Please sign in again to continue.';
  }
  // ── The provider fulfilment gate ──
  //
  // Migration 0113 answers a refusal with the REASONS rather than a bare
  // code: `PROVIDER_NOT_FULFILMENT_READY: DOCUMENTS_UNVERIFIED,WALLET_EMPTY`.
  //
  // This branch exists because "You do not have permission to do that" is the
  // single least useful sentence this product could show a provider who has
  // done everything right and is waiting on a review. Each reason is
  // translated into the thing they can actually DO about it, which is the
  // entire point of returning a list instead of a boolean.
  else if (_any(lower, ['provider_not_fulfilment_ready'])) {
    final reasons = _fulfilmentReasons(raw);
    message = reasons.isEmpty
        ? 'Finish your account setup before taking this on. Open your '
            'business profile to see what is outstanding.'
        : 'Before you can take this on: ${reasons.join('; ')}. Open your '
            'business profile to fix it.';
  }

  // ── Authorisation (RLS denials arrive as plain 403s) ──
  //
  // `insufficient_permission` is the app's OWN refusal code, raised by
  // `RAISE EXCEPTION 'INSUFFICIENT_PERMISSION'` in the admin and staff RPCs.
  // PostgREST returns that as a 400, not a 403, and the message body is the
  // raw code — so without this entry a staff member who acted outside their
  // scope got the generic "Something went wrong" fallback, which tells them
  // nothing and reads like a bug. Migrations 110-112 put this code on the
  // five provider lifecycle actions, the task feed and payment verification,
  // so it stopped being rare.
  else if (_any(lower, [
    '403',
    'forbidden',
    'permission denied',
    'not authorized',
    'row-level security',
    'row level security',
    'pgrst301',
    'insufficient_permission',
    'admin_only',
  ])) {
    message = _any(lower, ['insufficient_permission'])
        // The overwhelmingly common cause is a staff member reaching past
        // their assigned city, so say that specifically rather than making
        // them guess. A CEO or super admin has no city scope and will never
        // see this branch reached against them.
        ? 'That is outside the area you are assigned to. Ask a manager or '
            'the CEO if you need access to it.'
        : 'You do not have permission to do that.';
  }
  // ── Missing rows / removed records ──
  else if (_any(lower, [
    '404',
    'not found',
    'pgrst116',
    'pgrst202',
    'does not exist',
  ])) {
    // PGRST116 is what `.single()` raises on zero rows, with the message
    // "JSON object requested, multiple (or no) rows returned" — it contains
    // neither "not found" nor a 404, so without this it would fall through
    // to the malformed-data branch and tell the user the response was
    // unexpected when the real answer is simply "there is no such record".
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

/// True when [error] means "this record genuinely is not there", as opposed
/// to "the request failed".
///
/// Screens with a dedicated not-found state need this distinction: without
/// it, a dropped connection on a detail page and a deleted record produce
/// the same user-visible screen, and the user is told the thing they were
/// looking for does not exist when it very much does.
bool isNotFound(Object error) {
  final lower = error.toString().toLowerCase();
  return _any(lower, [
    'pgrst116',
    'pgrst202',
    'not found',
    'does not exist',
    '404',
  ]);
}
