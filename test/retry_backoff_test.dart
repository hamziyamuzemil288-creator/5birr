// Tests for the retry helper — the thing every network call in the app goes
// through, and therefore the thing that decides whether a user sees a
// spinner, a retry button, or a wrong number on a money screen.
//
// WHAT IS ACTUALLY BEING PINNED
// ------------------------------
// 1. A transient failure is retried and the user still gets their data. This
//    is the entire point; if it regresses, every screen gets worse for
//    everyone on a bad network.
// 2. A business error is NOT retried. Resending a request the server already
//    rejected on its merits produces the same rejection, delays the message
//    the user needs to read, and burns quota. This is the assertion most
//    likely to be broken by someone "fixing" a slow error message.
// 3. The backoff grows and is capped, so a long outage does not turn into a
//    request every 400ms from every phone.
// 4. The jitter is real. Identical clients that all failed during the same
//    blip retrying in the same millisecond is how a brief outage becomes a
//    self-inflicted thundering herd on recovery.
// 5. Attempts are hard-capped, so total time is bounded and a screen can
//    bound its own UI with confidence.
//
// The tests use an injected Random and zero backoff wherever they are
// asserting on attempt counts, so they are fast and not timing-flaky.
import 'dart:async';
import 'dart:math';

import 'package:birr5/core/resilience/app_failure.dart';
import 'package:birr5/core/resilience/safe_call.dart';
import 'package:flutter_test/flutter_test.dart';

/// A policy with no real waiting, so attempt-count assertions are instant.
const RetryPolicy _instant =
    RetryPolicy(maxAttempts: 3, initialBackoff: Duration.zero, jitterFactor: 0);

