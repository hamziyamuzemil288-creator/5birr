/// Realtime helpers that cannot crash the app.
///
/// ## Scope, and why it is this small
///
/// The core requirement — a dropped subscription must not take the screen
/// down — is already met by `resilient_subscription.dart`, which re-listens
/// with exponential backoff, consumes the error, and never throws. It is
/// used by every realtime screen and covered by
/// `test/realtime_resilient_subscription_test.dart`.
///
/// This file adds the piece that is genuinely missing from it: a way to take
/// a raw Supabase stream without it being able to fail the zone. The one
/// thing it deliberately does NOT do is manage `RealtimeChannel` objects.
///
/// An earlier draft of this file did. It could not be verified in the
/// environment it was written in — no Dart SDK — and when CI finally compiled
/// it, nine of its assumptions about the `realtime_client` API were wrong
/// (`channel.onError` does not exist, `filter:` is a `PostgresChangeFilter`
/// and not a `String`, `subscribe()` has no `onError` named parameter).
/// Every one of those would have been a runtime failure in exactly the code
/// path whose whole purpose is to not fail at runtime.
///
/// A smaller file that provably compiles is worth more here than a larger one
/// that does not. If a polling fallback is added later, it should be written
/// against the real package, with a device test, in a change that does not
/// also have to carry the crash fix.
library;

import 'dart:async';

import '../resilience/app_failure.dart';
import '../resilience/failure_mapper.dart';

/// A success-or-failure value, for a stream that must not throw.
///
/// Dart streams have exactly one error channel and it is a global-ish one: an
/// unlistened error reaches the zone, and `PlatformDispatcher.instance.onError`
/// decides what the whole app does about it. So the safe shape is to not use
/// that channel at all for expected failures.
class AsyncResult<T> {
  const AsyncResult.ok(this.data) : failure = null;
  const AsyncResult.err(this.failure) : data = null;

  final T? data;
  final AppFailure? failure;

  bool get isOk => failure == null;
  bool get isErr => failure != null;

  /// The value, or null. Named so a call site cannot accidentally treat a
  /// failure as a value by reaching for `.data`.
  T? get valueOrNull => data;

  /// The failure, or null. Symmetric with [valueOrNull].
  AppFailure? get errorOrNull => failure;

  @override
  String toString() =>
      isOk ? 'AsyncResult.ok($data)' : 'AsyncResult.err($failure)';
}

/// Wrap [source] so its errors become values.
///
/// The returned stream emits `AsyncResult.ok(data)` for every item and
/// `AsyncResult.err(failure)` for every error, and never completes with an
/// error. That is what keeps a `RealtimeSubscribeException` from reaching
/// the zone's unhandled-error path — the exact path that used to replace the
/// entire app with a red error page.
///
/// A terminated socket simply stops emitting. The caller is responsible for
/// deciding what "no news" means: `resilient_subscription.dart` answers that
/// by re-listening with backoff.
///
/// ```dart
/// safeStream(client.from('orders').stream(primaryKey: ['id']), label: 'orders')
///     .listen((r) {
///   if (r.isErr) return;      // classified, logged, not thrown
///   render(r.data!);
/// });
/// ```
///
/// [label] becomes part of the failure message, so the UI can say which
/// stream went quiet rather than the generic sentence.
Stream<AsyncResult<T>> safeStream<T>(Stream<T> source, {String? label}) {
  return source.transform(
    StreamTransformer<T, AsyncResult<T>>.fromHandlers(
      handleData: (data, sink) => sink.add(AsyncResult<T>.ok(data)),
      handleError: (Object error, StackTrace stack, Sink<AsyncResult<T>> sink) {
        // Classified here so no caller has to, and so two streams that fail
        // the same way cannot report it two different ways.
        sink.add(AsyncResult<T>.err(
          AppFailureMapper.map(error, context: label),
        ));
      },
    ),
  );
}
