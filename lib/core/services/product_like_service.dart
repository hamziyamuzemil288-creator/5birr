import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/safe_call.dart';

/// Like state for products, with an optimistic toggle and an authoritative
/// server answer behind it.
///
/// WHY THE OPTIMISM IS HERE AT ALL
/// -------------------------------
/// A like is the cheapest interaction in the app and the one a user is most
/// likely to repeat quickly. A heart that takes a round trip to fill feels
/// broken, and a user who taps twice because the first tap did not visibly do
/// anything has now liked something they may not want. So the UI updates
/// immediately and the server decides afterwards.
///
/// Three things protect that optimism from turning into a lie:
///
///   * [InFlightGuard] per product — a second tap while the first is still in
///     flight is dropped, not queued. Queuing would replay the toggle and undo
///     the user's most recent intent.
///   * [Debouncer] per product — rapid taps collapse into one request. The
///     guard above is about concurrency; this is about the window before the
///     first request even leaves.
///   * Rollback on failure — if the server rejects the change, the optimistic
///     value is restored exactly, not merely decremented. If a user un-likes
///     and the request fails, the count must go back UP, which only a saved
///     previous value gets right.
///
/// The server response is authoritative and always wins, including its
/// like_count: the counter is maintained by a database trigger, so the number
/// this returns is the same one the next list query will show.
class ProductLikeService extends ChangeNotifier {
  ProductLikeService._();

  static final ProductLikeService instance = ProductLikeService._();

  final Map<String, bool> _liked = {};
  final Map<String, int> _counts = {};
  final Map<String, Debouncer> _debouncers = {};
  final Map<String, InFlightGuard> _guards = {};

  /// Whether the signed-in user has liked [productId], as far as we know.
  ///
  /// False until the server says otherwise. An unknown is treated as unliked
  /// so the heart renders in its outline state, which is the honest state: we
  /// have not been told it is liked.
  bool isLiked(String productId) => _liked[productId] ?? false;

  /// The count to display, preferring the live value over [fallback].
  ///
  /// [fallback] is whatever came with the product row. Before any interaction
  /// this returns that untouched, so a product the user never touches shows
  /// exactly the number the database sent.
  int likeCount(String productId, int fallback) =>
      _counts[productId] ?? fallback;

  /// True once the count reaches the CEO-configured Popular threshold.
  ///
  /// A threshold of 0 means "never", which is how a CEO turns the mark off
  /// without a migration.
  bool isPopular(int likeCount, int threshold) =>
      threshold > 0 && likeCount >= threshold;

  /// Seed state from a server payload without treating it as a user action.
  ///
  /// Used when a feed arrives with the user's own like state already joined
  /// in. Deliberately does not notify per row: a caller hydrating twenty
  /// products should not rebuild twenty widgets.
  void hydrate(Iterable<({String productId, bool liked, int likeCount})> rows) {
    var changed = false;
    for (final row in rows) {
      if (_liked[row.productId] != row.liked) {
        _liked[row.productId] = row.liked;
        changed = true;
      }
      if (_counts[row.productId] != row.likeCount) {
        _counts[row.productId] = row.likeCount;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  /// Toggle the caller's like on [productId].
  ///
  /// [currentCount] is the count currently on screen, used to compute the
  /// optimistic value before the server has answered. Returns immediately.
  void toggle(String productId, {required int currentCount}) {
    final guard = _guards.putIfAbsent(productId, () => InFlightGuard());
    final debouncer =
        _debouncers.putIfAbsent(productId, () => Debouncer(delay: const Duration(milliseconds: 250)));

    final wasLiked = _liked[productId] ?? false;
    final wasCount = _counts[productId] ?? currentCount;
    final willBeLiked = !wasLiked;

    // Optimistic. The listener rebuilds the heart before this method returns.
    _liked[productId] = willBeLiked;
    _counts[productId] = wasLiked ? wasCount - 1 : wasCount + 1;
    notifyListeners();

    debouncer.call(() async {
      await guard.run(() async {
        try {
          final result = await safeCall<Map<String, dynamic>>(
            () => Supabase.instance.client.rpc(
                  'toggle_product_like',
                  params: {'p_product_id': productId},
                ),
            context: 'like product',
          );

          final liked = result['liked'] as bool?;
          final count = result['like_count'] as int?;
          _liked[productId] = liked ?? willBeLiked;
          if (count != null) _counts[productId] = count;
        } catch (_) {
          // Roll back to the exact previous values rather than inverting the
          // current ones. Inverting is wrong the moment two things can change
          // between the optimistic write and the failure, and it is wrong
          // outright if the count the user saw was already stale.
          _liked[productId] = wasLiked;
          _counts[productId] = wasCount;
        }
        notifyListeners();
      });
    });
  }
}
