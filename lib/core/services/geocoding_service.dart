import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:geocoding/geocoding.dart' as platform;

import 'location_service.dart' show GeoPoint;
import '../utils/ethiopia_cities.dart' as cities;

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
///
/// COUNTRY SCOPE
/// -------------
/// Every query is pinned to Ethiopia and every response is filtered to
/// Ethiopia, because this is an Ethiopian marketplace and the reported symptom
/// was a global index answering local questions: typing "Jimma" returned Jimma
/// in other countries, so the nearest-match ranking put a foreign city ahead of
/// the one the user was standing in.
///
/// Photon's lat/lon parameters are a SOFT ranking hint, not a filter — a soft
/// hint is not enough, which is why the `bbox` below and the client-side
/// [PlaceResult.isInEthiopia] check both exist. Nominatim's `countrycodes=et`
/// was already a hard filter, but it only ran on the FALLBACK path, so the bug
/// lived in the primary one.
class GeocodingService {
  GeocodingService._();
  static final instance = GeocodingService._();

  static const _photonUrl = 'https://photon.komoot.io/api';
  static const _nominatimUrl = 'https://nominatim.openstreetmap.org';
  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';
  static const _minInterval = Duration(milliseconds: 1100);
  static const _httpTimeout = Duration(seconds: 8);

  /// Ethiopia, generously padded so border towns and lakeside kebeles are not
  /// clipped away. Photon wants minLon,minLat,maxLon,maxLat; Nominatim's
  /// `viewbox` wants minLon,MAXLat,maxLon,minLat (top before bottom). They are
  /// NOT the same string, so they are two constants rather than one reused.
  static const _ethiopiaBbox = '32.9,3.3,48.0,15.0';
  static const _ethiopiaViewbox = '32.9,15.0,48.0,3.3';

