// Tests for the failure mapper — the single place an exception becomes
// something a user can read.
//
// WHY THIS IS PINNED
// ------------------
// The mapper is the app's only defence against a raw driver message reaching
// a screen. `PostgrestException: {"code":"42501","message":"new row violates
// row-level security policy for table \"wallets\""}` is not something to show
// somebody who just tapped Withdraw. Every assertion below is either
// "classifies as the right kind" or "does not leak the original text".
//
// The leakage assertions are the ones that matter. It is easy to classify
// correctly and still append the raw message in a debug-ish gesture, and that
// failure mode stays invisible until a real user sees a database table name on
// their phone.
//
// WHY LOCAL DOUBLES INSTEAD OF THE REAL PACKAGE TYPES
// ----------------------------------------------------
// The mapper is deliberately `dart:core`-only and identifies its inputs by
// `runtimeType.toString()` plus message text, so it never imports
// postgrest/functions/realtime. That design is what makes it usable from a
// service, a widget and a plain test alike — and it means the test can
// reproduce the shape without depending on a third-party constructor
// signature. Using the real `PostgrestException` here would pin this test to
// one package version's API for no added coverage: the mapper never sees the
// object, only its name and its text.
//
// `_Fake*` below mimic the `toString()` output of the real classes. If
// postgrest ever changes that rendering, this file is where the mismatch
// shows up — which is the point of keeping the doubles visible.
import 'dart:async';
import 'dart:io';

