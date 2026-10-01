// Regression test for the sentence a customer must never be shown.
//
// The report was: "when user try to order ride its saying that function may
// have be removed", and "1st of user is not supposed to see error txt like
// this".
//
// PGRST202 and PGRST203 mean PostgREST could not RESOLVE the call the app made:
// a misspelt parameter name, a GRANT that names a signature the function does
// not have, a migration that was never applied, or two overloads it cannot
// choose between. Every one of those is a defect on our side of the wire. Not
// one of them means a record was deleted.
//
// Both mappers had PGRST202 sitting in the "missing record" branch, so:
//
//   * friendlyError() told the user "That item could not be found. It may have
//     been removed." This is the sentence that made a fee editor's
//     `p_booking_base_fare` typo read as a deleted category (ARCHITECTURE
//     §7.1.6), and it is the same sentence a rider would read for a ride that
//     could not be created;
//   * isNotFound() returned true, so detail screens rendered their not-found
//     state — "Ride not found" for a ride that was never made;
//   * failure_mapper.dart did the same in two places.
//
// A test for this is only worth having if it fails when the bug comes back, so
// the guard is on the WORDS: no unresolvable-call error may produce a message
// containing "removed", "not found", or "does not exist", and none may satisfy
// isNotFound().
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/resilience/failure_mapper.dart';
import 'package:birr5/core/utils/friendly_error.dart';

/// The real PostgREST bodies. PGRST202 with a function name is what the server
/// sends when an argument name does not match; the bare-code form is what a
/// client that only sees `code:` sends.
const _unresolvable = <String, Object>{
  'PGRST202 named function': '''
PostgrestException(code: PGRST202, message: Could not find the function
public.create_ride_request(pickup_lat, pickup_lng) in the schema cache.
Details: Key error: create_ride_request)''',

  'PGRST202 misspelt parameter': '''
PostgrestException(code: PGRST202, message: Could not find the function
public.admin_save_category_fee(p_category_id, p_booking_base_fare) in the
schema cache.)''',

  'PGRST202 bare code': 'PostgrestException(code: PGRST202)',

  'PGRST203 ambiguous overload': '''
PostgrestException(code: PGRST203, message: Could not choose the best
candidate function for public.search_products. In schema cache: 2)''',

  'PGRST202 lowercased body': '{"code":"pgrst202","message":"could not find '
      'the function public.create_order_secure in the schema cache"}',
};

/// The genuine missing-record cases, which MUST keep saying so. Without these
/// the fix could be "stop reporting missing records at all", which would be a
/// regression in the other direction.
const _genuinelyMissing = <String, Object>{
  'PGRST116 no rows': '''
PostgrestException(code: PGRST116, message: JSON object requested, multiple
(or no) rows returned)''',
  '404': 'HttpException: 404 Not Found',
};

/// Words that blame the user's data for a defect on our side of the wire.
const _blamingWords = <String>[
  'removed',
  'not found',
  'does not exist',
  'no longer',
];

void main() {
  group('an unresolvable call is never reported as a missing record', () {
    _unresolvable.forEach((name, error) {
      test('friendlyError: $name', () {
        final message = friendlyError(error).toLowerCase();
        for (final word in _blamingWords) {
          expect(message, isNot(contains(word)),
              reason: 'PGRST202/203 is a defect on our side of the wire, but '
                  'the user was told it contained "$word": ${friendlyError(error)}');
        }
      });

      test('isNotFound: $name', () {
        expect(isNotFound(error), isFalse,
            reason: 'rendering a not-found screen for an unresolvable call '
                'tells the user their ride or product does not exist, when '
                'the request never got as far as asking');
      });

      test('failure_mapper: $name', () {
        final failure = AppFailureMapper.map(error);
        final message = failure.message.toLowerCase();
        for (final word in _blamingWords) {
          expect(message, isNot(contains(word)),
              reason: 'failure_mapper produced a blaming sentence for an '
                  'unresolvable call: ${failure.message}');
        }
      });
    });
  });

  group('a genuinely missing record still says so', () {
    _genuinelyMissing.forEach((name, error) {
      test('friendlyError: $name', () {
        // The fix must not become "stop saying a record is missing".
        expect(friendlyError(error).toLowerCase(), contains('may have been removed'),
            reason: 'a real missing row must still be reported as missing');
      });

      test('isNotFound: $name', () {
        expect(isNotFound(error), isTrue);
      });
    });
  });

  group('the sentence names our side, not the user\'s data', () {
    test('it tells the user to retry and offers support', () {
      final message = friendlyError(_unresolvable['PGRST202 named function']!)
          .toLowerCase();
      expect(message, contains('try again'));
      expect(message, contains('support'));
    });
  });
}
