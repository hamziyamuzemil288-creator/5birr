import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/safe_call.dart';

/// Registered business names for providers, batched and cached.
///
/// WHY A SEPARATE LOOKUP RATHER THAN A JOIN
/// ---------------------------------------
/// The product grid asks for twelve cards at once and each card wants the
/// seller's name. Joining `provider_profiles` into the product query would
/// carry twelve copies of the same handful of business names across the wire
/// and re-fetch them on every page, scroll and refresh. [RankService] solves
/// the same problem for rank badges; this is the same shape for names.
///
/// One round trip per frame of cards, then cached for the session. A name does
/// not change often enough to justify re-fetching it behind a list that is
/// being scrolled.
class ProviderNameService extends ChangeNotifier {
  ProviderNameService._();

  static final ProviderNameService instance = ProviderNameService._();

  final Map<String, String> _names = {};
  final Set<String> _pending = {};
  Future<void>? _batchInFlight;

  /// The business name for [providerId], or null if not resolved yet.
  ///
  /// Null means "we do not know", which callers must render as nothing. A
  /// provider mid-registration can genuinely have no business name, and that
  /// is different from not having looked yet.
  String? nameOf(String providerId) => _names[providerId];

  /// True once a lookup for [providerId] has completed, with or without a name.
  ///
  /// Distinguishes "looked and found nothing" from "not looked yet", so a
  /// widget can stop asking without the two being confused.
  bool hasResolved(String providerId) => _names.containsKey(providerId);

  /// Queue [providerIds] for lookup, coalescing every caller in this frame.
  ///
  /// Always returns the in-flight batch when there is one, even if the ids are
  /// all cached: a widget that asked before the answer landed must still be
  /// told when it arrives, or it renders blank forever.
  Future<void> ensure(Iterable<String?> providerIds) {
    for (final id in providerIds) {
      if (id == null) continue;
      if (!_names.containsKey(id)) _pending.add(id);
    }
    _batchInFlight ??= () {
      if (_pending.isEmpty) return Future<void>.value();
      return Future<void>.delayed(const Duration(milliseconds: 16))
          .then((_) => _flush())
          .whenComplete(() => _batchInFlight = null);
    }();
    return _batchInFlight!;
  }

  Future<void> _flush() async {
    while (_pending.isNotEmpty) {
      final ids = _pending.toList();
      _pending.clear();
      try {
        final rows = await safeCall<List<dynamic>>(
          () => Supabase.instance.client
              .from('provider_profiles')
              .select('id, business_name')
              .inFilter('id', ids),
          context: 'provider business names',
        );
        // Record a miss as a miss so a provider with no business name is not
        // re-queried on every rebuild.
        for (final id in ids) {
          _names.putIfAbsent(id, () => '');
        }
        for (final raw in rows) {
          final row = Map<String, dynamic>.from(raw as Map);
          final id = row['id'] as String?;
          if (id == null) continue;
          final name = (row['business_name'] as String?)?.trim() ?? '';
          _names[id] = name;
        }
      } catch (_) {
        // Drop the ids so a later pass can retry. Leaving them cached as empty
        // would turn a transient network failure into "this provider has no
        // name" for the rest of the session, which is a lie the user sees.
        for (final id in ids) {
          _names.remove(id);
        }
        return;
      }
    }
    notifyListeners();
  }
}
