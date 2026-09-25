// Regression tests for the RealtimeSubscribeException crash.
//
// Same bug class as location_stream_safety_test.dart: a realtime subscribe
// timeout was reaching the zone's unhandled-error path, which
// PlatformDispatcher.instance.onError in main.dart turns into
// globalCrashError — replacing the entire app with the "App Error Detected"
// page. A dropped websocket is not an application fault.
//
// The decisive assertion here is implicit: flutter_test fails a test on any
// unhandled asynchronous error. So "a stream that errors does not fail the
// test" IS the assertion that the crash is gone. A regression that removed
// the onError handler would fail this suite loudly.
import 'dart:async';

import 'package:birr5/core/services/resilient_subscription.dart';
import 'package:flutter_test/flutter_test.dart';

/// A stream that fails its first [failures] subscribe attempts the way
/// SupabaseStreamBuilder reports a subscribe timeout, then succeeds.
///
/// Stream.multi's callback runs once per listen, which is what we need: the
/// wrapper re-listens to the SAME Stream object, so the failure has to be
/// re-armed on every attempt rather than left behind on a closed controller.
Stream<int> flaky({
  int failures = 1,
  int? emitAfterSuccess,
  int? emitEveryAttempt,
}) {
  var attempt = 0;
  return Stream<int>.multi((controller) {
    attempt++;
    if (attempt <= failures) {
      // RealtimeSubscribeException(status: timedOut)
      controller.addError(Exception('RealtimeSubscribeException: timedOut'));
      return;
    }
    if (emitAfterSuccess != null) controller.add(emitAfterSuccess);
    if (emitEveryAttempt != null) controller.add(emitEveryAttempt);
  });
}

void main() {
  test('a subscribe timeout does NOT reach the unhandled-error path', () async {
    // If onError were missing, this error would be unhandled and flutter_test
    // would fail this test — which is exactly the crash being guarded.
    final states = <RealtimeConnState>[];
    final received = <int>[];

    final sub = ResilientSubscription<int>(
      stream: flaky(failures: 1, emitAfterSuccess: 42),
      initialBackoff: const Duration(milliseconds: 10),
      onData: received.add,
      onState: states.add,
    );

    await Future<void>.delayed(const Duration(milliseconds: 150));
    sub.cancel();

    expect(received, [42], reason: 'should recover and deliver the event');
    expect(
      states,
      contains(RealtimeConnState.retrying),
      reason: 'the UI must be told it is retrying, not left waiting forever',
    );
  });

  test('a healthy stream reports connecting and passes data through',
      () async {
    final states = <RealtimeConnState>[];
    final received = <int>[];

    final sub = ResilientSubscription<int>(
      stream: flaky(failures: 0, emitAfterSuccess: 1),
      onData: received.add,
      onState: states.add,
    );

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(received, [1]);
    expect(states.first, RealtimeConnState.connecting);
    sub.cancel();
  });

  test('repeated failures back off, then give up quietly as offline',
      () async {
    final states = <RealtimeConnState>[];

    final sub = ResilientSubscription<int>(
      stream: flaky(failures: 999),
      initialBackoff: const Duration(milliseconds: 5),
      maxBackoff: const Duration(milliseconds: 10),
      maxRetries: 3,
      onData: (_) {},
      onState: states.add,
    );

    // Long enough for 3 retries at the capped backoff to elapse.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(
      states.last,
      RealtimeConnState.offline,
      reason: 'must give up without throwing — a lost feed is a degradation',
    );
    expect(
      states.where((s) => s == RealtimeConnState.retrying).length,
      3,
      reason: 'exactly maxRetries retries, no runaway reconnect loop',
    );
    sub.cancel();
  });

  test('cancel() stops retries and stops delivering data', () async {
    final received = <int>[];
    final states = <RealtimeConnState>[];

    final sub = ResilientSubscription<int>(
      stream: flaky(failures: 999),
      initialBackoff: const Duration(milliseconds: 20),
      onData: received.add,
      onState: states.add,
    );

    sub.cancel();
    final countAtCancel = states.length;
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // The contract dispose() depends on: no timer keeps re-subscribing past
    // teardown, which would call setState on a disposed State.
    expect(received, isEmpty);
    expect(states.length, countAtCancel);
  });

  test('backoff resets after a successful frame', () async {
    final states = <RealtimeConnState>[];

    final sub = ResilientSubscription<int>(
      stream: flaky(failures: 1, emitAfterSuccess: 7),
      initialBackoff: const Duration(milliseconds: 10),
      onData: (_) {},
      onState: states.add,
    );

    await Future<void>.delayed(const Duration(milliseconds: 150));

    // After a good frame the connection is reported live, so the UI stops
    // showing "reconnecting" and the backoff no longer escalates.
    expect(states.last, RealtimeConnState.live);
    sub.cancel();
  });
}
