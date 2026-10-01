/// Converts any exception thrown anywhere in the app into an [AppFailure].
///
/// THIS IS THE ONLY PLACE that classifies exceptions. Screens call
/// `AppFailureMapper.map(e)` (or, more usually, `safeCall`, which does it for
/// them) and branch on [AppFailure.kind]. Adding a second classifier is how
/// the same underlying fault starts producing two different user-facing
/// strings in two different screens, which is the bug this file exists to
/// prevent.
///
/// ## Sources it understands
///
/// Supabase Dart throws several unrelated types, and the app also calls
/// Edge Functions and geocoding over raw `http`, so this mapper handles all
/// of them without importing any of those packages. It works on the
/// exception's type name and message text, which is why it is `dart:core`
/// only — it must be importable from a test, a widget, and a service alike
/// without dragging in Flutter.
///
/// Anything it does not recognise becomes [AppFailureKind.unknown], which is
/// deliberately **not** retryable: a wrong guess in that direction turns
/// "user taps Retry four times" into a small denial-of-service against our
/// own quota.
library;

import 'dart:async';

import 'app_failure.dart';

/// Plain sentences a person can act on. Deliberately not identical to
/// `friendly_error.dart` — that file is a screen-level convenience kept for
/// call sites not yet migrated — but the two agree on the important cases
/// (session expiry, permission, not found) so migrating a screen does not
/// change what the user reads.
class AppFailureMapper {
  const AppFailureMapper._();

  static const _unknownMessage = 'Something went wrong. Please try again.';

  /// Classify [error] into an [AppFailure].
  ///
  /// [context] is a short prefix describing the action, e.g.
  /// 'Could not load your orders'. The result reads as a full sentence.
  static AppFailure map(Object error, {String? context}) {
    final failure = _classify(error);
    if (context == null || context.trim().isEmpty) return failure;
    return failure.withContext(context);
  }

