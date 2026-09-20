import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/location_service.dart';
import '../../core/services/points_service.dart';

class VehicleProviderDashboard extends ConsumerStatefulWidget {
  const VehicleProviderDashboard({super.key});
  @override
  ConsumerState<VehicleProviderDashboard> createState() =>
      _VehicleProviderDashboardState();
}

class _VehicleProviderDashboardState
    extends ConsumerState<VehicleProviderDashboard> {
  Map<String, dynamic>? _providerProfile;
  Map<String, dynamic>? _driverStatus;
  int _vehicleCount = 0;
  int _points = 0;
  double? _walletBalance;
  bool _loading = true;
  bool _togglingOnline = false;
  StreamSubscription? _posSub;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select()
          .eq('user_id', userId)
          .eq('provider_type', 'VEHICLE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final vehicles = await client
          .from('vehicles')
          .select('id')
          .eq('provider_id', prov['id'])
          .count(CountOption.exact);
      final status = await client
          .from('driver_status')
          .select()
          .eq('provider_id', prov['id'])
          .maybeSingle();
      final points = await PointsService.instance.getProviderPoints(prov['id'] as String);
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      if (mounted) {
        setState(() {
          _providerProfile = prov;
          _vehicleCount = vehicles.count ?? 0;
          _driverStatus = status;
          _points = points;
          _walletBalance = (wallet?['balance'] as num?)?.toDouble();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleOnline() async {
    if (_providerProfile == null) return;
    setState(() => _togglingOnline = true);
    try {
      final isCurrentlyOnline = _driverStatus?['is_online'] ?? false;
      if (!isCurrentlyOnline) {
        // Going online - need a real GPS fix (and the runtime permission).
        final r = await LocationService.instance.getCurrentPositionDetailed();
        if (!r.success) {
          if (mounted) {
            final openSettings = r.status == LocationStatus.deniedForever ||
                r.status == LocationStatus.serviceDisabled;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(_onlineBlockedMessage(r.status)),
              action: openSettings
                  ? SnackBarAction(
                      label: 'Open settings',
                      onPressed: () =>
                          LocationService.instance.openLocationSettings())
                  : null,
            ));
          }
          setState(() => _togglingOnline = false);
          return;
        }
        final pos = r.position!;
        await LocationService.instance.setDriverOnline(
            _providerProfile!['id'], true,
            lat: pos.latitude, lng: pos.longitude);
        // Start location updates
        _startLocationUpdates(_providerProfile!['id']);
      } else {
        // Going offline
        await LocationService.instance.setDriverOnline(
            _providerProfile!['id'], false);
        _posSub?.cancel();
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _togglingOnline = false);
    }
  }

  void _startLocationUpdates(String providerId) {
    _posSub?.cancel();
    _posSub = LocationService.instance.getPositionStream(
        distanceFilter: 100, interval: const Duration(seconds: 15))
        .listen((pos) {
      LocationService.instance.updateDriverLocation(
          providerId, pos.latitude, pos.longitude);
    },
        onError: (_) {}); // keep last fix if GPS hiccups mid-shift
  }

  String _onlineBlockedMessage(LocationStatus status) {
    switch (status) {
      case LocationStatus.serviceDisabled:
        return 'Turn on GPS to go online';
      case LocationStatus.deniedForever:
        return 'Location permission blocked — enable it in app settings';
      case LocationStatus.denied:
        return 'Location permission is required to go online';
      default:
        return 'Could not get your location — try again';
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  bool get _isOnline => _driverStatus?['is_online'] ?? false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aliob Transport'),
        actions: [
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Coming soon')),
              )),
          IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => ref.read(authProvider.notifier).signOut()),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.teal))
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with online toggle
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: _isOnline
                                ? [AppTheme.teal, const Color(0xFF00695C)]
                                : [AppTheme.textMuted, AppTheme.textSecondary]),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        _providerProfile?['business_name'] ??
                                            auth.profile?.fullName ??
                                            'Provider',
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white)),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.2),
                                        borderRadius:
                                            BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                          (_providerProfile?['status'] ??
                                                  'UNKNOWN')
                                              .replaceAll('_', ' '),
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white)),
                                    ),
                                  ],
                                ),
                              ),
                              // Online/offline toggle
                              GestureDetector(
                                onTap: _togglingOnline ? null : _toggleOnline,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: _togglingOnline
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white))
                                      : Text(
                                          _isOnline ? 'ONLINE' : 'OFFLINE',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Wallet balance strip
                    _walletCard(),
                    const SizedBox(height: 20),
                    // Stats
                    Row(
                      children: [
                        _stat(Icons.directions_car, 'Vehicles', '$_vehicleCount'),
                        const SizedBox(width: 12),
                        _stat(Icons.stars_rounded, 'Points', '$_points'),
                        const SizedBox(width: 12),
                        _stat(Icons.star_outline, 'Rating', '0.0'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Actions
                    const Text('Actions',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    // Buyer mode: vehicle providers can shop from service
                    // providers using the regular user experience while
                    // keeping this transport dashboard.
                    _action(Icons.shopping_bag_outlined, 'Browse & Shop',
                        () => context.push('/user')),
                    _action(Icons.local_taxi_outlined, 'Ride Requests',
                        () => context.push('/vehicle/ride-requests')),
                    _action(Icons.play_circle_outline, 'Active Trip',
                        () => context.push('/vehicle/trip')),
                    _action(Icons.history, 'Ride History',
                        () => context.push('/vehicle/ride-history')),
                    _action(Icons.directions_car_outlined, 'Manage Vehicles',
                        () => context.push('/vehicle/vehicles')),
                    _action(Icons.add_circle_outline, 'Add Vehicle',
                        () => context.push('/vehicle/vehicles/new')),
                    _action(Icons.account_balance_wallet_outlined, 'Wallet',
                        () => context.push('/wallet')),
                    _action(Icons.person_outline, 'Profile',
                        () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coming soon')),
                        )),
                  ],
                ),
              ),
            ),
    );
  }

  /// Compact wallet balance strip: balance at a glance + one-tap recharge.
  Widget _walletCard() {
    final balance = _walletBalance ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.account_balance_wallet_outlined,
                color: AppTheme.teal, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Wallet Balance',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text('${balance.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => context.push('/wallet/recharge'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Recharge',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(foregroundColor: AppTheme.teal),
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppTheme.teal, size: 22),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            Text(label,
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.teal),
        title: Text(label,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right,
            color: AppTheme.textMuted, size: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: AppTheme.surface,
      ),
    );
  }
}
