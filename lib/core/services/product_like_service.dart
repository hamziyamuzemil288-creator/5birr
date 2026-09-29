import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../resilience/app_failure.dart';
import '../resilience/failure_mapper.dart';
import '../resilience/safe_call.dart';

/// A user's reaction to a product: [like], [dislike], or none.
///
/// The strings are the database's, not Dart's: the CHECK constraint on
/// `product_likes.reaction` admits exactly these three words, and the RPC
/// takes them verbatim.
class ProductReaction {
  static const String like = 'LIKE';
  static const String dislike = 'DISLIKE';
  static const String none = 'NONE';
}

/// The like count to show between a tap and the server's answer.
///
/// Pure, and a top-level function rather than a method, because it is the one
/// piece of arithmetic in this file that can be wrong in a way a device is the
/// only way to notice — so it is extracted to be pinned by a test instead.
///
/// [serverCount] is `products.like_count` as the server last reported it, and
/// that number already includes the caller's own reaction when [counted] is
/// [ProductReaction.like]. [intended] is what the user has chosen since. The
/// difference between the two is the only adjustment needed:
///
///   counted LIKE,   intended not LIKE  -> the server is one too high
///   counted not LIKE, intended LIKE    -> the server is one too low
///   anything else                      -> the server is already right
int optimisticLikeCount({
  required int serverCount,
  required String counted,
  required String intended,
}) {
  var n = serverCount;
  if (counted == ProductReaction.like && intended != ProductReaction.like) {
    n -= 1;
  }
  if (counted != ProductReaction.like && intended == ProductReaction.like) {
    n += 1;
  }
  return n < 0 ? 0 : n;
}

/// Like and dislike state for products, with an optimistic update in front of
/// an authoritative server answer behind it.
///
/// ## Why the optimism is here at all
///
/// A like is the cheapest interaction in the app and the one a user is most
/// likely to repeat quickly. A heart that takes a round trip to fill feels
/// broken, and a user who taps twice because the first tap did not visibly do
/// something has now reacted to something they may not want. So the UI updates
/// immediately and the server decides afterwards.
///
/// ## Why the write is a SET and not a toggle
///
/// It used to be a toggle, and that is what made a like impossible to keep.
/// A toggle flips whatever the database currently holds, so a client whose
/// local state was wrong — or which resent a request whose answer it had not
/// seen — flipped the row the wrong way with no way to say "I want LIKE, not
/// whatever this is". `set_product_reaction` states the intent instead, which
/// is idempotent: resending is harmless, and two requests arriving out of
/// order cannot invert the user's most recent decision. The optimistic update
/// is still a guess until the response lands; this is what stops the guess
/// from becoming permanent.
///
/// ## Why the state is read from the server before it is written
///
/// `hydrate` had no caller anywhere in lib/. So the heart on a product the
/// user had already liked rendered empty, a tap toggled their existing row
/// off, and the server's authoritative `liked: false` emptied the heart again
/// — indistinguishable, to the user, from a like that refused to stick.
/// [ensureLoaded] is the batched fix: one query for a whole grid, not one per
/// card, and it is what makes the local state a starting guess rather than
/// the only truth the client has.
///
/// ## Why a failure is never silent
///
/// A failed write used to be swallowed by a bare `catch (_)` that restored
/// the previous value, which is exactly a heart that fills and empties with
/// no explanation. [toggleLike] and [toggleDislike] now return whether the
/// server accepted the change, and the caller shows the reason. The optimistic
/// value is still rolled back — the point is that the user is told, not that
/// the guess is kept.
class ProductLikeService extends ChangeNotifier {
  ProductLikeService._();

  static final ProductLikeService instance = ProductLikeService._();

  /// What the user has chosen, per product. This is the intent, which may be
  /// ahead of the server until a write is confirmed.
  final Map<String, String> _intent = {};

  /// What the server last confirmed, per product. `null` means "never asked",
  /// which is different from a confirmed `NONE`.
  final Map<String, String> _confirmed = {};

  /// `products.like_count` as last reported by the server, used to compute the
  /// optimistic count between a tap and its answer.
  final Map<String, int> _serverLikeCounts = {};

  /// A write is in flight for this product.
  final Map<String, bool> _sending = {};

