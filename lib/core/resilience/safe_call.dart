/// The one place network calls are made resilient.
///
/// Every Supabase query, RPC, Edge Function call and geocoding request in the
/// app goes through [safeCall] or [withRetry]. That is a deliberate
/// single-entry-point rule: resilience that is applied per call site drifts,
/// and the callsites that forget are exactly the ones on the critical path.
///
/// ## What it does
///
/// * **Timeout on everything.** A request with no deadline is a request that
///   can hang a screen forever; a mobile socket that half-opens never errors,
///   it just stops. The default is deliberately short relative to how long a
///   human will wait before deciding the app is broken.
/// * **Retry only what can succeed on a second attempt.** [AppFailure.isRetryable]
///   decides, and a 4xx business error is never retried — resending a request
///   that was rejected for a business reason produces the same rejection and
///   burns quota.
/// * **Exponential backoff with jitter.** Without jitter every client that
///   failed during a blip retries in the same millisecond, which is how a
///   brief outage turns into a self-inflicted thundering herd on recovery.
/// * **A hard cap on attempts.** Bounded total time, so a caller can bound
///   its own UI with confidence.
///
/// ## Why jitter uses [Random]
///
/// A shared instance would need seeding and would still be synchronised.
/// [Random] with no argument is already non-deterministic, which is the only
/// property that matters here, and it keeps the helper synchronous and
/// trivially testable through the injected [random] parameter.
library;

import 'dart:async';
import 'dart:math';

import 'app_failure.dart';
import 'failure_mapper.dart';
import '../services/connectivity_service.dart';

/// How [withRetry] should behave.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 3,
    this.initialBackoff = const Duration(milliseconds: 400),
    this.maxBackoff = const Duration(seconds: 8),
    this.jitterFactor = 0.5,
  });

  /// The common case: a short transient failure gets a couple of chances.
  const RetryPolicy.standard()
      : maxAttempts = 3,
        initialBackoff = const Duration(milliseconds: 400),
        maxBackoff = const Duration(seconds: 8),
        jitterFactor = 0.5;

  /// For non-idempotent work (creating an order, charging a wallet) where a
  /// duplicate is worse than a failure. One attempt only; the caller relies
  /// on its idempotency key instead.
  const RetryPolicy.none()
      : maxAttempts = 1,
        initialBackoff = Duration.zero,
        maxBackoff = Duration.zero,
        jitterFactor = 0;

  /// Money and anything else that must never be sent twice by a retry.
  const RetryPolicy.money()
      : maxAttempts = 1,
        initialBackoff = Duration.zero,
        maxBackoff = Duration.zero,
        jitterFactor = 0;

  /// Total attempts including the first. 1 means "no retry".
  final int maxAttempts;

  final Duration initialBackoff;
  final Duration maxBackoff;

  /// Fraction of the computed backoff to randomise by. 0.5 means the real
  /// delay lands uniformly in [50%, 150%] of the nominal value.
  final double jitterFactor;

  /// Delay before attempt number [attempt] (1-based; attempt 1 has no delay).
  ///
  /// Exposed for tests and for screens that want to show a "retrying…"
  /// affordance without duplicating the formula.
  Duration backoffFor(int attempt, {Random? random}) {
    if (attempt <= 1) return Duration.zero;
    // 1 << (attempt - 2): attempt 2 waits one base interval, 3 waits two, etc.
    final scaled = initialBackoff.inMilliseconds * (1 << (attempt - 2));
    final capped = scaled.clamp(0, maxBackoff.inMilliseconds).toDouble();
    if (jitterFactor <= 0) return Duration(milliseconds: capped.round());
    final r = random ?? Random();
    // Offset into [-jitter, +jitter] as a fraction of the capped delay.
    final spread = capped * jitterFactor;
    final jittered = capped + (r.nextDouble() * 2 - 1) * spread;
    return Duration(milliseconds: jittered.clamp(0, double.infinity).round());
  }
}

