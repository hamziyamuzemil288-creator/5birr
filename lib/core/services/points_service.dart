import 'package:supabase_flutter/supabase_flutter.dart';

/// Read-only access to loyalty points (migration 0028).
///
/// Points are written exclusively by DB triggers when an order or ride
/// reaches COMPLETED — this service only reads totals.
/// RLS on `user_points` allows: your own USER row, your own provider
/// rows, and every row for admins.
class PointsService {
  PointsService._();
  static final instance = PointsService._();
  final _client = Supabase.instance.client;

  /// Current signed-in user's own points (USER subject).
  Future<int> getMyPoints() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return 0;
    return _pointsFor('USER', userId);
  }

  /// Points for a specific provider profile.
  Future<int> getProviderPoints(String providerId) async {
    return _pointsFor('PROVIDER', providerId);
  }

  /// Points for arbitrary users (admin view) — batch.
  Future<Map<String, int>> getUserPointsBulk(Iterable<String> userIds) =>
      _bulk('USER', userIds);

  /// Points for arbitrary provider profiles (admin view) — batch.
  Future<Map<String, int>> getProviderPointsBulk(Iterable<String> ids) =>
      _bulk('PROVIDER', ids);

  Future<int> _pointsFor(String subjectType, String subjectId) async {
    final row = await _client
        .from('user_points')
        .select('points')
        .eq('subject_type', subjectType)
        .eq('subject_id', subjectId)
        .maybeSingle();
    return (row?['points'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, int>> _bulk(
      String subjectType, Iterable<String> ids) async {
    final idList = ids.toList();
    if (idList.isEmpty) return {};
    final rows = await _client
        .from('user_points')
        .select('subject_id, points')
        .eq('subject_type', subjectType)
        .inFilter('subject_id', idList);
    final result = <String, int>{};
    for (final row in rows as List) {
      result[row['subject_id'] as String] =
          (row['points'] as num?)?.toInt() ?? 0;
    }
    return result;
  }
}
