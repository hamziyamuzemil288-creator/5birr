import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';

class DriverRideRequestsScreen extends StatefulWidget {
  const DriverRideRequestsScreen({super.key});
  @override
  State<DriverRideRequestsScreen> createState() => _State();
}

class _State extends State<DriverRideRequestsScreen> {
  StreamSubscription? _rideSub;
  List<Map<String, dynamic>> _requests = [];
  bool _loading = true;
  String? _providerId;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
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

    // Subscribe to new ride requests
    _rideSub = RideService.instance.watchRideRequests().listen((rides) {
      if (mounted) setState(() => _requests = rides);
    });

    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _rideSub?.cancel();
    super.dispose();
  }

  Future<void> _claim(Map<String, dynamic> ride) async {
    if (_providerId == null) return;
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

    try {
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
        final msg = e.toString().contains('RIDE_ALREADY_TAKEN')
            ? 'This ride was just taken by another driver'
            : 'Failed to claim ride: $e';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ride Requests')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.teal))
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
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () => _claim(r),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppTheme.teal,
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  child: const Text('CLAIM RIDE',
                                      style: TextStyle(
                                          fontWeight: FontWeight.w700)),
                                ),
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
