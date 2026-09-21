import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:geocoding/geocoding.dart' as platform;

import 'location_service.dart' show GeoPoint;

/// Phase 5: geocoding / places service (isolated module).
///
/// Free-tier evaluation (no API keys, no paid services):
///   - Photon (photon.komoot.io): free OSM autocomplete, no key, built for
///     search-as-you-type. PRIMARY for forward search / city autocomplete.
///   - Nominatim public instance: free, 1 req/s, global coverage. Used for
///     reverse geocoding and forward fallback, throttled by [minInterval].
///   - Platform geocoder (geocoding package): last-resort fallback when the
///     network services fail, so a booking never blocks.
///
/// Rate limiting: shared stopwatch enforces >= 1.1s between external HTTP
/// calls. Failures surface as empty results, never exceptions — callers
/// keep working (old GPS-only behavior) when geocoding is unavailable.
class GeocodingService {
  GeocodingService._();
  static final instance = GeocodingService._();

  static const _photonUrl = 'https://photon.komoot.io/api';
  static const _nominatimUrl = 'https://nominatim.openstreetmap.org';
  static const _minInterval = Duration(milliseconds: 1100);
  static const _httpTimeout = Duration(seconds: 8);

  /// Simple in-memory cache (address -> coords, coords -> address). Keeps
  /// repeat lookups free and blips invisible; capped to stay tiny.
  final Map<String, dynamic> _cache = {};
  static const _cacheMax = 64;

  DateTime _lastCall = DateTime.now().subtract(const Duration(days: 1));

  Future<void> _throttle() async {
    final wait = _minInterval - DateTime.now().difference(_lastCall);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastCall = DateTime.now();
  }

  /// GET [uri] and decode the JSON body. Throws on any failure.
  Future<dynamic> _getJson(Uri uri) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(uri).timeout(_httpTimeout);
      request.headers.set(HttpHeaders.userAgentHeader, 'aliob-app/1.0');
      final response = await request.close().timeout(_httpTimeout);
      if (response.statusCode != 200) {
        throw HttpException('status ${response.statusCode}');
      }
      final body =
          await response.transform(utf8.decoder).join().timeout(_httpTimeout);
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }

  void _cachePut(String key, dynamic value) {
    if (_cache.length >= _cacheMax) _cache.remove(_cache.keys.first);
    _cache[key] = value;
  }

  // ------------------------------------------------------------------
  // Place / city search + autocomplete (Photon; Nominatim fallback)
  // ------------------------------------------------------------------

  Future<List<PlaceResult>> searchPlaces(
    String query, {
    String? biasCity,
    int limit = 6,
  }) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final cacheKey = 'search:$q:${biasCity ?? ''}';
    final cached = _cache[cacheKey];
    if (cached is List<PlaceResult>) return cached;

    // Photon: lat/lon bias toward the active city center when known.
    final bias = biasCity != null ? _cityBias[biasCity] : null;
    final params = {
      'q': q,
      'limit': '$limit',
      'lang': 'en',
      if (bias != null) ...{
        'lat': '${bias.$1}',
        'lon': '${bias.$2}',
      },
    };
    try {
      await _throttle();
      final uri = Uri.parse('$_photonUrl').replace(queryParameters: params);
      final data = await _getJson(uri) as Map<String, dynamic>;
      final features = (data['features'] as List? ?? []);
      final results = features
          .map((f) => PlaceResult.fromPhoton(f as Map<String, dynamic>))
          .toList();
      _cachePut(cacheKey, results);
      return results;
    } catch (_) {
      // Nominatim fallback (same free OSM data, different index).
      try {
        await _throttle();
        final uri = Uri.parse('$_nominatimUrl/search').replace(queryParameters: {
          'q': q,
          'format': 'json',
          'limit': '$limit',
          'countrycodes': 'et',
          if (bias != null) 'viewbox': _ethiopiaViewbox,
        });
        final list = await _getJson(uri) as List<dynamic>;
        final results = list
            .map((e) => PlaceResult.fromNominatim(e as Map<String, dynamic>))
            .toList();
        _cachePut(cacheKey, results);
        return results;
      } catch (_) {
        return const [];
      }
    }
  }

  // ------------------------------------------------------------------
  // Forward geocode: address -> coordinates (for provider/listing maps)
  // ------------------------------------------------------------------

  Future<GeoPoint?> geocode(String address, {String? city}) async {
    final full = city == null ? address : '$address, $city, Ethiopia';
    final cacheKey = 'fwd:$full';
    final cached = _cache[cacheKey];
    if (cached is GeoPoint) return cached;

    // 1. Photon (free, no key).
    final places = await searchPlaces(full, limit: 1);
    if (places.isNotEmpty) {
      _cachePut(cacheKey, places.first.point);
      return places.first.point;
    }
    // 2. Platform geocoder as last resort.
    try {
      final found = await platform.locationFromAddress(full)
          .timeout(_httpTimeout);
      if (found.isNotEmpty) {
        final p = found.first;
        final point = GeoPoint(p.latitude, p.longitude);
        _cachePut(cacheKey, point);
        return point;
      }
    } catch (_) {}
    return null;
  }

  // ------------------------------------------------------------------
  // Reverse geocode: GPS -> address + city (rides/delivery)
  // ------------------------------------------------------------------

  Future<ReverseGeocode?> reverseGeocode(double lat, double lng) async {
    final cacheKey = 'rev:$lat,$lng';
    final cached = _cache[cacheKey];
    if (cached is ReverseGeocode) return cached;

    try {
      await _throttle();
      final uri = Uri.parse('$_nominatimUrl/reverse').replace(queryParameters: {
        'lat': '$lat',
        'lon': '$lng',
        'format': 'json',
        'zoom': '17',
        'addressdetails': '1',
      });
      final data = await _getJson(uri) as Map<String, dynamic>;
      final addr = (data['address'] as Map<String, dynamic>?) ?? {};
      final result = ReverseGeocode(
        address: (data['display_name'] as String?) ?? '',
        city: (addr['city'] ?? addr['town'] ?? addr['village'] ??
                addr['state'] ?? '')
            .toString(),
      );
      _cachePut(cacheKey, result);
      return result;
    } catch (_) {
      // Platform fallback; null is acceptable (callers keep GPS coords).
      try {
        final marks = await platform
            .placemarkFromCoordinates(lat, lng)
            .timeout(_httpTimeout);
        if (marks.isNotEmpty) {
          final m = marks.first;
          final result = ReverseGeocode(
            address: [m.thoroughfare, m.subLocality, m.locality]
                .whereType<String>()
                .where((s) => s.isNotEmpty)
                .join(', '),
            city: m.locality ?? m.administrativeArea ?? '',
          );
          _cachePut(cacheKey, result);
          return result;
        }
      } catch (_) {}
      return null;
    }
  }

  static const _ethiopiaViewbox = '32.9,15.0,48.0,3.4';

  /// Approximate city centers for search bias (sufficient for relevance).
  static const Map<String, (double, double)> _cityBias = {
    'Addis Ababa': (9.005, 38.763),
    'Adama': (8.542, 39.267),
    'Bahir Dar': (11.594, 37.391),
    'Gondar': (12.609, 37.466),
    'Hawassa': (7.062, 38.476),
    'Jimma': (7.675, 36.834),
    'Mekelle': (13.497, 39.475),
    'Dire Dawa': (9.593, 41.866),
    'Dessie': (11.133, 39.633),
    'Arba Minch': (6.033, 37.553),
    'Bishoftu': (8.752, 38.985),
    'Nekemte': (9.088, 36.552),
  };
}

