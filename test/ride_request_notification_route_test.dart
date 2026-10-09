// The ride request must notify through the queue, and the code that says so
// must not be confused with the comment that says so.
//
// The failure this test exists to catch is the one that turned Connectivity CI
// red on Release 1.7.5+112 (#213):
//
//   PostgrestException(message: the ride path bypasses the notification queue:
//     create_ride_request calls insert_notification() directly ... code: P0001)
//
// Nothing was wrong with the ride path. 20261008000001 had moved both call
// sites onto `notify_user_safe()` / `notify_user()`, and the body comment says
// as much -- by naming the helper that was removed. The assertion that same
// migration added scanned `pg_proc.prosrc`, which carries COMMENTS, so it
// matched the explanation and raised. A body that only *mentions* a forbidden
// pattern in prose read exactly like one that contains it.
//
// So this file checks two separate things against the migrations themselves:
//
//   1. the ride-request path does not write notifications directly (the defect
//      the live assertion exists to find), and
//   2. the rule used to decide that reads code, not comments.
//
// It runs on push, before any deploy, which the live assertion cannot: that one
// only moves after a Supabase deploy, and until then a restatement is invisible
// to it. The same trap is pinned the SQL way in
// tools/harness/restated_body_diff.py (the FIXES entry for this function).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The functions that carry the ride request and its driver fan-out. Both are
/// called from the rider's own client path, so a direct notification write in
/// either one is the defect.
const rideNotificationFunctions = <String>[
  'create_ride_request',
  'notify_best_effort',
];

/// The spellings that bypass the queue. `insert_notification()` is the older
/// helper; a hand-written INSERT is the same bypass. Kept in step with the
/// live assertion's three ILIKE patterns by the tests below.
const directWriteSpellings = <String>[
  'insert_notification',
  'insert into notifications',
  'insert into public.notifications',
];

/// Every migration file, in deploy order (the filenames are fixed-width
/// timestamps, so a lexicographic sort is the deploy order).
List<File> migrationFiles() {
  final dir = Directory('supabase/migrations');
  if (!dir.existsSync()) {
    fail('supabase/migrations not found — run this test from the package root');
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.sql'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files;
}

/// The body of the LATEST definition of `public.<name>` across all migrations —
/// what is actually live after a full deploy, not the first draft of it.
String latestFunctionBody(String name) {
  final pattern = RegExp(
    r'create\s+or\s+replace\s+function\s+public\.' + name + r'\b',
    caseSensitive: false,
  );
  String? found;
  for (final f in migrationFiles()) {
    final text = f.readAsStringSync();
    for (final m in pattern.allMatches(text)) {
      final end = text.indexOf(r'$$;', m.start);
      if (end == -1) continue;
      found = text.substring(m.start, end);
    }
  }
  if (found == null) {
    fail('no definition of public.$name in any migration');
  }
  return found;
}

/// The SQL the server actually runs, with its comments removed: line comments
/// (`--` to end of line, outside a string literal) and block comments
/// (`/* ... */`), then whitespace collapsed.
///
/// This mirrors the rule in `assert_ride_create_notifies_through_the_queue()`.
/// It is written out rather than regexed in one pass because `--` inside a
/// string literal is data, not a comment -- and the fix's own `E'--[^\n]*'`
/// literal is exactly that case.
String stripSqlComments(String sql) {
  final out = StringBuffer();
  var i = 0;
  var quote = false;
  while (i < sql.length) {
    final ch = sql[i];
    if (quote) {
      out.write(ch);
      if (ch == "'") {
        // A doubled quote is an escaped quote, not the end of the literal.
        if (i + 1 < sql.length && sql[i + 1] == "'") {
          out.write("'");
          i += 2;
          continue;
        }
        quote = false;
      }
      i++;
      continue;
    }
    if (ch == "'") {
      quote = true;
      out.write(ch);
      i++;
      continue;
    }
    if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final end = sql.indexOf('\n', i);
      if (end == -1) break;
      i = end;
      continue;
    }
    if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*') {
      final end = sql.indexOf('*/', i + 2);
      if (end == -1) break;
      out.write(' ');
      i = end + 2;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

String codeOf(String functionName) => stripSqlComments(latestFunctionBody(functionName));

void main() {
  test('the stripper removes prose and keeps code', () {
    // Proven on a known string rather than on the live file, so the test keeps
    // its meaning even after someone rewords the comment that caused this.
    const sample = '''
-- NOT insert_notification(): the direct call was removed
PERFORM public.notify_user_safe('ride-request:1', p_user_id);
/* insert into public.notifications */
INSERT INTO ride_requests (user_id) VALUES (p_user_id);
''';
    // Lowercased only in this test: the SQL keeps its own casing, and the
    // assertions below are written the way the live ILIKE patterns are.
    final code = stripSqlComments(sample).toLowerCase();

    expect(code, isNot(contains('insert_notification')),
        reason: 'a comment naming the forbidden helper was kept as code');
    expect(code, isNot(contains('insert into public.notifications')),
        reason: 'a block comment naming a direct insert was kept as code');
    expect(code, contains('notify_user_safe'),
        reason: 'the stripper ate real code along with the comments');
    expect(code, contains('insert into ride_requests'),
        reason: 'the stripper mangled a string or a real statement');
  });

  for (final name in rideNotificationFunctions) {
    test('$name does not write notifications directly', () {
      final code = codeOf(name);

      for (final spelling in directWriteSpellings) {
        expect(
          code.contains(spelling),
          isFalse,
          reason: '$name contains "$spelling" in code. Both functions run on '
              'a rider\'s own client call, where the notification guard raises '
              'and the ride row is rolled back before it is ever visible to a '
              'driver — or, inside notify_best_effort\'s own swallow, is lost '
              'with nobody told. It must route through notify_user()/'
              'notify_user_safe().',
        );
      }

      expect(
        code.contains('notify_user'),
        isTrue,
        reason: '$name no longer routes its notice through notify_user(), so '
            'the queue-aware path is gone and the client path writes into '
            'notifications directly.',
      );
    });
  }

  test('an apostrophe in a comment does not swallow the code after it', () {
    // The scanner's other edge: a `'` inside a comment. Treated as an opening
    // string literal it eats everything up to the next quote, which for a
    // comment ending in "rider's" is the rest of the body.
    const sample = '''
-- the rider's own call must not write directly
PERFORM public.notify_user_safe('ride-request:1', p_user_id);
''';
    expect(stripSqlComments(sample), contains('notify_user_safe'));
  });

  test('the assertion that guards this reads code, not comments', () {
    final assertion =
        latestFunctionBody('assert_ride_create_notifies_through_the_queue');

    // It must strip comments before matching...
    expect(assertion, contains(r"E'--[^\n]*'"),
        reason: 'the guard matches raw prosrc, which carries comments: a body '
            'that explains why a direct call was removed reads like one that '
            'makes it, and the check raises on its own explanation.');
    expect(assertion, contains(r"'/\*.*?\*/'"),
        reason: 'block comments are not stripped, so prose inside one can '
            'still decide the outcome');
    // ...and it must not go back to the raw read.
    expect(assertion.contains('SELECT prosrc INTO'), isFalse,
        reason: 'the guard is reading prosrc without stripping comments again');
    // ...and it must still look for all three spellings.
    for (final spelling in directWriteSpellings) {
      expect(assertion.contains(spelling), isTrue,
          reason: 'the guard stopped checking for "$spelling"');
    }
  });
}
