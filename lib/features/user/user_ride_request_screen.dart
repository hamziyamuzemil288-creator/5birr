import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
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

class _State extends State<UserRideRequestScreen>
    with WidgetsBindingObserver {
  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  final _destFocus = FocusNode();
  Position? _pickupPos;
  // Pickup fallback when GPS is unavailable: set by typing an address
  // (geocoded on submit) or by picking a point on the map.
  LatLng? _pickupManual;
  // Destination coordinates come from the map picker — nothing else sets
  // these, so a ride request cannot be submitted without picking a pin.
  LatLng? _destLatLng;
  bool _geocoding = false;
  String? _selectedVehicleCategory;
  List<Map<String, dynamic>> _vehicleCategories = [];
  bool _loading = true;
  bool _submitting = false;
  bool _fareLoading = false;
  String? _fareError;
  double? _fareEstimate;
  String? _error;
  LocationStatus? _locStatus;
  // Destination inline suggestions (Photon/OSM, free, no API key).
  List<PhotonPlace> _destSuggestions = const [];
  bool _destFieldFocused = false;
  bool _suppressDestSearch = false;
  int _destReqId = 0;
  Timer? _destDebounce;
  // Set before openLocationSettings(): the next app resume re-runs the
  // GPS fix once instead of requiring a second manual tap.
  bool _afterResumePending = false;

  // ---- TEMPORARY on-screen diagnostics (remove after debugging) ----
  // Shows the live GPS/search state on the screen itself so failures are
  // visible on a real device without ADB/logcat access.
  String _dbgGps = '—';
  String _dbgPhoton = '—';

  /// Latest inputs sent to calculate_fare_estimate — dedupes and skips
  /// stale responses when the user changes points quickly.
  (double, double, double, double, String?)? _fareRequestKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _destFocus.addListener(_onDestFocusChanged);
    _destCtrl.addListener(_onDestChanged);
    // Categories render immediately; GPS resolves in the background so the
    // form is never hostage to a slow fix or the permission dialog.
    _loadCategories();
    _resolvePickupLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _destFocus.removeListener(_onDestFocusChanged);
    _destFocus.dispose();
    _destCtrl.removeListener(_onDestChanged);
    _destDebounce?.cancel();
    _pickupCtrl.dispose();
    _destCtrl.dispose();
    super.dispose();
  }

  /// Server-side fare (system_settings pricing, per-category overrides).
  /// Fire-and-refresh: failures leave the estimate hidden, never block a
  /// ride request — the server re-computes authoritatively on submit.
  Future<void> _refreshFare() async {
    final p = _pickupPoint;
    final d = _destLatLng;
    if (p == null || d == null) return;
    final key = (p.latitude, p.longitude, d.latitude, d.longitude, _selectedVehicleCategory);
    if (key == _fareRequestKey && _fareEstimate != null) return;
    _fareRequestKey = key;
    setState(() {
      _fareLoading = true;
      _fareError = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'calculate_fare_estimate',
        params: {
          'p_pickup_lat': p.latitude,
          'p_pickup_lng': p.longitude,
          'p_dest_lat': d.latitude,
          'p_dest_lng': d.longitude,
          if (_selectedVehicleCategory != null)
            'p_vehicle_category_id': _selectedVehicleCategory,
        },
      );
      // A newer request superseded this one — discard.
      if (_fareRequestKey != key) return;
      if (mounted) {
        setState(() {
          _fareEstimate = (res as num?)?.toDouble();
          _fareLoading = false;
        });
      }
    } catch (_) {
      if (_fareRequestKey != key) return;
      if (mounted) {
        setState(() {
          _fareLoading = false;
          _fareError = 'Fare unavailable';
        });
      }
    }
  }

  /// Loads vehicle categories. The only gate on the loading spinner — GPS
  /// intentionally excluded so the form appears immediately.
  Future<void> _loadCategories() async {
    try {
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
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Background GPS resolution for pickup (asks permission on first use;
  /// failures surface inline via the pickup section, not silently).
  Future<void> _resolvePickupLocation() async {
    setState(() => _dbgGps = 'requesting… (init)');
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() {
      _locStatus = r.status;
      _dbgGps = _dbgDescribeLocationResult(r);
    });
    if (r.success) _applyPickupPosition(r.position!);
  }

  /// TEMP diagnostics: one-line human summary of a location attempt.
  String _dbgDescribeLocationResult(LocationResult r) {
    switch (r.status) {
      case LocationStatus.ready:
        final p = r.position!;
        return 'ready (${p.latitude.toStringAsFixed(4)}, '
            '${p.longitude.toStringAsFixed(4)})';
      case LocationStatus.serviceDisabled:
        return 'serviceDisabled';
      case LocationStatus.denied:
        return 'denied';
      case LocationStatus.deniedForever:
        return 'deniedForever';
      case LocationStatus.error:
        final msg = (r.errorMessage ?? 'unknown').replaceAll('\n', ' ');
        return 'error: ${msg.length > 60 ? msg.substring(0, 60) : msg}';
    }
  }

  /// Applies a GPS fix to the pickup state, clearing any manual override.
  void _applyPickupPosition(Position position) {
    setState(() {
      _pickupPos = position;
      _pickupManual = null; // GPS re-take clears any manual override
    });
    _pickupCtrl.text = 'Current Location';
    _refreshFare();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the OS location settings: take one fresh fix instead
    // of making the user tap "Use current location" again.
    if (state == AppLifecycleState.resumed && _afterResumePending) {
      _afterResumePending = false;
      _resolvePickupLocation();
    }
  }

  // ---- Destination inline suggestions (Photon / OpenStreetMap) ----

  void _onDestFocusChanged() {
    setState(() => _destFieldFocused = _destFocus.hasFocus);
  }

  /// Debounced Photon autocomplete as the user types a destination.
  /// Controller updates from picking a result are suppressed via
  /// [_suppressDestSearch]; every search request is tagged so stale
  /// responses never overwrite newer ones.
  void _onDestChanged() {
    if (_suppressDestSearch) return;
    final q = _destCtrl.text.trim();
    _destDebounce?.cancel();
    if (q.length < 3 || !_destFieldFocused) {
      if (mounted && _destSuggestions.isNotEmpty) {
        setState(() => _destSuggestions = const []);
      }
      return;
    }
    _destDebounce = Timer(const Duration(milliseconds: 450), () {
      _searchDestSuggestions(q);
    });
  }

  Future<void> _searchDestSuggestions(String query) async {
    final reqId = ++_destReqId;
    setState(() => _dbgPhoton = 'searching "$query"…');
    final results = await PhotonService.autocomplete(query);
    if (!mounted || reqId != _destReqId) return;
    setState(() {
      _destSuggestions = results;
      _dbgPhoton = results.isEmpty
          ? '0 results for "$query"'
          : '${results.length} results';
    });
  }

  void _selectDestSuggestion(PhotonPlace place) {
    setState(() {
      _destLatLng = LatLng(place.lat, place.lng);
      _destSuggestions = const [];
      _error = null;
    });
    _destFocus.unfocus();
    _suppressDestSearch = true;
    _destCtrl.text = place.label;
    _suppressDestSearch = false;
    _refreshFare();
  }

  /// Effective pickup point: the latest explicit choice wins — a typed or
  /// map-picked pickup overrides an earlier GPS fix; "Use current location"
  /// clears the manual override. Null until one is set.
  LatLng? get _pickupPoint =>
      _pickupManual ??
      (_pickupPos != null
          ? LatLng(_pickupPos!.latitude, _pickupPos!.longitude)
          : null);

  /// Initial map center for the picker: current pin, else GPS pickup,
  /// else a sensible default (Addis Ababa).
  LatLng _initialMapCenter() {
    if (_destLatLng != null) return _destLatLng!;
    if (_pickupPoint != null) return _pickupPoint!;
    return const LatLng(9.03, 38.74); // Addis Ababa, Ethiopia
  }

  Future<void> _pickPickupOnMap() async {
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) => _MapPickerScreen(
          initialCenter: _initialMapCenter(),
          title: 'Pick Pickup Location',
          initialCenterReliable: _pickupPoint != null || _destLatLng != null,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pickupManual = picked;
      _error = null;
    });
    _pickupCtrl.text = _formatCoords(picked);
    _refreshFare();
    // Reverse geocode into a readable label (best-effort, same as dest).
    try {
      final placemarks = await placemarkFromCoordinates(
          picked.latitude, picked.longitude);
      if (!mounted) return;
      final address =
          _formatPlacemark(placemarks.isNotEmpty ? placemarks.first : null);
      if (address.isNotEmpty) _pickupCtrl.text = address;
    } catch (_) {
      // Coordinate text remains as the label.
    }
  }

  /// Geocode a typed pickup address. Returns true when a coordinate was
  /// found and stored in [_pickupManual].
  Future<bool> _geocodeTypedPickup() async {
    final text = _pickupCtrl.text.trim();
    if (text.isEmpty) return false;
    try {
      final locations = await locationFromAddress(text);
      if (locations.isEmpty) return false;
      final loc = locations.first;
      if (!mounted) return true;
      setState(() =>
          _pickupManual = LatLng(loc.latitude, loc.longitude));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _formatCoords(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  /// Geocode a typed destination address at submit time. Returns true when
  /// a coordinate was found and stored in [_destLatLng].
  Future<bool> _geocodeTypedDestination() async {
    final text = _destCtrl.text.trim();
    if (text.isEmpty) return false;
    try {
      final locations = await locationFromAddress(text);
      if (locations.isEmpty) return false;
      final loc = locations.first;
      if (!mounted) return true;
      setState(() => _destLatLng = LatLng(loc.latitude, loc.longitude));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _pickDestinationOnMap() async {
    final picked = await Navigator.of(context).push<LatLng>(
      MaterialPageRoute(
        builder: (_) =>
            _MapPickerScreen(
              initialCenter: _initialMapCenter(),
              initialCenterReliable: _pickupPoint != null || _destLatLng != null,
            ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _destLatLng = picked;
      _error = null;
    });
    // Coordinates go in the text field immediately; the reverse-geocoded
    // address replaces them when (and if) it resolves. Writes are
    // suppressed so the suggestion listener doesn't search the raw text.
    _suppressDestSearch = true;
    _destCtrl.text = _formatCoords(picked);
    _suppressDestSearch = false;
    _refreshFare();
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
        _suppressDestSearch = true;
        if (address.isNotEmpty) _destCtrl.text = address;
        _suppressDestSearch = false;
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
    // No GPS fix yet? Try the typed address before giving up.
    if (_pickupPoint == null) {
      final found = await _geocodeTypedPickup();
      if (!mounted) return;
      if (!found) {
        setState(() => _error =
            'Pickup location is required — use current location, type an address, or pick on the map');
        return;
      }
    }
    if (_destLatLng == null) {
      // Typed destination that never resolved via a suggestion or the map
      // picker: attempt one forward-geocode of the text before failing.
      final found = await _geocodeTypedDestination();
      if (!mounted) return;
      if (!found) {
        setState(() => _error =
            'Destination is required — type an address and pick a suggestion, or pick on the map');
        return;
      }
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await RideService.instance.createRideRequest(
        pickupLat: _pickupPoint!.latitude,
        pickupLng: _pickupPoint!.longitude,
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
                  Row(
                    children: [
                      TextButton.icon(
                    onPressed: () async {
                      setState(() => _dbgGps = 'requesting… (tap)');
                      final r =
                          await LocationService.instance
                              .getCurrentPositionDetailed();
                      if (!mounted) return;
                      setState(() {
                        _locStatus = r.status;
                        _dbgGps = _dbgDescribeLocationResult(r);
                      });
                      if (r.success) {
                        _applyPickupPosition(r.position!);
                      } else if (r.status == LocationStatus.deniedForever ||
                          r.status == LocationStatus.serviceDisabled) {
                        // Recovery path: jump straight to the OS settings;
                        // when the user returns, one fix is re-attempted
                        // automatically (see didChangeAppLifecycleState).
                        _afterResumePending = true;
                        await LocationService.instance.openLocationSettings();
                      } else {
                        setState(() => _error =
                            'Could not get your location — check GPS and try again');
                      }
                    },
                    icon: const Icon(Icons.my_location, size: 16),
                    label: const Text('Use current location'),
                  ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _pickPickupOnMap,
                        icon: const Icon(Icons.map_outlined, size: 16),
                        label: const Text('Pick on map'),
                      ),
                    ],
                  ),
                  if (_pickupPoint == null &&
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
                    focusNode: _destFocus,
                    hint: 'Type an address, or pick on map',
                    suffixIcon: _destCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: _geocoding
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: AppTheme.primaryGreen))
                                : const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _destDebounce?.cancel();
                              if (mounted) {
                                setState(() {
                                  _destCtrl.clear();
                                  _destLatLng = null;
                                  _destSuggestions = const [];
                                });
                              }
                            },
                          )
                        : null,
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
                  // TEMPORARY on-screen diagnostics — remove after debugging.
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.textMuted.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'DIAG v33b · GPS: $_dbgGps · Photon: $_dbgPhoton · '
                      'field: ${_destFieldFocused ? 'focused' : 'not focused'}, '
                      '${_destCtrl.text.length} chars',
                      style: const TextStyle(
                          fontSize: 10, color: AppTheme.textMuted),
                    ),
                  ),
                  if (_destFieldFocused && _destSuggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppTheme.textMuted.withOpacity(0.25)),
                      ),
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _destSuggestions.length,
                        itemBuilder: (context, i) {
                          final place = _destSuggestions[i];
                          return ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: const Icon(Icons.place_outlined,
                                size: 20, color: AppTheme.primaryGreen),
                            title: Text(
                              place.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: AppTheme.textPrimary),
                            ),
                            onTap: () => _selectDestSuggestion(place),
                          );
                        },
                      ),
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
                          _refreshFare();
                        },
                        selectedColor: AppTheme.teal,
                        labelStyle: TextStyle(
                            color: selected ? Colors.white : AppTheme.textPrimary,
                            fontSize: 13),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  // Fare estimate from the server's pricing engine (base +
                  // per-km × distance, minimum enforced) — the same values
                  // stamped onto the ride request.
                  if (_fareLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 8),
                        Text('Estimating fare…',
                            style:
                                TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                      ]),
                    )
                  else if (_fareEstimate != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryGreen.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.payments_outlined,
                              color: AppTheme.primaryGreen, size: 20),
                          const SizedBox(width: 10),
                          Text('Estimated fare',
                              style: TextStyle(
                                  fontSize: 13, color: AppTheme.textPrimary)),
                          const Spacer(),
                          Text(
                            'ETB ${_fareEstimate!.toStringAsFixed(2)}',
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.primaryGreen),
                          ),
                        ],
                      ),
                    )
                  else if (_fareError != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(_fareError!,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.textMuted)),
                    ),
                  const SizedBox(height: 8),
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

