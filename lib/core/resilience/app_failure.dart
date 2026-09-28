/// The typed failure hierarchy every layer of the app agrees on.
///
/// WHY THIS EXISTS — before this, each screen caught `Object` and rendered
/// `friendlyError(e, context: ...)`, which is a *string* produced by pattern
/// matching on the exception's `toString()`. That is fine for display but
/// useless for control flow: a screen cannot ask "is this worth retrying?"
/// or "should I show the last good data instead of an error?" without
/// re-parsing English prose. So the classification now happens once, here,
/// and produces a value the UI can branch on.
///
/// The mapping is deliberately conservative — when an exception is
/// unrecognised it becomes [AppFailure.unknown] rather than being guessed
/// into a category, because misclassifying a business error as "network"
/// makes the app retry a request that can never succeed.
library;

/// What kind of failure this is, in the terms the UI cares about.
enum AppFailureKind {
  /// No usable connection, DNS failure, socket dropped.
  network,

  /// The request was made but nothing came back in time.
  timeout,

  /// 5xx, or a 429 from PostgREST. Transient by definition: worth retrying.
  serverBusy,

  /// 401 — the session is gone or invalid.
  unauthorized,

  /// 403 — signed in, but not allowed.
  forbidden,

  /// 4xx business errors: validation, not found, duplicate, conflict.
  /// Never retried: sending the same request again produces the same
  /// answer and only wastes the user's battery and our quota.
  validation,

  /// The response was not what the code expected.
  malformed,

  /// Not recognised. Treated as non-retryable by default.
  unknown,
}

/// A failure, classified.
///
/// [message] is always a complete, plain, actionable sentence — never raw
/// exception text, never a Postgres error code, never a stack fragment. It is
/// safe to put in front of a user and safe to screenshot.
///
/// [code] and [details] carry the machine-readable parts for logs and
/// telemetry. They are deliberately kept off the user-facing path: the whole
/// point of separating them is that a screenshot of an Aliob screen must not
/// leak schema.
class AppFailure implements Exception {
  const AppFailure({
    required this.kind,
    required this.message,
    this.code,
    this.statusCode,
    this.details,
    this.cause,
  });

  final AppFailureKind kind;

  /// Plain, actionable, user-facing. Never technical.
  final String message;

  /// PostgREST / RPC / Edge Function code, e.g. `PGRST116`, `23505`.
  /// Diagnostic only — never shown to a user.
  final String? code;

  /// HTTP status when one was received.
  final int? statusCode;

  /// Extra diagnostic context (function name, table, screen). Log only.
  final Map<String, Object?>? details;

  /// The original exception, kept for logging. Never rendered.
  final Object? cause;

  /// True when trying the identical request again could plausibly succeed.
  ///
  /// This is the single rule the retry helper and every screen consult, so
  /// "should we retry?" is answered in exactly one place.
  bool get isRetryable => switch (kind) {
        AppFailureKind.network => true,
        AppFailureKind.timeout => true,
        AppFailureKind.serverBusy => true,
        AppFailureKind.validation => false,
        AppFailureKind.unauthorized => false,
        AppFailureKind.forbidden => false,
        AppFailureKind.malformed => false,
        AppFailureKind.unknown => false,
      };

  /// True when the user must sign in again before anything else works.
  bool get needsAuth => kind == AppFailureKind.unauthorized;

  /// True when the request never reached the server, so nothing changed
  /// server-side. A screen holding last-good data can keep showing it and
  /// simply say it could not refresh.
  bool get isTransport => isRetryable;

  AppFailure copyWith({String? message, Map<String, Object?>? details}) => AppFailure(
        kind: kind,
        message: message ?? this.message,
        code: code,
        statusCode: statusCode,
        details: details ?? this.details,
        cause: cause,
      );

  /// Prefix a message with a short phrase describing what was being done,
  /// e.g. 'Could not load your orders'. Keeps sentences readable in context.
  AppFailure withContext(String context) => AppFailure(
        kind: kind,
        message: '$context. $message',
        code: code,
        statusCode: statusCode,
        details: details,
        cause: cause,
      );

  @override
  String toString() => 'AppFailure(${kind.name}): $message';
}