  static const _ethMinLat = 3.3;
  static const _ethMaxLat = 15.0;
  static const _ethMinLng = 32.9;
  static const _ethMaxLng = 48.0;

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
    GeoPoint? biasPoint,
    int limit = 6,
  }) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final cacheKey = 'search:$q:${biasCity ?? ''}:${biasPoint ?? ''}';
    final cached = _cache[cacheKey];
    if (cached is List<PlaceResult>) return cached;

    // Task 13: prefer the user's live GPS position for bias (proximity-
    // ranked results), falling back to the active city center when the fix
    // is unavailable. Photon's lat/lon params are soft ranking, so results
    // still match the typed text first and nearby ones rank higher.
    final (double, double)? bias = biasPoint != null
        ? (biasPoint.lat, biasPoint.lng)
        : (biasCity != null ? _cityBias[biasCity] : null);
    // Over-fetch from the remote service, then keep only Ethiopian hits. The
    // bbox is a hard server-side filter; asking for exactly `limit` and then
    // discarding the foreign ones is how a search for an Ethiopian place came
    // back with nothing at all.
    final fetch = limit * 3;
    final params = {
      'q': q,
      'limit': '$fetch',
      'lang': 'en',
      'bbox': _ethiopiaBbox,
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
          .where((p) => p.isInEthiopia)
          .take(limit)
          .toList();
      if (results.isNotEmpty) {
        _cachePut(cacheKey, results);
        return results;
      }
      // Photon answered, but nothing survived the country filter. Falling
      // through to the second index is the safe reading: either Photon ignored
      // the bbox we sent, or this really has no Ethiopian match, and the
      // second index settles which. Returning the empty list here instead
      // would have turned "the bbox parameter was not honoured" into a search
      // bar that silently finds nothing.
    } catch (_) {
      // Network/HTTP failure — fall through to the other index.
    }

    // Nominatim fallback (same free OSM data, different index).
    try {
      await _throttle();
      final uri = Uri.parse('$_nominatimUrl/search').replace(queryParameters: {
        'q': q,
        'format': 'json',
        'limit': '$limit',
        'addressdetails': '1',
        'countrycodes': 'et',
        'viewbox': _ethiopiaViewbox,
        // viewbox only ranks; bounded makes it a filter. Without it
        // Nominatim is free to return an equally-named place in Kenya.
        'bounded': '1',
      });
      final list = await _getJson(uri) as List<dynamic>;
      final results = list
          .map((e) => PlaceResult.fromNominatim(e as Map<String, dynamic>))
          .where((p) => p.isInEthiopia)
          .take(limit)
          .toList();
      _cachePut(cacheKey, results);
      return results;
    } catch (_) {
      return const [];
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

    // 1. Photon (free, no key), Ethiopia-scoped by searchPlaces.
    final places = await searchPlaces(full, limit: 1);
    if (places.isNotEmpty) {
      _cachePut(cacheKey, places.first.point);
      return places.first.point;
    }
    // 2. Platform geocoder as last resort. It is a GLOBAL index with no
    //    country filter of its own, so its answer is checked too: an
    //    unqualified "Jimma" resolves to a street in another country, and a
    //    ride request pinned there is silently, expensively wrong.
    try {
      final found = await platform.locationFromAddress(full)
          .timeout(_httpTimeout);
      for (final p in found) {
        if (!isInEthiopia(p.latitude, p.longitude)) continue;
        final point = GeoPoint(p.latitude, p.longitude);
        _cachePut(cacheKey, point);
        return point;
      }
    } catch (_) {}
    return null;
  }

  /// Forward geocode a TYPED pickup/destination with the user's GPS position
  /// as bias (Task 13: proximity-ranked forward search for the ride screen).
  /// Same fallbacks as [geocode]; null on no match.
  Future<GeoPoint?> geocodeNear(String address, GeoPoint near) async {
    final q = address.trim();
    if (q.isEmpty) return null;
    final cacheKey = 'fwdn:$q:${near.lat},${near.lng}';
    final cached = _cache[cacheKey];
    if (cached is GeoPoint) return cached;

    final places = await searchPlaces(q, biasPoint: near, limit: 1);
    if (places.isNotEmpty) {
      _cachePut(cacheKey, places.first.point);
      return places.first.point;
    }
    // Platform geocoder as last resort (platform geocoders are already
    // network-proximate, so no explicit bias is possible) — country-checked
    // for the same reason as in geocode().
    try {
      final found = await platform.locationFromAddress(q).timeout(_httpTimeout);
      for (final p in found) {
        if (!isInEthiopia(p.latitude, p.longitude)) continue;
        final point = GeoPoint(p.latitude, p.longitude);
        _cachePut(cacheKey, point);
        return point;
      }
    } catch (_) {}
    return null;
  }

  /// Is this coordinate inside the Ethiopia search box? Padding matches
  /// [_ethiopiaBbox]; a place just over the line in an adjacent country is not
  /// a place a rider in this app can be sent to.
  static bool isInEthiopia(double lat, double lng) =>
      lat >= _ethMinLat &&
      lat <= _ethMaxLat &&
      lng >= _ethMinLng &&
      lng <= _ethMaxLng;

  /// Nearby known/registered places (POIs) around a live GPS point — the
  /// chips shown after "Current Location" centers the map (Task 13).
  ///
  /// Uses Photon's /reverse around a radius; verified live that /reverse
  /// accepts lat/lon/radius/limit (zoom is REJECTED — an earlier version
  /// sent zoom and got an error body with zero features, the reported
  /// "Photon: 0 results" class of bug). distance_sort keeps the closest
  /// POIs first. Returns [] on any failure — chips are best-effort.
  Future<List<PlaceResult>> nearbyPlaces(GeoPoint at, {int limit = 8}) async {
    final cacheKey = 'near:${at.lat.toStringAsFixed(4)},${at.lng.toStringAsFixed(4)}';
    final cached = _cache[cacheKey];
    if (cached is List<PlaceResult>) return cached;

    try {
      await _throttle();
      final uri = Uri.parse('$_photonUrl/reverse').replace(queryParameters: {
        'lat': '${at.lat}',
        'lon': '${at.lng}',
        'radius': '2', // km — walkable/driverable neighborhood
        'limit': '$limit',
        'distance_sort': 'true',
        'lang': 'en',
      });
      final data = await _getJson(uri) as Map<String, dynamic>;
      final features = (data['features'] as List? ?? []);
      final results = features
          .map((f) => PlaceResult.fromPhoton(f as Map<String, dynamic>))
          .where((p) => p.label.isNotEmpty && p.label != 'Place')
          .where((p) => p.isInEthiopia)
          .take(limit)
          .toList();
      _cachePut(cacheKey, results);
      return results;
    } catch (_) {
      // Nominatim fallback (same free OSM data). Search for nothing — a
      // generic query would return unrelated places — so just degrade.
      return const [];
    }
  }

  // ------------------------------------------------------------------
  // Nearby SMALL AREAS (kebele / sub-city / village) around a GPS point
  // ------------------------------------------------------------------

  /// Small named places near [at] -- kebele, sub-city, neighbourhood,
  /// village, township -- the ones a person actually uses to tell a driver
  /// where they are.
  ///
  /// ## Why this is a different service from [nearbyPlaces]
  ///
  /// [nearbyPlaces] uses Photon `/reverse`, and Photon indexes only
  /// place-level features: it returns the city and large institutions
  /// (a hospital, a university, a stadium). That is precisely the reported
  /// symptom -- "it brings the nearest city and big institution but still
  /// not the nearest areas / small locations". Asking Photon harder does not
  /// help; the small areas are simply not in its index.
  ///
  /// Overpass is the same OpenStreetMap data queried structurally instead of
  /// by name, so `place=neighbourhood|quarter|hamlet|village|suburb` and
  /// `admin_level=9|10` (the admin levels that correspond to a kebele) DO
  /// come back. Free, no key.
  ///
  /// Best-effort by construction: every failure path returns an empty list,
  /// because this only feeds suggestion chips and a label. A rider with no
  /// network still gets a priced ride from raw coordinates.
  Future<List<PlaceResult>> nearbyAreas(
    GeoPoint at, {
    int radiusMeters = 4000,
    int limit = 10,
  }) async {
    final cacheKey = 'area:${at.lat.toStringAsFixed(4)},'
        '${at.lng.toStringAsFixed(4)}:$radiusMeters';
    final cached = _cache[cacheKey];
    if (cached is List<PlaceResult>) return cached;

    // `out center` gives every node/way/relation a usable coordinate. The
    // regex covers exactly the `place` values that mean "a small area" in
    // OSM's taxonomy, plus the admin levels that are a kebele.
    final query = [
      '[out:json][timeout:20];',
      '(',
      // `\$` and not `$`: the regex end-anchor has to reach Overpass as a
      // literal dollar. An unescaped `$` followed by `"` is an interpolation
      // with no identifier, which is a compile error, not a string.
      'node["place"~"^(neighbourhood|quarter|hamlet|village|suburb|'
          'borough|locality|town)\$"](around:$radiusMeters,'
          '${at.lat},${at.lng});',
      'way["place"~"^(neighbourhood|quarter|hamlet|village|suburb|'
          'borough|locality|town)\$"](around:$radiusMeters,'
          '${at.lat},${at.lng});',
      'relation["place"~"^(neighbourhood|quarter|hamlet|village|suburb|'
          'borough|locality|town)\$"](around:$radiusMeters,'
          '${at.lat},${at.lng});',
      'way["admin_level"~"^(9|10)\$"](around:$radiusMeters,'
          '${at.lat},${at.lng});',
      'relation["admin_level"~"^(9|10)\$"](around:$radiusMeters,'
          '${at.lat},${at.lng});',
      ');',
      'out center $limit;',
    ].join(' ');

    try {
      await _throttle();
      final client = HttpClient();
      late final dynamic data;
      try {
        // Overpass reads the query from the REQUEST BODY on POST. A GET would
        // need it percent-encoded into a URL, and this query is far too long
        // for one to survive.
        final request =
            await client.postUrl(Uri.parse(_overpassUrl))
                .timeout(_httpTimeout);
        request.headers.set(HttpHeaders.userAgentHeader, 'aliob-app/1.0');
        request.write(query);
        final response = await request.close().timeout(_httpTimeout);
        if (response.statusCode != 200) {
          throw HttpException('overpass status ${response.statusCode}');
        }
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(_httpTimeout + const Duration(seconds: 10));
        data = jsonDecode(body);
      } finally {
        client.close(force: true);
      }

      final elements = (data['elements'] as List? ?? const []);
      final seen = <String>{};
      final results = <PlaceResult>[];
      for (final raw in elements) {
        if (raw is! Map) continue;
        final tags = (raw['tags'] as Map?) ?? const {};
        final name = (tags['name'] ?? tags['name:en'])?.toString() ?? '';
        if (name.isEmpty) continue;
        // One kebele frequently appears as both a node and a relation under
        // the same name; showing it twice makes the chip row look broken.
        if (!seen.add(name.toLowerCase())) continue;

        final lat = _coordOf(raw, 'lat');
        final lng = _coordOf(raw, 'lon');
        if (lat == null || lng == null) continue;
        if (!isInEthiopia(lat, lng)) continue;

        results.add(
          PlaceResult(
            label: name,
            city: (tags['is_in'] ?? '').toString(),
            lat: lat,
            lng: lng,
            countryCode: 'et',
            kind: PlaceKind.area,
            distanceMeters: _haversineMeters(at.lat, at.lng, lat, lng),
          ),
        );
      }

      // Nearest first: the point of the feature is the CLOSEST area, and
      // Overpass returns rows in its own arbitrary order.
      results.sort((a, b) =>
          (a.distanceMeters ?? 1e9).compareTo(b.distanceMeters ?? 1e9));
      final trimmed = results.take(limit).toList();
      _cachePut(cacheKey, trimmed);
      return trimmed;
    } catch (_) {
      return const [];
    }
  }

  /// Latitude of an Overpass element: nodes carry `lat`/`lon`, ways and
  /// relations carry a `center` object instead. Returns null when neither is
  /// present, so an element with no geometry is skipped rather than plotted
  /// at (0, 0) in the Gulf of Guinea.
  static double? _coordOf(Map raw, String key) {
    final direct = raw[key];
    if (direct is num) return direct.toDouble();
    final center = raw['center'];
    if (center is Map && center[key] is num) {
      return (center[key] as num).toDouble();
    }
    return null;
  }

  /// Great-circle distance in metres, computed locally rather than through
  /// `Geolocator.distanceBetween` so this service keeps no dependency on the
  /// platform location plugin.
  static double _haversineMeters(
      double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(a)));
  }

  static double _rad(double degrees) => degrees * math.pi / 180.0;

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
        // Without this, `namedetails` is absent and the specific place name
        // is unavailable. It costs nothing on the response and is the only
        // way to name a landmark the point is actually inside.
        'namedetails': '1',
      });
      final data = await _getJson(uri) as Map<String, dynamic>;
      final addr = (data['address'] as Map<String, dynamic>?) ?? {};
      final named =
          (data['namedetails'] as Map<String, dynamic>?) ?? const {};

      final city = _firstString(addr, ['city', 'town', 'village', 'state']);

      // Most-specific-first. OSM's own hierarchy, and the order matters: a
      // kebele's `suburb` is the answer the rider wants, `city` is not, and
      // the city is already reported separately as `city`.
      //
      // `town` and `village` are last because when the point really is in a
      // town they ARE the area -- but they are also what Nominatim uses for
      // the city in most of Ethiopia, so trying them first would fill `area`
      // with the city name on every row. `_dedupe` drops the repeat.
      final area = _dedupe(
        _firstString(addr, [
          'suburb',
          'neighbourhood',
          'city_district',
          'quarter',
          'residential',
          'hamlet',
          'borough',
          'township',
          'village',
          'town',
        ]),
        city,
      );

      final result = ReverseGeocode(
        address: (data['display_name'] as String?) ?? '',
        city: city,
        area: area,
        district: _firstString(addr, ['county', 'state_district', 'region']),
        road: _firstString(addr, ['road', 'pedestrian', 'footway']),
        placeName: (named['name'] ?? '').toString(),
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
            // The platform geocoder DOES carry a sub-locality -- the same
            // kebele-level unit -- and it was being dropped here too. It is
            // the one source that works with no network to Nominatim.
            area: (m.subLocality ?? '').trim(),
            road: (m.thoroughfare ?? '').trim(),
          );
          _cachePut(cacheKey, result);
          return result;
        }
      } catch (_) {}
      return null;
    }
  }

  /// First non-empty string among [keys] in [map], or ''.
  static String _firstString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /// [value] unless it is the same as [other] or empty -- so `area` never
  /// repeats the city back at the user as if it were new information.
  static String _dedupe(String value, String other) {
    if (value.isEmpty) return '';
    if (other.isEmpty) return value;
    return value.toLowerCase() == other.toLowerCase() ? '' : value;
  }

  /// Approximate city centers for search bias (sufficient for relevance).
  ///
  /// Reads the shared city list rather than keeping its own copy. When this
  /// file had its own map, a city added to the picker but not here was
  /// selectable but unfindable by search, with nothing to catch the drift.
  // Not `const`: a const map literal cannot contain a `for` element, and
  // building it from the shared list is the entire point of this change.
  static final Map<String, (double, double)> _cityBias = {
    for (final c in cities.cities)
      if (cities.cityCenter(c) case final center?) c: center,
  };
}

