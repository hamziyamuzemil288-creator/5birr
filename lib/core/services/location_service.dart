import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// Outcome of an attempt to obtain the device position.
enum LocationStatus { ready, serviceDisabled, denied, deniedForever, error }

/// A device-position attempt with a structured result so screens can
/// distinguish "GPS off" from "permission denied" from a hard error and
/// offer the right recovery (enable GPS / retry / open app settings).
class LocationResult {
  final LocationStatus status;
  final Position? position;
  final String? errorMessage;

  /// True when [position] came from the OS cache rather than a fresh fix —
  /// callers can show "approximate location" instead of implying live GPS.
  final bool isLastKnown;
  const LocationResult._(this.status,
      [this.position, this.errorMessage, this.isLastKnown = false]);
  const LocationResult.ready(Position p, {bool isLastKnown = false})
      : this._(LocationStatus.ready, p, null, isLastKnown);
  const LocationResult.serviceDisabled()
      : this._(LocationStatus.serviceDisabled);
  const LocationResult.denied() : this._(LocationStatus.denied);
  const LocationResult.deniedForever() : this._(LocationStatus.deniedForever);
  const LocationResult.error(String msg)
      : this._(LocationStatus.error, null, msg);

  bool get success => status == LocationStatus.ready && position != null;
}

/// A latitude/longitude pair parsed from a Postgres geography column
/// (Supabase returns these as GeoJSON) or a WKT-ish string.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);

  static GeoPoint? parse(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map) {
      final coords = raw['coordinates'];
      if (coords is List && coords.length >= 2) {
        final lng = (coords[0] as num?)?.toDouble();
        final lat = (coords[1] as num?)?.toDouble();
        if (lat != null && lng != null) return GeoPoint(lat, lng);
      }
      return null;
    }
    if (raw is String) {
      final m =
          RegExp(r'POINT\s*\(\s*(-?[0-9.]+)\s+(-?[0-9.]+)').firstMatch(raw);
      if (m != null) {
        final lng = double.tryParse(m.group(1)!);
        final lat = double.tryParse(m.group(2)!);
        if (lat != null && lng != null) return GeoPoint(lat, lng);
      }
    }
    return null;
  }
}

class LocationService {
  LocationService._();
  static final instance = LocationService._();

  /// How long a fresh-fix attempt may take before falling back to the
  /// last-known position. Long enough for a cold GPS fix, short enough
  /// that screens never appear frozen.
  static const Duration _freshFixTimeLimit = Duration(seconds: 10);

  /// Tracks the permission result across calls so repeated UI triggers do
  /// not re-open the OS permission dialog in a loop (Task 13 flicker).
  LocationPermission? _lastKnownPermission;

  /// One in-flight fix attempt at a time; concurrent callers share the
  /// same future instead of stacking GPS requests.
  Future<LocationResult>? _inFlight;

  /// Best-effort current position, or null on any failure.
  /// (Legacy call sites; prefer [getCurrentPositionDetailed].)
  Future<Position?> getCurrentPosition() async {
    final r = await getCurrentPositionDetailed();
    return r.position;
  }

  /// Structured attempt: verifies location services are on, requests the
  /// runtime permission if needed, then fetches a fresh high-accuracy GPS
  /// fix. Falls back to the OS last-known position when the fresh fix
  /// times out, and NEVER throws — failures come back as a [LocationResult].
  ///
  /// Concurrent callers share one in-flight attempt (permission dialogs and
  /// GPS requests do not stack), and repeated calls reuse the permission
  /// answer so the permission dialog cannot flicker in a loop.
  Future<LocationResult> getCurrentPositionDetailed() async {
    final existing = _inFlight;
    if (existing != null) return existing;

    final attempt = _attemptFreshFix();
    _inFlight = attempt;
    try {
      return await attempt;
    } finally {
      if (identical(_inFlight, attempt)) _inFlight = null;
    }
  }

  Future<LocationResult> _attemptFreshFix() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return const LocationResult.serviceDisabled();

