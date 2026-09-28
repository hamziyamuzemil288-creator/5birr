import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/app_theme.dart';
import 'resilient_subscription.dart';

/// One moving vehicle on the live map.
///
/// Positions come from `nearby_provider_markers()`, which rounds coordinates
/// to ~110 m on purpose — see that function's header. [headingDegrees] and
/// [speedMps] are therefore DERIVED on the device from two successive fixes
/// rather than sent by the server, which has only one row and no history.
/// They are null until a vehicle has been seen moving at least twice.
class LiveMapVehicle {
  LiveMapVehicle({
    required this.providerId,
    required this.providerType,
    required this.displayName,
    required this.lat,
    required this.lng,
    required this.onRide,
    required this.secondsSinceFix,
    required this.categorySlug,
    required this.categoryName,
    this.headingDegrees,
    this.speedMps,
  });

  final String providerId;
  final String? providerType;
  final String displayName;
  final double lat;
  final double lng;

  /// True when the driver is carrying a passenger. Shown, not hidden: a busy
  /// street full of cars is the point of a live map, and a rider who cannot
  /// see a single vehicle assumes the app is broken.
  final bool onRide;
  final int secondsSinceFix;
  final String? categorySlug;
  final String? categoryName;
  final double? headingDegrees;
  final double? speedMps;

  LatLng get position => LatLng(lat, lng);

  factory LiveMapVehicle.fromRow(Map<String, dynamic> row) {
    return LiveMapVehicle(
      providerId: row['provider_id'] as String,
      providerType: row['provider_type'] as String?,
      displayName: (row['display_name'] as String?) ?? 'Aliob partner',
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lng'] as num).toDouble(),
      onRide: (row['on_ride'] as bool?) ?? false,
      secondsSinceFix: (row['seconds_since_fix'] as num?)?.toInt() ?? 0,
      categorySlug: row['category_slug'] as String?,
      categoryName: row['category_name'] as String?,
    );
  }

  /// Fold a fresh fix onto the previous one, carrying the derived heading and
  /// speed forward so the marker keeps pointing the way it was last seen
  /// travelling between updates.
  LiveMapVehicle mergeFrom(LiveMapVehicle? previous) {
    if (previous == null) {
      return LiveMapVehicle(
        providerId: providerId,
        providerType: providerType,
        displayName: displayName,
        lat: lat,
        lng: lng,
        onRide: onRide,
        secondsSinceFix: secondsSinceFix,
        categorySlug: categorySlug,
        categoryName: categoryName,
      );
    }

    final from = previous.position;
    final to = position;
    final metres = const Distance().as(LengthUnit.Meter, from, to);

    // Below ~8 m the movement is GPS jitter, not travel; keeping the old
    // heading is what stops a parked car spinning on its axis. The old SPEED
    // must not be carried with it, though: the feed rounds positions to
    // ~110 m, so a car stopped at a light reports a byte-identical point on
    // every poll and would keep the 12 m/s it had while moving indefinitely.
    // The map then dead-reckons that phantom speed forever, and the pin
    // drives off on its own. No movement means no speed.
    if (metres < 8) {
      return LiveMapVehicle(
        providerId: providerId,
        providerType: providerType,
        displayName: displayName,
        lat: lat,
        lng: lng,
        onRide: onRide,
        secondsSinceFix: secondsSinceFix,
        categorySlug: categorySlug,
        categoryName: categoryName,
        headingDegrees: previous.headingDegrees,
      );
    }

    final seconds = (secondsSinceFix - previous.secondsSinceFix).abs();
    return LiveMapVehicle(
      providerId: providerId,
      providerType: providerType,
      displayName: displayName,
      lat: lat,
      lng: lng,
      onRide: onRide,
      secondsSinceFix: secondsSinceFix,
      categorySlug: categorySlug,
      categoryName: categoryName,
      headingDegrees: _bearingDegrees(from, to),
      // A vehicle whose fix has not advanced is being reported from the same
      // instant, so dividing by it would fabricate an enormous speed. Fall
      // back to the previous one only in that case.
      speedMps: seconds > 0
          ? metres / seconds
          : previous.speedMps,
    );
  }
}

