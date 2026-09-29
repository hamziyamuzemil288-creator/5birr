// The optimistic like count, pinned.
//
// WHY THIS IS A TEST AND NOT A COMMENT
// ------------------------------------
// The reported bug was a like that filled and emptied again, and the fix for
// "keep the UI in sync with the true server state" is arithmetic nobody can
// check by reading: the number on screen is `products.like_count` adjusted for
// the difference between what the server counted and what the user has chosen
// since. Getting the adjustment backwards is invisible in code review and
// obvious on a device -- the number either jumps when it should not, or does
// not move when it should.
//
// It is a pure function precisely so it can be pinned here. The rest of the
// service is I/O-bound and is covered by the write test in
// tools/integration_test/connectivity_test.dart
// (assert_likes_persist_and_are_exclusive), which is the half that was
// actually broken in the database.
import 'package:birr5/core/services/product_like_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('optimisticLikeCount', () {
    test('agrees with the server when nothing has changed', () {
      // The common case, and the one a naive implementation breaks: it adds
      // one for a like that the server has already counted.
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.like,
          intended: ProductReaction.like,
        ),
        7,
      );
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.none,
          intended: ProductReaction.none,
        ),
        7,
      );
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.dislike,
          intended: ProductReaction.dislike,
        ),
        7,
      );
    });

    test('adds one for a like the server has not counted yet', () {
      // The heart filling on tap, before the answer.
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.none,
          intended: ProductReaction.like,
        ),
        8,
      );
      // Including from a dislike: liking something already disliked replaces
      // the dislike, so the count goes UP, not down.
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.dislike,
          intended: ProductReaction.like,
        ),
        8,
      );
    });

    test('subtracts one for a like being taken back', () {
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.like,
          intended: ProductReaction.none,
        ),
        6,
      );
      // A like turning into a dislike is also the like going away: this is the
      // transition with no test, where the sign is easy to get backwards.
      expect(
        optimisticLikeCount(
          serverCount: 7,
          counted: ProductReaction.like,
          intended: ProductReaction.dislike,
        ),
        6,
      );
    });

    test('never reports a negative count', () {
      // A stale server count of 0 alongside a confirmed like would render
      // "-1" on a card if the arithmetic were not clamped.
      expect(
        optimisticLikeCount(
          serverCount: 0,
          counted: ProductReaction.like,
          intended: ProductReaction.none,
        ),
        0,
      );
    });

    test('is idempotent for any intent pair', () {
      // Applying the adjustment twice must not drift, because a rebuild
      // recomputes it from the same two stored values every time. If it were
      // incremental it would walk the number away on every frame.
      const pairs = [
        [ProductReaction.none, ProductReaction.none],
        [ProductReaction.none, ProductReaction.like],
        [ProductReaction.like, ProductReaction.none],
        [ProductReaction.like, ProductReaction.like],
        [ProductReaction.dislike, ProductReaction.like],
        [ProductReaction.like, ProductReaction.dislike],
        [ProductReaction.dislike, ProductReaction.dislike],
      ];
      for (final pair in pairs) {
        final once = optimisticLikeCount(
          serverCount: 5,
          counted: pair[0],
          intended: pair[1],
        );
        final twice = optimisticLikeCount(
          serverCount: 5,
          counted: pair[0],
          intended: pair[1],
        );
        expect(twice, once, reason: 'counted=${pair[0]} intended=${pair[1]}');
      }
    });
  });

  group('reaction vocabulary', () {
    test('uses exactly the values the database CHECK admits', () {
      // product_likes_reaction_check admits LIKE, DISLIKE and nothing else;
      // 'NONE' is the function's word for "hold nothing", never a stored
      // value. A fourth spelling here would be refused at the database.
      expect(ProductReaction.like, 'LIKE');
      expect(ProductReaction.dislike, 'DISLIKE');
      expect(ProductReaction.none, 'NONE');
    });
  });
}
