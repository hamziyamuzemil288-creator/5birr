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

class UserActiveRideScreen extends StatefulWidget {
  const UserActiveRideScreen({super.key});
  @override
  State<UserActiveRideScreen> createState() => _State();
}

class _State extends State<UserActiveRideScreen> {
  Map<String, dynamic>? _ride;
  ResilientSubscription<Map<String, dynamic>>? _sub;
  ResilientSubscription<List<Map<String, dynamic>>>? _driverSub;
  RealtimeConnState _rideConn = RealtimeConnState.connecting;
  StreamSubscription? _posSub;
  bool _loading = true;
  // Set when _load() throws. Otherwise a failed request cleared the spinner
  // and fell through to "No active ride" — telling a rider waiting in a car
  // that their ride does not exist.
  String? _error;

  // Live GPS state
  GeoPoint? _driverLoc; // parsed from driver_status.current_location embed
  geo.Position? _myPos;
  bool _directionsLaunching = false;
  LocationStatus? _locStatus;

  /// True when the shown position came from the OS cache (GPS timed out);
  /// the caption says "approximate" instead of implying a live lock.
  bool _myLocationApproximate = false;

  /// A camera move requested before FlutterMap attached (onMapReady).
  bool _mapReady = false;
  bool _pendingCameraMove = false;

  /// How long the search runs before the server gives up on an unclaimed
  /// request (expire_stale_ride_requests, claim_ride's RIDE_REQUEST_EXPIRED)
  /// and this screen offers a retry. Kept in lockstep with the driver-side
  /// filter in driver_ride_requests_screen.dart.
  static const Duration _searchTimeout = Duration(minutes: 3);

  /// 1-second ticker while a request is unclaimed: drives the countdown and,
  /// every 15th beat, re-reads the row from the server so the timeout is
  /// honoured even when realtime is down.
  Timer? _searchTimer;
  int _searchTicks = 0;

  /// True once THIS screen cancelled the ride, so a CANCELLED row seen while
  /// still on the page is read as the server's timeout, not as the rider's
  /// own cancel (which navigates away).
  bool _iCancelled = false;
  bool _retrying = false;

