/// The one place Ethiopian cities are listed.
///
/// ## Why this file exists
///
/// Two files used to carry their own list: `CityService.knownCities` (what
/// the picker offers) and `GeocodingService._cityBias` (approximate centres
/// used to bias place search). They happened to agree, and that is the
/// problem — nothing made them agree. Adding Hawassa to the picker and
/// forgetting the bias entry produces a city a user can select and then
/// cannot find anywhere by searching, which is a bug report nobody can
/// reproduce from a description.
///
/// One list, one file. [cityCenter] returns null for a city with no
/// coordinates rather than throwing, so a city can be added here before its
/// centre is surveyed — the picker works from [cities], the geocoder falls
/// back to no bias for that city, and nothing crashes.
///
/// ## Why coordinates are approximate
///
/// These are city centres used only to rank search results toward the right
/// part of the country. They are not used for navigation, geofencing or
/// pricing, so metre accuracy is not required and a survey would be wasted
/// effort. Anything within a few kilometres does the same job here.
library;

/// City name -> approximate (latitude, longitude).
const Map<String, (double, double)> _cityCenters = {
  'Addis Ababa': (9.005, 38.763),
  'Adama': (8.542, 39.267),
  'Arba Minch': (6.033, 37.553),
  'Bahir Dar': (11.594, 37.391),
  'Bishoftu': (8.752, 38.985),
  'Dessie': (11.133, 39.633),
  'Dire Dawa': (9.593, 41.866),
  'Gondar': (12.609, 37.466),
  'Hawassa': (7.062, 38.476),
  'Jimma': (7.675, 36.834),
  'Mekelle': (13.497, 39.475),
  'Nekemte': (9.088, 36.552),
};

/// Every city the app offers, alphabetically.
///
/// Alphabetical rather than by population: the picker is a search over
/// names, and an unsorted list makes "Adama" harder to find than "Hawassa"
/// depending on where you happened to put it.
const List<String> cities = [
  'Addis Ababa',
  'Adama',
  'Arba Minch',
  'Bahir Dar',
  'Bishoftu',
  'Dessie',
  'Dire Dawa',
  'Gondar',
  'Hawassa',
  'Jimma',
  'Mekelle',
  'Nekemte',
];

/// The city used when nothing better is known. Also the app's default
/// travel city, so it must be in [cities].
const String fallbackCity = 'Addis Ababa';

/// Alias with an unambiguous name, for call sites that import this file
/// alongside other city-related symbols and would otherwise have two
/// `fallbackCity`s in scope.
const String ethiopiaCitiesFallback = fallbackCity;

/// Approximate centre for [city], or null if it has none.
///
/// Null rather than a default coordinate: falling back to Addis Ababa for an
/// unknown city would silently bias search results toward the capital, which
/// is worse than no bias at all.
(double, double)? cityCenter(String city) => _cityCenters[city];

/// Alias of [cities], named for the importing file's vocabulary.
const List<String> ethiopiaCities = cities;

/// True if [city] is one the app offers.
bool isKnownCity(String city) => _cityCenters.containsKey(city);