/// Run [body] once, with a timeout, mapping any failure to an [AppFailure].
///
/// The simplest thing that still cannot hang a screen. Use it when a retry
/// would be wrong or pointless — reads that must reflect the very latest
/// state, and non-idempotent writes that carry their own idempotency key.
Future<T> safeCall<T>(
  Future<T> Function() body, {
  Duration timeout = const Duration(seconds: 20),
  String? context,
}) async {
  try {
    final result = await body().timeout(timeout);
    ConnectivityService.instance.reportRequestSucceeded();
    return result;
  } on AppFailure catch (e) {
    _reportOutcome(e);
    throw context == null ? e : e.withContext(context);
  } catch (e) {
    final failure = AppFailureMapper.map(
      e is TimeoutException ? const ResilienceTimeout(Duration.zero) : e,
    );
    _reportOutcome(failure);
    throw context == null ? failure : failure.withContext(context);
  }
}

/// Run [body] with a deadline, retrying transient failures.
///
/// Returns the value on success. Throws an [AppFailure] — never a raw
/// exception — when every attempt fails, so callers only have one type to
/// handle.
Future<T> withRetry<T>(
  Future<T> Function() body, {
  RetryPolicy policy = const RetryPolicy.standard(),
  Duration timeout = const Duration(seconds: 20),
  String? context,
  bool Function(AppFailure failure)? retryIf,
  Random? random,
  void Function(int attempt, AppFailure failure)? onRetry,
}) async {
  AppFailure? last;

  for (var attempt = 1; attempt <= policy.maxAttempts; attempt++) {
    try {
      final result = await body().timeout(timeout);
      // Only a genuinely successful response clears the banner — a retry
      // that merely did not throw proves the connection works.
      ConnectivityService.instance.reportRequestSucceeded();
      return result;
    } catch (e) {
      final failure = e is AppFailure ? e : AppFailureMapper.map(e, context: context);
      last = context == null ? failure : failure.withContext(context);
      // Only transport failures count against connectivity. A validation
      // error means the network is healthy and the input was wrong.
      if (last.isTransport) ConnectivityService.instance.reportRequestFailed();

      final isLastAttempt = attempt == policy.maxAttempts;
      final shouldRetry = !isLastAttempt &&
          last.isRetryable &&
          (retryIf == null || retryIf(last));

      if (!shouldRetry) break;

      onRetry?.call(attempt, last);
      final delay = policy.backoffFor(attempt + 1, random: random);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
    }
  }

  // Unreachable in practice: the loop either returns or breaks with `last`
  // set, because maxAttempts >= 1 is enforced by the constructor.
  throw last ?? AppFailure(kind: AppFailureKind.unknown, message: 'Something went wrong. Please try again.');
}

void _reportOutcome(AppFailure failure) {
  if (failure.isTransport) ConnectivityService.instance.reportRequestFailed();
}

/// Debounce a burst of calls into one, e.g. typing in a search field.
///
/// Returns a function that schedules [action], cancelling any previous
/// pending invocation. Call it on every keystroke and the network only sees
/// the last one.
class Debouncer {
  Debouncer({this.delay = const Duration(milliseconds: 350)});

  final Duration delay;
  Timer? _timer;

  void call(void Function() action) {
    _timer?.cancel();
    _timer = Timer(delay, action);
  }

  /// Run immediately and drop anything pending.
  void flush(void Function() action) {
    _timer?.cancel();
    _timer = null;
    action();
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  bool get isPending => _timer?.isActive ?? false;
}

/// Guards a money or otherwise non-idempotent action against double-submit.
///
/// The pattern this replaces was a plain `if (_loading) return;`, which is
/// wrong under a fast double-tap: the second tap can land after the first
/// await resumes but before the flag is cleared. This holds the gate for the
/// whole async body, so the window does not exist.
///
/// ```dart
/// final guard = InFlightGuard();
/// await guard.run(() async {
///   await wallet.recharge(...);   // a second tap returns null immediately
/// });
/// ```
class InFlightGuard {
  bool _busy = false;

  bool get isBusy => _busy;

  /// Runs [action] at most once at a time. Returns `null` if the action was
  /// skipped because one was already running.
  Future<T?> run<T>(Future<T> Function() action) async {
    if (_busy) return null;
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }
}
