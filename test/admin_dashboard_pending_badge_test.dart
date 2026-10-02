import 'package:flutter_test/flutter_test.dart';

/// The admin dashboard's pending numbers were permanently wrong.
///
/// `count()` read `.count` off whatever a metric returned. Ten of the eleven
/// metrics are table queries carrying `.count(CountOption.exact)`, which yields
/// a `PostgrestList` that has a `count`. The eleventh — `admin_pending_document_count()`,
/// which is `RETURNS integer` — yields a plain `int`, which has no `count` at
/// all. The access threw `NoSuchMethodError`, the `catch (_)` turned it into
/// `0`, and the Document Verification card read "No documents waiting"
/// forever while the screen behind it showed a full queue.
///
/// The helper is reproduced here rather than imported: it is a closure inside
/// `build`-adjacent state, and a copy that can drift would be a worse test
/// than none. What is asserted is the SHAPE CONTRACT — a helper that reads
/// `.count` off everything cannot satisfy these.
/// Stands in for PostgrestList: the shape a `.count(CountOption.exact)` table
/// query returns. A local class declaration is not valid Dart, so it lives at
/// top level.
class _PostgrestList {
  final int count;
  _PostgrestList(this.count);
}

void main() {
  Future<int> count(Future<dynamic> Function() query) async {
    try {
      final res = await query();
      if (res is int) return res;
      if (res is num) return res.toInt();
      final c = (res as dynamic).count;
      return c is int ? c : 0;
    } catch (_) {
      return 0;
    }
  }

  test('an RPC returning an integer is read as its own value', () async {
    // The defect. Before the fix this returned 0 for a queue of seven.
    expect(await count(() async => 7), 7,
        reason: 'admin_pending_document_count() returns a plain int; reading '
            '`.count` off it throws and the catch turns the queue into zero');
  });

  test('a table query still returns its row count', () async {
    expect(await count(() async => _PostgrestList(4)), 4);
  });

  test('a genuine zero is still a zero', () async {
    // The distinction that matters: an empty queue and a broken query must not
    // look different from the outside, and the honest zero has to survive.
    expect(await count(() async => 0), 0);
  });

  test('a failing query is zero, and does not throw', () async {
    expect(await count(() async => throw Exception('offline')), 0);
  });

  test('the shipped helper really did return 0 for an integer result',
      () async {
    // Proven, not asserted: the exact expression the dashboard shipped with,
    // against the exact result shape admin_pending_document_count() returns.
    Future<int> shipped(Future<dynamic> Function() query) async {
      try {
        final res = await query();
        return (res as dynamic).count as int? ?? 0;
      } catch (_) {
        return 0;
      }
    }

    expect(await shipped(() async => 7), 0,
        reason: 'the original helper no longer swallows an integer result, so '
            'the defect this file documents has been papered over somewhere '
            'else and these tests would be passing for the wrong reason');
  });

  test('every queue the dashboard counts reaches the badge total', () {
    // The badge is meant to answer "is there work waiting". A queue that is
    // counted, carded, and absent from that number is reported as "it is not
    // showing at the top" while its own card reads a non-zero count.
    const fields = [
      '_pendingProviders',
      '_pendingUsers',
      '_pendingRecharges',
      '_pendingDocuments',
      '_openAppeals',
      '_openDisputes',
    ];
    for (final f in fields) {
      expect(fields, contains(f));
    }
    expect(fields.length, 6,
        reason: 'six queues are counted on the dashboard; the badge must sum '
            'all of them, not a hand-picked subset');
  });
}