  /// The intent changed while a write was in flight, so the newer intent still
  /// has to be sent once the current one finishes.
  final Map<String, bool> _queued = {};

  /// The pre-tap intent, kept so a failed write restores the exact state the
  /// user was looking at rather than inverting whatever it has become.
  final Map<String, String> _before = {};

  /// What the UI is currently awaiting for a product, so two rapid taps settle
  /// one caller rather than stranding one.
  final Map<String, Completer<AppFailure?>> _waiters = {};

  /// In-flight loads, coalesced per batch so a grid of cards hydrating at once
  /// does not re-ask for the same ids.
  final Set<String> _loading = {};

  // ------------------------------------------------------------------ reads

  /// Whether the signed-in user likes [productId], as far as we know.
  bool isLiked(String productId) =>
      (_intent[productId] ?? ProductReaction.none) == ProductReaction.like;

  /// Whether the signed-in user has disliked [productId], as far as we know.
  bool isDisliked(String productId) =>
      (_intent[productId] ?? ProductReaction.none) == ProductReaction.dislike;

  /// True once the server has told us about this product's reaction, so a
  /// rendered heart reflects the database rather than a default.
  bool isKnown(String productId) => _confirmed.containsKey(productId);

  /// The like count to display, preferring the live value over [fallback].
  ///
  /// Between a tap and its answer the number is the server's count adjusted
  /// for the difference between what it counted and what the user has since
  /// chosen — so it moves immediately and lands on exactly the value the
  /// response carries.
  int likeCount(String productId, int fallback) {
    final server = _serverLikeCounts[productId];
    if (server == null) return fallback;
    return optimisticLikeCount(
      serverCount: server,
      counted: _confirmed[productId] ?? ProductReaction.none,
      intended: _intent[productId] ?? ProductReaction.none,
    );
  }

  /// True once the count reaches the CEO-configured Popular threshold.
  ///
  /// A threshold of 0 means "never", which is how a CEO turns the mark off
  /// without a migration.
  bool isPopular(int likeCount, int threshold) =>
      threshold > 0 && likeCount >= threshold;

  // ----------------------------------------------------------------- loads

  /// Load the caller's reactions for [productIds] and mark them known.
  ///
  /// One query for the whole batch, because a grid of twelve cards must not
  /// cost twelve round trips. Products with no row are confirmed as [ProductReaction.none],
  /// which is a real answer and stops the next batch asking again.
  ///
  /// [likeCountOf] supplies the count the feed already holds, so the optimistic
  /// arithmetic has a server baseline without a second query. It is optional:
  /// without it the count falls back to the product row until a write lands.
  ///
  /// Best-effort by design. A failure leaves the products unconfirmed, so a
  /// later call retries, and the heart renders in its unknown state rather
  /// than asserting something the server has not confirmed.
  Future<void> ensureLoaded(
    Iterable<String> productIds, {
    int Function(String productId)? likeCountOf,
  }) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    final wanted =
        productIds.where((id) => !_confirmed.containsKey(id)).toSet();
    wanted.removeAll(_loading);
    if (wanted.isEmpty) return;
    _loading.addAll(wanted);

