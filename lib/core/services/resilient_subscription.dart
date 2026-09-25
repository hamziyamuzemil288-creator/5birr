import 'dart:async';

/// Connection state of a [ResilientSubscription], so the UI can stay up and
/// show a quiet inline hint instead of anything modal.
enum RealtimeConnState { connecting, live, retrying, offline }

/// A subscription that survives a realtime subscribe failure.
///
/// WHY THIS EXISTS — every `.stream()` call in this app funnels through
/// `SupabaseStreamBuilder`, which surfaces a failed subscribe as
/// `RealtimeSubscribeException(status: timedOut)`. A `Stream.listen()` with
/// no `onError` lets that reach the zone's unhandled-error path, which
/// `PlatformDispatcher.instance.onError` in `main.dart` turns into
/// `globalCrashError` — swapping the entire app for the "App Error Detected"
/// page. A dropped websocket on a flaky mobile connection is not an
/// application fault, so it must never take the screen down with it.
///
/// The failure is also transient: Supabase's client reconnects on its own,
/// but the first subscribe attempt can time out while the socket is still
/// being established. So this retries the subscription with exponential
/// backoff, reports the state inline, and gives up quietly after
/// [maxRetries] rather than throwing.
///
/// Always call [cancel] from `dispose()`.
class ResilientSubscription<T> {
  ResilientSubscription._(this._stream, this._onData, this._onState);

  final Stream<T> _stream;
  final void Function(T data) _onData;
  final void Function(RealtimeConnState state) _onState;

  StreamSubscription<T>? _sub;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _cancelled = false;

  /// Start a resilient subscription. [_onData] is only called while the
  /// widget is still mounted — callers still guard with `mounted`, because
  /// this object has no knowledge of the widget tree.
  ///
  /// A factory constructor rather than a static method because Dart forbids
  /// using the class type parameter inside a static member, and the stream
  /// type is exactly what we need to parameterise here.
  factory ResilientSubscription({
    required Stream<T> stream,
    required void Function(T data) onData,
    required void Function(RealtimeConnState state) onState,
    Duration initialBackoff = const Duration(seconds: 2),
    Duration maxBackoff = const Duration(seconds: 30),
    int maxRetries = 5,
  }) {
    final sub = ResilientSubscription<T>._(stream, onData, onState);
    sub._initialBackoff = initialBackoff;
    sub._maxBackoff = maxBackoff;
    sub._maxRetries = maxRetries;
    sub._attach();
    return sub;
  }

  late final Duration _initialBackoff;
  late final Duration _maxBackoff;
  late final int _maxRetries;

  void _attach() {
    if (_cancelled) return;
    // Only the very first attach reports `connecting`; _scheduleRetry owns
    // the `retrying` transition. Emitting here as well would notify the UI
    // twice per retry and rebuild the screen for nothing.
    if (_attempt == 0) _onState(RealtimeConnState.connecting);
    // onError is the whole point: consuming the error here is what stops it
    // reaching the unhandled-error path. `cancelOnError` is false so the
    // subscription stays open if the stream recovers on its own.
    _sub = _stream.listen(
      (T data) {
        // A data frame proves the connection is healthy again. Done here
        // rather than in the caller's onData so no call site can forget it
        // and leave the backoff permanently escalated.
        markLive();
        _onData(data);
      },
      onError: (Object _) => _scheduleRetry(),
      cancelOnError: false,
    );
  }

  void _scheduleRetry() {
    _sub?.cancel();
    _sub = null;
    if (_cancelled) return;

    if (_attempt >= _maxRetries) {
      _onState(RealtimeConnState.offline);
      return;
    }

    _attempt++;
    _onState(RealtimeConnState.retrying);
    final backoffMs = _initialBackoff.inMilliseconds * (1 << (_attempt - 1));
    final delay = Duration(
      milliseconds: backoffMs.clamp(_initialBackoff.inMilliseconds, _maxBackoff.inMilliseconds),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _attach);
  }

  /// Internal: reset the backoff after a successful data frame. A long-lived
  /// stream that blips repeatedly would otherwise keep escalating the delay
  /// and eventually give up permanently.
  void markLive() {
    if (_cancelled || _attempt == 0) return;
    _attempt = 0;
    _onState(RealtimeConnState.live);
  }

  void cancel() {
    _cancelled = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _sub?.cancel();
    _sub = null;
  }
}