import 'package:birr5/core/resilience/app_failure.dart';
import 'package:birr5/core/resilience/failure_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('already-typed failures pass through', () {
    test('a failure is not reclassified', () {
      const original = AppFailure(
        kind: AppFailureKind.validation,
        message: 'That name is already taken.',
      );
      final mapped = AppFailureMapper.map(original);
      expect(mapped.kind, AppFailureKind.validation);
      expect(mapped.message, 'That name is already taken.');
    });

    test('a timeout marker maps to timeout', () {
      final mapped =
          AppFailureMapper.map(const ResilienceTimeout(Duration(seconds: 20)));
      expect(mapped.kind, AppFailureKind.timeout);
      expect(mapped.isRetryable, isTrue);
    });
  });

  group('transport failures', () {
    test('a dropped socket is a network failure', () {
      final mapped =
          AppFailureMapper.map(const SocketException('Connection refused'));
      expect(mapped.kind, AppFailureKind.network);
      expect(mapped.isRetryable, isTrue);
    });

    test('a TLS handshake failure is a network failure, not unknown', () {
      final mapped =
          AppFailureMapper.map(const HandshakeException('Handshake error'));
      expect(mapped.kind, AppFailureKind.network);
    });

    test('a timeout is a timeout and is retryable', () {
      final mapped = AppFailureMapper.map(TimeoutException('no reply'));
      expect(mapped.kind, AppFailureKind.timeout);
      expect(mapped.isRetryable, isTrue);
    });
  });

  group('HTTP status mapping', () {
    void check(int status, AppFailureKind expected, {bool retryable = false}) {
      // PostgREST puts the HTTP status in the `code` field for most errors
      // and in `status` for the rest; both are exercised below.
      final mapped = AppFailureMapper.map(_FakePostgrest(status: status));
      expect(mapped.statusCode, status, reason: 'status $status');
      expect(mapped.kind, expected, reason: 'status $status');
      expect(mapped.isRetryable, retryable, reason: 'status $status');
    }

    test('401 is unauthorized', () => check(401, AppFailureKind.unauthorized));
    test('403 is forbidden', () => check(403, AppFailureKind.forbidden));
    test('404 is a business error',
        () => check(404, AppFailureKind.validation));
    test('409 conflict is a business error',
        () => check(409, AppFailureKind.validation));
    test('422 is a business error',
        () => check(422, AppFailureKind.validation));
    test('429 is worth retrying',
        () => check(429, AppFailureKind.serverBusy, retryable: true));
    test('500 is worth retrying',
        () => check(500, AppFailureKind.serverBusy, retryable: true));
    test('502 is worth retrying',
        () => check(502, AppFailureKind.serverBusy, retryable: true));
    test('503 is worth retrying',
        () => check(503, AppFailureKind.serverBusy, retryable: true));
  });

  group('business sentinels from our own triggers', () {
    void sentinel(String code, AppFailureKind expected, String readable) {
      final mapped = AppFailureMapper.map(
        _FakePostgrest(
          status: 400,
          message: 'insufficient_balance',
          rawCode: code,
        ),
      );
      expect(mapped.kind, expected, reason: code);
      expect(mapped.message, contains(readable), reason: code);
      expect(mapped.message, isNot(contains(code)),
          reason: 'the internal sentinel name must not reach the user');
    }

    test('a low wallet balance reads as "top up"', () {
      sentinel('insufficient_balance', AppFailureKind.validation, 'top up');
    });

    test('a taken ride reads as "someone else got it"', () {
      sentinel('ride_already_taken', AppFailureKind.validation, 'another driver');
    });

    test('an admin-only setting reads as a permission problem', () {
      sentinel('SETTINGS_ARE_ADMIN_ONLY', AppFailureKind.validation,
          'permission');
    });

    test('an unknown sentinel degrades to a generic sentence, not a leak', () {
      final mapped = AppFailureMapper.map(
        _FakePostgrest(
          status: 400,
          message: 'SOME_INTERNAL_DETAIL_9931',
          rawCode: 'P0001',
        ),
      );
      expect(mapped.message, isNot(contains('9931')));
      expect(mapped.message, isNotEmpty);
    });
  });

  group('isRetryable is the retry decision, and it is correct', () {
    test('business errors are never retried', () {
      for (final kind in [
        AppFailureKind.validation,
        AppFailureKind.unauthorized,
        AppFailureKind.forbidden,
        AppFailureKind.malformed,
        AppFailureKind.unknown,
      ]) {
        expect(
          AppFailure(kind: kind, message: 'x').isRetryable,
          isFalse,
          reason: '$kind must not be retried',
        );
      }
    });

    test('transport failures are always retried', () {
      for (final kind in [
        AppFailureKind.network,
        AppFailureKind.timeout,
        AppFailureKind.serverBusy,
      ]) {
        expect(
          AppFailure(kind: kind, message: 'x').isRetryable,
          isTrue,
          reason: '$kind must be retried',
        );
      }
    });
  });

  group('messages are user-readable, never raw', () {
    void expectNoLeak(AppFailure failure, List<String> secrets) {
      for (final secret in secrets) {
        expect(
          failure.message.toLowerCase(),
          isNot(contains(secret.toLowerCase())),
          reason: 'leaked "$secret" in: ${failure.message}',
        );
      }
    }

    test('an RLS violation does not surface table or policy names', () {
      final mapped = AppFailureMapper.map(
        _FakePostgrest(
          status: 403,
          message: 'new row violates row-level security policy for table '
              '"wallets"',
          rawCode: '42501',
        ),
      );
      expectNoLeak(mapped, ['row-level security', 'wallets', 'policy', '42501']);
    });

    test('a database exception does not surface SQL', () {
      final mapped = AppFailureMapper.map(
        _FakePostgrest(
          status: 400,
          message: 'syntax error at or near "SELCT" in schema public',
          rawCode: '42601',
        ),
      );
      expectNoLeak(mapped, ['SELCT', '42601', 'syntax error']);
    });

    test('an edge function failure does not surface the stack', () {
      final mapped = AppFailureMapper.map(
        _FakeFunctionException(
          functionName: 'repo-chat',
          statusCode: 500,
          message: 'TypeError: x is not a function',
        ),
      );
      expectNoLeak(mapped, ['TypeError', 'not a function', 'repo-chat']);
    });

    test('a realtime subscribe failure does not surface internals', () {
      final mapped = AppFailureMapper.map(
        _FakeRealtimeSubscribeException(
          message: 'WebSocket error connecting to wss://xyz.supabase.co',
        ),
      );
      expect(mapped.kind, AppFailureKind.network);
      expect(mapped.isRetryable, isTrue);
      expectNoLeak(mapped, ['WebSocket', 'wss://', 'timedOut', 'supabase.co']);
    });

    test('every mapped message is a complete sentence, not a fragment', () {
      final cases = <Object>[
        const SocketException('refused'),
        TimeoutException('slow'),
        _FakePostgrest(status: 500),
        _FakePostgrest(status: 401),
        _FakePostgrest(status: 400),
        _FakePostgrest(status: 404),
        _FakeFunctionException(functionName: 'f', statusCode: 503),
        _FakeRealtimeSubscribeException(message: 'ws failed'),
        Exception('something'),
      ];
      for (final error in cases) {
        final message = AppFailureMapper.map(error).message;
        expect(message, isNotEmpty, reason: '$error');
        expect(message.trim(), message, reason: '$error — untrimmed');
        expect(
          message,
          startsWith(RegExp(r'[A-Z]')),
          reason: '"$message" should start with a capital',
        );
        expect(
          RegExp(r'[.!?]$').hasMatch(message),
          isTrue,
          reason: '"$message" reads as a fragment, not a sentence',
        );
      }
    });
  });

  group('context is additive and readable', () {
    test('the call site is added without losing the original meaning', () {
      final mapped = AppFailureMapper.map(
        _FakePostgrest(status: 500),
        context: 'loading your orders',
      );
      expect(mapped.kind, AppFailureKind.serverBusy);
      expect(mapped.message, contains('orders'));
    });

    test('a blank context changes nothing', () {
      final a =
          AppFailureMapper.map(_FakePostgrest(status: 500), context: '   ');
      final b = AppFailureMapper.map(_FakePostgrest(status: 500));
      expect(a.message, b.message);
    });
  });

  group('unknown exceptions degrade to something safe', () {
    test('an unrecognised exception still produces a usable message', () {
      final mapped =
          AppFailureMapper.map(ArgumentError('unexpected null at index 3'));
      expect(mapped.kind, AppFailureKind.unknown);
      expect(mapped.isRetryable, isFalse,
          reason: 'guessing wrong here turns a Retry tap into a quota attack');
      expect(mapped.message, isNot(contains('index 3')));
      expect(mapped.message, isNot(contains('ArgumentError')));
      expect(mapped.message, isNotEmpty);
    });

    test('the mapper itself never throws', () {
      // A mapper that throws is the worst possible failure: it converts a
      // recoverable error into a crash while reporting a crash.
      expect(() => AppFailureMapper.map(Object()), returnsNormally);
      expect(() => AppFailureMapper.map(''), returnsNormally);
      expect(() => AppFailureMapper.map(42), returnsNormally);
    });
  });
}

