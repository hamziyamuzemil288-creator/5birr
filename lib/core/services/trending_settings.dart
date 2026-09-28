import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/safe_call.dart';

/// The CEO-tunable knobs behind the trending score and the Popular mark.
///
/// Read from `trending_settings()` rather than hardcoded, because these are
/// business decisions the CEO owns: how much a like is worth relative to a
/// sale, how fast trending follows the news, and where the line for "popular"
/// sits. A constant here would mean changing the policy required a release.
///
/// Cached for the session after the first read. The values are read on nearly
/// every card, and re-reading them per card would put a round trip in the
/// middle of building a grid.
class TrendingSettings extends ChangeNotifier {
  TrendingSettings._();

  static final TrendingSettings instance = TrendingSettings._();

  static const int _defaultPopularThreshold = 10;

  int _popularThreshold = _defaultPopularThreshold;
  bool _loaded = false;
  Future<void>? _inFlight;

  /// Like count at or above which a product is marked Popular.
  ///
  /// 0 means the mark is off everywhere. That is a configuration choice, not
  /// a missing value, so it is distinct from "not loaded yet".
  int get popularThreshold => _popularThreshold;

  bool get isLoaded => _loaded;

  /// Load the settings once, coalescing concurrent callers.
  Future<void> ensure() {
    if (_loaded) return Future<void>.value();
    _inFlight ??= _load().whenComplete(() => _inFlight = null);
    return _inFlight!;
  }

  Future<void> _load() async {
    try {
      final row = await safeCall<List<dynamic>>(
        () => Supabase.instance.client.rpc('trending_settings'),
        context: 'trending settings',
      );
      if (row.isNotEmpty) {
        final r = Map<String, dynamic>.from(row.first as Map);
        final threshold = r['popular_threshold'];
        if (threshold is int) _popularThreshold = threshold;
      }
      _loaded = true;
      notifyListeners();
    } catch (_) {
      // Leave the default in place and stay unloaded, so a later call retries.
      // Showing an arbitrary threshold because the read failed would mark the
      // wrong products popular, which is worse than marking none.
    }
  }
}
