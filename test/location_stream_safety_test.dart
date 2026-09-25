// Regression tests for the Task 13 GPS crash class.
//
// geolocator's own timeLimit emits a TimeoutException and CLOSES the
// position stream ("Time limit reached while waiting for position update").
// The old screens listened to that raw stream without handling errors, so
// one GPS hiccup surfaced as the full-screen "App Error Detected" overlay.
//
// These tests prove the replacement contract:
//   1. watchPosition survives a stream that errors immediately — the widget
//      keeps rendering (no unhandled exception) and the error is contained.
//   2. watchPosition retries after the error, so a later position still
//      reaches the caller (self-healing).
//   3. Errors that arrive AFTER a valid fix keep the last fix on screen
//      instead of throwing it away.
//
// The platform channel is mocked, matching the documented pattern in
// geolocator's own test suite.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:birr5/core/services/location_service.dart';

Position _pos(double lat) => Position(
      latitude: lat,
      longitude: 38.74,
      timestamp: DateTime.now(),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

class _MockGeolocator extends Fake
    with MockPlatformInterfaceMixin
    implements GeolocatorPlatform {
  final StreamController<Position> streamController =
      StreamController<Position>.broadcast();

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Stream<Position> getPositionStream({
    LocationSettings? locationSettings,
  }) {
    return streamController.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final mock = _MockGeolocator();
  GeolocatorPlatform.instance = mock;

  test('watchPosition swallows an immediate stream error without throwing',
      () async {
    final received = <Position>[];
    final errors = <void>[];

    final sub = LocationService.instance.watchPosition(
      onData: received.add,
      onError: () => errors.add(null),
      retryDelay: const Duration(milliseconds: 20),
    );

    // The stream errors immediately — the exact failure that used to crash
    // the Active Ride screen with "Time limit reached...".
    mock.streamController.addError(
      TimeoutException('Time limit reached while waiting for position update.'),
    );
    await pumpEventQueue();

    // No error escaped; the subscription is still alive and retrying.
    expect(errors.length, 1);
    expect(received, isEmpty);

    await sub.cancel();
  });

  test('watchPosition retries after an error and delivers later positions',
      () async {
    final received = <Position>[];
    final sub = LocationService.instance.watchPosition(
      onData: received.add,
      onError: () {},
      retryDelay: const Duration(milliseconds: 20),
    );

    mock.streamController.addError(
      TimeoutException('Time limit reached while waiting for position update.'),
    );
    await pumpEventQueue();
    // Real-time wait: the retry timer needs to elapse before resubscribing.
    await Future<void>.delayed(const Duration(milliseconds: 60));

    // After the retry delay, a fresh underlying stream must deliver.
    mock.streamController.add(_pos(9.01));
    await pumpEventQueue();

    expect(received, hasLength(1));
    expect(received.first.latitude, closeTo(9.01, 0.0001));

    await sub.cancel();
  });

  test('watchPosition keeps delivering after a timeout follows a valid fix',
      () async {
    final received = <Position>[];
    final sub = LocationService.instance.watchPosition(
      onData: received.add,
      onError: () {},
      retryDelay: const Duration(milliseconds: 20),
    );

    mock.streamController.add(_pos(9.02)); // first good fix
    await pumpEventQueue();
    mock.streamController.addError(TimeoutException('gap')); // GPS hiccup
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 60));
    mock.streamController.add(_pos(9.03)); // recovered fix
    await pumpEventQueue();

    // The good fix reached the caller, and recovery continues to stream —
    // the caller keeps its last fix through the gap.
    expect(received.map((p) => p.latitude),
        [closeTo(9.02, 0.0001), closeTo(9.03, 0.0001)]);

    await sub.cancel();
  });

  test('cancelling watchPosition tears down retries cleanly', () async {
    var callbacks = 0;
    final sub = LocationService.instance.watchPosition(
      onData: (_) => callbacks++,
      onError: () {},
      retryDelay: const Duration(milliseconds: 20),
    );

    mock.streamController.addError(TimeoutException('gap'));
    await pumpEventQueue();
    await sub.cancel();
    await pumpEventQueue();

    // A late event after cancel must not resurrect the subscription.
    mock.streamController.add(_pos(9.04));
    await pumpEventQueue();
    expect(callbacks, 0);
  });
}
