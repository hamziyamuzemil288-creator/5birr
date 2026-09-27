import 'package:supabase_flutter/supabase_flutter.dart';

/// Read access to loyalty points, plus the one write a person can make
/// against their own balance: converting points into wallet credit.
///
/// Points are otherwise written exclusively by DB triggers — the ledger is
/// the audit and the totals follow it, both server-side. RLS on `user_points`
/// and `points_ledger` allows: your own USER row, your own provider rows, and
/// every row for admins.
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

  /// The caller's own provider profile, if they hold one.
  ///
  /// A wallet belongs to a provider profile, so this is also the answer to
  /// "does this account have somewhere to convert points into?".
  Future<String?> currentProviderProfileId() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;
    final row = await _client
        .from('provider_profiles')
        .select('id')
        .eq('user_id', userId)
        .order('created_at')
        .limit(1)
        .maybeSingle();
    return row?['id'] as String?;
  }

  /// The points this account has earned, per balance, with the ledger entry
  /// that earned each one. Newest first.
  Future<List<Map<String, dynamic>>> getLedger({
    required String subjectType,
    required String subjectId,
    int limit = 50,
  }) async {
    final rows = await _client
        .from('points_ledger')
        .select('id, points, source_type, reason, created_at')
        .eq('subject_type', subjectType)
        .eq('subject_id', subjectId)
        .order('created_at', ascending: false)
        .limit(limit);
    return List<Map<String, dynamic>>.from(rows as List);
  }

  /// Spend points into the wallet.
  ///
  /// The birr amount is computed by the server from the CEO-set
  /// points_to_birr_rate and written to the wallet ledger in the same
  /// transaction as the points debit. The client sends a count and nothing
  /// else — it never does the arithmetic and never sends an amount.
  ///
  /// Throws on refusal (below the minimum, not enough points, no wallet yet);
  /// callers should surface [friendlyError] text.
  Future<Map<String, dynamic>> convertToWallet({
    required String subjectType,
    required int points,
    String? providerId,
  }) async {
    final result = await _client.rpc('convert_points_to_wallet', params: {
      'p_subject_type': subjectType,
      'p_points': points,
      if (providerId != null) 'p_provider_id': providerId,
    });
    return Map<String, dynamic>.from(result as Map);
  }
}
