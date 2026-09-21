import 'package:supabase_flutter/supabase_flutter.dart';

/// Phase 1: multi-city support.
///
/// Holds the user's saved city (persisted on profiles.city) and the active
/// browse city ("travel mode"). The active city is the travel city while
/// travel mode is on, otherwise the saved city. Travel mode is a browse
/// session: it intentionally resets to the saved default on app restart.
class CityService {
  CityService(this._client);

  final SupabaseClient _client;

  /// Shared instance for screens that don't use Riverpod refs. Created on
  /// first access — always after Supabase.initialize() (main awaits it),
  /// and the provider exposes this same instance.
  static CityService? _instance;
  static CityService get instance {
    _instance ??= CityService(Supabase.instance.client);
    return _instance!;
  }

  static const String fallbackCity = 'Addis Ababa';

  /// Ethiopian cities offered in the city picker. Add cities here as
  /// coverage expands — the list is UI-level only; any non-empty string is
  /// accepted from search autocomplete (Phase 5) and stored as-is.
  static const List<String> knownCities = [
    'Addis Ababa',
    'Adama',
    'Bahir Dar',
    'Gondar',
    'Hawassa',
    'Jimma',
    'Mekelle',
    'Dire Dawa',
    'Dessie',
    'Arba Minch',
    'Bishoftu',
    'Nekemte',
  ];

  String? _savedCity;
  String? _travelCity;
  bool _travelMode = false;
  bool _loaded = false;

  /// The city the user signed up with (profiles.city). May be null until
  /// the profile loads.
  String? get savedCity => _savedCity;

  /// The city currently browsed: travel city in travel mode, saved city
  /// otherwise, default fallback when nothing is known yet.
  String get activeCity {
    if (_travelMode && (_travelCity?.trim().isNotEmpty ?? false)) {
      return _travelCity!;
    }
    return _savedCity ?? fallbackCity;
  }

  bool get isTravelMode => _travelMode;
  bool get isLoaded => _loaded;

  /// Load the saved city from the signed-in user's profile row.
  Future<void> loadSavedCity() async {
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid == null) {
        _savedCity = null;
        _loaded = true;
        return;
      }
      final row = await _client
          .from('profiles')
          .select('city')
          .eq('id', uid)
          .maybeSingle();
      _savedCity = (row?['city'] as String?)?.trim();
      if (_savedCity == null || _savedCity!.isEmpty) _savedCity = null;
      _loaded = true;
    } catch (_) {
      // A failure must never block the app; fall back to the default city.
      _savedCity = null;
      _loaded = true;
    }
  }

  /// Update the saved city (profile settings + signup). Writes profiles.city
  /// for the signed-in user. Leaving travel mode so the browse city follows
  /// the new saved city immediately.
  Future<bool> updateSavedCity(String city) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return false;
    try {
      await _client.from('profiles').update({'city': city}).eq('id', uid);
      _savedCity = city;
      if (_travelMode) setTravelMode(false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Mark the saved city locally right after signup (the profile row was
  /// just created via trigger; avoids an extra read).
  void seedSavedCity(String city) {
    _savedCity = city;
    _loaded = true;
  }

  /// Travel mode: browse [city] without changing the saved default.
  void setTravelCity(String city) {
    _travelCity = city;
    _travelMode = true;
  }

  /// Leave travel mode; browsing returns to the saved default city.
  void setTravelMode(bool on) {
    _travelMode = on;
    if (!on) _travelCity = null;
  }
}
