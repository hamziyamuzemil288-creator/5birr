import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';

class UserRideRequestScreen extends StatefulWidget {
  const UserRideRequestScreen({super.key});
  @override
  State<UserRideRequestScreen> createState() => _State();
}

class _State extends State<UserRideRequestScreen> {
  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  Position? _pickupPos;
  // Destination coordinates come from the map picker — nothing else sets
  // these, so a ride request cannot be submitted without picking a pin.
  LatLng? _destLatLng;
  bool _geocoding = false;
  String? _selectedVehicleCategory;
  List<Map<String, dynamic>> _vehicleCategories = [];
  bool _loading = true;
  bool _submitting = false;
  String? _error;
  LocationStatus? _locStatus;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Get current location for pickup (asks permission on first use;
      // failures surface inline via the pickup section, not silently).
      final r = await LocationService.instance.getCurrentPositionDetailed();
      if (mounted) setState(() => _locStatus = r.status);
      if (r.success) {
        _pickupPos = r.position;
        _pickupCtrl.text = 'Current Location';
      }
      // Load vehicle categories
      final cats = await Supabase.instance.client
          .from('categories')
          .select('id,name,slug')
          .eq('sector', 'VEHICLE')
          .eq('is_active', true)
          .order('sort_order');
      if (mounted) {
        setState(() {
          _vehicleCategories = List<Map<String, dynamic>>.from(cats as List);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Initial map center for the picker: current pin, else GPS pickup,
  /// else a sensible default (Addis Ababa).
  LatLng _initialMapCenter() {
    if (_destLatLng != null) return _destLatLng!;
    if (_pickupPos != null) {
      return LatLng(_pickupPos!.latitude, _pickupPos!.longitude);
    }
    return const LatLng(9.03, 38.74); // Addis Ababa, Ethiopia
  }

  String _formatCoords(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  Future<void> _pickDestinationOnMap() async {
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) =>
            _MapPickerScreen(initialCenter: _initialMapCenter()),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _destLatLng = picked;
      _error = null;
    });
    // Coordinates go in the text field immediately; the reverse-geocoded
    // address replaces them when (and if) it resolves.
    _destCtrl.text = _formatCoords(picked);
    await _reverseGeocode(picked);
  }

  Future<void> _reverseGeocode(LatLng point) async {
    setState(() => _geocoding = true);
    try {
      final placemarks =
          await placemarkFromCoordinates(point.latitude, point.longitude);
      if (!mounted) return;
      final address =
          _formatPlacemark(placemarks.isNotEmpty ? placemarks.first : null);
      setState(() {
        if (address.isNotEmpty) _destCtrl.text = address;
        _geocoding = false;
      });
    } catch (_) {
      // Reverse geocoding is best-effort; the coordinate text remains.
      if (mounted) setState(() => _geocoding = false);
    }
  }

  String _formatPlacemark(Placemark? p) {
    if (p == null) return '';
    return [
      p.street,
      p.subLocality,
      p.locality,
      p.administrativeArea,
      p.country,
    ].where((s) => s != null && s.trim().isNotEmpty).join(', ');
  }

  Future<void> _submit() async {
    if (_pickupPos == null) {
      setState(() => _error = 'Pickup location is required');
      return;
    }
    if (_destLatLng == null) {
      setState(() => _error = 'Destination is required');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await RideService.instance.createRideRequest(
        pickupLat: _pickupPos!.latitude,
        pickupLng: _pickupPos!.longitude,
        destLat: _destLatLng!.latitude,
        destLng: _destLatLng!.longitude,
        pickupText: _pickupCtrl.text,
        destText: _destCtrl.text,
        vehicleCategoryId: _selectedVehicleCategory,
      );
      if (mounted) {
        context.go('/user/ride-active');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Failed to create ride: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Request Ride')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_error != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_error!,
                          style: const TextStyle(
                              fontSize: 13, color: AppTheme.error)),
                    ),
                    const SizedBox(height: 16),
                  ],
                  const Text('Pickup Location',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  BirrTextField(
                    label: 'Pickup',
                    controller: _pickupCtrl,
                    hint: 'Tap to use current location',
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () async {
                      final r =
                          await LocationService.instance
                              .getCurrentPositionDetailed();
                      if (!mounted) return;
                      setState(() => _locStatus = r.status);
                      if (r.success) {
                        setState(() => _pickupPos = r.position);
                        _pickupCtrl.text = 'Current Location';
                      } else if (r.status == LocationStatus.deniedForever ||
                          r.status == LocationStatus.serviceDisabled) {
                        // Recovery path: jump straight to the OS settings.
                        await LocationService.instance.openLocationSettings();
                      } else {
                        setState(() => _error =
                            'Could not get your location — check GPS and try again');
                      }
                    },
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text('Use current location'),
                  ),
                  if (_pickupPos == null &&
                      (_locStatus == LocationStatus.deniedForever ||
                          _locStatus == LocationStatus.serviceDisabled))
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 4),
                      child: Text(
                        'Location is off — enable it in settings so drivers can find you',
                        style:
                            TextStyle(fontSize: 12, color: AppTheme.warning),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text('Destination',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  BirrTextField(
                    label: 'Destination',
                    controller: _destCtrl,
                    hint: 'Pick on map, or type an address',
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _geocoding ? null : _pickDestinationOnMap,
                        icon: const Icon(Icons.map_outlined, size: 16),
                        label: const Text('Pick on map'),
                      ),
                      if (_geocoding)
                        const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.primaryGreen),
                          ),
                        ),
                    ],
                  ),
                  if (_destLatLng != null)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Text(
                        'Destination coordinates set — tap the map icon to change',
                        style: TextStyle(fontSize: 12, color: AppTheme.success),
                      ),
                    ),
                  const SizedBox(height: 16),
                  // Vehicle category selection
                  const Text('Vehicle Type',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _vehicleCategories.map((c) {
                      final selected = _selectedVehicleCategory == c['id'];
                      return ChoiceChip(
                        label: Text(c['name'] ?? ''),
                        selected: selected,
                        onSelected: (_) {
                          setState(() => _selectedVehicleCategory =
                              selected ? null : c['id']);
                        },
                        selectedColor: AppTheme.teal,
                        labelStyle: TextStyle(
                            color: selected ? Colors.white : AppTheme.textPrimary,
                            fontSize: 13),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: PrimaryButton(
                      label: 'REQUEST RIDE',
                      isLoading: _submitting,
                      // Destination coordinates must be picked before the
                      // request can be submitted.
                      onPressed: _destLatLng == null ? null : _submit,
                    ),
                  ),
                  if (_destLatLng == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Pick a destination on the map to enable the request',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Full-screen OpenStreetMap destination picker.
/// Drag the map and tap to drop a pin; confirm returns the picked [LatLng].
class _MapPickerScreen extends StatefulWidget {
  final LatLng initialCenter;
  const _MapPickerScreen({super.key, required this.initialCenter});

  @override
  State<_MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<_MapPickerScreen> {
  LatLng? _picked;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pick Destination')),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: 14,
              onTap: (_, point) => setState(() => _picked = point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // Android identifies tile requests by the app's package name.
                // TODO: replace with the real applicationId once the
                // android/app/build.gradle scaffold exists in this repo.
                userAgentPackageName: 'com.amistbirr.myapp',
              ),
              if (_picked != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _picked!,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_pin,
                          color: AppTheme.primaryGreen, size: 44),
                    ),
                  ],
                ),
              // Required by the OpenStreetMap tile usage policy.
              const RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
          if (_picked == null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.12),
                        blurRadius: 10,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: const Text(
                    'Drag the map, then tap to drop a pin',
                    style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_picked != null)
                Text(
                  '${_picked!.latitude.toStringAsFixed(5)}, '
                  '${_picked!.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary),
                ),
              if (_picked != null) const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'CONFIRM DESTINATION',
                  onPressed: _picked == null
                      ? null
                      : () => Navigator.of(context).pop(_picked),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}