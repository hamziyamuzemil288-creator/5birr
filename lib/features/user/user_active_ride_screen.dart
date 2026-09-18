import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';
import '../../core/widgets/primary_button.dart';

class UserActiveRideScreen extends StatefulWidget {
  const UserActiveRideScreen({super.key});
  @override
  State<UserActiveRideScreen> createState() => _State();
}

class _State extends State<UserActiveRideScreen> {
  Map<String, dynamic>? _ride;
  StreamSubscription? _sub;
  bool _loading = true;

  // Live GPS state
  GeoPoint? _driverLoc; // parsed from driver_status.current_location embed
  geo.Position? _myPos;
  bool _directionsLaunching = false;
  LocationStatus? _locStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ride = await RideService.instance.getMyActiveRide();
      if (ride != null) {
        _sub = RideService.instance.watchRide(ride['id']).listen((updated) {
          if (mounted && updated.isNotEmpty) {
            setState(() => _ride = updated);
            _parseDriverLocation(updated);
          }
        });
      }
      if (mounted) {
        setState(() {
          _ride = ride;
          _loading = false;
        });
      }
      _parseDriverLocation(ride);
      await _refreshMyLocation();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The ride row embeds `driver_status(current_location)`; RLS now lets the
  /// rider read that row only while it is assigned to their ride (0032).
  void _parseDriverLocation(Map<String, dynamic>? ride) {
    GeoPoint? p;
    final ds = ride?['driver_status'];
    if (ds is List && ds.isNotEmpty) {
      p = GeoPoint.parse((ds.first as Map)['current_location']);
    } else if (ds is Map) {
      p = GeoPoint.parse(ds['current_location']);
    }
    if (mounted) setState(() => _driverLoc = p);
  }

