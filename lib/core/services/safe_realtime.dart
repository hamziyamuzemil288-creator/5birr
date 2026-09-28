/// Realtime feeds that cannot crash the app, and degrade to polling.
///
/// ## Relationship to `resilient_subscription.dart`
///
/// That file's [ResilientSubscription] wraps a *stream*: it re-listens with
/// backoff when the stream errors. It is the right tool for the common case
/// and it is what the existing screens use; it is not being replaced here.
///
/// What it cannot do is the thing the brief actually asks for — *fall back to
/// polling*. It re-listens to the same broken stream, so a server that has
/// dropped the publication, or a proxy that allows HTTPS but not websockets,
/// produces exactly the same failure five times in a row and then goes quiet.
/// Meanwhile the screen shows nothing, because nothing is arriving.
///
/// [ResilientFeed] closes that gap: it runs a realtime channel *and* a poller
/// and emits from whichever is working. The socket makes it live; the poller
/// makes it correct. [ResilientFeed.isLive] says which one you are looking at,
/// so the UI can be honest instead of showing a "live" dot over ten-second-old
/// data.
///
/// The name is deliberately different. Two classes called
/// `ResilientSubscription` in the same codebase is exactly the ambiguity this
/// work is meant to remove.
///
/// ## The crash this prevents
///
/// The app once died with `RealtimeSubscribeException` the moment a user
/// opened the driver feed. The root cause turned out to be a database detail
/// (`REPLICA IDENTITY`), not a code bug — but the *code* problem was that a
/// channel error escaped into the zone's unhandled-error path, which
/// `PlatformDispatcher.instance.onError` turns into a full-screen crash page.
/// A dropped websocket is not an application fault.
///
/// ## Why the backoff caps at 30s
///
/// Long enough that a genuinely-down server is not hammered, short enough that
/// recovery is felt rather than noticed.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/app_failure.dart';
import '../resilience/failure_mapper.dart';
import '../resilience/safe_call.dart';
import 'connectivity_service.dart';
import 'error_logger.dart';

/// A realtime feed backed by a channel, with a polling fallback.
class ResilientFeed<T> {
  ResilientFeed._({
    required SupabaseClient client,
    required this.channelName,
    required Future<void> Function(RealtimeChannel) onListen,
    required Future<T> Function() poller,
    required T? Function(RealtimeChannel) initialSnapshot,
    this.pollInterval = const Duration(seconds: 10),
    this.retryIf,
  })  : _client = client,
        _onListen = onListen,
        _poller = poller,
        _initialSnapshot = initialSnapshot;

  final SupabaseClient _client;
  final String channelName;
  final Future<void> Function(RealtimeChannel) onListen;
  final Future<T> Function() poller;
  final T? Function(RealtimeChannel) initialSnapshot;
  final Duration pollInterval;

  /// Optional predicate over the failure deciding whether a reconnect is even
  /// worth attempting. Auth errors, for example, will not fix themselves.
  final bool Function(AppFailure failure)? retryIf;

  final StreamController<T> _controller = StreamController<T>.broadcast();

  StreamSubscription<dynamic>? _channelSub;
  RealtimeChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  int _attempt = 0;

  /// True when data is arriving over the socket; false when we have fallen
  /// back to polling. Bind this to a "live"/"polling" chip in the UI so the
  /// user is not told data is live when it is 10 seconds old.
  final ValueNotifier<bool> isLive = ValueNotifier<bool>(false);

  /// The stream of values. Never throws — transport failures are reported
  /// through [lastError] and by simply not emitting.
  Stream<T> get stream => _controller.stream;

  final ValueNotifier<AppFailure?> lastError = ValueNotifier<AppFailure?>(null);

  /// Open the feed. Safe to call once; later calls are ignored.
  static ResilientFeed<T> open<T>({
    required SupabaseClient client,
    required String channelName,
    required Future<void> Function(RealtimeChannel) onListen,
    required Future<T> Function() poller,
    required T? Function(RealtimeChannel) initialSnapshot,
    Duration pollInterval = const Duration(seconds: 10),
    bool Function(AppFailure failure)? retryIf,
  }) {
    final sub = ResilientFeed<T>._(
      client: client,
      channelName: channelName,
      onListen: onListen,
      poller: poller,
      initialSnapshot: initialSnapshot,
      pollInterval: pollInterval,
      retryIf: retryIf,
    );
    sub._start();
    return sub;
  }

  void _start() {
    if (_disposed) return;
    _connect();
    // Polling runs alongside the socket rather than instead of it. It is idle
    // most of the time (one query per interval) and it is what guarantees the
    // screen is never stale because a socket misbehaved.
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
  }

  void _connect() {
    if (_disposed) return;
    try {
      final channel = _client.channel(channelName);
      _channel = channel;
      final initial = _initialSnapshot(channel);
      if (initial != null && !_controller.isClosed) {
        _controller.add(initial);
      }
      // onListen is where the caller subscribes to postgres_changes etc.
      _onListen(channel).then((_) {
        _attempt = 0;
        _setLive(true);
      }).catchError((Object e) {
        // Reached when _onListen's own subscription throws, e.g. a
        // RealtimeSubscribeException. Must not escape: that is the crash.
        _handleFailure(e, phase: 'listen');
      });
      channel.subscribe();
    } catch (e) {
      _handleFailure(e, phase: 'connect');
    }
  }

