import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/widgets/map_tile_layer.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/realtime_status_banner.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class DriverTripScreen extends StatefulWidget {
  const DriverTripScreen({super.key});
  @override
  State<DriverTripScreen> createState() => _State();
}

class _State extends State<DriverTripScreen> {
  Map<String, dynamic>? _ride;
  ResilientSubscription<Map<String, dynamic>>? _sub;
  RealtimeConnState _rideConn = RealtimeConnState.connecting;
  StreamSubscription<geo.Position>? _posSub;
  bool _loading = true;
  // Set when _load() throws. Without it the catch below cleared the spinner
  // and the screen fell through to "No active trip" — telling a driver who is
  // mid-journey that they have no trip, because the request failed.
  String? _error;

  // Live GPS state
  String? _providerId;
  geo.Position? _driverPos;
  LocationStatus? _locStatus;
  bool _directionsLaunching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ride = await RideService.instance.getMyActiveDriverRide();
      if (ride != null) {
        // Live ride-status channel. A subscribe timeout is transient — retry
        // quietly rather than dropping the whole trip screen into the global
        // crash overlay.
        _sub = ResilientSubscription(
          stream: RideService.instance.watchRide(ride['id']),
          onData: (updated) {
            if (mounted && updated.isNotEmpty) {
              setState(() => _ride = updated);
              _syncProviderId(updated);
            }
          },
          onState: (s) {
            if (mounted) setState(() => _rideConn = s);
          },
        );
      }
      if (mounted) {
        setState(() {
          _ride = ride;
          _loading = false;
          _error = null;
        });
      }
      _syncProviderId(ride);
      await _startLiveLocation();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your trip');
        });
      }
    }
  }

  Future<void> _syncProviderId(Map<String, dynamic>? ride) async {
    if (_providerId != null || ride == null) return;
    final claimed = ride['claimed_by_provider_id'] as String?;
    if (claimed != null && mounted) setState(() => _providerId = claimed);
  }

  /// Real device GPS: get a first fix (asking permission when needed), push
  /// it to driver_status so the rider can see it, then keep streaming while
  /// this screen is open. Failures are handled inline — never silent.
  Future<void> _startLiveLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() {
      _locStatus = r.status;
      if (r.success) _driverPos = r.position;
    });
    if (!r.success) return;
    await _pushDriverLocation();

    // watchPosition self-heals: a GPS hiccup mid-trip must not close the
    // stream (the raw geolocator stream would) — it retries with the last
    // fix still on screen.
    _posSub = LocationService.instance.watchPosition(
      distanceFilter: 50,
      onError: () {},
      onData: (pos) {
        if (!mounted) return;
        setState(() => _driverPos = pos);
        _pushDriverLocation();
      },
    );
  }

  Future<void> _pushDriverLocation() async {
    final pos = _driverPos;
    final providerId = _providerId;
    if (pos == null || providerId == null) return;
    try {
      await LocationService.instance
          .updateDriverLocation(providerId, pos.latitude, pos.longitude);
    } catch (_) {
      // Non-fatal: the rider still sees the last pushed fix.
    }
  }

  Future<void> _openSettings() async {
    await LocationService.instance.openLocationSettings();
    if (_locStatus == LocationStatus.deniedForever) return;
    await _startLiveLocation();
  }

  Future<void> _openDirections() async {
    final ride = _ride;
    final pickup = GeoPoint.parse(ride?['pickup_location']);
    if (pickup == null) return;
    final pos = _driverPos;
    setState(() => _directionsLaunching = true);
    final ok = await LocationService.instance.openDirectionsTo(
      destLat: pickup.lat,
      destLng: pickup.lng,
      label: ride?['pickup_text'] ?? 'Pickup',
      originLat: pos?.latitude,
      originLng: pos?.longitude,
    );
    if (mounted) {
      setState(() => _directionsLaunching = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No maps app available on this device')));
      }
    }
  }

  Future<void> _transition(String newStatus) async {
    if (_ride == null) return;
    try {
      await RideService.instance.transitionRide(
        rideId: _ride!['id'],
        newStatus: newStatus,
      );
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update this trip'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Trip'),
        bottom: RealtimeStatusBar(state: _rideConn),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : _error != null
              ? LoadErrorView(
                  message: _error!,
                  onRetry: _load,
                  icon: Icons.directions_car_outlined,
                )
          : _ride == null
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_outline,
                        size: 64, color: AppTheme.textMuted),
                    const SizedBox(height: 16),
                    const Text('No active trip',
                        style: TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => context.go('/vehicle'),
                      child: const Text('Back to Dashboard'),
                    ),
                  ],
                ))
              : _buildTrip(),
    );
  }

  Widget _buildTrip() {
    final status = _ride!['status'] ?? '';
    final pickup = _ride!['pickup_text'] ?? 'Pickup';
    final dest = _ride!['destination_text'] ?? 'Destination';
    final profile = _ride!['profiles'] as Map<String, dynamic>?;
    final passengerName = profile?['full_name'] ?? 'Passenger';

    final pickupPoint = GeoPoint.parse(_ride!['pickup_location']);
    final destPoint = GeoPoint.parse(_ride!['destination_location']);

    // Distance from my live GPS fix to the pickup (shown once GPS is live).
    String? distanceText;
    if (pickupPoint != null && _driverPos != null) {
      final km = LocationService.instance.calculateDistance(
        _driverPos!.latitude,
        _driverPos!.longitude,
        pickupPoint.lat,
        pickupPoint.lng,
      );
      distanceText = km < 1
          ? '${(km * 1000).round()} m to pickup'
          : '${km.toStringAsFixed(1)} km to pickup';
    }

    final driverMarker = _driverPos != null
        ? LatLng(_driverPos!.latitude, _driverPos!.longitude)
        : null;
    final pickupMarker =
        pickupPoint != null ? LatLng(pickupPoint.lat, pickupPoint.lng) : null;
    final destMarker =
        destPoint != null ? LatLng(destPoint.lat, destPoint.lng) : null;
    final points =
        [driverMarker, pickupMarker, destMarker].whereType<LatLng>().toList();

    Widget map;
    if (points.isEmpty) {
      map = Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: AppTheme.creamDark,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 44, color: AppTheme.textMuted),
              SizedBox(height: 8),
              Text('Waiting for location…',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            ],
          ),
        ),
      );
    } else {
      map = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: points.first,
            initialZoom: points.length == 1 ? 15 : 13.5,
          ),
          children: [
            const ResilientTileLayer(),
            MarkerLayer(
              markers: [
                if (driverMarker != null)
                  Marker(
                    point: driverMarker,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.local_taxi,
                        color: AppTheme.teal, size: 44),
                  ),
                if (pickupMarker != null)
                  Marker(
                    point: pickupMarker,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.trip_origin,
                        color: AppTheme.success, size: 36),
                  ),
                if (destMarker != null)
                  Marker(
                    point: destMarker,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.location_on,
                        color: AppTheme.error, size: 40),
                  ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('© OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(status.replaceAll('_', ' '),
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.teal)),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 220,
            child: map,
          ),
          const SizedBox(height: 8),
          // GPS state line + recovery
          Row(
            children: [
              Expanded(
                child: Text(
                  _gpsStateText(),
                  style:
                      const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ),
              if (_driverPos == null)
                TextButton.icon(
                  onPressed: (_locStatus == LocationStatus.deniedForever ||
                          _locStatus == LocationStatus.serviceDisabled)
                      ? _openSettings
                      : _startLiveLocation,
                  icon: const Icon(Icons.gps_fixed, size: 16),
                  label: Text(_locStatus == LocationStatus.deniedForever ||
                          _locStatus == LocationStatus.serviceDisabled
                      ? 'Enable location'
                      : 'Retry GPS'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (distanceText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(distanceText,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryGreen)),
            ),
          // Passenger info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Passenger',
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                const SizedBox(height: 4),
                Text(passengerName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Directions to pickup — real routing from my live GPS position.
          if (pickupPoint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'GET DIRECTIONS TO PICKUP',
                  isLoading: _directionsLaunching,
                  onPressed: _openDirections,
                ),
              ),
            ),
          // Pickup
          _locationTile(Icons.circle, AppTheme.success, 'Pickup', pickup),
          const SizedBox(height: 8),
          _locationTile(Icons.location_on, AppTheme.error, 'Destination', dest),
          const SizedBox(height: 24),
          // Actions based on status
          if (status == 'CLAIMED')
            _actionButton(
                'DRIVER_ARRIVING', 'HEADING TO PICKUP', AppTheme.teal),
          if (status == 'DRIVER_ARRIVING' || status == 'ARRIVED')
            _actionButton(
                'ARRIVED', 'ARRIVED AT PICKUP', AppTheme.primaryGreen),
          if (status == 'ARRIVED')
            _actionButton('TRIP_STARTED', 'START TRIP', AppTheme.primaryGreen),
          if (status == 'TRIP_STARTED')
            _actionButton('COMPLETED', 'COMPLETE TRIP', AppTheme.success),
        ],
      ),
    );
  }

  String _gpsStateText() {
    switch (_locStatus) {
      case LocationStatus.serviceDisabled:
        return 'Location services are off — turn on GPS to share your location';
      case LocationStatus.denied:
        return 'Location permission needed to share your live position';
      case LocationStatus.deniedForever:
        return 'Location blocked — enable it in app settings to navigate';
      case LocationStatus.error:
        return 'Could not get GPS fix — tap Retry GPS';
      case LocationStatus.ready:
        return _driverPos != null
            ? 'Sharing live location with the rider'
            : 'Getting GPS fix…';
      default:
        return '';
    }
  }

  Widget _locationTile(IconData icon, Color color, String label, String text) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 16),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text(text,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton(String status, String label, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => _transition(status),
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        ),
      ),
    );
  }
}