  static AppFailure _classify(Object error) {
    // 1. Already typed. Re-mapping would discard the classification a
    //    service layer did deliberately, and re-derive a worse one.
    if (error is AppFailure) return error;

    // 2. Our own timeout marker, thrown by safeCall/withRetry.
    if (error is ResilienceTimeout) {
      return AppFailure(
        kind: AppFailureKind.timeout,
        message: 'This is taking longer than usual. Check your connection and try again.',
        cause: error,
      );
    }

    // 3. Real Dart timeout, in case a caller did not use safeCall.
    if (error is TimeoutException) {
      return AppFailure(
        kind: AppFailureKind.timeout,
        message: 'This is taking longer than usual. Check your connection and try again.',
        cause: error,
      );
    }

    final type = error.runtimeType.toString();
    final raw = error.toString();
    final lower = raw.toLowerCase();

    // 4. PostgrestException. Status is the strongest signal and is checked
    //    before the message text, because a 4xx body can contain almost any
    //    wording (including words like "timeout" in a user's own field).
    if (type.contains('PostgrestException') || type.contains('PostgrestError')) {
      final status = _statusFromPostgrest(error, lower);
      final code = _codeFrom(lower);
      // P0001 is PostgREST's generic 400. Every `RAISE EXCEPTION` in this
      // app's triggers and RPCs arrives as one, so it is checked BEFORE the
      // status switch — otherwise "insufficient_balance" and
      // "ride_already_taken" both become "Please check the details you
      // entered", which is advice that helps nobody.
      if (code != null && code.toUpperCase() == 'P0001') {
        return _classifyBusinessSentinel(lower, error, 'P0001');
      }
      return _fromStatus(
        status: status,
        code: code,
        lower: lower,
        cause: error,
      );
    }

    // 5. Supabase's realtime subscribe failure. Historically this reached
    //    the unhandled-error path and blanked the whole app; it is a
    //    transport problem and is retryable.
    if (type.contains('RealtimeSubscribeException') || type.contains('RealtimeException')) {
      return AppFailure(
        kind: AppFailureKind.network,
        message: 'Live updates paused. Reconnecting...',
        cause: error,
      );
    }

    // 6. Edge Function invocation (supabase functions v2 wraps a
    //    FunctionException; older code used a bare http client).
    if (type.contains('FunctionException') || type.contains('DioException')) {
      final status = _intAfter(raw, 'statusCode:') ?? _intAfter(raw, 'status:');
      return _fromStatus(status: status, code: _codeFrom(lower), lower: lower, cause: error);
    }

    // 7. Raw http / socket failures from geocoding and storage.
    if (type.contains('SocketException') ||
        type.contains('HttpException') ||
        type.contains('ClientException') ||
        type.contains('HandshakeException') ||
        type.contains('TlsException')) {
      return AppFailure(
        kind: AppFailureKind.network,
        message: 'No internet connection. Check your network and try again.',
        cause: error,
      );
    }

    // 8. Auth failures. Checked before generic status matching so an
    //    expired refresh token is never shown as a permissions problem.
    if (_any(lower, const [
          'jwt',
          'invalid token',
          'token is expired',
          'expired_token',
          'refresh token not found',
          'invalid login credentials',
          'user not found',
          'email not confirmed',
        ])) {
      return AppFailure(
        kind: AppFailureKind.unauthorized,
        message: 'Your session has expired. Please sign in again.',
        cause: error,
      );
    }

    // 9. Transport phrasing, for exceptions that do not carry a useful type
    //    (some are constructed as plain strings by third-party code).
    if (_any(lower, const [
          'failed host lookup',
          'connection refused',
          'connection reset',
          'connection closed',
          'network is unreachable',
          'no address associated',
          'nodename nor servname',
          'socketexception',
          'connection error',
        ])) {
      return AppFailure(
        kind: AppFailureKind.network,
        message: 'No internet connection. Check your network and try again.',
        cause: error,
      );
    }

    // 10a. PostgREST could not RESOLVE the call we made. PGRST202 is a wrong
    //      parameter name, a missing GRANT, or a migration that never ran;
    //      PGRST203 is an ambiguous overload. Both are defects on our side of
    //      the wire, so the message must not imply the user's data or their
    //      order went missing — see friendly_error.dart for the same split.
    if (_any(lower, const [
          'pgrst202',
          'pgrst203',
          'could not choose the best candidate',
          'could not find the function',
        ])) {
      return AppFailure(
        kind: AppFailureKind.malformed,
        message: 'We could not complete that just now. Please try again in a '
            'moment — if it keeps happening, contact support.',
        cause: error,
      );
    }

    // 10b. PostgREST shape errors: the response parsed but did not match what
    //     the code expected. Nothing the user can retry.
    if (_any(lower, const [
          'pgrst201',
          'could not parse',
          'format',
          'type cast',
          'rangeerror',
          'stateerror',
          'null check operator',
          'unexpected response',
        ])) {
      return AppFailure(
        kind: AppFailureKind.malformed,
        message: 'We received an unexpected response. Please try again.',
        cause: error,
      );
    }

    // 11. A bare Postgres error code, from a trigger RAISE or an RPC.
    //
    //     This is where the app's own business sentinels actually arrive. A
    //     `RAISE EXCEPTION 'insufficient_balance'` surfaces as a
    //     PostgrestException whose `code` is P0001 — and P0001 is NOT a
    //     five-digit SQLSTATE, so a test that only accepts `[0-9]{5}` here
    //     silently drops every one of them into "Something went wrong". The
    //     sentinels are the *actionable* errors (top up your wallet, the ride
    //     went to someone else), so losing them is the difference between a
    //     user knowing what to do and a user filing a support ticket.
    final pgCode = _codeFrom(lower);
    if (pgCode != null) {
      if (pgCode.toUpperCase() == 'P0001') {
        return _classifyBusinessSentinel(lower, error, 'P0001');
      }
      if (_isFiveDigitCode(pgCode)) {
        return _fromPostgresCode(pgCode, lower, error);
      }
      if (pgCode.toLowerCase().startsWith('pgrst')) {
        return _fromPostgresCode(pgCode.toLowerCase(), lower, error);
      }
    }

    return AppFailure(kind: AppFailureKind.unknown, message: _unknownMessage, cause: error);
  }