  /// The assigned driver's public details — name/business and plate — filled
  /// in once the ride is claimed. Null before that, and deliberately
  /// non-fatal after: the map, the status and the countdown all stand without
  /// it, so a profile row that cannot be read simply leaves the card out.
  Map<String, dynamic>? _driver;

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
    _searchTimer?.cancel();
    _sub?.cancel();
    _driverSub?.cancel();
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final ride = await RideService.instance.getMyActiveRide();
      if (ride != null) {
        // Live ride-status channel. A subscribe timeout is transient — retry
        // quietly rather than dropping the whole tracking screen into the
        // global crash overlay.
        _sub = ResilientSubscription(
          stream: RideService.instance.watchRide(ride['id']),
          onData: (updated) {
            if (mounted && updated.isNotEmpty) {
              setState(() => _ride = updated);
              _parseDriverLocation(updated);
              // The claim may only become known now (the unclaimed case
              // starts no driver subscription).
              _watchDriverLocation(updated);
              _loadDriver(updated);
              _syncSearchTimer();
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
          // Clear a prior failure so a successful retry leaves the error
          // screen instead of showing the ride behind stale error text.
          _error = null;
        });
        _syncSearchTimer();
      }
      _parseDriverLocation(ride);
      _watchDriverLocation(ride);
      _loadDriver(ride);
      await _refreshMyLocation();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your ride');
        });
      }
    }
  }

  /// Who is coming to the pickup: the assigned driver's name, business and
  /// plate, fetched once the moment the claim lands. Realtime only carries
  /// the ride row (watchRide has no embed), so this is a single read through
  /// the public provider/vehicle policies — never on the status path.
  Future<void> _loadDriver(Map<String, dynamic>? ride) async {
    if (_driver != null || ride == null) return;
    final providerId = ride['claimed_by_provider_id'];
    if (providerId is! String || providerId.isEmpty) return;
    try {
      final profile =
          await RideService.instance.getProviderProfile(providerId);
      if (profile == null) return;
      String? plate;
      final vehicleId = ride['claimed_vehicle_id'];
      if (vehicleId is String && vehicleId.isNotEmpty) {
        plate = await RideService.instance.getVehiclePlate(vehicleId);
      }
      if (!mounted) return;
      setState(() => _driver = <String, dynamic>{
        ...profile,
        if (plate != null && plate.isNotEmpty) 'plate_number': plate,
      });
    } catch (_) {
      // Non-fatal by design — see the field's note.
    }
  }

  /// When the server stamped the request (requested_at; created_at for rows
  /// predating the timeout column), or null when neither parses.
  DateTime? _requestedAt() {
    final raw = _ride?['requested_at'] ?? _ride?['created_at'];
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  /// True when the unclaimed search has run out of time — either by the
  /// clock (the cron may lag) or because the server already cancelled the
  /// row while this screen was open (realtime down, poll caught it).
  bool get _noDriver {
    final r = _ride;
    if (r == null || _iCancelled) return false;
    final status = r['status'];
    if (status == 'CANCELLED') return true;
    if (status != 'REQUESTED') return false;
    final at = _requestedAt();
    return at != null && DateTime.now().difference(at) >= _searchTimeout;
  }

  /// Starts/stops the 1-second search ticker to match the ride's status.
  /// Called whenever [_ride] changes; idempotent.
  void _syncSearchTimer() {
    final searching = _ride?['status'] == 'REQUESTED';
    if (searching && _searchTimer == null) {
      _searchTicks = 0;
      _searchTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        _searchTicks++;
        // Realtime has a ResilientSubscription behind it, but the one thing
        // this screen must not do is sit on a stale "Searching" while the
        // server gave up minutes ago — so poll the row itself every 15 s.
        if (_searchTicks % 15 == 0) _pollRide();
        setState(() {}); // repaint the countdown / timeout panel
      });
    } else if (!searching && _searchTimer != null) {
      _searchTimer?.cancel();
      _searchTimer = null;
      _searchTicks = 0;
    }
  }

  /// Polling fallback: re-read THIS ride by id (no status filter, so a
  /// server-side timeout flipping it to CANCELLED is seen even when the
  /// realtime channel is down).
  Future<void> _pollRide() async {
    final id = _ride?['id'] as String?;
    if (id == null) return;
    try {
      final fresh = await RideService.instance.getRideById(id);
      if (!mounted || fresh == null || fresh['id'] != _ride?['id']) return;
      final status = fresh['status'];
      if (status != _ride?['status']) {
        setState(() => _ride = fresh);
        _parseDriverLocation(fresh);
        _watchDriverLocation(fresh);
        _syncSearchTimer();
      } else {
        setState(() => _ride = fresh);
      }
    } catch (_) {
      // A failed poll keeps the last known row; the ticker tries again.
    }
  }

  /// "Try again": stand the timed-out request down (best effort — the cron
  /// may already have cancelled it) and return to the request form, where
  /// widening the search is one vehicle-type choice away.
  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    final id = _ride?['id'] as String?;
    if (id != null) {
      try {
        await RideService.instance.cancelRide(id);
      } catch (_) {
        // Already expired server-side, or already cancelled — either way
        // there is nothing left to stand down.
      }
    }
    if (mounted) context.go('/user/ride-request');
  }

  /// The ride row embeds `driver_status(current_location)`; RLS now lets the
  /// rider read that row only while it is assigned to their ride (0032).
  ///
  /// `watchRide` streams bare `ride_requests` rows with NO embed, so a ride
  /// event used to null this out and wipe the driver pin. Only apply a value
  /// when the embed is actually present; the live subscription below owns
  /// ongoing updates.
  void _parseDriverLocation(Map<String, dynamic>? ride) {
    GeoPoint? p;
    final ds = ride?['driver_status'];
    if (ds is List && ds.isNotEmpty) {
      p = GeoPoint.parse((ds.first as Map)['current_location']);
    } else if (ds is Map) {
      p = GeoPoint.parse(ds['current_location']);
    }
    if (p == null) return;
    if (mounted) setState(() => _driverLoc = p);
  }

  /// Track the driver's device GPS live.
  ///
  /// The driver pushes fixes to `driver_status` (via update_driver_location),
  /// which is now in the realtime publication. Each change re-reads the row
  /// through PostgREST so the geography parses the same way as the embed does
  /// (a raw realtime payload ships PostGIS as hex EWKB, which GeoPoint cannot
  /// read).
  void _watchDriverLocation(Map<String, dynamic>? ride) {
    if (_driverSub != null) return;
    final rideId = ride?['id'] as String?;
    final providerId = ride?['claimed_by_provider_id'] as String?;
    if (rideId == null || providerId == null) return;

    _driverSub = ResilientSubscription(
      stream: RideService.instance.watchDriverStatus(providerId),
      onData: (_) async {
        try {
          final p =
              await RideService.instance.getDriverLocationForRide(rideId);
          if (!mounted || p == null) return;
          if (p.lat == _driverLoc?.lat && p.lng == _driverLoc?.lng) return;
          setState(() => _driverLoc = p);
        } catch (_) {
          // A transient read failure must not clear the last known pin.
        }
      },
      // The map's own status bar tracks the ride stream; the driver signal is
      // silent, so it does not disturb that indicator.
      onState: (_) {},
    );
  }

  Future<void> _refreshMyLocation() async {
    // Use the wrapper, not the raw stream: geolocator's own timeLimit emits
    // TimeoutException and CLOSES the stream — an unhandled error there
    // crashed the whole screen. watchPosition swallows/retries instead.
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() {
      _locStatus = r.status;
      if (r.success) {
        _myPos = r.position;
        _myLocationApproximate = r.isLastKnown;
      }
    });
    _moveCameraToMe();
    // Keep the map live: the rider's own pin used to be a one-shot fix that
    // never moved, making the screen feel like a static image.
    if (r.success && _posSub == null) {
      _posSub = LocationService.instance.watchPosition(
        distanceFilter: 15,
        onError: () {},
        onData: (pos) {
          if (!mounted) return;
          setState(() {
            _myPos = pos;
            _myLocationApproximate = false;
          });
          _moveCameraToMe();
        },
      );
    }
  }

  void _moveCameraToMe() {
    final me = _myPos;
    if (me == null || !_followUser) return;
    if (!_mapReady) {
      // FlutterMap attaches asynchronously — queue the move for onMapReady
      // instead of relying on a try/catch that hides real regressions.
      _pendingCameraMove = true;
      return;
    }
    _mapController.move(
        LatLng(me.latitude, me.longitude), _mapController.camera.zoom);
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
      // On-screen CANCELLED from here on means the rider's own cancel, not
      // the server's no-driver timeout.
      _iCancelled = true;
      if (mounted) context.go('/user');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e, context: 'Could not update this ride'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Active Ride'),
        bottom: RealtimeStatusBar(state: _rideConn),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
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
              onMapReady: () {
                _mapReady = true;
                if (_pendingCameraMove) {
                  _pendingCameraMove = false;
                  _moveCameraToMe();
                }
              },
              onTap: (_, __) => setState(() => _followUser = false),
            ),
            children: [
              const ResilientTileLayer(),
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
                      width: 96,
                      height: 64,
                      alignment: Alignment.topCenter,
                      child: SearchingPin(claimed: claimed),
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
          // The unclaimed countdown, ticking down to the 3-minute window
          // the server enforces (expire_stale_ride_requests).
          if (!_noDriver && status == 'REQUESTED')
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _countdownText(),
                style:
                    const TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
            ),
          // Out of time: the retry / widen-search panel.
          if (_noDriver) _noDriverPanel(),
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
                )
              else if (_myLocationApproximate)
                const Text('approximate location',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            ],
          ),
          const SizedBox(height: 12),
          // Who is coming: name, business and plate for the driver who
          // claimed the ride. The live position is the pin above; this is
          // what the rider matches it to at the kerb.
          if (claimed && _driver != null && _driver!.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 18,
                    backgroundColor: AppTheme.primaryGreen,
                    child: Icon(Icons.person_outline,
                        size: 20, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _driverName(),
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w700),
                        ),
                        if (_driverBusiness() != null)
                          Text(_driverBusiness()!,
                              style: const TextStyle(
                                  fontSize: 12, color: AppTheme.textMuted)),
                        if (_driverPlate() != null)
                          Text('Plate ${_driverPlate()}',
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  color: AppTheme.primaryGreen,
                                  fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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

  /// "No driver yet — 2:41 left before we stop looking": the countdown to
  /// the server's 3-minute unclaimed timeout, computed from requested_at so
  /// it survives app close/reopen.
  /// The rider-visible name for the assigned driver: the person's name when
  /// the profile has one, else the business they drive under, never blank.
  String _driverName() {
    final d = _driver ?? const <String, dynamic>{};
    final name = (d['full_name'] as String?)?.trim();
    if (name != null && name.isNotEmpty) return name;
    final nested = d['profiles'] is Map
        ? ((d['profiles'] as Map)['full_name'] as String?)?.trim()
        : null;
    if (nested != null && nested.isNotEmpty) return nested;
    final shop = (d['business_name'] as String?)?.trim();
    if (shop != null && shop.isNotEmpty) return shop;
    return 'Your driver';
  }

  /// The business line under the name — only when it adds to it.
  String? _driverBusiness() {
    final d = _driver ?? const <String, dynamic>{};
    final shop = (d['business_name'] as String?)?.trim();
    final name = (d['full_name'] as String?)?.trim();
    if (shop == null || shop.isEmpty) return null;
    if (name != null && name.isNotEmpty && name == shop) return null;
    return shop;
  }

  String? _driverPlate() {
    final plate = (_driver?['plate_number'] as String?)?.trim();
    return (plate == null || plate.isEmpty) ? null : plate;
  }

  String _countdownText() {
    final at = _requestedAt();
    if (at == null) return 'Looking for a driver nearby…';
    var left = _searchTimeout - DateTime.now().difference(at);
    if (left.isNegative) left = Duration.zero;
    final seconds = (left.inSeconds % 60).toString().padLeft(2, '0');
    return 'No driver yet — ${left.inMinutes}:$seconds left before we stop '
        'looking';
  }

  /// The timed-out state: what happened, and the two ways out. "Try again"
  /// stands the old request down and returns to the form; widening the
  /// search is choosing any vehicle type there, which is what the caption
  /// tells the rider to do.
  Widget _noDriverPanel() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.block,
                  color: AppTheme.warning, size: 20),
              const SizedBox(width: 8),
              Text('No driver found',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.warning)),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'No driver accepted your ride within 3 minutes. Try again — or '
            'widen your search: on the next request, pick any vehicle type '
            'to reach more drivers.',
            style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: PrimaryButton(
                  label: 'TRY AGAIN',
                  isLoading: _retrying,
                  onPressed: _retry,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => context.go('/user'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('BACK TO HOME'),
                ),
              ),
            ],
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

/// Status pin shown on the map while no GPS fix / driver location exists
/// (the "Searching for a driver…" / "Waiting for driver location…" chip).
///
/// Replaces an inline Column inside a 48×48 marker box that stacked a 30px
/// icon + a text chip (~47px) — a guaranteed 29px RenderFlex overflow on
/// every device while the ride is unclaimed (screenshot bug). Icon and chip
/// are height-pinned (34 + 4 + 20 = 58 ≤ 64) and the text scales down inside
/// the chip, so it fits at any text scale or locale.
///
/// Public so the overflow regression test can render it directly; only
/// meant for use inside the Active Ride screen.
class SearchingPin extends StatelessWidget {
  final bool claimed;
  const SearchingPin({super.key, required this.claimed});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          height: 34,
          child: Icon(Icons.location_searching,
              color: AppTheme.textMuted, size: 30),
        ),
        const SizedBox(height: 4),
        Container(
          height: 20,
          width: 88,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.cardBorder, width: 0.5),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              claimed
                  ? 'Waiting for driver location…'
                  : 'Searching for a driver…',
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(fontSize: 9, color: AppTheme.textMuted),
            ),
          ),
        ),
      ],
    );
  }
}