      // checkPermission is cheap and dialog-free; only escalate to a
      // request when the answer is not yet known, and never re-prompt on
      // the same run when a previous request was already answered.
      var permission =
          _lastKnownPermission ?? await Geolocator.checkPermission();
      _lastKnownPermission = permission;
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        _lastKnownPermission = permission;
        if (permission == LocationPermission.denied) {
          return const LocationResult.denied();
        }
      }
      if (permission == LocationPermission.deniedForever) {
        return const LocationResult.deniedForever();
      }
      if (permission == LocationPermission.unableToDetermine) {
        return const LocationResult.denied();
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: _freshFixTimeLimit,
      );
      return LocationResult.ready(position);
    } on TimeoutException {
      // A GPS cold-start can exceed the limit. The OS cache is still a
      // usable approximation — return it instead of an error (Task 13:
      // a slow GPS must degrade gracefully, never fail the screen).
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) return LocationResult.ready(last, isLastKnown: true);
      } catch (_) {
        // Fall through to the generic error path.
      }
      return const LocationResult.error(
          'Location is taking too long — try again.');
    } catch (e) {
      return LocationResult.error(e.toString());
    }
  }

  /// A subscription that never throws into the caller's widget tree.
  ///
  /// geolocator emits a TimeoutException and CLOSES the stream whenever its
  /// `timeLimit` elapses without an update — an unhandled error there
  /// crashed the whole screen (the "App Error Detected" overlay). This
  /// wrapper swallows timeout/handler errors, keeps the last good fix on
  /// the caller's side, and retries the underlying stream automatically so
  /// GPS hiccups recover without UI action.
  Stream<Position> getPositionStream({
    int distanceFilter = 50,
    Duration interval = const Duration(seconds: 10),
  }) {
    // No timeLimit on the raw stream: geolocator would close it on any
    // gap (indoor lobbies, elevator rides) and the caller would have to
    // resubscribe anyway. Retries are handled by [watchPosition] below.
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
      ),
    );
  }

  /// Long-lived, self-healing position subscription. Errors (GPS toggled
  /// off mid-trip, platform hiccups) do not kill the subscription: they
  /// pause it and retry with backoff until [backoff] is exceeded, while
  /// [onError] keeps the caller informed for inline status UI.
  StreamSubscription<Position> watchPosition({
    required void Function(Position pos) onData,
    void Function()? onError,
    int distanceFilter = 50,
    Duration retryDelay = const Duration(seconds: 5),
  }) {
    late StreamController<Position> controller;
    StreamSubscription<Position>? inner;
    Timer? retryTimer;
    var retrying = false;

    void subscribe() {
      inner = getPositionStream(distanceFilter: distanceFilter).listen(
        controller.add,
        onError: (Object e) {
          inner?.cancel();
          inner = null;
          if (!retrying) {
            retrying = true;
            retryTimer = Timer(retryDelay, () {
              retrying = false;
              if (!controller.isClosed) subscribe();
            });
          }
          onError?.call();
        },
        cancelOnError: true,
      );
    }

    controller = StreamController<Position>(
      onResume: subscribe,
      onPause: () {
        retryTimer?.cancel();
        inner?.cancel();
        inner = null;
      },
    );
    controller.onListen = subscribe;

    return controller.stream.listen(onData)
      ..onDone(() {
        retryTimer?.cancel();
        inner?.cancel();
        controller.close();
      });
  }

  /// Deep-links to the OS location settings so the user can enable GPS or
  /// grant the permission after "don't ask again". Returns false when the
  /// platform can't handle it (caller should show a manual hint instead).
  Future<bool> openLocationSettings() async {
    try {
      return await Geolocator.openLocationSettings();
    } catch (_) {
      return false;
    }
  }

  /// Update driver location on server.
  Future<void> updateDriverLocation(
      String providerId, double lat, double lng) async {
    await Supabase.instance.client.rpc('update_driver_location', params: {
      'p_provider_id': providerId,
      'p_lat': lat,
      'p_lng': lng,
    });
  }

  /// Set driver online/offline.
  Future<void> setDriverOnline(String providerId, bool online,
      {double? lat, double? lng}) async {
    await Supabase.instance.client.rpc('set_driver_online', params: {
      'p_provider_id': providerId,
      'p_online': online,
      'p_lat': lat,
      'p_lng': lng,
    });
  }

  /// Get driver's current status.
  Future<Map<String, dynamic>?> getDriverStatus(String providerId) async {
    final data = await Supabase.instance.client
        .from('driver_status')
        .select()
        .eq('provider_id', providerId)
        .maybeSingle();
    return data;
  }

  /// Find nearby online drivers around a live GPS point.
  Future<List<Map<String, dynamic>>> findNearbyDrivers(double lat, double lng,
      {double radiusKm = 10, String? vehicleCategoryId}) async {
    final data =
        await Supabase.instance.client.rpc('find_nearby_drivers', params: {
      'p_lat': lat,
      'p_lng': lng,
      'p_radius_km': radiusKm,
      'p_vehicle_category_id': vehicleCategoryId,
    });
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Calculate distance between two points in km (Haversine).
  double calculateDistance(double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2) / 1000;
  }

  // ---- Directions / routing ----

  /// Opens turn-by-turn directions to [destLat]/[destLng] in the platform
  /// maps app (Google Maps on Android, Apple Maps on iOS), with an optional
  /// origin so the route starts from the driver's live GPS fix. Never
  /// throws; returns false when no handler is available.
  Future<bool> openDirectionsTo({
    required double destLat,
    required double destLng,
    String? label,
    double? originLat,
    double? originLng,
  }) async {
    final dest = '$destLat,$destLng';
    final origin = (originLat != null && originLng != null)
        ? '$originLat,$originLng'
        : null;
    final name = (label == null || label.trim().isEmpty) ? dest : label;

    final List<Uri> candidates;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final apple = origin != null
          ? Uri.parse(
              'https://maps.apple.com/?saddr=$origin&daddr=$dest&dirflg=d')
          : Uri.parse('https://maps.apple.com/?daddr=$dest&dirflg=d&q=$name');
      final google = origin != null
          ? Uri.parse(
              'https://www.google.com/maps/dir/?api=1&origin=$origin&destination=$dest&travelmode=driving')
          : Uri.parse(
              'https://www.google.com/maps/dir/?api=1&destination=$dest&travelmode=driving');
      candidates = [apple, google];
    } else {
      final geo = Uri.parse('geo:0,0?q=$dest(${Uri.encodeComponent(name)})');
      final google = origin != null
          ? Uri.parse(
              'https://www.google.com/maps/dir/?api=1&origin=$origin&destination=$dest&travelmode=driving')
          : Uri.parse(
              'https://www.google.com/maps/dir/?api=1&destination=$dest&travelmode=driving');
      candidates = [google, geo];
    }

    for (final uri in candidates) {
      if (await _tryLaunch(uri)) return true;
    }
    return false;
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      if (!await canLaunchUrl(uri)) return false;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}
