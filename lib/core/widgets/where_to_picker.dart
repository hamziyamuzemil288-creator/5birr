import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/services/geocoding_service.dart';
import '../../core/services/location_service.dart';
import '../theme/app_theme.dart';

/// "Where to?" — the full-screen destination picker.
///
/// WHY A SHEET AND NOT A FIELD
/// ---------------------------
/// A text field forces a rider to know an address well enough to type it. On
/// this platform the answer a rider actually has is a **kebele** or a
/// landmark — "Bole", "Pietros", "the place near the roundabout" — and typing
/// either is slow and error-prone. So the search bar and the nearby-area chips
/// are the same control, and both end in a map tap.
///
/// WHAT IT DOES
/// ------------
///   * a **search bar** over `GeocodingService.searchPlaces`, biased toward the
///     rider's own position so "Bole" ranks the Bole they are in;
///   * a **nearby-areas locator** — kebeles, sub-cities and villages from
///     `nearbyAreas()` (Overpass, keyed on `place=neighbourhood|quarter|
///     hamlet|village|suburb` and `admin_level=9|10`, which is what makes a
///     kebele come back at all), each with its distance, tap to select;
///   * the **GPS animation**: a pulsing halo while a fix is being acquired,
///     which is the same `Ticker`-driven pulse the live map uses for the
///     rider's own dot, so the two read as one thing;
///   * a **live map** that centres on the first suggestion and follows the
///     rider's fix when they grant location.
///
/// BEST-EFFORT BY CONSTRUCTION, and deliberately so: `nearbyAreas` returns an
/// empty list on every failure path, because a rider with no network must
/// still be able to drop a pin and get a priced trip. Nothing here is allowed to
/// block selection — the map is always tappable and the confirm button is
/// always live once a point exists.
///
/// Returns the chosen `PlaceResult`, or null when dismissed.
class WhereToPicker extends StatefulWidget {
  const WhereToPicker({
    super.key,
    this.title = 'Where to?',
    this.initialCenter,
  });

  final String title;

  /// Where the map opens before anything is chosen. Falls back to Addis Ababa
  /// so the map is never blank on a cold start with no fix and no query.
  final GeoPoint? initialCenter;

  /// Opens the picker and returns the chosen place, or null if dismissed.
  static Future<PlaceResult?> open(
    BuildContext context, {
    String title = 'Where to?',
    GeoPoint? initialCenter,
  }) {
    return showModalBottomSheet<PlaceResult>(
      context: context,
      isScrollControlled: true,
      // The picker owns almost the whole screen; the default half-height sheet
      // would clip the map and force the keyboard over the results.
      constraints: const BoxConstraints(maxHeight: 0.94),
      backgroundColor: Colors.transparent,
      builder: (_) => WhereToPicker(
        title: title,
        initialCenter: initialCenter,
      ),
    );
  }

  @override
  State<WhereToPicker> createState() => _WhereToPickerState();
}

