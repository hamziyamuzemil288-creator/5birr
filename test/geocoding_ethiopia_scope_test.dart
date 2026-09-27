// The place search answered global questions about a local app.
//
// Typing "Jimma" returned Jimma in other countries, and the nearest-match
// ranking put those ahead of the Ethiopian city the user was standing in. The
// fix pins every query to Ethiopia and filters every response, so the filter
// itself is what needs guarding here: a future edit that drops the country
// check, widens the box, or trusts a provider's country field without also
// checking the coordinates would silently restore the bug, and none of it is
// visible without a live network call.
//
// These are pure tests over the parsers and the box, so they run in CI with no
// key, no network and no device.

import 'package:birr5/core/services/geocoding_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A Photon feature as the service actually receives one.
Map<String, dynamic> _photon({
  required String name,
  required double lat,
  required double lng,
  String? countryCode,
  String? city,
}) =>
    {
      'geometry': {
        'coordinates': [lng, lat]
      },
      'properties': {
        'name': name,
        if (city != null) 'city': city,
        if (countryCode != null) 'countrycode': countryCode,
      },
    };

Map<String, dynamic> _nominatim({
  required String displayName,
  required double lat,
  required double lng,
  String? countryCode,
}) =>
    {
      'display_name': displayName,
      'lat': '$lat',
      'lon': '$lng',
      if (countryCode != null) 'country_code': countryCode,
    };

void main() {
  group('the Ethiopia box', () {
    test('contains every city the app itself offers', () {
      // CityService.knownCities + the search-bias table. If a city the product
      // ships falls outside the box, its own name becomes unsearchable.
      const cities = <String, (double, double)>{
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
      for (final entry in cities.entries) {
        expect(GeocodingService.isInEthiopia(entry.value.$1, entry.value.$2),
            isTrue,
            reason: '${entry.key} is offered by the app but falls outside the '
                'search box, so searching for it returns nothing');
      }
    });

    test('rejects the neighbouring countries a global index would return', () {
      // Coordinates of real places elsewhere. None of these can be a
      // destination for a rider in this app.
      expect(GeocodingService.isInEthiopia(-4.043, 39.668), isFalse,
          reason: 'Mombasa, Kenya — 4 degrees SOUTH, not north');
      expect(GeocodingService.isInEthiopia(-1.286, 36.817), isFalse,
          reason: 'Nairobi, Kenya');
      expect(GeocodingService.isInEthiopia(0.347, 32.582), isFalse,
          reason: 'Kampala, Uganda');
      expect(GeocodingService.isInEthiopia(15.322, 44.207), isFalse,
          reason: 'Sanaa, Yemen — just north of the box');
      expect(GeocodingService.isInEthiopia(11.825, -13.231), isFalse,
          reason: 'Conakry, Guinea');
    });

    test('rejects (0, 0) — the classic broken-GPS fix in the ocean', () {
      // A null island fix used to centre the map in the Gulf of Guinea and
      // search from there, which is how "nearest places" came back empty.
      expect(GeocodingService.isInEthiopia(0, 0), isFalse);
    });
  });

  group('Photon results', () {
    test('an Ethiopian result is kept', () {
      final place = PlaceResult.fromPhoton(_photon(
        name: 'Jimma',
        lat: 7.675,
        lng: 36.834,
        countryCode: 'ET',
      ));
      expect(place.isInEthiopia, isTrue);
    });

    test('a foreign result is rejected even though it is a valid feature', () {
      final place = PlaceResult.fromPhoton(_photon(
        name: 'Jimma',
        lat: -1.286,
        lng: 36.817,
        countryCode: 'KE',
      ));
      expect(place.isInEthiopia, isFalse,
          reason: 'This is the exact reported symptom: a valid Photon feature '
              'for a Jimma somewhere else, offered as if it were local');
    });

    test('a provider that reports no country still has to be inside the box',
        () {
      // Trusting the country field alone would let anything through when the
      // provider omits it, which is exactly the "search finds nothing" failure
      // the bug report describes from the other direction.
      final noCode = PlaceResult.fromPhoton(_photon(
        name: 'Jimma',
        lat: 7.675,
        lng: 36.834,
      ));
      expect(noCode.isInEthiopia, isTrue);

      final noCodeButForeign = PlaceResult.fromPhoton(_photon(
        name: 'Jimma',
        lat: -1.286,
        lng: 36.817,
      ));
      expect(noCodeButForeign.isInEthiopia, isFalse);
    });

    test('a country code of ET cannot rescue coordinates outside the box', () {
      // Defence in depth: if the provider ever mislabels, or the box is edited
      // narrower than the country, both checks still have to hold.
      final place = PlaceResult.fromPhoton(_photon(
        name: 'Somewhere',
        lat: -33.868,
        lng: 151.209,
        countryCode: 'ET',
      ));
      expect(place.isInEthiopia, isFalse);
    });
  });

  group('Nominatim results', () {
    test('reads the country code from addressdetails', () {
      final kept = PlaceResult.fromNominatim(_nominatim(
        displayName: 'Jimma, Ethiopia',
        lat: 7.675,
        lng: 36.834,
        countryCode: 'et',
      ));
      expect(kept.isInEthiopia, isTrue);

      final dropped = PlaceResult.fromNominatim(_nominatim(
        displayName: 'Jimma, Kenya',
        lat: -1.286,
        lng: 36.817,
        countryCode: 'ke',
      ));
      expect(dropped.isInEthiopia, isFalse);
    });

    test('falls back to the coordinates when no code is supplied', () {
      final place = PlaceResult.fromNominatim(_nominatim(
        displayName: 'Jimma, Ethiopia',
        lat: 7.675,
        lng: 36.834,
      ));
      expect(place.isInEthiopia, isTrue);
    });
  });
}
