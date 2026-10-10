import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/auth_provider.dart' show cityProvider;
import '../../core/services/city_service.dart';
import '../../core/services/geocoding_service.dart';
import '../../core/theme/app_theme.dart';

/// Phase 1: city switcher / "travel mode" picker.
///
/// Pick a different city to browse without changing the saved default.
/// "Back to <saved city>" leaves travel mode. Pops `true` when the active
/// city changed so callers can reload their queries.
class CitySwitcherSheet extends ConsumerStatefulWidget {
  const CitySwitcherSheet({super.key});

  @override
  ConsumerState<CitySwitcherSheet> createState() => _CitySwitcherSheetState();
}

class _CitySwitcherSheetState extends ConsumerState<CitySwitcherSheet> {
  String _query = '';
  bool _busy = false;

  // Phase 5: live place suggestions via the geocoding module (Photon with
  // Nominatim fallback), debounced to respect the free-tier rate limits.
  List<PlaceResult> _suggestions = [];
  Timer? _debounce;
  bool _searching = false;

  void _onQueryChanged(String v) {
    setState(() => _query = v);
    _debounce?.cancel();
    if (v.trim().length < 3) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => _searching = true);
      final service = ref.read(cityProvider);
      final active = service.activeCity;
      // "All cities" has no place to bias a search toward, so the saved city
      // stands in — the query is still free text, this only nudges the ranking.
      final bias = active.isNotEmpty ? active : (service.savedCity ?? '');
      final places = await GeocodingService.instance
          .searchPlaces(v.trim(), biasCity: bias, limit: 5);
      if (mounted) {
        setState(() {
          _suggestions = places;
          _searching = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cityService = ref.read(cityProvider);
    final saved = cityService.savedCity;
    final active = cityService.activeCity;
    final all = {...CityService.knownCities, if (saved != null) saved}.toList()
      ..sort();
    final matches = _query.trim().isEmpty
        ? all
        : all
            .where((c) =>
                c.toLowerCase().contains(_query.trim().toLowerCase()) ||
                // Allow selecting a city typed in search that is not in the
                // known list yet (Phase 5 autocomplete will extend this).
                c.toLowerCase() == _query.trim().toLowerCase())
            .toList();
    final showTyped =
        _query.trim().length >= 3 && !all.contains(_query.trim());

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Choose a city', style: AppTheme.sectionHeader),
                ),
                if (cityService.isTravelMode && saved != null)
                  TextButton(
                    onPressed:
                        _busy ? null : () => _apply(cityService, saved, saved),
                    child: const Text('Back to my city'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              saved == null
                  ? 'Browsing the default city'
                  : 'My city: $saved',
              style: AppTheme.caption,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                hintText: 'Search city or place…',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onQueryChanged,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  // Every city together. Placed first because it is the whole
                  // point of the sheet's "browse" promise, and because it is
                  // the one option that is not a city name.
                  ListTile(
                    leading: Icon(
                      cityService.isAllCities
                          ? Icons.check_circle
                          : Icons.public,
                      color: cityService.isAllCities
                          ? AppTheme.primaryGreen
                          : null,
                    ),
                    title: const Text('All cities'),
                    subtitle: const Text('See everything, from every city'),
                    onTap: _busy
                        ? null
                        : () {
                            cityService.setAllCities(true);
                            Navigator.of(context).pop(true);
                          },
                  ),
                  if (_searching)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))),
                    ),
                  if (showTyped && _suggestions.isEmpty && !_searching)
                    ListTile(
                      leading: const Icon(Icons.add_location_alt_outlined),
                      title: Text('Use "${_query.trim()}"'),
                      subtitle: const Text('City not in the list yet'),
                      onTap: _busy
                          ? null
                          : () => _apply(
                              cityService, _query.trim(), saved ?? active),
                    ),
                  if (_suggestions.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text('Places', style: AppTheme.caption),
                    ),
                    ..._suggestions.map((p) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(p.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: p.city.isEmpty ? null : Text(p.city),
                          onTap: _busy
                              ? null
                              : () => _apply(cityService,
                                  p.city.isNotEmpty ? p.city : p.label, saved),
                        )),
                  ],
                  ...matches.map((c) {
                    final isActive = c == active && !showTyped;
                    return ListTile(
                      leading: Icon(
                        isActive
                            ? Icons.check_circle
                            : Icons.location_city_outlined,
                        color: isActive ? AppTheme.primaryGreen : null,
                      ),
                      title: Text(c),
                      subtitle: c == saved ? const Text('My city') : null,
                      onTap:
                          _busy ? null : () => _apply(cityService, c, saved),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _apply(
      CityService cityService, String city, String? saved) async {
    setState(() => _busy = true);
    if (saved != null && city == saved) {
      cityService.setTravelMode(false);
    } else {
      cityService.setTravelCity(city);
    }
    if (mounted) Navigator.of(context).pop(true);
  }
}