/// One Photon autocomplete result (OpenStreetMap-backed, free, no key).
class PhotonPlace {
  final double lat;
  final double lng;
  final String label;
  const PhotonPlace({required this.lat, required this.lng, required this.label});
}

/// Minimal Photon (https://photon.komoot.io) autocomplete client.
/// Debouncing and the <3-char guard live with the callers.
class PhotonService {
  PhotonService._();

  static const _endpoint = 'https://photon.komoot.io/api/';

  static String _label(Map<String, dynamic> p) {
    final name = p['name'];
    final street = p['street'];
    final city = p['city'];
    final state = p['state'];
    final country = p['country'];
    final head = (name is String && name.trim().isNotEmpty)
        ? name
        : (street is String ? street : '');
    final tail = [city, state, country]
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet() // de-dupe (city often equals the name)
        .join(', ');
    return [head, tail].where((s) => s.isNotEmpty).join(', ');
  }

  /// Returns up to [limit] suggestions for [query], or an empty list on
  /// any network/parse failure (suggestions must never block booking).
  static Future<List<PhotonPlace>> autocomplete(String query,
      {int limit = 5}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    try {
      final uri = Uri.parse(_endpoint).replace(queryParameters: {
        'q': q,
        'limit': '$limit',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body);
      final features = body['features'];
      if (features is! List) return const [];
      final places = <PhotonPlace>[];
      for (final f in features) {
        if (f is! Map) continue;
        final geometry = f['geometry'];
        final coords = geometry is Map ? geometry['coordinates'] : null;
        if (coords is! List || coords.length < 2) continue;
        final lng = (coords[0] as num?)?.toDouble();
        final lat = (coords[1] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        final props = f['properties'];
        final label = props is Map ? _label(Map<String, dynamic>.from(props)) : '';
        places.add(PhotonPlace(
          lat: lat,
          lng: lng,
          label: label.isNotEmpty
              ? label
              : '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
        ));
      }
      return places;
    } catch (_) {
      return const [];
    }
  }
}

/// Full-screen OpenStreetMap location picker with address search.
/// Search a place, drag the map, or tap to drop a pin; confirm returns the
/// picked [LatLng]. Shared by pickup and destination picking.
class _MapPickerScreen extends StatefulWidget {
  final LatLng initialCenter;
  final String title;
  final bool initialCenterReliable;
  const _MapPickerScreen(
      {super.key,
      required this.initialCenter,
      this.title = 'Pick Destination',
      this.initialCenterReliable = false});

  @override
  State<_MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<_MapPickerScreen> {
  final _mapController = MapController();
  final _searchCtrl = TextEditingController();
  LatLng? _picked;
  bool _recentering = false;
  List<PhotonPlace> _results = const [];
  bool _searching = false;
  int _reqId = 0;
  Timer? _debounce;

  /// The fallback center is a constant, not a real position — self-center
  /// on GPS instead of trusting it.
  bool get _centerIsFallback =>
      !widget.initialCenterReliable &&
      widget.initialCenter.latitude == 9.03 &&
      widget.initialCenter.longitude == 38.74;

  @override
  void initState() {
    super.initState();
    if (_centerIsFallback) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _seedFromLastKnown();
        _moveToCurrentLocation(showError: false);
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// Instant coarse seed while the fresh fix is still in flight.
  Future<void> _seedFromLastKnown() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted && _centerIsFallback) {
        _mapController.move(LatLng(last.latitude, last.longitude), 15);
      }
    } catch (_) {
      // Best-effort seed only.
    }
  }

  /// Fresh GPS fix: permission is already held in the common case (the
  /// parent screen requested it), so this usually resolves quickly.
  Future<void> _moveToCurrentLocation({bool showError = true}) async {
    if (_recentering) return;
    setState(() => _recentering = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() => _recentering = false);
    if (r.success) {
      setState(() => _picked = LatLng(
          r.position!.latitude, r.position!.longitude));
      _mapController.move(
          LatLng(r.position!.latitude, r.position!.longitude), 15);
    } else if (showError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Could not get your location — check GPS and try again')),
      );
    }
  }

