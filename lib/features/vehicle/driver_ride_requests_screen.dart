import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart' as geo;
import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';
import '../../core/services/provider_doc_gate.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/realtime_status_banner.dart';

class DriverRideRequestsScreen extends StatefulWidget {
  const DriverRideRequestsScreen({super.key});
  @override
  State<DriverRideRequestsScreen> createState() => _State();
}

class _State extends State<DriverRideRequestsScreen> {
  /// How long a request may sit unclaimed before the server gives up on it
  /// (expire_stale_ride_requests) and this screen stops offering it. Kept in
  /// lockstep with the rider-side countdown in user_active_ride_screen.dart.
  static const Duration _unclaimedTimeout = Duration(minutes: 3);

  ResilientSubscription<List<Map<String, dynamic>>>? _rideSub;
  RealtimeConnState _rideConn = RealtimeConnState.connecting;
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;
  bool _claiming = false;
  String? _error;
  String? _providerId;

  // Live GPS: lets the driver see how far each open request is.
  geo.Position? _myPos;
  bool _directionsLaunching = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Previously unguarded: if the provider lookup threw, the exception escaped
    // this method, _loading was never cleared, and the driver sat on a
    // spinner forever with no way to tell whether the screen was broken or
    // there was simply no work nearby.
    try {
      // Retry replaces the realtime subscription. Without cancelling the
      // previous one first it would be orphaned — still live, still calling
      // setState, never disposed — so two feeds would drive one screen.
      _rideSub?.cancel();
      await _initInner();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load ride requests');
        });
      }
    }
  }

  Future<void> _initInner() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    final prov = await client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .eq('provider_type', 'VEHICLE_PROVIDER')
        .maybeSingle();
    if (prov == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _providerId = prov['id'];

    // Subscribe to new ride requests. A subscribe timeout is transient, so it
    // retries quietly instead of tearing the screen down (see
    // ResilientSubscription for why this must never reach the crash handler).
    _rideSub = ResilientSubscription(
      stream: RideService.instance.watchRideRequests(),
      onData: (rides) {
        // The realtime filter only sees INSERTs and matching UPDATEs: a
        // request the server expired (3-minute unclaimed timeout) can linger
        // in this feed, offering a CLAIM button that would only come back as
        // "expired". Drop rows the timeout has already claimed as its own.
        final cutoff =
            DateTime.now().subtract(_unclaimedTimeout);
        final fresh = rides.where((r) {
          final raw = (r['requested_at'] ?? r['created_at']) as String?;
          final at = raw == null ? null : DateTime.tryParse(raw);
          return at == null || at.isAfter(cutoff);
        }).toList(growable: false);
        if (mounted) setState(() => _requests = fresh);
      },
      onState: (s) {
        if (mounted) setState(() => _rideConn = s);
      },
    );

    setState(() => _loading = false);

    // Prime live GPS (asks permission on first use; failures stay silent —
    // distance hints just don't render).
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (mounted && r.success) {
      setState(() => _myPos = r.position);
    }
  }

  @override
  void dispose() {
    _rideSub?.cancel();
    super.dispose();
  }

  Future<void> _claim(Map<String, dynamic> ride) async {
    // Double-tap guard: two rapid taps fire two claims — the second loses
    // the race the first one just won and tells the driver the ride was
    // "taken by another driver".
    if (_providerId == null || _claiming) return;
    setState(() => _claiming = true);
    try {
      // Task 7: one-time document check before accepting an order — the
      // post-recharge trigger point. Missing docs open the upload + QR
      // verification sheet; declining keeps the ride available to others.
      if (!(await ProviderDocGate.instance.ensureDocuments(context))) return;
      // Get first available vehicle
      final client = Supabase.instance.client;
      final vehicles = await client
          .from('vehicles')
          .select('id')
          .eq('provider_id', _providerId!)
          .eq('is_available', true)
          .eq('status', 'APPROVED')
          .limit(1);
      if (vehicles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No available vehicles')));
        }
        return;
      }

      await RideService.instance.claimRide(
        rideId: ride['id'],
        providerId: _providerId!,
        vehicleId: vehicles.first['id'],
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ride claimed!')));
        context.push('/vehicle/trip');
      }
    } catch (e) {
      if (mounted) {
        // Keep the specific "someone beat you to it" and "it expired"
        // wordings, but stop interpolating the raw exception for every
        // other failure.
        final text = e.toString();
        final msg = text.contains('RIDE_ALREADY_TAKEN')
            ? 'This ride was just taken by another driver'
            : text.contains('RIDE_REQUEST_EXPIRED')
                ? 'This request just expired — the rider has been asked to try again'
                : friendlyError(e, context: 'Could not claim this ride');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
        // An expired or taken row must stop being offered immediately —
        // rebuild the feed from the server instead of trusting it.
        await _init();
      }
    } finally {
      if (mounted) setState(() => _claiming = false);
    }
  }

  /// Distance from my live GPS to this request's pickup (null without GPS).
  String? _distanceText(Map<String, dynamic> ride) {
    final pos = _myPos;
    final pickup = GeoPoint.parse(ride['pickup_location']);
    if (pos == null || pickup == null) return null;
    final km = LocationService.instance.calculateDistance(
        pos.latitude, pos.longitude, pickup.lat, pickup.lng);
    return km < 1 ? '${(km * 1000).round()} m away' : '${km.toStringAsFixed(1)} km away';
  }

  Future<void> _openDirections(Map<String, dynamic> ride) async {
    final pickup = GeoPoint.parse(ride['pickup_location']);
    if (pickup == null) return;
    setState(() => _directionsLaunching = true);
    final pos = _myPos;
    final ok = await LocationService.instance.openDirectionsTo(
      destLat: pickup.lat,
      destLng: pickup.lng,
      label: ride['pickup_text'] ?? 'Pickup',
      originLat: pos?.latitude,
      originLng: pos?.longitude,
    );
    if (mounted) {
      setState(() => _directionsLaunching = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No maps app available on this device')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ride Requests'),
        bottom: RealtimeStatusBar(state: _rideConn),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.teal))
          : _error != null
              ? LoadErrorView(
                  message: _error!,
                  icon: Icons.local_taxi_outlined,
                  onRetry: _init)
              : _requests.isEmpty
              ? const Center(
                  child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.local_taxi_outlined,
                        size: 64, color: AppTheme.textMuted),
                    SizedBox(height: 16),
                    Text('No ride requests nearby',
                        style: TextStyle(color: AppTheme.textMuted)),
                    SizedBox(height: 8),
                    Text('Stay online to receive requests',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  ],
                ))
              : RefreshIndicator(
                  onRefresh: () async {},
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _requests.length,
                    itemBuilder: (_, i) {
                      final r = _requests[i];
                      final pickup = r['pickup_text'] ?? 'Pickup location';
                      final dest = r['destination_text'] ?? 'Destination';
                      final created = r['created_at'] != null
                          ? DateTime.parse(r['created_at'])
                          : DateTime.now();

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.circle,
                                      color: AppTheme.success, size: 10),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(pickup,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  Text(
                                      '${DateTime.now().difference(created).inMinutes}m ago',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.textMuted)),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  const Icon(Icons.location_on,
                                      color: AppTheme.error, size: 10),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(dest,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500)),
                                  ),
                                ],
                              ),
                              if (_distanceText(r) != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.near_me_outlined,
                                          size: 13, color: AppTheme.teal),
                                      const SizedBox(width: 6),
                                      Text(_distanceText(r)!,
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.teal,
                                              fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: SizedBox(
                                      height: 42,
                                      child: ElevatedButton(
                                        onPressed: _claiming
                                            ? null
                                            : () => _claim(r),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: AppTheme.teal,
                                          padding: const EdgeInsets
                                              .symmetric(vertical: 10),
                                        ),
                                        child: const Text('CLAIM RIDE',
                                            style: TextStyle(
                                                fontWeight:
                                                    FontWeight.w700)),
                                      ),
                                    ),
                                  ),
                                  // Navigate to the pickup with the device
                                  // maps app (from my live GPS).
                                  IconButton(
                                    tooltip: 'Directions to pickup',
                                    onPressed: () => _openDirections(r),
                                    icon: _directionsLaunching
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: AppTheme.teal))
                                        : const Icon(Icons.directions,
                                            color: AppTheme.primaryGreen),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