/// What kind of thing a [PlaceResult] names. Used to group and label the
/// chips under the ride map, so a kebele never reads like a hospital.
enum PlaceKind { place, area }

/// A searchable place (city, street, landmark, small area).
class PlaceResult {
  const PlaceResult({
    required this.label,
    required this.city,
    required this.lat,
    required this.lng,
    this.countryCode,
    this.kind = PlaceKind.place,
    this.distanceMeters,
  });

  final String label;
  final String city;
  final double lat;
  final double lng;

  /// [PlaceKind.area] for a kebele / sub-city / village from
  /// [GeocodingService.nearbyAreas]; [PlaceKind.place] for a POI or a city.
  final PlaceKind kind;

  /// Straight-line distance from the query point, set only by
  /// [GeocodingService.nearbyAreas]. Null elsewhere rather than 0, so "not
  /// measured" never renders as "right here".
  final double? distanceMeters;

  /// ISO-3166 alpha-2 code when the provider supplies one. Photon does,
  /// Nominatim only with `addressdetails=1`. Null means "unknown" — never
  /// "not Ethiopia": the coordinate check is what decides, so a provider that
  /// omits the field cannot smuggle a foreign result back in.
  final String? countryCode;

  GeoPoint get point => GeoPoint(lat, lng);

  bool get isInEthiopia =>
      (countryCode?.toLowerCase() == 'et' || countryCode == null) &&
      GeocodingService.isInEthiopia(lat, lng);

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
      countryCode: props['countrycode']?.toString(),
    );
  }

  factory PlaceResult.fromNominatim(Map<String, dynamic> e) {
    final address = (e['address'] as Map<String, dynamic>?) ?? const {};
    return PlaceResult(
      label: (e['display_name'] as String?) ?? 'Place',
      city: (address['city'] ?? address['town'] ?? address['village'] ?? '')
          .toString(),
      lat: double.tryParse((e['lat'] ?? '').toString()) ?? 0,
      lng: double.tryParse((e['lon'] ?? '').toString()) ?? 0,
      countryCode: (e['country_code'] ?? address['country_code'])?.toString(),
    );
  }
}

