import 'package:flutter/material.dart' show Color;
import 'package:supabase_flutter/supabase_flutter.dart';

/// A rung of the loyalty ladder.
///
/// The thresholds, names and colours are DATA, not Dart: they are read from
/// the `rank_tiers` value in `system_settings` through points_rank_tiers(),
/// so the CEO can retune the ladder from the admin settings screen without an
/// app release. Nothing here hardcodes a threshold.
class RankTier {
  final String code;
  final String name;
  final int minPoints;
  final Color color;
  final int sortOrder;

  const RankTier({
    required this.code,
    required this.name,
    required this.minPoints,
    required this.color,
    required this.sortOrder,
  });

  factory RankTier.fromMap(Map<String, dynamic> m) {
    return RankTier(
      code: (m['code'] as String?) ?? '',
      name: (m['name'] as String?) ?? '',
      minPoints: (m['min_points'] as num?)?.toInt() ?? 0,
      color: parseHexColor(m['color'] as String?),
      sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
    );
  }

  /// '#A9714B' / 'A9714B' -> Color. Falls back to the theme's muted grey
  /// rather than throwing on a colour the CEO typed by hand.
  static Color parseHexColor(String? hex) {
    const fallback = Color(0xFF8A8A8A);
    if (hex == null) return fallback;
    var v = hex.trim();
    if (v.startsWith('#')) v = v.substring(1);
    if (v.length == 6) v = 'FF$v';
    if (v.length != 8) return fallback;
    final parsed = int.tryParse(v, radix: 16);
    return parsed == null ? fallback : Color(parsed);
  }
}

/// Where an account stands on the ladder, and how far the next rung is.
class RankProgress {
  final int points;

  /// Null below the lowest rung — an account that has not earned Bronze yet
  /// holds no rank, which is what makes "100 points to Bronze" readable.
  final RankTier? current;
  final RankTier? next;

  const RankProgress({required this.points, this.current, this.next});

  bool get hasRank => current != null;
  bool get isTop => current != null && next == null;

  /// Progress through the current band, 0..1. Below Bronze the band is
  /// 0 -> first rung, so the bar reflects real progress from zero.
  double get fraction {
    final upper = next;
    if (upper == null) return 1;
    final floor = current?.minPoints ?? 0;
    final span = upper.minPoints - floor;
    if (span <= 0) return 1;
    return ((points - floor) / span).clamp(0.0, 1.0);
  }

  int get pointsToNext {
    final upper = next;
    if (upper == null) return 0;
    final gap = upper.minPoints - points;
    return gap < 0 ? 0 : gap;
  }
}

/// Rank tiers and per-person rank lookups.
///
/// The badge has to appear next to other people's names — a listing, an order,
/// a review — and `user_points` is readable only by its owner and an admin.
/// points_rank_for_subjects() resolves a set of ids server-side and returns
/// the tier. Two consequences shape this service:
///
///   * lookups are BATCHED. A listing with twelve products would otherwise
///     fire twelve RPCs as each tile builds; ids requested in the same frame
///     share one call.
///   * lookups are CACHED for the session, because a tier changes at most a
///     few times a day and a badge is not worth a round trip per rebuild.
///
/// A tier is a trust signal and nothing more. No screen gates behaviour on it.
class RankService {
  RankService._();
  static final instance = RankService._();

  final _client = Supabase.instance.client;

  List<RankTier>? _tiers;
  Future<List<RankTier>>? _tiersInFlight;

  /// 'USER:<id>' / 'PROVIDER:<id>' -> tier (null = loaded, no rank yet).
  final Map<String, RankTier?> _ranks = {};

  final Set<String> _pendingUsers = {};
  final Set<String> _pendingProviders = {};
  Future<void>? _batchInFlight;

  static String _userKey(String id) => 'USER:$id';
  static String _providerKey(String id) => 'PROVIDER:$id';

  /// The whole ladder, lowest rung first.
  Future<List<RankTier>> tiers({bool refresh = false}) async {
    if (refresh) {
      _tiers = null;
      _tiersInFlight = null;
    }
    final cached = _tiers;
    if (cached != null) return cached;
    final inFlight = _tiersInFlight;
    if (inFlight != null) return inFlight;

    final future = _loadTiers();
    _tiersInFlight = future;
    return future;
  }