  Future<void> _refreshMyLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() {
      _locStatus = r.status;
      if (r.success) _myPos = r.position;
    });
  }

  Future<void> _openSettings() async {
    await LocationService.instance.openLocationSettings();
    await _refreshMyLocation();
  }

  Future<void> _openDirections() async {
    final pos = _myPos;
    final driver = _driverLoc;
    if (driver == null) return;
    setState(() => _directionsLaunching = true);
    final ok = await LocationService.instance.openDirectionsTo(
      destLat: driver.lat,
      destLng: driver.lng,
      label: 'Driver location',
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

  Future<void> _cancel() async {
    if (_ride == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Cancel Ride?'),
        content: const Text('Are you sure you want to cancel this ride?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Cancel Ride',
                  style: TextStyle(color: AppTheme.error))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await RideService.instance.cancelRide(_ride!['id']);
      if (mounted) context.go('/user');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Active Ride')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _ride == null
              ? Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.directions_car_outlined,
                        size: 64, color: AppTheme.textMuted),
                    const SizedBox(height: 16),
                    const Text('No active ride',
                        style: TextStyle(color: AppTheme.textMuted)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => context.go('/user'),
                      child: const Text('Back to Home'),
                    ),
                  ],
                ))
              : _buildRide(),
    );
  }

  Widget _buildRide() {
    final status = _ride!['status'] ?? '';
    final pickup = _ride!['pickup_text'] ?? 'Pickup';
    final dest = _ride!['destination_text'] ?? 'Destination';
    final claimed = ['CLAIMED', 'DRIVER_ARRIVING', 'DRIVER_EN_ROUTE', 'ARRIVED', 'TRIP_STARTED', 'STARTED'].contains(status);

    // Live tracking map: driver pin once assigned, my GPS pin when granted.
    final LatLng? driverMarker =
        _driverLoc != null ? LatLng(_driverLoc!.lat, _driverLoc!.lng) : null;
    final LatLng? myMarker =
        _myPos != null ? LatLng(_myPos!.latitude, _myPos!.longitude) : null;
    final points = [driverMarker, myMarker].whereType<LatLng>().toList();

    Widget map;
    if (points.isEmpty) {
      map = _noLiveLocationWidget(claimed);
    } else {
      final center = _initialCenter(points);
      map = ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: points.length == 1 ? 15 : 13.5,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.amistbirr.myapp',
            ),
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
                if (myMarker != null)
                  Marker(
                    point: myMarker,
                    width: 40,
                    height: 40,
                    alignment: Alignment.topCenter,
                    child: const Icon(Icons.person_pin_circle,
                        color: AppTheme.primaryGreen, size: 40),
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
          // Status
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _statusColor(status).withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(_statusText(status),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _statusColor(status))),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 220,
            child: map,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  driverMarker != null
                      ? 'Driver location updates live'
                      : 'Driver will appear on the map once your ride is claimed',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textMuted),
                ),
              ),
              if (myMarker == null)
                TextButton.icon(
                  onPressed: (_locStatus == LocationStatus.deniedForever ||
                          _locStatus == LocationStatus.serviceDisabled)
                      ? _openSettings
                      : _refreshMyLocation,
                  icon: const Icon(Icons.gps_fixed, size: 16),
                  label: Text(_locStatus == LocationStatus.deniedForever ||
                          _locStatus == LocationStatus.serviceDisabled
                      ? 'Enable location'
                      : 'Show my location'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // Directions to the driver (ride claimed only — same reveal timing
          // as before: pickup details reach the driver at claim, and the
          // driver status row only becomes readable after it is assigned).
          if (claimed && driverMarker != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'GET DIRECTIONS TO DRIVER',
                  isLoading: _directionsLaunching,
                  onPressed: _openDirections,
                ),
              ),
            ),
          // Locations
          _locationTile(Icons.circle, AppTheme.success, 'Pickup', pickup),
          const SizedBox(height: 8),
          _locationTile(
              Icons.location_on, AppTheme.error, 'Destination', dest),
          const SizedBox(height: 20),
          // Cancel button (only before trip starts)
          if (['REQUESTED', 'CLAIMED', 'DRIVER_ARRIVING'].contains(status))
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _cancel,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.error),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('CANCEL RIDE',
                    style: TextStyle(color: AppTheme.error)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _noLiveLocationWidget(bool claimed) {
    if (!claimed) {
      return _mapPlaceholder('Searching for a driver — the map goes live once one claims your ride');
    }
    return _mapPlaceholder('Waiting for driver location…');
  }

  Widget _mapPlaceholder(String text) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.creamDark,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.map_outlined, size: 44, color: AppTheme.textMuted),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textMuted)),
            ),
          ],
        ),
      ),
    );
  }

  LatLng _initialCenter(List<LatLng> points) {
    final lat = points.map((p) => p.latitude).reduce((a, b) => a + b) /
        points.length;
    final lng = points.map((p) => p.longitude).reduce((a, b) => a + b) /
        points.length;
    return LatLng(lat, lng);
  }

  Widget _locationTile(
      IconData icon, Color color, String label, String text) {
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

  Color _statusColor(String status) {
    switch (status) {
      case 'REQUESTED': return AppTheme.warning;
      case 'CLAIMED': return AppTheme.info;
      case 'DRIVER_ARRIVING': return AppTheme.teal;
      case 'ARRIVED': return AppTheme.primaryGreen;
      case 'TRIP_STARTED': return AppTheme.primaryGreen;
      case 'COMPLETED': return AppTheme.success;
      case 'CANCELLED': return AppTheme.error;
      default: return AppTheme.textMuted;
    }
  }

  String _statusText(String status) {
    switch (status) {
      case 'REQUESTED': return 'Searching for driver...';
      case 'CLAIMED': return 'Driver is on the way';
      case 'DRIVER_ARRIVING': return 'Driver is approaching';
      case 'ARRIVED': return 'Driver has arrived';
      case 'TRIP_STARTED': return 'Trip in progress';
      case 'COMPLETED': return 'Trip completed';
      case 'CANCELLED': return 'Ride cancelled';
      default: return status;
    }
  }
}