  // ---- Address search (Photon) ----

  void _onSearchChanged(String value) {
    final q = value.trim();
    _debounce?.cancel();
    if (q.length < 3) {
      if (mounted && _results.isNotEmpty) setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 450), () {
      _runSearch(q);
    });
  }

  Future<void> _runSearch(String query) async {
    final reqId = ++_reqId;
    setState(() => _searching = true);
    final results = await PhotonService.autocomplete(query);
    if (!mounted || reqId != _reqId) return;
    setState(() {
      _searching = false;
      _results = results;
    });
  }

  void _selectPlace(PhotonPlace place) {
    final point = LatLng(place.lat, place.lng);
    setState(() {
      _picked = point;
      _results = const [];
    });
    _searchCtrl.text = place.label;
    _mapController.move(point, 15);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter,
              initialZoom: 14,
              onTap: (_, point) => setState(() => _picked = point),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                // Android identifies tile requests by the app's package name.
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
          // Address search panel (Photon / OpenStreetMap, free).
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Column(
              children: [
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(24),
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: _onSearchChanged,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search address or place',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                            )
                          : (_searchCtrl.text.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () {
                                    _debounce?.cancel();
                                    setState(() {
                                      _searchCtrl.clear();
                                      _results = const [];
                                    });
                                  },
                               )),
                      isDense: true,
                      filled: true,
                      fillColor: AppTheme.surface,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                if (_results.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: _results
                          .map((place) => ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                leading: const Icon(Icons.place_outlined,
                                    size: 20, color: AppTheme.primaryGreen),
                                title: Text(
                                  place.label,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: AppTheme.textPrimary),
                                ),
                                onTap: () => _selectPlace(place),
                              ))
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
          if (_picked == null)
            Positioned(
              bottom: 140,
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
                    'Search, drag the map, then tap to drop a pin',
                    style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
                  ),
                ),
              ),
            ),
          // Manual recenter on the current GPS position.
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton(
              heroTag: 'mapPickerRecenter',
              onPressed: _recentering ? null : () => _moveToCurrentLocation(),
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
              child: _recentering
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.my_location),
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