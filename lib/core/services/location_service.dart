import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
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
  const LocationResult._(this.status, [this.position, this.errorMessage]);
  const LocationResult.ready(Position p) : this._(LocationStatus.ready, p);
  const LocationResult.serviceDisabled() : this._(LocationStatus.serviceDisabled);
  const LocationResult.denied() : this._(LocationStatus.denied);
  const LocationResult.deniedForever() : this._(LocationStatus.deniedForever);
  const LocationResult.error(String msg) : this._(LocationStatus.error, null, msg);

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
      final m = RegExp(r'POINT\s*\(\s*(-?[0-9.]+)\s+(-?[0-9.]+)').firstMatch(raw);
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

  /// Best-effort current position, or null on any failure.
  /// (Legacy call sites; prefer [getCurrentPositionDetailed].)
  Future<Position?> getCurrentPosition() async {
    final r = await getCurrentPositionDetailed();
    return r.position;
  }

  /// Structured attempt: verifies location services are on, requests the
  /// runtime permission if needed, then fetches a fresh high-accuracy GPS
  /// fix. Never throws — failures come back as a [LocationResult].
  Future<LocationResult> getCurrentPositionDetailed() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return const LocationResult.serviceDisabled();

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
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
        timeLimit: const Duration(seconds: 15),
      );
      return LocationResult.ready(position);
    } catch (e) {
      return LocationResult.error(e.toString());
    }
  }

  /// Stream of position updates. Callers must hold permission already
  /// (checked via [getCurrentPositionDetailed] before subscribing).
  Stream<Position> getPositionStream({
    int distanceFilter = 50,
    Duration interval = const Duration(seconds: 10),
  }) {
    return Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        timeLimit: interval,
      ),
    );
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
  Future<void> updateDriverLocation(String providerId, double lat, double lng) async {
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
  Future<List<Map<String, dynamic>>> findNearbyDrivers(
      double lat, double lng,
      {double radiusKm = 10, String? vehicleCategoryId}) async {
    final data = await Supabase.instance.client.rpc('find_nearby_drivers', params: {
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
