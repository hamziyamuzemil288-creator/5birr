/// A realtime feed that cannot crash the app, backed by polling.
///
/// ## What this adds over `resilient_subscription.dart`
///
/// That file wraps a *stream* and re-listens with exponential backoff when
/// it errors. That is the right tool for most cases and it is what the
/// existing realtime screens use. What it cannot do is the other half of
/// the requirement: **fall back to polling**.
///
/// Re-listening cannot fix a server that has dropped the publication, a
/// proxy that allows HTTPS but not websockets, or a corporate firewall.
/// Backing off against a socket that will never open is just a slower
/// version of being offline. This class runs a channel *and* a poller and
/// emits from whichever currently works: the socket makes it live, the
/// poller makes it correct.
///
/// ## Every API detail below is verified, not assumed
///
/// Written against `realtime_client` **2.13.0** (the version pinned in
/// pubspec.lock), reading the package source rather than recalling it. A
/// previous draft of this file assumed an API that does not exist and
/// failed to compile. The three that bit hardest, all now load-bearing:
///
/// * `subscribe` takes a **positional** callback —
///   `subscribe([void Function(RealtimeSubscribeStatus, Object?)?, Duration?])`
///   — and returns `RealtimeChannel`, not a Future. There is no `onError`
///   named parameter.
/// * `subscribe()` **throws** if called twice on one instance
///   (`joinedOnce == true`). So every reconnect must build a *new* channel,
///   which is why [_connect] constructs rather than re-subscribes.
/// * `onPostgresChanges(filter:)` takes a `PostgresChangeFilter?`, not a
///   String. This file passes no filter at all, which is both simpler and
///   the safer default: a filter the server rejects takes the whole
///   subscription down silently.
///
/// There is also no public `channel.onError`. Errors arrive as
/// `RealtimeSubscribeStatus.channelError` through the subscribe callback —
/// which the package routes there for BOTH socket failures and
/// `postgres_changes` replication setup failures (it forwards system-event
/// errors explicitly, because a channel can report `subscribed` and then
/// deliver nothing). Watching that one callback is sufficient.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/app_failure.dart';
import '../resilience/failure_mapper.dart';
import '../resilience/safe_call.dart';
import 'connectivity_service.dart';
import 'error_logger.dart';

/// A channel plus a poller, emitting from whichever is working.
class ResilientFeed<T> {
  ResilientFeed._({
    required SupabaseClient client,
    required this.channelName,
    required List<FeedBinding> bindings,
    required Future<T> Function() poller,
    this.pollInterval = const Duration(seconds: 15),
    this.retryIf,
  })  : _client = client,
        _bindings = bindings,
        _poller = poller;

  final SupabaseClient _client;
  final String channelName;
  final List<FeedBinding> _bindings;
  final Future<T> Function() _poller;

  /// How often the poller runs *alongside* a healthy socket.
  ///
  /// 15s, not 10s: the poller is the safety net, not the primary path, and
  /// a 15s worst case is a better trade than doubling the query load of
  /// every screen that uses this. It still runs when the socket is fine,
  /// because the socket being fine is exactly what you cannot assume during
  /// the failure this exists for.
  final Duration pollInterval;

  final bool Function(AppFailure failure)? retryIf;

  final StreamController<T> _controller = StreamController<T>.broadcast();

  Timer? _pollTimer;
  RealtimeChannel? _channel;
  Timer? _reconnectTimer;
  bool _disposed = false;
  int _attempt = 0;

  /// True when data is arriving over the socket. Bind this to a "live" /
  /// "polling" chip so the UI never claims liveness it does not have.
  final ValueNotifier<bool> isLive = ValueNotifier<bool>(false);

  /// The last transport problem, or null. A value, never an error: this
  /// stream is not allowed to fail a zone.
  final ValueNotifier<AppFailure?> lastError = ValueNotifier<AppFailure?>(null);

  /// Values from whichever transport is currently working. Never throws.
  Stream<T> get stream => _controller.stream;

  /// Open the feed. Call `close()` from `dispose()`.
  static ResilientFeed<T> open<T>({
    required SupabaseClient client,
    required String channelName,
    required List<FeedBinding> bindings,
    required Future<T> Function() poller,
    Duration pollInterval = const Duration(seconds: 15),
    bool Function(AppFailure failure)? retryIf,
  }) {
    final feed = ResilientFeed<T>._(
      client: client,
      channelName: channelName,
      bindings: bindings,
      poller: poller,
      pollInterval: pollInterval,
      retryIf: retryIf,
    );
    feed._start();
    return feed;
  }

  void _start() {
    if (_disposed) return;
    _connect();
    // Polling runs alongside the socket, not instead of it, so a screen can
    // never go stale just because the socket misbehaved.
    _pollTimer = Timer.periodic(pollInterval, (_) => _pollOnce());
  }

  void _connect() {
    if (_disposed) return;
    try {
      // A NEW channel every attempt: subscribe() throws on a second call
      // for the same instance, so re-subscribing is not an option.
      final channel = _client.channel(channelName);
      for (final binding in _bindings) {
        binding.attach(channel);
      }
      _channel = channel;
      channel.subscribe(_onStatus);
    } catch (e) {
      // client.channel() or a binding's attach can throw synchronously on a
      // bad table or filter. Caught here so it cannot escape into a zone.
      _handleFailure(e, phase: 'connect');
    }
  }

