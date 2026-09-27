import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/map_tile_layer.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/services/geocoding_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/ride_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

class UserRideRequestScreen extends StatefulWidget {
  const UserRideRequestScreen({
    super.key,
    this.initialDestinationLabel,
    this.initialDestinationLat,
    this.initialDestinationLng,
  });

  /// A destination handed over by the live map's "Where to?" flow. Arriving
  /// with it already set means the rider answers that question once, on the
  /// map, instead of being asked it again on the next screen.
  final String? initialDestinationLabel;
  final double? initialDestinationLat;
  final double? initialDestinationLng;

  @override
  State<UserRideRequestScreen> createState() => _State();
}

class _State extends State<UserRideRequestScreen>
    with WidgetsBindingObserver {
  final _pickupCtrl = TextEditingController();
  final _destCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
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
  // Separate from _error, which carries form/submit copy. This one is a
  // failed fetch: without the vehicle categories the pickup form cannot be
  // completed at all, and the user was left with an empty selector.
  String? _loadError;
  String? _fareError;
  double? _fareEstimate;
  String? _error;
  LocationStatus? _locStatus;  // Inline place suggestions (GeocodingService: Photon/OSM, GPS-biased).
  List<PlaceResult> _destSuggestions = const [];
  List<PlaceResult> _pickupSuggestions = const [];
  bool _pickupFieldFocused = false;
  bool _destFieldFocused = false;
  bool _suppressDestSearch = false;
  bool _suppressPickupSearch = false;
  int _destReqId = 0;
  int _pickupReqId = 0;
  Timer? _destDebounce;
  Timer? _pickupDebounce;

  // Task 13 item 1: the pickup map lives on THIS screen so "Current
  // Location" re-centers it on the live GPS fix (previously the fix only
  // relabeled the text field and the screen stayed text-only).
  final MapController _mapController = MapController();
  bool _mapReady = false;
  LatLng? _pendingCenter;
  // Known/registered places near the latest GPS fix, shown as chips.
  List<PlaceResult> _nearbyPois = const [];
  // Last successful GPS fix, kept as search bias even after a manual pickup.
  Position? _lastFix;

  // Set before openLocationSettings(): the next app resume re-runs the
  // GPS fix once instead of requiring a second manual tap.
  bool _afterResumePending = false;

  /// Latest inputs sent to calculate_fare_estimate — dedupes and skips
  /// stale responses when the user changes points quickly.
  (double, double, double, double, String?)? _fareRequestKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickupFocus.addListener(_onPickupFocusChanged);
    _pickupCtrl.addListener(_onPickupChanged);
    _destFocus.addListener(_onDestFocusChanged);
    _destCtrl.addListener(_onDestChanged);
    // Categories render immediately; GPS resolves in the background so the
    // form is never hostage to a slow fix or the permission dialog.
    _loadCategories();
    _resolvePickupLocation();
    _applyPrefilledDestination();
  }

  /// Seed the destination from the live map. The `_destCtrl` listener would
  /// otherwise treat this as typing and start a geocode search for text that
  /// came from an already-resolved place — suppressed for the assignment.
  void _applyPrefilledDestination() {
    final lat = widget.initialDestinationLat;
    final lng = widget.initialDestinationLng;
    if (lat == null || lng == null) return;

    _suppressDestSearch = true;
    _destCtrl.text = widget.initialDestinationLabel ?? '';
    _destLatLng = LatLng(lat, lng);
    _suppressDestSearch = false;
    _refreshFare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pickupFocus.removeListener(_onPickupFocusChanged);
    _pickupFocus.dispose();
    _pickupCtrl.removeListener(_onPickupChanged);
    _pickupDebounce?.cancel();
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
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError =
              friendlyError(e, context: 'Could not load vehicle types');
        });
      }
    }
  }

  /// Background GPS resolution for pickup (asks permission on first use;
  /// failures surface inline via the pickup section, not silently).
  Future<void> _resolvePickupLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() => _locStatus = r.status);
    if (r.success) _applyPickupPosition(r.position!);
  }

  /// Applies a GPS fix to the pickup state, clearing any manual override,
  /// re-centers the embedded map and loads nearby places (Task 13: the fix
  /// must visibly move the map, not just relabel the text field).
  void _applyPickupPosition(Position position) {
    setState(() {
      _pickupPos = position;
      _lastFix = position;
      _pickupManual = null; // GPS re-take clears any manual override
    });
    _pickupCtrl.text = 'Current Location';
    _moveCamera(LatLng(position.latitude, position.longitude));
    _loadNearbyPois(position);
    _refreshFare();
  }

  /// Camera move that is safe at any time: applies immediately once the map
  /// is ready, otherwise queues until onMapReady fires (move() on an
  /// unattached controller throws).
  void _moveCamera(LatLng center, {double zoom = 16}) {
    if (_mapReady) {
      _mapController.move(center, zoom);
    } else {
      _pendingCenter = center;
    }
  }

  /// Known/registered places around the GPS fix (best-effort chips).
  Future<void> _loadNearbyPois(Position p) async {
    final pois = await GeocodingService.instance
        .nearbyPlaces(GeoPoint(p.latitude, p.longitude));
    if (!mounted) return;
    setState(() => _nearbyPois = pois);
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

  // ---- Pickup suggestions (GeocodingService, GPS-biased) ----

  void _onPickupFocusChanged() {
    setState(() => _pickupFieldFocused = _pickupFocus.hasFocus);
  }

  /// Debounced autocomplete for the typed pickup, biased to the user's
  /// actual position (Task 13: proximity-ranked results, not generic ones).
  void _onPickupChanged() {
    if (_suppressPickupSearch) return;
    final q = _pickupCtrl.text.trim();
    _pickupDebounce?.cancel();
    if (q.length < 3 || !_pickupFieldFocused) {
      if (mounted && _pickupSuggestions.isNotEmpty) {
        setState(() => _pickupSuggestions = const []);
      }
      return;
    }
    _pickupDebounce = Timer(const Duration(milliseconds: 450), () {
      _searchPickupSuggestions(q);
    });
  }

  Future<void> _searchPickupSuggestions(String query) async {
    final reqId = ++_pickupReqId;
    final results = await GeocodingService.instance
        .searchPlaces(query, biasPoint: _searchBias(), limit: 5);
    if (!mounted || reqId != _pickupReqId) return;
    setState(() => _pickupSuggestions = results);
  }

  void _selectPickupSuggestion(PlaceResult place) {
    setState(() {
      _pickupManual = LatLng(place.lat, place.lng);
      _pickupSuggestions = const [];
      _error = null;
    });
    _pickupFocus.unfocus();
    _suppressPickupSearch = true;
    _pickupCtrl.text = place.label;
    _suppressPickupSearch = false;
    _refreshFare();
  }

  // ---- Destination inline suggestions (GeocodingService, GPS-biased) ----

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
    final results = await GeocodingService.instance
        .searchPlaces(query, biasPoint: _searchBias(), limit: 5);
    if (!mounted || reqId != _destReqId) return;
    setState(() => _destSuggestions = results);
  }

  void _selectDestSuggestion(PlaceResult place) {
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

  /// Search bias: the latest GPS fix when available (proximity ranking);
  /// null lets the service fall back to its city-center bias table.
  GeoPoint? _searchBias() {
    final fix = _lastFix;
    return fix == null ? null : GeoPoint(fix.latitude, fix.longitude);
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
          // Picking a pickup FROM the current position is what the user
          // usually wants, so this screen may start with the pin already
          // dropped. The destination screen may not — see below.
          seedPinFromGps: true,
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
      final rev = await GeocodingService.instance
          .reverseGeocode(picked.latitude, picked.longitude);
      if (!mounted) return;
      if (rev != null && rev.address.isNotEmpty) {
        _pickupCtrl.text = rev.address;
      }
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
      // GPS-biased forward search; the service carries its own platform-
      // geocoder fallback, so no separate locationFromAddress call here.
      final bias = _searchBias();
      final point = bias != null
          ? await GeocodingService.instance.geocodeNear(text, bias)
          : await GeocodingService.instance.geocode(text);
      if (point == null) return false;
      if (!mounted) return true;
      setState(() => _pickupManual = LatLng(point.lat, point.lng));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _formatCoords(LatLng p) =>
      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}';

  /// Straight-line pickup -> destination distance in km, or null until both
  /// ends are known.
  ///
  /// Shown on the form because the fare is opaque: the server prices
  /// base + per_km * distance against a rounded distance and a floor, so a
  /// request priced at the minimum gave the user no way to tell "short trip"
  /// from "the destination was never actually chosen and defaulted to me".
  double? get _tripDistanceKm {
    final p = _pickupPoint;
    final d = _destLatLng;
    if (p == null || d == null) return null;
    return LocationService.instance.calculateDistance(
      p.latitude,
      p.longitude,
      d.latitude,
      d.longitude,
    );
  }

  /// Geocode a typed destination address at submit time. Returns true when
  /// a coordinate was found and stored in [_destLatLng].
  Future<bool> _geocodeTypedDestination() async {
    final text = _destCtrl.text.trim();
    if (text.isEmpty) return false;
    try {
      final bias = _searchBias();
      final point = bias != null
          ? await GeocodingService.instance.geocodeNear(text, bias)
          : await GeocodingService.instance.geocode(text);
      if (point == null) return false;
      if (!mounted) return true;
      setState(() => _destLatLng = LatLng(point.lat, point.lng));
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
      final rev = await GeocodingService.instance
          .reverseGeocode(point.latitude, point.longitude);
      if (!mounted) return;
      final address = rev?.address ?? '';
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
          _error = friendlyError(e, context: 'Could not request this ride');
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
          : _loadError != null
              ? LoadErrorView(message: _loadError!, onRetry: _loadCategories)
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
                  // Task 13 item 1: live pickup map on the ride screen itself.
                  // "Use current location" centers this map on the real GPS
                  // fix; the pin shows the effective pickup point.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: SizedBox(
                      height: 200,
                      width: double.infinity,
                      child: Stack(
                        children: [
                          FlutterMap(
                            mapController: _mapController,
                            options: MapOptions(
                              initialCenter: _initialMapCenter(),
                              initialZoom: 15,
                              onMapReady: () {
                                _mapReady = true;
                                final pending = _pendingCenter;
                                if (pending != null) {
                                  _pendingCenter = null;
                                  _mapController.move(pending, 16);
                                }
                              },
                            ),
                            children: [
                              const ResilientTileLayer(),
                              if (_pickupPoint != null)
                                MarkerLayer(
                                  markers: [
                                    Marker(
                                      point: _pickupPoint!,
                                      width: 36,
                                      height: 36,
                                      alignment: Alignment.topCenter,
                                      child: const Icon(Icons.location_pin,
                                          color: AppTheme.primaryGreen,
                                          size: 36),
                                    ),
                                  ],
                                ),
                              const RichAttributionWidget(
                                attributions: [
                                  TextSourceAttribution(
                                      '© OpenStreetMap contributors'),
                                ],
                              ),
                            ],
                          ),
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: SizedBox(
                              width: 38,
                              height: 38,
                              child: FloatingActionButton(
                                heroTag: 'rideMapRecenter',
                                onPressed: _resolvePickupLocation,
                                backgroundColor: AppTheme.primaryGreen,
                                foregroundColor: Colors.white,
                                child: const Icon(Icons.my_location, size: 20),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Known/registered places near the GPS fix (Task 13).
                  if (_nearbyPois.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _nearbyPois.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) {
                          final poi = _nearbyPois[i];
                          return ActionChip(
                            avatar: const Icon(Icons.place_outlined,
                                size: 16, color: AppTheme.primaryGreen),
                            label: Text(
                              poi.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            visualDensity: VisualDensity.compact,
                            backgroundColor:
                                AppTheme.primaryGreen.withOpacity(0.06),
                            side: BorderSide(
                                color: AppTheme.primaryGreen.withOpacity(0.3)),
                            labelStyle: const TextStyle(
                                fontSize: 12, color: AppTheme.textPrimary),
                            onPressed: () => _selectPickupSuggestion(poi),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text('Pickup Location',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  BirrTextField(
                    label: 'Pickup',
                    controller: _pickupCtrl,
                    focusNode: _pickupFocus,
                    hint: 'Type an address, or use current location',
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton.icon(
                    onPressed: () async {
                      final r =
                          await LocationService.instance
                              .getCurrentPositionDetailed();
                      if (!mounted) return;
                      setState(() => _locStatus = r.status);
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
                  // Pickup inline suggestions (GPS-biased, proximity-ranked).
                  if (_pickupFieldFocused && _pickupSuggestions.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: AppTheme.textMuted.withOpacity(0.25)),
                      ),
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _pickupSuggestions.length,
                        itemBuilder: (context, i) {
                          final place = _pickupSuggestions[i];
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
                            onTap: () => _selectPickupSuggestion(place),
                          );
                        },
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
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Builder(builder: (context) {
                        final km = _tripDistanceKm;
                        // km is null when the pickup is still unknown (no GPS
                        // and nothing typed), so it is computed once here
                        // rather than asserted into the string.
                        final tooClose = km != null && km < 0.15;
                        final message = km == null
                            ? 'Destination set — tap the map icon to change it.'
                            : tooClose
                                ? 'Pickup and destination are at the same spot '
                                    '— tap the map icon to move the pin.'
                                : 'Destination set — ${km.toStringAsFixed(1)} '
                                    'km away. Tap the map icon to change it.';
                        return Text(
                          message,
                          style: TextStyle(
                            fontSize: 12,
                            color: tooClose
                                ? AppTheme.warning
                                : AppTheme.success,
                          ),
                        );
                      }),
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
                      // A destination may be given as a picked pin OR as typed
                      // text: _submit() geocodes the text before it submits,
                      // but the button used to be hard-disabled until a pin
                      // existed, so that branch was unreachable and typing an
                      // address simply did nothing. The one thing still not
                      // allowed is an empty destination.
                      onPressed: (_destLatLng == null &&
                              _destCtrl.text.trim().isEmpty)
                          ? null
                          : _submit,
                    ),
                  ),
                  if (_destLatLng == null && _destCtrl.text.trim().isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Type a destination or pick one on the map to enable '
                        'the request',
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

/// Full-screen OpenStreetMap location picker with address search.
/// Search a place, drag the map, or tap to drop a pin; confirm returns the
/// picked [LatLng]. Shared by pickup and destination picking.
class _MapPickerScreen extends StatefulWidget {
  final LatLng initialCenter;
  final String title;
  final bool initialCenterReliable;

  /// Whether opening this screen may already have the pin on the user.
  ///
  /// True for pickup, false for destination. This is the "it takes default km"
  /// bug: the picker used to drop a pin at the live GPS fix the moment it
  /// opened, for BOTH purposes, so opening "Pick destination" silently set
  /// the destination to where the user already was. Pickup and destination
  /// were then the same point, the server priced the trip at its minimum
  /// (ETB 80 by default, base 50 + 20/km over a rounded 0.00 km), and the
  /// "REQUEST RIDE" button was live — a complete, confident, wrong ride for
  /// the price of a starting fare. Nothing on screen said the destination had
  /// never been chosen by the user.
  final bool seedPinFromGps;
  const _MapPickerScreen(
      {super.key,
      required this.initialCenter,
      this.title = 'Pick Destination',
      this.initialCenterReliable = false,
      this.seedPinFromGps = false});

  @override
  State<_MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<_MapPickerScreen> {
  final _mapController = MapController();
  final _searchCtrl = TextEditingController();
  LatLng? _picked;
  bool _recentering = false;
  List<PlaceResult> _results = const [];
  bool _searching = false;
  int _reqId = 0;
  Timer? _debounce;
  // Latest camera center reported by the map (onPositionChanged) — the
  // search bias. This flutter_map version exposes no center getter.
  late LatLng _cameraCenter = widget.initialCenter;
  // True once FlutterMap has attached to _mapController (onMapReady).
  // move() on an unattached controller throws or silently no-ops, so
  // requests that arrive early are queued in _pendingCenter and applied
  // the moment the map is ready.
  bool _mapReady = false;
  LatLng? _pendingCenter;

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
        _moveToCurrentLocation(
          showError: false,
          dropPin: widget.seedPinFromGps,
        );
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// Camera move that is safe at any time: applies immediately once the
  /// map is ready, otherwise queues until onMapReady fires.
  void _moveCamera(LatLng center, {double zoom = 15}) {
    if (_mapReady) {
      _mapController.move(center, zoom);
    } else {
      _pendingCenter = center;
    }
  }

  /// Instant coarse seed while the fresh fix is still in flight.
  Future<void> _seedFromLastKnown() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted && _centerIsFallback) {
        _moveCamera(LatLng(last.latitude, last.longitude));
      }
    } catch (_) {
      // Best-effort seed only.
    }
  }

  /// Fresh GPS fix: permission is already held in the common case (the
  /// parent screen requested it), so this usually resolves quickly.
  ///
  /// [dropPin] is what keeps the destination honest. Recentring the map on
  /// the user is always helpful; choosing a point FOR them never is, and on
  /// this screen a chosen point is a live, priced, submittable ride request.
  Future<void> _moveToCurrentLocation({
    bool showError = true,
    bool dropPin = false,
  }) async {
    if (_recentering) return;
    setState(() => _recentering = true);
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() => _recentering = false);
    if (r.success) {
      final point = LatLng(r.position!.latitude, r.position!.longitude);
      if (dropPin) setState(() => _picked = point);
      _moveCamera(point);
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

  /// Current visible map center — the search bias (Task 13: results are
  /// ranked around where the user is actually looking, not globally).
  LatLng get _currentCenter =>
      _mapReady ? _cameraCenter : widget.initialCenter;

  Future<void> _runSearch(String query) async {
    final reqId = ++_reqId;
    setState(() => _searching = true);
    final c = _currentCenter;
    final results = await GeocodingService.instance.searchPlaces(
      query,
      biasPoint: GeoPoint(c.latitude, c.longitude),
      limit: 5,
    );
    if (!mounted || reqId != _reqId) return;
    setState(() {
      _searching = false;
      _results = results;
    });
  }

  void _selectPlace(PlaceResult place) {
    final point = LatLng(place.lat, place.lng);
    setState(() {
      _picked = point;
      _results = const [];
    });
    _searchCtrl.text = place.label;
    _moveCamera(point);
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
              onMapReady: () {
                // Controller is now attached; apply any camera move that
                // arrived before the first frame completed.
                _mapReady = true;
                final pending = _pendingCenter;
                if (pending != null) {
                  _pendingCenter = null;
                  _mapController.move(pending, 15);
                }
              },
              onPositionChanged: (_, __) {
                // Track the camera center for search bias; hasGesture-only
                // would miss programmatic moves, so update on every event.
                _cameraCenter = _mapController.camera.center;
              },
              onTap: (_, point) => setState(() => _picked = point),
            ),
            children: [
              // Tile errors fail gracefully (placeholder + retry) instead
              // of crashing the screen — see ResilientTileLayer.
              const ResilientTileLayer(),
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
                      hintText: 'Search a place in Ethiopia',
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
                  )
                else if (!_searching && _searchCtrl.text.trim().length >= 3)
                  // Say WHY it is empty. The underlying fix pinned every
                  // query to Ethiopia, so an unqualified name that exists
                  // abroad now correctly returns nothing — and a bare "no
                  // results" for "Jimma" would look like a broken search bar.
                  Container(
                    margin: const EdgeInsets.only(top: 6),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'No match in Ethiopia. Try adding a town or a kebele.',
                      style: TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
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
          // Manual recenter on the current GPS position. Camera only: it
          // must never overwrite a pin the user has already placed, and it
          // must never place one for them.
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