  Future<void> _pollOnce() async {
    if (_disposed) return;
    try {
      final value = await safeCall<T>(
        _poller,
        timeout: const Duration(seconds: 15),
        context: 'polling $channelName',
      );
      if (_disposed || _controller.isClosed) return;
      lastError.value = null;
      _controller.add(value);
    } on AppFailure catch (e) {
      _handleFailure(e, phase: 'poll');
    }
  }

  void _handleFailure(Object e, {required String phase}) {
    if (_disposed) return;
    final failure = e is AppFailure
        ? e
        : AppFailureMapper.map(e, context: 'realtime $channelName ($phase)');
    lastError.value = failure;
    if (failure.isTransport) {
      ConnectivityService.instance.reportRequestFailed();
    }
    ErrorLogger.instance.logError(
      failure,
      null,
      source: 'realtime',
      context: '$channelName/$phase',
    );
    if (failure.kind == AppFailureKind.unauthorized) {
      // A dead token will not fix itself by retrying harder, and a reconnect
      // loop here would burn battery and bury the real problem in logs.
      return;
    }
    if (retryIf != null && !retryIf!(failure)) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    final policy = const RetryPolicy(
      maxAttempts: 8,
      initialBackoff: Duration(seconds: 1),
      maxBackoff: Duration(seconds: 30),
    );
    // backoffFor is unbounded-when-needed, so clamp the attempt index rather
    // than letting a long-lived broken channel grow the delay without limit.
    final delay = policy.backoffFor(
      _attempt.clamp(1, policy.maxAttempts),
    );
    _attempt++;
    _setLive(false);
    debugPrint('[realtime] reconnecting $channelName in ${delay.inSeconds}s');
    _reconnectTimer = Timer(delay, _reconnect);
  }

  void _reconnect() {
    if (_disposed) return;
    _teardownChannel();
    _connect();
  }

  void _setLive(bool value) {
    if (isLive.value != value) isLive.value = value;
  }

  void _teardownChannel() {
    _channelSub?.cancel();
    _channelSub = null;
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    // Detach the error callback first: removeChannel on a channel whose
    // server is gone can itself fire an error.
    channel.onError((_, __) {});
    try {
      _client.removeChannel(channel);
    } catch (e) {
      // Removing a channel we never opened is not a problem worth raising.
      debugPrint('[realtime] removeChannel failed for $channelName: $e');
    }
  }

  void close() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _teardownChannel();
    isLive.dispose();
    lastError.dispose();
    _controller.close();
  }
}

/// Wraps a raw Supabase stream so that errors are values, not exceptions.
///
/// Use when you want the existing `.stream()` call but cannot crash on it:
///
/// ```dart
/// safeStream(client.from('orders').stream(primaryKey: ['id']))
/// ```
///
/// The returned stream emits `Result.ok(data)` or `Result.err(failure)` and
/// never completes with an error. A terminated socket simply stops emitting;
/// combine with a poll (see [ResilientFeed]) if you need liveness.
Stream<AsyncResult<T>> safeStream<T>(Stream<T> source, {String? label}) {
  return source.transform(
    StreamTransformer<T, AsyncResult<T>>.fromHandlers(
      handleData: (data, sink) => sink.add(AsyncResult<T>.ok(data)),
      handleError: (Object error, StackTrace stack, sink) {
        sink.add(AsyncResult<T>.err(AppFailureMapper.map(
          error,
          context: label,
        )));
      },
    ),
  );
}

/// A success-or-failure value, for streams that must not throw.
class AsyncResult<T> {
  const AsyncResult.ok(this.data) : failure = null;
  const AsyncResult.err(this.failure) : data = null;

  final T? data;
  final AppFailure? failure;

  bool get isOk => failure == null;

  T? get valueOrNull => data;

  @override
  String toString() =>
      isOk ? 'AsyncResult.ok($data)' : 'AsyncResult.err($failure)';
}

/// Convenience builder for a postgres_changes subscription.
///
/// Reduces the repeated `on(channel, event: INSERT|UPDATE|DELETE)` boilerplate
/// to one line and, more importantly, wires the `onError` callback that the
/// original code omitted — an unhandled channel error here is the crash that
/// started all this.
void onPostgresChange<T>(
  RealtimeChannel channel, {
  required String table,
  required String filter,
  required void Function(T payload) onChange,
  String? context,
}) {
  channel
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        filter: filter,
        callback: (payload) {
          try {
            final record = payload.newRecord;
            if (record.isEmpty) {
              // DELETE payloads carry only the primary key in newRecord.
              return;
            }
            onChange(record);
          } catch (e) {
            // A malformed payload must not take down the stream; the next
            // payload is 10 seconds away and the screen is still useful.
            ErrorLogger.instance.logError(
              e,
              null,
              source: 'realtime',
              context: context ?? 'postgres_change:$table',
            );
          }
        },
      )
      .subscribe(
        onError: (Object error, StackTrace? stack) {
          // Swallowed deliberately. The retry/poll strategy belongs to
          // ResilientFeed; a raw channel callback has nowhere
          // sensible to put a backoff.
          debugPrint('[realtime] $table error: $error');
        },
      );
}