class _WhereToPickerState extends State<WhereToPicker>
    with SingleTickerProviderStateMixin {
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _mapController = MapController();

  late final Ticker _pulse;

  List<PlaceResult> _results = const [];
  List<PlaceResult> _areas = const [];
  GeoPoint? _self;
  PlaceResult? _selected;
  bool _locating = true;
  bool _searching = false;
  String _query = '';

  /// Bounded so a slow response for "Bol" cannot overwrite a fast one for
  /// "Bole". The same discard-the-stale-response rule as the fare estimate on
  /// the ride screen.
  int _searchGeneration = 0;
  Timer? _debounce;

  static const _fallbackCenter = LatLng(9.0192, 38.7525); // Addis Ababa

  @override
  void initState() {
    super.initState();
    _pulse = createTicker((_) {
      if (mounted && _locating) setState(() {});
    });
    _pulse.start();
    _locate();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pulse.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _mapController.dispose();
    super.dispose();
  }

  LatLng get _center {
    final s = _self;
    if (s != null) return LatLng(s.lat, s.lng);
    final i = widget.initialCenter;
    if (i != null) return LatLng(i.lat, i.lng);
    return _fallbackCenter;
  }

  /// One fix, then the areas around it. Failure at any point leaves the map
  /// usable and the sheet empty rather than showing an error the rider can do
  /// nothing about.
  Future<void> _locate() async {
    try {
      final r = await LocationService.instance.getCurrentPositionDetailed();
      if (!mounted) return;
      if (!r.success || r.position == null) {
        setState(() => _locating = false);
        return;
      }
      final here = GeoPoint(r.position!.latitude, r.position!.longitude);
      setState(() {
        _self = here;
        _locating = false;
      });
      _mapController.move(LatLng(here.lat, here.lng), 14.5);
      _loadAreas(here);
    } catch (_) {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _loadAreas(GeoPoint at) async {
    try {
      final areas = await GeocodingService.instance.nearbyAreas(at);
      if (!mounted) return;
      setState(() => _areas = areas);
    } catch (_) {
      // Empty is a correct outcome, not an error: Overpass is best-effort.
    }
  }

  void _onQueryChanged(String value) {
    _query = value;
    _debounce?.cancel();
    if (value.trim().length < 3) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    // 320ms: long enough that typing "Bole" is one request rather than four,
    // short enough that the list feels attached to the keyboard.
    _debounce = Timer(const Duration(milliseconds: 320), _runSearch);
  }

  Future<void> _runSearch() async {
    final generation = ++_searchGeneration;
    setState(() => _searching = true);
    try {
      final found = await GeocodingService.instance.searchPlaces(
        _query,
        biasPoint: _self,
        limit: 8,
      );
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = found;
        _searching = false;
      });
      // Frame the first hit, but never yank the map away from a rider who has
      // already tapped something.
      if (found.isNotEmpty && _selected == null) {
        _mapController.move(LatLng(found.first.lat, found.first.lng), 14);
      }
    } catch (_) {
      if (!mounted || generation != _searchGeneration) return;
      setState(() {
        _results = const [];
        _searching = false;
      });
    }
  }

  void _select(PlaceResult place, {bool recenter = true}) {
    setState(() => _selected = place);
    if (recenter) {
      _mapController.move(LatLng(place.lat, place.lng), 15);
    }
    // Drop the keyboard so the results list is visible on a short screen.
    _searchFocus.unfocus();
  }

  void _confirm() {
    final picked = _selected;
    if (picked == null) return;
    Navigator.pop(context, picked);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    // The results sheet is the top of a rounded card that sits OVER the map,
    // which is why the map can be full-bleed behind it.
    return Material(
      color: AppTheme.background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _grabber(),
            _searchBar(),
            _mapArea(),
            SizedBox(height: bottomInset),
            _list(),
          ],
        ),
      ),
    );
  }

  Widget _grabber() {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.cardBorder,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: _onQueryChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Search a place, kebele or landmark',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onQueryChanged('');
                        },
                      ),
                filled: true,
                fillColor: AppTheme.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // A discrete "use my location" button rather than only the map's
          // recenter: on this screen it is the FIRST thing a rider reaches
          // for, and a rider with location off must still be able to proceed.
          _roundAction(
            icon: _locating
                ? null
                : (_self == null ? Icons.location_disabled : Icons.my_location),
            busy: _locating,
            onTap: _locate,
            tooltip: 'Use my location',
          ),
        ],
      ),
    );
  }

  Widget _roundAction({
    required IconData? icon,
    required bool busy,
    required VoidCallback onTap,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: busy ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            // A fixed 48x48 box with a centred child: the same shape whatever
            // is inside it, so the search bar does not resize when the button
            // swaps a spinner for an icon.
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primaryGreen),
                  )
                : Icon(icon, size: 20, color: AppTheme.primaryGreenDark),
          ),
        ),
      ),
    );
  }

  /// The map, with the rider's own position drawn as a pulsing halo while a
  /// fix is being acquired.
  Widget _mapArea() {
    return SizedBox(
      height: 210,
      child: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 13.5,
              onTap: (_, point) => _select(
                PlaceResult(
                  label: '${point.latitude.toStringAsFixed(5)}, '
                      '${point.longitude.toStringAsFixed(5)}',
                  city: '',
                  lat: point.latitude,
                  lng: point.longitude,
                ),
              ),
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'app.aliob.birr5',
              ),
              if (_self != null)
                CircleLayer(circles: [
                  CircleMarker(
                    point: LatLng(_self!.lat, _self!.lng),
                    // A fixed halo, not an accuracy circle: `LocationResult`
                    // carries no accuracy, and inventing a radius that does not
                    // match the fix would be a lie drawn on a map.
                    radius: 60,
                    useRadiusInMeter: true,
                    color: AppTheme.primaryGreen.withOpacity(0.12),
                    borderColor: AppTheme.primaryGreen.withOpacity(0.30),
                    borderStrokeWidth: 1,
                  ),
                ]),
              MarkerLayer(markers: [
                if (_self != null)
                  Marker(
                    point: LatLng(_self!.lat, _self!.lng),
                    width: 58,
                    height: 58,
                    child: _GpsPulse(animate: _locating),
                  ),
                if (_selected != null)
                  Marker(
                    point: LatLng(_selected!.lat, _selected!.lng),
                    width: 46,
                    height: 46,
                    child: const Icon(Icons.place, color: AppTheme.error, size: 44),
                  ),
              ]),
            ],
          ),
          if (_locating) const _locatingBanner(),
        ],
      ),
    );
  }

  /// The results and the nearby-area locator, in one scrollable column.
  Widget _list() {
    // Nothing to show is a normal state, not an error: a rider with no network
    // still has the map.
    if (_results.isEmpty && _areas.isEmpty && !_searching) {
      return _footer(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Text(
            _locating
                ? 'Finding where you are…'
                : 'Search above, or tap the map to drop a pin.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
          ),
        ),
      );
    }

    final rows = <Widget>[];

    if (_results.isNotEmpty) {
      rows.add(_sectionLabel('Results'));
      for (final r in _results) rows.add(_placeTile(r));
    } else if (_searching) {
      rows.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppTheme.primaryGreen),
          ),
        ),
      ));
    }

    if (_areas.isNotEmpty) {
      rows.add(_sectionLabel('Nearby areas'));
      for (final a in _areas) rows.add(_placeTile(a, showDistance: true));
    }

    return Flexible(
      child: ConstrainedBox(
        // Bounded so the map never disappears on a tall list, and so the sheet
        // cannot exceed the 0.94 the caller allowed.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.34,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 8),
          children: rows,
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppTheme.textMuted,
        ),
      ),
    );
  }

  Widget _placeTile(PlaceResult place, {bool showDistance = false}) {
    final selected = _selected?.lat == place.lat && _selected?.lng == place.lng;
    final isArea = place.kind == PlaceKind.area;
    final metres = place.distanceMeters;

    return ListTile(
      dense: true,
      onTap: () => _select(place),
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: (selected ? AppTheme.primaryGreen : AppTheme.teal)
              .withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          isArea ? Icons.grid_view_outlined : Icons.place_outlined,
          size: 18,
          color: selected ? AppTheme.primaryGreen : AppTheme.textSecondary,
        ),
      ),
      // An area name is long ("Kirkos South III, Bole Sub-City, Addis
      // Ababa"), a landmark is longer, and both are unbounded in the source.
      //
      // `maxLines` here is not an overflow guard: a ListTile bounds its own
      // height and CLIPS a second line rather than growing, which
      // test/where_to_picker_overflow_test.dart measured -- the row is 64dp
      // whether the label is "Bole" or forty words long. So what the cap buys
      // is that the overflow is an ELLIPSIS the user can see, instead of a
      // name chopped at an arbitrary pixel with nothing to show it was cut.
      // `dense` is the other half: it is what makes the row 64dp instead of
      // 72dp, and therefore what fits more results above the confirm button.
      // Both are asserted in that test.
      title: Text(place.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
      subtitle: Text(
        [
          if (place.city.isNotEmpty) place.city,
          if (showDistance && metres != null)
            '${(metres / 1000).toStringAsFixed(1)} km away',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
      ),
      trailing: selected
          ? const Icon(Icons.check_circle, size: 20, color: AppTheme.primaryGreen)
          : null,
    );
  }

  Widget _footer({required Widget child}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        _confirmButton(),
      ],
    );
  }

  Widget _confirmButton() {
    final picked = _selected;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          // Disabled, never hidden: a rider who cannot see why the button is
          // greyed out will tap it and conclude the app is broken.
          onPressed: picked == null ? null : _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primaryGreen,
            disabledBackgroundColor: AppTheme.cardBorder,
            padding: const EdgeInsets.symmetric(vertical: 15),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(
            picked == null
                ? 'Pick a place to continue'
                : 'Go to ${picked.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 14.5, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// The pulsing halo drawn under the rider's own dot while a fix is acquired.
///
/// Rebuilds from the parent's ticker rather than owning one, so the sheet has
/// exactly one animation driving it and disposing this cannot leave a ticker
/// running behind a dismissed sheet.
class _GpsPulse extends StatelessWidget {
  const _GpsPulse({required this.animate});
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final t = Curves.easeOut.transform(
      (DateTime.now().millisecondsSinceEpoch % 1600) / 1600.0,
    );
    return Center(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: animate ? 20 + 26 * t : 18,
        height: animate ? 20 + 26 * t : 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.primaryGreen.withOpacity(animate ? 0.30 * (1 - t) : 0.18),
          border: Border.all(
            color: AppTheme.primaryGreen.withOpacity(animate ? 0.55 * (1 - t) : 0.5),
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

/// "Finding you…" over the map, so the animation is explained rather than
/// being decoration the rider has to interpret.
class _locatingBanner extends StatelessWidget {
  const _locatingBanner();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 10,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: AppTheme.textPrimary.withOpacity(0.86),
          borderRadius: BorderRadius.circular(20),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
                SizedBox(width: 8),
                Text('Finding you…',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