  /// Map an HTTP status code to a kind, then to a sentence.
  static AppFailure _fromStatus({
    required int? status,
    required String? code,
    required String lower,
    required Object cause,
  }) {
    switch (status) {
      case 400:
      case 422:
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          statusCode: status,
          message: _validationMessage(lower),
          cause: cause,
        );
      case 401:
        return AppFailure(
          kind: AppFailureKind.unauthorized,
          code: code,
          statusCode: status,
          message: 'Your session has expired. Please sign in again.',
          cause: cause,
        );
      case 403:
        return AppFailure(
          kind: AppFailureKind.forbidden,
          code: code,
          statusCode: status,
          message: 'You do not have permission to do that.',
          cause: cause,
        );
      case 404:
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          statusCode: status,
          message: 'That item could not be found. It may have been removed.',
          cause: cause,
        );
      case 408:
        return AppFailure(
          kind: AppFailureKind.timeout,
          code: code,
          statusCode: status,
          message: 'This is taking longer than usual. Check your connection and try again.',
          cause: cause,
        );
      case 409:
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          statusCode: status,
          message: 'That already exists. Please choose a different one.',
          cause: cause,
        );
      case 429:
        return AppFailure(
          kind: AppFailureKind.serverBusy,
          code: code,
          statusCode: status,
          message: 'Too many requests. Please wait a moment and try again.',
          cause: cause,
        );
    }

    if (status != null && status >= 500) {
      return AppFailure(
        kind: AppFailureKind.serverBusy,
        code: code,
        statusCode: status,
        message: 'Our servers are busy right now. Please try again in a moment.',
        cause: cause,
      );
    }
    if (status != null && status >= 400) {
      return AppFailure(
        kind: AppFailureKind.validation,
        code: code,
        statusCode: status,
        message: _validationMessage(lower),
        cause: cause,
      );
    }

    // No usable status. Fall back to the message text.
    return _classifyByMessage(lower, code, cause);
  }

  /// Postgres raise codes. These reach the client through RPC errors, which
  /// carry the code in the message body.
  static AppFailure _fromPostgresCode(String code, String lower, Object cause) {
    switch (code) {
      case '23505': // unique_violation
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          message: 'That already exists. Please choose a different one.',
          cause: cause,
        );
      case '23503': // foreign_key_violation
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          message: 'This cannot be completed while related records still exist.',
          cause: cause,
        );
      case '23502': // not_null_violation
        return AppFailure(
          kind: AppFailureKind.validation,
          code: code,
          message: 'Please fill in all the required fields.',
          cause: cause,
        );
      case '42501': // insufficient_privilege — an RLS denial
        return AppFailure(
          kind: AppFailureKind.forbidden,
          code: code,
          message: 'You do not have permission to do that.',
          cause: cause,
        );
      case 'P0001': // raise_exception — the app's own business sentinels
        return _classifyBusinessSentinel(lower, cause, code);
      case '57014': // query_canceled — statement_timeout fired
        return AppFailure(
          kind: AppFailureKind.serverBusy,
          code: code,
          message: 'That took too long. Please try again with a smaller search.',
          cause: cause,
        );
    }
    if (code.startsWith('PGRST')) {
      // PGRST116 is zero rows for .single() — a record genuinely not there.
      // PGRST202/203 are unresolvable CALLS, handled in 10a above so they never
      // share a message with a missing row; reaching them here means the
      // status-code path saw the code without the text, so they still get the
      // honest sentence rather than the "may have been removed" one.
      if (code == 'PGRST202' || code == 'PGRST203') {
        return AppFailure(
          kind: AppFailureKind.malformed,
          code: code,
          message: 'We could not complete that just now. Please try again in a '
              'moment — if it keeps happening, contact support.',
          cause: cause,
        );
      }
      if (code == 'PGRST116') {
        return AppFailure(
          kind: AppFailureKind.malformed,
          code: code,
          message: 'That item could not be found. It may have been removed.',
          cause: cause,
        );
      }
      return AppFailure(
        kind: AppFailureKind.validation,
        code: code,
        message: _validationMessage(lower),
        cause: cause,
      );
    }
    return AppFailure(
      kind: AppFailureKind.validation,
      code: code,
      message: _validationMessage(lower),
      cause: cause,
    );
  }

  /// The app's own business errors, raised as `RAISE EXCEPTION 'SOME_CODE'`.
  /// Each of these has a specific meaning to a user, so each gets its own
  /// sentence rather than a generic validation message.
  static AppFailure _classifyBusinessSentinel(String lower, Object cause, String code) {
    String? message;
    if (lower.contains('ride_already_taken')) {
      message = 'This ride was just taken by another driver.';
    } else if (lower.contains('insufficient_balance')) {
      message = 'Your wallet balance is too low for this. Please top up first.';
    } else if (lower.contains('otp_required') || lower.contains('email_otp_required')) {
      message = 'Please verify your email code to continue.';
    } else if (lower.contains('settings_are_admin_only')) {
      message = 'You do not have permission to change this.';
    } else if (lower.contains('location_required') || lower.contains('location_out_of_range')) {
      message = 'We could not read your location. Please try again.';
    } else if (lower.contains('captcha')) {
      message = 'Please complete the security check and try again.';
    } else if (lower.contains('not_approved') || lower.contains('approval')) {
      message = 'Your account is still being approved. Please check back shortly.';
    } else if (lower.contains('already_claimed')) {
      message = 'Someone else is already handling this.';
    }
    return AppFailure(
      kind: message != null ? AppFailureKind.validation : AppFailureKind.unknown,
      code: code,
      message: message ?? 'We could not complete that. Please try again.',
      cause: cause,
    );
  }

  static AppFailure _classifyByMessage(String lower, String? code, Object cause) {
    if (_any(lower, const ['401', 'unauthorized'])) {
      return AppFailure(
        kind: AppFailureKind.unauthorized,
        code: code,
        message: 'Please sign in again to continue.',
        cause: cause,
      );
    }
    if (_any(lower, const ['403', 'forbidden', 'permission denied', 'row-level security', 'pgrst301'])) {
      return AppFailure(
        kind: AppFailureKind.forbidden,
        code: code,
        message: 'You do not have permission to do that.',
        cause: cause,
      );
    }
    if (_any(lower, const ['404', 'not found', 'pgrst116', 'does not exist'])) {
      return AppFailure(
        kind: AppFailureKind.validation,
        code: code,
        message: 'That item could not be found. It may have been removed.',
        cause: cause,
      );
    }
    if (_any(lower, const ['429', 'too many requests', 'rate limit'])) {
      return AppFailure(
        kind: AppFailureKind.serverBusy,
        code: code,
        message: 'Too many requests. Please wait a moment and try again.',
        cause: cause,
      );
    }
    if (_any(lower, const ['500', '502', '503', '504', 'internal server error', 'bad gateway'])) {
      return AppFailure(
        kind: AppFailureKind.serverBusy,
        code: code,
        message: 'Our servers are busy right now. Please try again in a moment.',
        cause: cause,
      );
    }
    if (_any(lower, const ['timedout', 'timeout', 'deadline exceeded'])) {
      return AppFailure(
        kind: AppFailureKind.timeout,
        code: code,
        message: 'This is taking longer than usual. Check your connection and try again.',
        cause: cause,
      );
    }
    final pg = _codeFrom(lower);
    if (pg != null) {
      if (pg.toUpperCase() == 'P0001') {
        return _classifyBusinessSentinel(lower, cause, 'P0001');
      }
      if (_isFiveDigitCode(pg)) {
        return _fromPostgresCode(pg, lower, cause);
      }
      if (pg.toLowerCase().startsWith('pgrst')) {
        return _fromPostgresCode(pg.toLowerCase(), lower, cause);
      }
    }
    return AppFailure(kind: AppFailureKind.unknown, message: _unknownMessage, cause: cause);
  }

  /// Turn a 4xx body into something specific where we can, generic otherwise.
  static String _validationMessage(String lower) {
    if (_any(lower, const ['23505', 'duplicate key', 'already exists', 'unique constraint'])) {
      return 'That already exists. Please choose a different one.';
    }
    if (_any(lower, const ['23503', 'foreign key'])) {
      return 'This cannot be completed while related records still exist.';
    }
    if (_any(lower, const ['23502', 'not-null', 'null value in column'])) {
      return 'Please fill in all the required fields.';
    }
    if (_any(lower, const ['check constraint', 'violates check'])) {
      return 'Please check the details you entered.';
    }
    return 'Please check the details you entered and try again.';
  }

  /// Pull `status`/`statusCode` out of a PostgrestException without importing
  /// postgrest. `toString()` renders it as `PostgrestException(message: ...,
  /// code: ..., details: ..., hint: ..., status: 404)`.
  static int? _statusFromPostgrest(Object error, String lower) {
    final raw = error.toString();
    return _intAfter(raw, 'status:') ?? _intAfter(raw, 'statusCode:') ?? _intAfter(raw, 'status');
  }

  /// Extract a `code:` value or a 5-digit SQLSTATE from text.
  ///
  /// The labelled form is tried first and matches both a numeric PostgREST
  /// code and an alphanumeric one (`code: P0001`), which matters because the
  /// business sentinels only ever appear in that field.
  static String? _codeFrom(String lower) {
    final labelled = RegExp(r'code:\s*([a-z0-9]+)').firstMatch(lower);
    if (labelled != null) return labelled.group(1);
    final pgrst = RegExp(r'\b(pgrst\d+)\b').firstMatch(lower);
    if (pgrst != null) return pgrst.group(1);
    final sqlstate = RegExp(r'\b([0-9]{5})\b').firstMatch(lower);
    if (sqlstate != null) return sqlstate.group(1);
    return null;
  }

  static bool _isFiveDigitCode(String code) => RegExp(r'^\d{5}$').hasMatch(code);

  /// Read an integer that follows [marker] in [text], e.g. `status:` -> 404.
  static int? _intAfter(String text, String marker) {
    final idx = text.toLowerCase().indexOf(marker.toLowerCase());
    if (idx < 0) return null;
    final rest = text.substring(idx + marker.length);
    final match = RegExp(r'\d+').firstMatch(rest);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  static bool _any(String lower, List<String> needles) {
    for (final n in needles) {
      if (lower.contains(n)) return true;
    }
    return false;
  }
}

/// Thrown by [safeCall]/[withRetry] when their own deadline expires.
///
/// A distinct type so the mapper can recognise "we gave up waiting" without
/// pattern-matching a message, and without confusing it with a server-side
/// timeout that a retry might fix.
class ResilienceTimeout implements Exception {
  const ResilienceTimeout(this.timeout);
  final Duration timeout;

  @override
  String toString() => 'ResilienceTimeout: exceeded ${timeout.inMilliseconds}ms';
}