// ---------------------------------------------------------------------------
// Doubles. See the file header for why these exist rather than the real
// package types. Each reproduces the real class's runtimeType name and its
// toString() rendering, which is the only thing the mapper reads.
// ---------------------------------------------------------------------------

/// Mirrors `postgrest`'s `PostgrestException` toString() shape:
/// `PostgrestException(message: ..., code: ..., status: ...)`.
class _FakePostgrest implements Exception {
  _FakePostgrest({
    required this.status,
    this.message = 'request failed',
    this.rawCode,
  });

  final int status;
  final String message;
  final String? rawCode;

  @override
  String toString() => 'PostgrestException(message: $message, '
      'code: ${rawCode ?? status}, details: null, status: $status)';
}

/// Mirrors `functions`' `FunctionException` shape, which carries the status
/// in `statusCode:`.
class _FakeFunctionException implements Exception {
  _FakeFunctionException({
    required this.functionName,
    required this.statusCode,
    this.message = 'Edge function error',
  });

  final String functionName;
  final int statusCode;
  final String message;

  @override
  String toString() => 'FunctionException(message: $message, '
      'functionName: $functionName, statusCode: $statusCode)';
}

/// Mirrors `realtime`'s `RealtimeSubscribeException`.
class _FakeRealtimeSubscribeException implements Exception {
  _FakeRealtimeSubscribeException({required this.message});

  final String message;

  @override
  String toString() =>
      'RealtimeSubscribeException(status: timedOut, message: $message)';
}
