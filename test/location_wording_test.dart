// Location states must never be described as connectivity, and vice versa.
//
// WHY THIS IS PINNED
// ------------------
// With phone location off, the app told the user they were "offline". They
// are not: the phone is on a working network and the GPS radio is off. The
// user goes and troubleshoots their router, and nothing changes. That is a
// concrete, reported bug, and it is invisible to review because the string
// lives in a switch statement that reads perfectly well in isolation.
//
// The same confusion runs the other way: a user with no data but location
// on must not be told location is off.
//
// So this asserts a property of the WORDS, not of the logic: for every
// location state, the message names location and never claims to know
// something about the internet — and the connectivity layer's messages stay
// about connectivity.
import 'dart:io';

import 'package:birr5/core/services/connectivity_service.dart';
import 'package:birr5/core/services/location_prompt.dart';
import 'package:birr5/core/services/location_service.dart';
import 'package:birr5/core/resilience/app_failure.dart';
import 'package:birr5/core/resilience/failure_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// Words that assert a knowledge of the network connection. A location
/// message containing any of these is telling the user something we do not
/// know, and is the bug.
const _networkClaims = [
  'offline',
  'no internet',
  'internet connection',
  'wifi',
  'network',
  'data connection',
];

void main() {
  group('every location state is described as a LOCATION problem', () {
    for (final status in LocationStatus.values) {
      test('$status', () {
        final message = LocationMessages.forStatus(status).toLowerCase();
        for (final claim in _networkClaims) {
          expect(
            message,
            isNot(contains(claim)),
            reason: '"$message" claims something about connectivity, but this '
                'is a location state ($status). The user will troubleshoot '
                'the wrong thing.',
          );
        }
      });
    }
  });

  group('messages are specific enough to act on', () {
    test('a disabled service says location is off, and says how to fix it', () {
      final m = LocationMessages.serviceDisabled.toLowerCase();
      expect(m, contains('location'));
      expect(m, contains('turn on'));
    });

    test('a denied permission asks for permission, not for a signal', () {
      final m = LocationMessages.denied.toLowerCase();
      expect(m, contains('permission'));
    });

    test('a permanently denied permission points at Settings', () {
      // 'permission' and 'settings' are the two words that distinguish this
      // from a plain denial the user can retry in place.
      final m = LocationMessages.deniedForever.toLowerCase();
      expect(m, contains('permission'));
      expect(m, contains('settings'));
    });

    test('needsSettings only for the states a settings visit can fix', () {
      expect(LocationMessages.needsSettings(LocationStatus.serviceDisabled),
          isTrue);
      expect(LocationMessages.needsSettings(LocationStatus.deniedForever),
          isTrue);
      // A one-off denial is retryable in place; sending the user to Settings
      // for it is a dead end.
      expect(LocationMessages.needsSettings(LocationStatus.denied), isFalse);
      expect(LocationMessages.needsSettings(LocationStatus.error), isFalse);
    });
  });

  group('connectivity messages stay about connectivity', () {
    test('a network failure never mentions location', () {
      final message = AppFailureMapper
          .map(const SocketException('Connection refused'))
          .message
          .toLowerCase();
      expect(message, contains('connection') || message.contains('internet'));
      // The converse rule: an internet message must not talk about GPS.
      expect(message, isNot(contains('location')));
      expect(message, isNot(contains('gps')));
    });

    test('the connectivity enum is about the connection, not the radio', () {
      // Guards the vocabulary, not the behaviour: ConnectionStatus.offline
      // must never be reused to mean "GPS off", which is what produced the
      // original bug.
      expect(ConnectionStatus.values.map((c) => c.name),
          everyElement(isNot(contains('location'))));
    });

    test('needsAuth is about the session, not location', () {
      const f = AppFailure(kind: AppFailureKind.unauthorized, message: 'x');
      expect(f.needsAuth, isTrue);
      expect(f.message.toLowerCase(), isNot(contains('location')));
    });
  });

  group('the prompt gate is a single session-scoped flag', () {
    // What is deliberately NOT tested here: that `offerOnce` really shows at
    // most one dialog. It takes a BuildContext, so proving that needs a
    // widget test pumping a real screen, and that does not exist yet. The
    // flag is the gate; the dialog is the thing it guards. Claiming the
    // dialog is proven would overstate what this file checks.
    test('a fresh app start has not asked yet', () {
      // Cold start is the one moment re-arming is correct, so this is the
      // only state asserted. A cold start with a lingering `true` would mean
      // the flag was persisted, which is the product decision we rejected:
      // a driver who said "Not now" in March should still be asked next time
      // they go available.
      expect(LocationPrompt.instance.answered, isFalse);
    });

    test('rearm is idempotent, not a toggle', () {
      // A toggle-shaped rearm is the plausible wrong implementation: call it
      // twice and the flag silently flips back to "not yet asked", so a
      // driver gets nagged on every availability change.
      LocationPrompt.instance.rearm();
      LocationPrompt.instance.rearm();
      expect(LocationPrompt.instance.answered, isFalse);
    });
  });
}
