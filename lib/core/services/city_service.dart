import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/ethiopia_cities.dart'
    show ethiopiaCities, ethiopiaCitiesFallback;

/// Phase 1: multi-city support.
///
/// Holds the user's saved city (persisted on profiles.city) and the active
/// browse city ("travel mode"). The active city is the travel city while
/// travel mode is on, otherwise the saved city. Travel mode is a browse
/// session: it intentionally resets to the saved default on app restart.
///
/// ## Why this notifies
///
/// The active city is app-global state, but the screens that scope their
/// query to it (the home feed, a category page, search) each read it once and
/// hold the result. Only the home chip's own flow remembered to reload — so
/// changing the city from anywhere else (the profile screen's city picker, in
/// particular) left those screens showing the OLD city's products, which is
/// exactly the reported "it keeps showing the old city's products". The fix is
/// to make the change observable: [CityService] is a [ChangeNotifier] and
/// every mutation publishes an event when the ACTIVE city actually changes, so
/// a scoped screen can reload regardless of who changed the city.
class CityService extends ChangeNotifier {
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

  /// Ethiopian cities offered in the city picker. Add cities here as
  /// coverage expands — the list is UI-level only; any non-empty string is
  /// accepted from search autocomplete (Phase 5) and stored as-is.
  ///
  /// Delegates to [ethiopiaCities] so the picker and the geocoder's search
  /// bias cannot drift apart. See that file for why that matters.
  static const List<String> knownCities = ethiopiaCities;

  static const String fallbackCity = ethiopiaCitiesFallback;

  String? _savedCity;
  String? _travelCity;
  bool _travelMode = false;
  bool _allCities = false;
  bool _loaded = false;

  /// The browse city that means "every city together". [activeCity] returns
  /// this, and every city-scoped read treats an empty value as "do not filter"
  /// (see migration 20261010000002).
  static const String allCitiesSentinel = '';

  /// The active city as of the last notification. Used to publish an event
  /// ONLY when the value the scoped screens query on actually changes — a
  /// redundant notify would reload every feed for a no-op.
  String? _lastNotifiedActive;

  /// The city the user signed up with (profiles.city). May be null until
  /// the profile loads.
  String? get savedCity => _savedCity;

  /// The city currently browsed: travel city in travel mode, saved city
  /// otherwise, default fallback when nothing is known yet.
  String get activeCity {
    if (_allCities) return allCitiesSentinel;
    if (_travelMode && (_travelCity?.trim().isNotEmpty ?? false)) {
      return _travelCity!;
    }
    return _savedCity ?? fallbackCity;
  }

  bool get isTravelMode => _travelMode;
  bool get isLoaded => _loaded;

  /// True while the feed is browsing every city at once rather than one.
  bool get isAllCities => _allCities;

  /// Publish a change when [activeCity] differs from the last notified value.
  ///
  /// [_loaded] flipping true is also worth a publish the first time: before
  /// the profile read finishes, [activeCity] is the fallback, and a screen
  /// that scoped to the fallback must re-query once the real saved city
  /// arrives.
  void _notifyIfActiveChanged() {
    final current = activeCity;
    if (current == _lastNotifiedActive) return;
    _lastNotifiedActive = current;
    notifyListeners();
  }

  /// Load the saved city from the signed-in user's profile row.
  Future<void> loadSavedCity() async {
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid == null) {
        _savedCity = null;
        _loaded = true;
        _notifyIfActiveChanged();
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
    _notifyIfActiveChanged();
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
      _allCities = false;
      if (_travelMode) {
        _travelMode = false;
        _travelCity = null;
      }
      // The screens scoped to the old city must reload: this is the path that
      // previously changed nothing on the home feed, so it went on showing the
      // products of the city the user had just left.
      _notifyIfActiveChanged();
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
    _notifyIfActiveChanged();
  }

  /// Travel mode: browse [city] without changing the saved default.
  void setTravelCity(String city) {
    _allCities = false;
    _travelCity = city;
    _travelMode = true;
    _notifyIfActiveChanged();
  }

  /// Leave travel mode; browsing returns to the saved default city.
  void setTravelMode(bool on) {
    _allCities = false;
    _travelMode = on;
    if (!on) _travelCity = null;
    _notifyIfActiveChanged();
  }

  /// Browse every city together. Leaves travel mode, because "all cities" is
  /// the opposite of a single travel city; the saved city is untouched, so
  /// "Back to my city" still returns to it.
  void setAllCities(bool on) {
    _allCities = on;
    if (on) {
      _travelMode = false;
      _travelCity = null;
    }
    _notifyIfActiveChanged();
  }
}
