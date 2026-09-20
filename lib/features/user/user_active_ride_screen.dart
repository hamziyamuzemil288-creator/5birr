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
  StreamSubscription? _posSub;
  bool _loading = true;

  // Live GPS state
  GeoPoint? _driverLoc; // parsed from driver_status.current_location embed
  geo.Position? _myPos;
  bool _directionsLaunching = false;
  LocationStatus? _locStatus;

  // Real interactive map: controller lets us keep the camera glued to the
  // rider's live position; [_followUser] mirrors the dashboards' behavior.
  final MapController _mapController = MapController();
  bool _followUser = true;

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
    _moveCameraToMe();
    // Keep the map live: the rider's own pin used to be a one-shot fix that
    // never moved, making the screen feel like a static image.
    if (r.success && _posSub == null) {
      _posSub = LocationService.instance
          .getPositionStream(distanceFilter: 15)
          .listen((pos) {
        if (!mounted) return;
        setState(() => _myPos = pos);
        _moveCameraToMe();
      });
    }
  }

  void _moveCameraToMe() {
    final me = _myPos;
    if (me == null || !_followUser) return;
    try {
      _mapController.move(
          LatLng(me.latitude, me.longitude), _mapController.camera.zoom);
    } catch (_) {
      // Map not mounted yet — the next fix will carry the position.
    }
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
    final claimed = [
      'CLAIMED',
      'DRIVER_ARRIVING',
      'DRIVER_EN_ROUTE',
      'ARRIVED',
      'TRIP_STARTED',
      'STARTED'
    ].contains(status);

    // Live tracking map: driver pin once assigned, my GPS pin when granted.
    final LatLng? driverMarker =
        _driverLoc != null ? LatLng(_driverLoc!.lat, _driverLoc!.lng) : null;
    final LatLng? myMarker =
        _myPos != null ? LatLng(_myPos!.latitude, _myPos!.longitude) : null;
    final points = [driverMarker, myMarker].whereType<LatLng>().toList();

    Widget map;
    // Center on the rider when known, else the driver, else Addis Ababa.
    final center = myMarker != null
        ? myMarker
        : (driverMarker ?? const LatLng(9.03, 38.74));
    // The map is ALWAYS real and interactive — pan/zoom work before any pin
    // exists. A static placeholder here previously made the whole feature
    // "look fake" whenever GPS or driver location was briefly unavailable.
    map = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: points.length == 1 ? 15 : 13.5,
              onTap: (_, __) => setState(() => _followUser = false),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.amistbirr.myapp',
              ),
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
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
                  if (points.isEmpty)
                    Marker(
                      point: center,
                      width: 48,
                      height: 48,
                      alignment: Alignment.topCenter,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.location_searching,
                            color: AppTheme.textMuted, size: 30),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: AppTheme.cardBorder, width: 0.5),
                          ),
                          child: Text(
                            claimed
                                ? 'Waiting for driver location…'
                                : 'Searching for a driver…',
                            style: const TextStyle(
                                fontSize: 9, color: AppTheme.textMuted),
                          ),
                        ),
                      ]),
                    ),
                ],
              ),
            ],
          ),
          if (points.isEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 30,
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                  ),
                  child: Text(
                    claimed
                        ? 'Connected to the live map — the driver pin appears here as soon as their location streams in.'
                        : 'Searching for a driver — the map is live; your driver pin appears once one claims this ride.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted),
                  ),
                ),
              ),
            ),
          Positioned(
            right: 8,
            bottom: 8,
            child: FloatingActionButton.small(
              heroTag: 'followUserRide',
              onPressed: () {
                setState(() => _followUser = true);
                _moveCameraToMe();
              },
              backgroundColor:
                  _followUser ? AppTheme.primaryGreen : AppTheme.surface,
              foregroundColor:
                  _followUser ? Colors.white : AppTheme.primaryGreen,
              child: const Icon(Icons.my_location, size: 20),
            ),
          ),
        ],
      ),
    );

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
                  style:
                      const TextStyle(fontSize: 12, color: AppTheme.textMuted),
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
          _locationTile(Icons.location_on, AppTheme.error, 'Destination', dest),
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

  Color _statusColor(String status) {
    switch (status) {
      case 'REQUESTED':
        return AppTheme.warning;
      case 'CLAIMED':
        return AppTheme.info;
      case 'DRIVER_ARRIVING':
        return AppTheme.teal;
      case 'ARRIVED':
        return AppTheme.primaryGreen;
      case 'TRIP_STARTED':
        return AppTheme.primaryGreen;
      case 'COMPLETED':
        return AppTheme.success;
      case 'CANCELLED':
        return AppTheme.error;
      default:
        return AppTheme.textMuted;
    }
  }

  String _statusText(String status) {
    switch (status) {
      case 'REQUESTED':
        return 'Searching for driver...';
      case 'CLAIMED':
        return 'Driver is on the way';
      case 'DRIVER_ARRIVING':
        return 'Driver is approaching';
      case 'ARRIVED':
        return 'Driver has arrived';
      case 'TRIP_STARTED':
        return 'Trip in progress';
      case 'COMPLETED':
        return 'Trip completed';
      case 'CANCELLED':
        return 'Ride cancelled';
      default:
        return status;
    }
  }
}