  Future<List<RankTier>> _loadTiers() async {
    try {
      final rows = await _client.rpc('points_rank_tiers');
      final tiers = (rows as List)
          .map((r) => RankTier.fromMap(Map<String, dynamic>.from(r as Map)))
          .toList()
        ..sort((a, b) => a.minPoints.compareTo(b.minPoints));
      _tiers = tiers;
      return tiers;
    } finally {
      _tiersInFlight = null;
    }
  }

  /// Ladder position for a point total. Client-side arithmetic over
  /// server-provided thresholds — the thresholds themselves are never
  /// duplicated here.
  RankProgress progressFor(int points, List<RankTier> ladder) {
    RankTier? current;
    RankTier? next;
    for (final tier in ladder) {
      if (points >= tier.minPoints) {
        current = tier;
      } else if (next == null) {
        next = tier;
      }
    }
    return RankProgress(points: points, current: current, next: next);
  }

  /// Convenience for the signed-in account's own card.
  Future<RankProgress> progressForPoints(int points) async {
    final ladder = await tiers();
    return progressFor(points, ladder);
  }

  RankTier? cachedUserRank(String? userId) =>
      userId == null ? null : _ranks[_userKey(userId)];

  RankTier? cachedProviderRank(String? providerId) =>
      providerId == null ? null : _ranks[_providerKey(providerId)];

  bool hasUserRank(String? userId) =>
      userId != null && _ranks.containsKey(_userKey(userId));

  bool hasProviderRank(String? providerId) =>
      providerId != null && _ranks.containsKey(_providerKey(providerId));

  /// Request ranks for a set of accounts. Resolves once the batch that
  /// includes them has been fetched. Never throws: a badge that cannot load
  /// renders as nothing rather than as an error.
  Future<void> ensure({
    Iterable<String?> userIds = const [],
    Iterable<String?> providerIds = const [],
  }) async {
    for (final id in userIds) {
      if (id == null) continue;
      if (!_ranks.containsKey(_userKey(id))) _pendingUsers.add(id);
    }
    for (final id in providerIds) {
      if (id == null) continue;
      if (!_ranks.containsKey(_providerKey(id))) _pendingProviders.add(id);
    }
    if (_batchInFlight == null) {
      if (_pendingUsers.isEmpty && _pendingProviders.isEmpty) return;
      // One frame's worth of requests share a single round trip. A badge fires
      // this from initState, so tiles built together coalesce.
      _batchInFlight = Future<void>.delayed(const Duration(milliseconds: 16))
          .then((_) => _flush())
          .whenComplete(() => _batchInFlight = null);
    }

    // Always handed back, even with nothing newly queued: a badge whose id is
    // already inside the batch in flight must still wait for it, or it would
    // rebuild with no tier and never be told the answer arrived.
    return _batchInFlight;
  }

  /// Drains the pending sets. Loops because a badge can request an id while a
  /// batch is already in flight; stopping after one round would leave that
  /// badge blank until something else happened to ask.
  Future<void> _flush() async {
    while (_pendingUsers.isNotEmpty || _pendingProviders.isNotEmpty) {
      final users = _pendingUsers.toList();
      final providers = _pendingProviders.toList();
      _pendingUsers.clear();
      _pendingProviders.clear();

      try {
        final rows = await _client.rpc('points_rank_for_subjects', params: {
          'p_user_ids': users,
          'p_provider_ids': providers,
        });
        for (final raw in rows as List) {
          final row = Map<String, dynamic>.from(raw as Map);
          final type = row['subject_type'] as String?;
          final id = row['subject_id'] as String?;
          if (type == null || id == null) continue;
          final code = row['rank_code'] as String?;
          final tier = code == null
              ? null
              : RankTier(
                  code: code,
                  name: (row['rank_name'] as String?) ?? code,
                  minPoints: (row['rank_min_points'] as num?)?.toInt() ?? 0,
                  color: RankTier.parseHexColor(row['rank_color'] as String?),
                  sortOrder: 0,
                );
          _ranks[type == 'USER' ? _userKey(id) : _providerKey(id)] = tier;
        }
        // Anything the server did not answer for is remembered as "no rank",
        // so a missing id cannot cause a request on every rebuild.
        for (final id in users) {
          _ranks.putIfAbsent(_userKey(id), () => null);
        }
        for (final id in providers) {
          _ranks.putIfAbsent(_providerKey(id), () => null);
        }
      } catch (_) {
        // Deliberately not cached as "no rank": the ids were already taken
        // off the pending sets, so a later request retries them.
        return;
      }
    }
  }
}