/// An open ride request shown to drivers on the map.
class LiveMapOpenRide {
  const LiveMapOpenRide({
    required this.id,
    required this.pickupText,
    required this.destinationText,
    required this.fareEstimate,
    required this.categoryName,
    required this.lat,
    required this.lng,
    required this.createdSecondsAgo,
  });

  final String id;
  final String? pickupText;
  final String? destinationText;
  final num? fareEstimate;
  final String? categoryName;
  final double lat;
  final double lng;
  final int createdSecondsAgo;

  LatLng get position => LatLng(lat, lng);

  factory LiveMapOpenRide.fromRow(Map<String, dynamic> row) {
    return LiveMapOpenRide(
      id: row['ride_request_id'] as String,
      pickupText: row['pickup_text'] as String?,
      destinationText: row['destination_text'] as String?,
      fareEstimate: row['fare_estimate'] as num?,
      categoryName: row['category_name'] as String?,
      lat: (row['lat'] as num).toDouble(),
      lng: (row['lng'] as num).toDouble(),
      createdSecondsAgo: (row['created_seconds_ago'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Icon + colour for a vehicle/service type.
///
/// Aliob's `categories` rows carry a `slug` and a `name` but no iconography,
/// so the glyph is chosen here from those two strings, matched on keywords
/// rather than on an exact list of slugs. That means a category the CEO adds
/// later (`scooter-taxi`, `refrigerated-truck`) still gets a sensible icon
/// instead of silently falling back to a generic car, and it needs no
/// migration and no app release to do it.
class VehicleMarkerStyle {
  const VehicleMarkerStyle(this.icon, this.color, this.label);

  final IconData icon;
  final Color color;
  final String label;
}

VehicleMarkerStyle vehicleMarkerStyle({
  String? categorySlug,
  String? categoryName,
  String? providerType,
}) {
  final haystack = '${categorySlug ?? ''} ${categoryName ?? ''}'.toLowerCase();

  bool has(List<String> needles) => needles.any(haystack.contains);

  if (has(const ['bicycle', 'bike-cycle', 'pedal', 'e-bike', 'ebike'])) {
    return const VehicleMarkerStyle(Icons.pedal_bike, AppTheme.teal, 'Bicycle');
  }
  // Checked before the car rules, because "motorbike" contains "bike" and
  // some slugs spell it "motor-bike".
  if (has(const ['moto', 'bajaj', 'tuk', 'rickshaw', 'three-wheel', 'threewheel'])) {
    return const VehicleMarkerStyle(Icons.two_wheeler, Color(0xFFEF6C00), 'Motorbike');
  }
  if (has(const ['truck', 'lorry', 'freight', 'cargo', 'isuzu', 'pickup-truck'])) {
    return const VehicleMarkerStyle(Icons.local_shipping, Color(0xFF5D4037), 'Truck');
  }
  if (has(const ['bus', 'minibus', 'minibus', 'coaster', 'higer'])) {
    return const VehicleMarkerStyle(Icons.directions_bus, Color(0xFF00695C), 'Bus');
  }
  if (has(const ['van', 'delivery', 'parcel', 'courier', 'package'])) {
    return const VehicleMarkerStyle(Icons.delivery_dining, Color(0xFF6A1B9A), 'Delivery');
  }
  if (has(const ['electric', 'ev', 'hybrid'])) {
    return const VehicleMarkerStyle(Icons.electric_car, AppTheme.primaryGreenLight, 'Electric car');
  }
  if (has(const ['vip', 'premium', 'luxury', 'executive'])) {
    return const VehicleMarkerStyle(Icons.local_taxi, AppTheme.gold, 'Executive car');
  }
  if (has(const ['taxi', 'ride'])) {
    return const VehicleMarkerStyle(Icons.local_taxi, Color(0xFFF9A825), 'Taxi');
  }
  // A service provider appearing on the map is not a vehicle; the storefront
  // glyph says so instead of pretending it is a car.
  if (providerType != null && providerType != 'VEHICLE_PROVIDER') {
    return const VehicleMarkerStyle(Icons.storefront, AppTheme.teal, 'Service');
  }
  return const VehicleMarkerStyle(Icons.directions_car, AppTheme.primaryGreen, 'Car');
}

/// Reads the live map's data and signals when it may have changed.
///
/// WHY POLLING IS THE PRIMARY PATH, not Realtime. Realtime applies the
/// subscriber's RLS to every row it delivers, and `driver_status` is
/// owner/rider-scoped — an ordinary user can only read their own ride's
/// driver row. So a Realtime subscription can never deliver a stranger's
/// vehicle to the map, no matter how the channel is configured, and the
/// nearby-driver feed has to go through the SECURITY DEFINER RPC instead.
///
/// Realtime is still used, as a *latency* optimisation rather than the source
/// of truth: any row the signed-in account is allowed to see (their own
/// driver, the open requests a driver may claim) triggers an immediate
/// re-read, and the poll covers everybody else. That keeps the map
/// near-real-time without pretending RLS can be bypassed.
class LiveMapService {
  LiveMapService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Default cadence for re-reading the marker feed. The floor exists because
  /// this is a paid-per-request backend and the feed is already rounded to
  /// ~110 m, so a faster loop would buy nothing but load.
  static const Duration defaultRefreshInterval = Duration(seconds: 8);

  Future<List<LiveMapVehicle>> nearbyVehicles({
    required double lat,
    required double lng,
    double radiusKm = 5,
    String? providerType,
    List<LiveMapVehicle> previous = const [],
  }) async {
    final rows = await _client.rpc('nearby_provider_markers', params: {
      'p_lat': lat,
      'p_lng': lng,
      'p_radius_km': radiusKm,
      if (providerType != null) 'p_provider_type': providerType,
    });

    final byId = {for (final v in previous) v.providerId: v};
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .map(LiveMapVehicle.fromRow)
        .map((v) => v.mergeFrom(byId[v.providerId]))
        .toList();
  }

  /// Open ride requests near a driver. Throws (a PostgrestException carrying
  /// `ONLY_APPROVED_VEHICLE_PROVIDERS_CAN_SEE_OPEN_RIDES`) for anyone who is
  /// not an approved vehicle provider — the map's driver mode treats that as
  /// "not a driver" rather than as an error to show.
  Future<List<LiveMapOpenRide>> openRidesNearby({
    required double lat,
    required double lng,
    double radiusKm = 8,
  }) async {
    final rows = await _client.rpc('live_map_open_rides', params: {
      'p_lat': lat,
      'p_lng': lng,
      'p_radius_km': radiusKm,
    });
    return (rows as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .map(LiveMapOpenRide.fromRow)
        .toList();
  }

  /// A change signal, layered on top of polling. [onSignal] fires at most
  /// once per [debounce] when a row the account may read changes.
  ResilientSubscription<List<Map<String, dynamic>>> watchMovement({
    required void Function() onSignal,
    required void Function(RealtimeConnState state) onState,
    Duration debounce = const Duration(seconds: 2),
  }) {
    Timer? pending;
    return ResilientSubscription<List<Map<String, dynamic>>>(
      stream: _client
          .from('driver_status')
          .stream(primaryKey: ['provider_id']),
      onState: onState,
      onData: (_) {
        pending?.cancel();
        pending = Timer(debounce, onSignal);
      },
    );
  }

  /// New open ride requests, for the driver map. Filtered on `status`, a
  /// non-primary-key column — which is exactly why migration
  /// 20260927000061 sets REPLICA IDENTITY FULL on `ride_requests`; without it
  /// this subscribe is rejected with a CHANNEL_ERROR.
  ResilientSubscription<List<Map<String, dynamic>>> watchOpenRides({
    required void Function() onSignal,
    required void Function(RealtimeConnState state) onState,
    Duration debounce = const Duration(seconds: 2),
  }) {
    Timer? pending;
    return ResilientSubscription<List<Map<String, dynamic>>>(
      stream: _client
          .from('ride_requests')
          .stream(primaryKey: ['id'])
          .eq('status', 'REQUESTED'),
      onState: onState,
      onData: (_) {
        pending?.cancel();
        pending = Timer(debounce, onSignal);
      },
    );
  }
}

/// Initial bearing from [a] to [b] in degrees clockwise from north.
double _bearingDegrees(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180.0;
  final lat2 = b.latitude * math.pi / 180.0;
  final dLon = (b.longitude - a.longitude) * math.pi / 180.0;
  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  return (math.atan2(y, x) * 180.0 / math.pi + 360.0) % 360.0;
}