/// GPS -> address, city, and the SMALL area the point sits in.
///
/// [area] is the field that was missing. Nominatim returns `suburb`,
/// `neighbourhood`, `city_district`, `quarter` and `hamlet` in its address
/// map -- for Addis Ababa these carry the kebele names -- but the service
/// used to read only `city ?? town ?? village ?? state` and discard the
/// rest. That is why the app could name the city and a big institution and
/// nothing smaller: the small areas arrived over the wire and were thrown
/// away before anyone could see them.
class ReverseGeocode {
  const ReverseGeocode({
    required this.address,
    required this.city,
    this.area = '',
    this.district = '',
    this.road = '',
    this.placeName = '',
  });

  /// The full `display_name` from the provider -- unchanged, and still what
  /// every existing caller shows as the address.
  final String address;

  /// City / town / village. Unchanged.
  final String city;

  /// The smallest named unit that contains the point: a kebele, sub-city,
  /// neighbourhood, quarter, hamlet or village. Empty when the provider named
  /// nothing below the city.
  final String area;

  /// County / sub-region / zone above the city. Often empty.
  final String district;

  /// Road / street name, when the provider has one.
  final String road;

  /// `namedetails.name` -- the specific named place, when the point is inside
  /// one. Never used on its own as the label: a house number is not an area.
  final String placeName;

  /// The label to show a rider: the area first, then the city, then the road.
  /// Empty only when the provider told us nothing at all.
  String get areaLabel {
    if (area.isNotEmpty && city.isNotEmpty && area != city) {
      return '$area, $city';
    }
    if (area.isNotEmpty) return area;
    if (city.isNotEmpty) return city;
    if (road.isNotEmpty) return road;
    return address;
  }

  /// True when we actually learned something below city level -- the
  /// condition for telling the user "here is your area" rather than
  /// "here is where you are".
  bool get hasArea => area.isNotEmpty || road.isNotEmpty;
}