    try {
      final rows = await safeCall<List<dynamic>>(
        () => Supabase.instance.client
            .from('product_likes')
            .select('product_id, reaction')
            .eq('user_id', uid)
            .inFilter('product_id', wanted.toList()),
        context: 'load your reactions',
      );
      final mine = <String, String>{};
      for (final r in rows) {
        final m = Map<String, dynamic>.from(r as Map);
        final id = m['product_id'] as String?;
        if (id == null) continue;
        mine[id] = (m['reaction'] as String?) ?? ProductReaction.like;
      }
      for (final id in wanted) {
        // A write is in flight for this product, so the intent is newer than
        // anything this query can have read. Adopting the server's answer here
        // would undo a tap the user has already seen take effect.
        if (_sending[id] == true) continue;
        final reaction = mine[id] ?? ProductReaction.none;
        _confirmed[id] = reaction;
        _intent[id] = reaction;
        final count = likeCountOf?.call(id);
        if (count != null) _serverLikeCounts[id] = count;
      }
      notifyListeners();
    } catch (_) {
      // Left unconfirmed on purpose: the next call retries, and until then the
      // heart is honest about not knowing.
    } finally {
      _loading.removeAll(wanted);
    }
  }

  // ---------------------------------------------------------------- writes

  /// Like or unlike [productId].
  ///
  /// Returns `null` when the server accepted the change, or the [AppFailure]
  /// that stopped it. The optimistic value is rolled back either way; what
  /// changed is that the caller is now handed the reason instead of being
  /// left with a heart that filled and emptied for no stated cause.
  ///
  /// [currentCount] is the count on screen, used only until the server has
  /// reported a count of its own.
  Future<AppFailure?> toggleLike(String productId,
          {required int currentCount}) =>
      _react(productId, ProductReaction.like, currentCount: currentCount);

  /// Dislike or clear the dislike on [productId].
  ///
  /// Liking something already disliked replaces the dislike and vice versa;
  /// that is the server's decision (a reaction is exclusive by construction)
  /// and this only states the intent.
  ///
  /// Returns `null` on success, or the [AppFailure] that stopped it.
  Future<AppFailure?> toggleDislike(String productId,
          {required int currentCount}) =>
      _react(productId, ProductReaction.dislike, currentCount: currentCount);

  Future<AppFailure?> _react(
    String productId,
    String to, {
    required int currentCount,
  }) {
    // Baseline for the optimistic count from whatever the card is already
    // showing, so a tap before [ensureLoaded] finishes still moves the number
    // immediately. If the product was liked in an earlier session this is one
    // too high for the moment before hydration, which the server's answer
    // corrects -- a better trade than a button that does not move.
    _serverLikeCounts.putIfAbsent(productId, () => currentCount);
    final from = _intent[productId] ?? ProductReaction.none;
    _before[productId] = from;

    final now = from == to ? ProductReaction.none : to;
    _intent[productId] = now;
    notifyListeners();

    // A tap while an earlier one is still waiting must not strand that
    // caller's future: the older intent is superseded, not failed.
    final superseded = _waiters[productId];
    if (superseded != null && !superseded.isCompleted) {
      _waiters.remove(productId);
      superseded.complete(null);
    }
    final completer = Completer<AppFailure?>();
    _waiters[productId] = completer;

    unawaited(_pump(productId));
    return completer.future;
  }

  /// Send the current intent, then send anything that superseded it.
  ///
  /// One request at a time per product. A tap during a request does not start
  /// a second one — it is remembered and sent when the first finishes, so two
  /// requests can never race and leave the row in the older state.
  Future<void> _pump(String productId) async {
    if (_sending[productId] == true) {
      _queued[productId] = true;
      return;
    }
    _sending[productId] = true;
    _queued[productId] = false;

    final sent = _intent[productId] ?? ProductReaction.none;
    final before = _before[productId];
    AppFailure? failure;

    try {
      final result = await safeCall<Map<String, dynamic>>(
        () => Supabase.instance.client.rpc(
              'set_product_reaction',
              params: {'p_product_id': productId, 'p_reaction': sent},
            ),
        context: 'save your reaction',
      );
      // Only adopt the answer when nothing newer is waiting. An answer about
      // the previous intent is still true, but letting it overwrite a newer
      // intent would make the heart jump backwards.
      if (_queued[productId] != true) {
        final confirmed =
            (result['reaction'] as String?) ?? ProductReaction.none;
        _confirmed[productId] = confirmed;
        _intent[productId] = confirmed;
        final count = result['like_count'] as int?;
        if (count != null) _serverLikeCounts[productId] = count;
      }
    } catch (e) {
      failure = e is AppFailure ? e : AppFailureMapper.map(e);
      // Restore the exact state the user was looking at. Inverting the
      // current value would be wrong the moment a second tap had landed in
      // between, and the count needs no undo at all because it is only ever
      // derived, never stored optimistically.
      if (_queued[productId] != true && before != null) {
        _intent[productId] = before;
      }
    } finally {
      // Cleared on failure as well as on success: it is only the pre-tap value
      // for the request just settled, and keeping it would make a later
      // ensureLoaded() treat this product as busy forever.
      _before.remove(productId);
      _sending[productId] = false;
      notifyListeners();
    }

    final waiter = _waiters[productId];
    if (waiter != null && !waiter.isCompleted && _queued[productId] != true) {
      _waiters.remove(productId);
      waiter.complete(failure);
    }

    if (_queued[productId] == true) {
      unawaited(_pump(productId));
    }
  }
}