void main() {
  group('withRetry — success paths', () {
    test('returns the value without retrying when the first attempt works', () async {
      var calls = 0;
      final result = await withRetry<String>(
        () async {
          calls++;
          return 'ok';
        },
        policy: _instant,
      );

      expect(result, 'ok');
      expect(calls, 1, reason: 'a working call must not be retried');
    });

    test('retries a transient failure and returns the eventual success', () async {
      var calls = 0;
      final result = await withRetry<String>(
        () async {
          calls++;
          if (calls < 3) {
            throw const AppFailure(
              kind: AppFailureKind.network,
              message: 'No connection.',
            );
          }
          return 'recovered';
        },
        policy: _instant,
      );

      expect(result, 'recovered');
      expect(calls, 3);
    });
  });

  group('withRetry — what must not be retried', () {
    test('does not retry a 4xx business error', () async {
      var calls = 0;
      await expectLater(
        withRetry<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.validation,
              message: 'That name is already taken.',
            );
          },
          policy: _instant,
        ),
        throwsA(isA<AppFailure>().having(
          (f) => f.kind,
          'kind',
          AppFailureKind.validation,
        )),
      );
      expect(calls, 1,
          reason: 'resending a rejected request cannot change the answer');
    });

    test('does not retry an expired session', () async {
      var calls = 0;
      await expectLater(
        withRetry<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.unauthorized,
              message: 'Please sign in again.',
            );
          },
          policy: _instant,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    });

    test('the money policy makes exactly one attempt', () async {
      var calls = 0;
      await expectLater(
        withRetry<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.serverBusy,
              message: 'Try again shortly.',
            );
          },
          policy: const RetryPolicy.money(),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1,
          reason: 'a duplicate charge is worse than a failed charge');
    });

    test('retryIf can veto a retryable failure', () async {
      var calls = 0;
      await expectLater(
        withRetry<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.serverBusy,
              message: 'Try again shortly.',
            );
          },
          policy: _instant,
          retryIf: (f) => f.statusCode == null,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    });
  });

  group('withRetry — attempt cap', () {
    test('stops at maxAttempts and throws the last failure', () async {
      var calls = 0;
      await expectLater(
        withRetry<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.serverBusy,
              message: 'Down.',
            );
          },
          policy: _instant,
        ),
        throwsA(isA<AppFailure>().having(
          (f) => f.message,
          'message',
          'Down.',
        )),
      );
      expect(calls, 3, reason: 'maxAttempts is a hard cap, not a target');
    });

    test('onRetry fires once per actual retry, not on the final failure', () async {
      final seen = <int>[];
      await expectLater(
        withRetry<String>(
          () async {
            throw const AppFailure(
              kind: AppFailureKind.network,
              message: 'No connection.',
            );
          },
          policy: _instant,
          onRetry: (attempt, _) => seen.add(attempt),
        ),
        throwsA(isA<AppFailure>()),
      );
      // 3 attempts means 2 waits between them.
      expect(seen, [1, 2]);
    });
  });

  group('withRetry — timeout', () {
    test('a call that never returns is failed as a timeout, not left hanging',
        () async {
      var completed = false;
      await expectLater(
        withRetry<String>(
          () async {
            await Future<void>.delayed(const Duration(seconds: 30));
            completed = true;
            return 'too late';
          },
          policy: const RetryPolicy.none(),
          timeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<AppFailure>().having(
          (f) => f.kind,
          'kind',
          AppFailureKind.timeout,
        )),
      );
      expect(completed, isFalse);
    });

    test('a raw TimeoutException maps to the same typed timeout', () async {
      await expectLater(
        safeCall<String>(
          () async {
            throw TimeoutException('too slow');
          },
          timeout: const Duration(seconds: 5),
        ),
        throwsA(isA<AppFailure>().having(
          (f) => f.kind,
          'kind',
          AppFailureKind.timeout,
        )),
      );
    });
  });

  group('safeCall', () {
    test('never retries, even on a transient failure', () async {
      var calls = 0;
      await expectLater(
        safeCall<String>(
          () async {
            calls++;
            throw const AppFailure(
              kind: AppFailureKind.network,
              message: 'No connection.',
            );
          },
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    });

    test('attaches the call-site context to the failure message', () async {
      await expectLater(
        safeCall<String>(
          () async => throw const AppFailure(
            kind: AppFailureKind.serverBusy,
            message: 'Down.',
          ),
          context: 'loading your orders',
        ),
        throwsA(isA<AppFailure>().having(
          (f) => f.message,
          'message',
          contains('loading your orders'),
        )),
      );
    });
  });

  group('RetryPolicy.backoffFor', () {
    const policy = RetryPolicy(
      initialBackoff: Duration(milliseconds: 400),
      maxBackoff: Duration(seconds: 8),
      jitterFactor: 0,
    );

    test('the first attempt has no delay', () {
      expect(policy.backoffFor(1), Duration.zero);
    });

    test('grows exponentially', () {
      expect(policy.backoffFor(2), const Duration(milliseconds: 400));
      expect(policy.backoffFor(3), const Duration(milliseconds: 800));
      expect(policy.backoffFor(4), const Duration(milliseconds: 1600));
    });

    test('is capped, so a long outage does not become a tight loop', () {
      expect(policy.backoffFor(20), const Duration(seconds: 8));
      expect(policy.backoffFor(200), const Duration(seconds: 8));
    });

    test('jitter stays inside the configured band', () {
      const jittered = RetryPolicy(
        initialBackoff: Duration(milliseconds: 1000),
        maxBackoff: Duration(seconds: 8),
        jitterFactor: 0.5,
      );
      // The extremes of Random: 0.0 -> -50%, ~1.0 -> +50%.
      final low = jittered.backoffFor(2, random: _FixedRandom(0.0)).inMilliseconds;
      final high =
          jittered.backoffFor(2, random: _FixedRandom(0.999999)).inMilliseconds;
      expect(low, inInclusiveRange(500, 501));
      expect(high, inInclusiveRange(1499, 1500));
    });

    test('jitter actually varies — a fixed delay is the thundering herd', () {
      const jittered = RetryPolicy(
        initialBackoff: Duration(milliseconds: 1000),
        maxBackoff: Duration(seconds: 8),
        jitterFactor: 0.5,
      );
      final delays = <int>{};
      for (var i = 0; i < 200; i++) {
        delays.add(jittered.backoffFor(2).inMilliseconds);
      }
      expect(delays.length, greaterThan(50),
          reason: 'a single repeated delay would be the bug this guards');
      expect(delays.every((d) => d >= 500 && d <= 1500), isTrue);
    });

    test('a zero jitter factor is fully deterministic', () {
      const noJitter = RetryPolicy(
        initialBackoff: Duration(milliseconds: 300),
        maxBackoff: Duration(seconds: 8),
        jitterFactor: 0,
      );
      expect(
        {for (var i = 0; i < 20; i++) noJitter.backoffFor(3).inMilliseconds},
        {600},
      );
    });
  });

  group('InFlightGuard', () {
    test('a second concurrent call is skipped', () async {
      final guard = InFlightGuard();
      final started = Completer<void>();
      var runs = 0;

      final first = guard.run(() async {
        runs++;
        started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return 'first';
      });
      await started.future;

      final second = await guard.run(() async {
        runs++;
        return 'second';
      });

      expect(second, isNull);
      expect(runs, 1);
      expect(await first, 'first');
    });

    test('releases the gate after success and after failure', () async {
      final guard = InFlightGuard();

      expect(await guard.run(() async => 'a'), 'a');

      await expectLater(
        guard.run<String>(() async => throw StateError('boom')),
        throwsStateError,
      );

      // A failure must not wedge the button forever.
      expect(guard.isBusy, isFalse);
      expect(await guard.run(() async => 'b'), 'b');
    });
  });

  group('Debouncer', () {
    test('collapses a burst into a single call', () async {
      final debouncer = Debouncer(delay: const Duration(milliseconds: 30));
      var calls = 0;

      for (var i = 0; i < 20; i++) {
        debouncer(() => calls++);
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(calls, 1, reason: 'only the last keystroke should reach the network');
    });

    test('flush runs immediately and drops the pending call', () async {
      final debouncer = Debouncer(delay: const Duration(milliseconds: 200));
      var calls = 0;

      debouncer(() => calls++);
      debouncer.flush(() => calls++);
      await Future<void>.delayed(const Duration(milliseconds: 260));

      expect(calls, 1);
    });
  });
}

/// A [Random] returning a fixed value, so jitter bounds can be asserted
/// exactly rather than statistically.
class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  double nextDouble() => _value;

  @override
  bool nextBool() => _value > 0.5;

  @override
  int nextInt(int max) => (_value * max).floor().clamp(0, max - 1);
}