/// A searchable place (city, street, landmark).
class PlaceResult {
  const PlaceResult({
    required this.label,
    required this.city,
    required this.lat,
    required this.lng,
  });

  final String label;
  final String city;
  final double lat;
  final double lng;

  GeoPoint get point => GeoPoint(lat, lng);

  factory PlaceResult.fromPhoton(Map<String, dynamic> feature) {
    final props = (feature['properties'] as Map<String, dynamic>?) ?? {};
    final geom = (feature['geometry'] as Map<String, dynamic>?) ?? {};
    final coords = (geom['coordinates'] as List? ?? const []);
    final label = [
      props['name'],
      props['street'],
      props['district'],
      props['city'],
      props['state'],
    ].whereType<String>().where((s) => s.isNotEmpty).toSet().join(', ');
    return PlaceResult(
      label: label.isEmpty ? (props['osm_id']?.toString() ?? 'Place') : label,
      city: (props['city'] ?? props['state'] ?? '').toString(),
      lat: coords.length > 1 ? (coords[1] as num).toDouble() : 0,
      lng: coords.isNotEmpty ? (coords[0] as num).toDouble() : 0,
    );
  }

  factory PlaceResult.fromNominatim(Map<String, dynamic> e) {
    return PlaceResult(
      label: (e['display_name'] as String?) ?? 'Place',
      city: ((e['address'] as Map<String, dynamic>?)?['city'] ?? '').toString(),
      lat: double.tryParse((e['lat'] ?? '').toString()) ?? 0,
      lng: double.tryParse((e['lon'] ?? '').toString()) ?? 0,
    );
  }
}

/// GPS -> address + city.
class ReverseGeocode {
  const ReverseGeocode({required this.address, required this.city});

  final String address;
  final String city;
}
