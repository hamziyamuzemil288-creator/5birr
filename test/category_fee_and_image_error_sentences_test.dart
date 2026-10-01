// The sentences an administrator sees when the fee editor or the image
// moderation section refuses something.
//
// These exist because of one specific failure. `admin_save_category_fee` set a
// column that does not exist, so EVERY save died with a 42703. The refusal the
// user was shown for it was "That item could not be found. It may have been
// removed." -- which is false on all three counts: nothing was removed, the fee
// settings table was never touched, and the cause was a typo in a migration.
//
// The rule this file pins: a refusal that is OUR fault must never be phrased as
// "your record is gone", and a refusal that really does mean a record is absent
// must keep saying so. Fixing the first without protecting the second is a
// regression in the other direction, so both directions are asserted.
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/utils/friendly_error.dart';

/// The exact text 0107 produced on every single save.
const _theRealFailure =
    '42703: column "booking_base_fare" of relation "category_fee_settings" '
    'does not exist';

void main() {
  group('a broken function is never reported as a removed record', () {
    test('the 42703 that broke the fee editor says nothing about removal', () {
      final message = friendlyError(_theRealFailure,
          context: 'Could not save these fees').toLowerCase();
      expect(message, isNot(contains('may have been removed')));
      expect(message, isNot(contains('could not be found')));
      expect(message, contains('our side'));
    });

    test('the SQLSTATE alone is enough, without the column name', () {
      // PostgREST does not always put the SQLSTATE in the string the client
      // stringifies, so both the code and the message shape have to match.
      final message = friendlyError('42703', context: 'Could not save').toLowerCase();
      expect(message, isNot(contains('may have been removed')));
      expect(message, contains('our side'));
    });

    test('CATEGORY_NOT_FOUND is not "this section has been removed"', () {
      // The literal string the report quoted. CATEGORY_NOT_FOUND contains the
      // substring "not found", which is why it reached the wrong branch.
      final message = friendlyError(
              'CATEGORY_NOT_FOUND', context: 'Could not save these fees')
          .toLowerCase();
      expect(message, isNot(contains('may have been removed')));
      expect(message, contains('category'));
    });

    test('the sentence says what to do about it', () {
      final message = friendlyError('CATEGORY_NOT_FOUND', context: 'Save');
      expect(message, contains('Reload'));
    });
  });

  group('the fee editor explains its own refusals', () {
    test('a non-owner is told they are not the owner, not that it vanished', () {
      final message = friendlyError('ONLY_THE_OWNER_CAN_CHANGE_FEES',
              context: 'Could not save these fees')
          .toLowerCase();
      expect(message, contains('account owner'));
      expect(message, isNot(contains('removed')));
    });

    test('a city name the server refused is named as the problem', () {
      final message = friendlyError('CITY_NAME_IS_NOT_A_CITY_NAME',
          context: 'Save');
      expect(message, contains('city'));
    });

    test('a missing reason says so, instead of failing silently', () {
      expect(friendlyError('A_REASON_IS_REQUIRED', context: 'Hide'),
          contains('reason'));
    });
  });

  group('a genuinely missing record still says so -- in BOTH directions', () {
    // The regression this file has to guard against is over-correcting: if
    // every server error started reading as "a problem on our side", a genuine
    // missing record would stop being reported as one.
    test('PGRST116 is still a missing record', () {
      final message = friendlyError(
              'PGRST116: JSON object requested, multiple (or no) rows returned',
              context: 'Could not load')
          .toLowerCase();
      expect(message, contains('may have been removed'));
    });

    test('a 404 is still a missing record', () {
      expect(friendlyError('404', context: 'Could not load'),
          contains('may have been removed'));
    });

    test('isNotFound() is still true for those two', () {
      expect(isNotFound('PGRST116: no rows returned'), isTrue);
      expect(isNotFound('404'), isTrue);
    });

    test('a bare "not found" IS a missing record', () {
      // Without this, removing the 'not found' arm from isNotFound() entirely
      // keeps every other test green -- which is exactly what happened: the
      // arm was dropped by accident, and only a direct assertion caught it.
      expect(isNotFound('that item was not found'), isTrue);
      expect(isNotFound('NOT FOUND'), isTrue);
    });

    test('CATEGORY_NOT_FOUND needs no exclusion list, and here is why', () {
      // The sentinel is CATEGORY_NOT_FOUND with an UNDERSCORE; the arm matches
      // 'not found' with a SPACE. An exclusion list was written on the
      // assumption that it matched, and its own mutation run proved the list
      // was dead code. This pins the reason so it is not written again.
      expect(isNotFound('CATEGORY_NOT_FOUND'), isFalse);
      expect(friendlyError('CATEGORY_NOT_FOUND', context: 'Save').toLowerCase(),
          isNot(contains('may have been removed')));
    });

    test('isNotFound() is false for the fee-editor refusals', () {
      // If these returned true, a detail screen would render its "not found"
      // state -- the exact failure §7.1.8 removed.
      expect(isNotFound(_theRealFailure), isFalse);
      expect(isNotFound('PGRST202'), isFalse);
      expect(isNotFound('ONLY_THE_OWNER_CAN_CHANGE_FEES'), isFalse);
      expect(isNotFound('ONLY_THE_OWNER_CAN_CHANGE_FEES'), isFalse);
    });
  });

  group('the same refusals read differently per context', () {
    test('the prefix still leads the sentence', () {
      // Otherwise the user is told "Please fill in all the required fields"
      // with no idea what they were filling in.
      final message = friendlyError('23502', context: 'Could not add photos');
      expect(message, startsWith('Could not add photos.'));
    });
  });
}