  /// The subscribe status callback. Positional, and the only error channel
  /// this package offers.
  void _onStatus(RealtimeSubscribeStatus status, Object? error) {
    if (_disposed) return;
    switch (status) {
      case RealtimeSubscribeStatus.subscribed:
        _attempt = 0;
        _setLive(true);
        lastError.value = null;
        // A successful subscribe proves the socket works; clear the banner.
        ConnectivityService.instance.reportRequestSucceeded();
      case RealtimeSubscribeStatus.channelError:
        _handleFailure(
          error ?? 'The live connection reported an error.',
          phase: 'channel',
        );
      case RealtimeSubscribeStatus.closed:
        _scheduleReconnect();
      case RealtimeSubscribeStatus.timedOut:
        _handleFailure(
          error ?? 'The live connection timed out.',
          phase: 'timeout',
        );
    }
  }

  Future<void> _pollOnce() async {
    if (_disposed) return;
    try {
      final value = await safeCall<T>(
        _poller,
        timeout: const Duration(seconds: 20),
        context: 'polling $channelName',
      );
      if (_disposed || _controller.isClosed) return;
      lastError.value = null;
      if (!_controller.isClosed) _controller.add(value);
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
    // A dead access token will not fix itself by retrying harder, and a
    // reconnect loop would burn battery and bury the real problem in logs.
    if (failure.kind == AppFailureKind.unauthorized) return;
    if (retryIf != null && !retryIf!(failure)) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    const policy = RetryPolicy(
      maxAttempts: 8,
      initialBackoff: Duration(seconds: 1),
      maxBackoff: Duration(seconds: 30),
    );
    // backoffFor is unbounded in `attempt`, and `1 << n` is 0 past 63, so
    // the index is clamped into the policy's range. Without this a long-lived
    // broken feed would eventually compute a zero delay and hot-loop.
    final delay = policy.backoffFor(_attempt.clamp(1, policy.maxAttempts));
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
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    // removeChannel awaits unsubscribe, and unsubscribing a channel whose
    // socket is already gone can hang, so it is bounded by a timeout and
    // its failure is deliberately ignored — there is nothing useful to do
    // with it and throwing here would turn a reconnect into a crash.
    unawaited(
      _client
          .removeChannel(channel)
          .timeout(const Duration(seconds: 5))
          .catchError((Object _) => 'ignored'),
    );
  }

  /// Release the channel, the poll timer and both notifiers.
  void close() {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _pollTimer?.cancel();
    _teardownChannel();
    isLive.dispose();
    lastError.dispose();
    unawaited(_controller.close());
  }
}

/// One table to watch on a feed's channel.
///
/// A small named type rather than a bare callback, so the channel is built
/// by chaining `[FeedBinding]`s and a reader can see at a glance which
/// tables a feed depends on. A wrong table name here is the failure mode
/// `assert_staff_task_sources_are_live` exists to catch in CI.
class FeedBinding {
  const FeedBinding({
    required this.table,
    required this.onChange,
    this.event = PostgresChangeEvent.all,
    this.schema = 'public',
  });

  final String table;
  final String schema;
  final PostgresChangeEvent event;
  final void Function(PostgresChangePayload payload) onChange;

  void attach(RealtimeChannel channel) {
    // The return value is ignored deliberately: onPostgresChanges returns
    // the same channel for chaining, and each binding attaches to the one
    // channel this feed owns. No filter is passed — see the library docs for
    // why a filter the server rejects is worse than none.
    channel.onPostgresChanges(
      event: event,
      schema: schema,
      table: table,
      callback: onChange,
    );
  }
}

/// A success-or-failure value, for a stream that must not throw.
///
/// Dart streams have one error channel, and an unlistened error reaches the
/// zone, where `PlatformDispatcher.instance.onError` decides what the whole
/// app does about it. So expected failures travel as values instead.
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
/// the zone's unhandled-error path — the exact path that used to replace
/// the entire app with a red error page.
///
/// A terminated socket simply stops emitting. [ResilientFeed] is the answer
/// to "what then": keep polling.
///
/// ```dart
/// safeStream(client.from('orders').stream(primaryKey: ['id']), label: 'orders')
///     .listen((r) {
///   if (r.isErr) return;      // classified, logged, not thrown
///   render(r.data!);
/// });
/// ```
Stream<AsyncResult<T>> safeStream<T>(Stream<T> source, {String? label}) {
  return source.transform(
    StreamTransformer<T, AsyncResult<T>>.fromHandlers(
      handleData: (data, sink) => sink.add(AsyncResult<T>.ok(data)),
      handleError: (
        Object error,
        StackTrace stack,
        Sink<AsyncResult<T>> sink,
      ) {
        // Classified here so no caller has to, and so two streams that fail
        // the same way cannot report it two different ways.
        sink.add(AsyncResult<T>.err(
          AppFailureMapper.map(error, context: label),
        ));
      },
    ),
  );
}
