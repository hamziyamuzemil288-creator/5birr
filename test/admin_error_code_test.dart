// The refusal code an ADMIN sees, next to the sentence everyone sees.
//
// Item 2 asked for exactly this: "Show the real error code to admins." The
// content-control and image-moderation surfaces used to swallow it — a
// moderator whose Hide tap came back NO_SUCH_IMAGE was shown a generic
// "Something went wrong", with nothing to tell support. End users must keep
// the plain sentence (a code tells a buyer nothing), so this file pins both
// directions: the code is present on the admin path and absent from the
// user one.
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/utils/friendly_error.dart';

/// The exact shape Supabase's PostgrestException stringifies to.
const _envelope =
    'PostgrestException(message: NO_SUCH_IMAGE, code: P0001, '
    'details: null, hint: null)';

void main() {
  group('errorCodeOf digs the real refusal out of the exception', () {
    test('a PostgrestException envelope yields the app code and the SQLSTATE',
        () {
      final code = errorCodeOf(_envelope);
      expect(code, isNotNull);
      expect(code, contains('NO_SUCH_IMAGE'));
      expect(code, contains('P0001'));
    });

    test('the SQLSTATE in front of a message survives on its own', () {
      expect(errorCodeOf('42703: column "booking_base_fare" does not exist'),
          contains('42703'));
    });

    test('a bare server sentinel yields itself', () {
      expect(errorCodeOf('ADMIN_ONLY'), contains('ADMIN_ONLY'));
      expect(errorCodeOf('A_REASON_IS_REQUIRED'),
          contains('A_REASON_IS_REQUIRED'));
    });

    test('an error with no code yields null, never an invented one', () {
      expect(errorCodeOf('network is unreachable'), isNull);
      expect(errorCodeOf(SocketishFailure()), isNull);
    });
  });

  group('friendlyErrorWithCode is the admin sentence', () {
    test('it keeps the friendly sentence and appends the real code', () {
      final shown =
          friendlyErrorWithCode(_envelope, context: 'Could not hide this');
      expect(shown, contains('['));
      expect(shown, contains('NO_SUCH_IMAGE'));
      // Still a sentence, not a raw dump.
      expect(shown.toLowerCase(), contains('could not hide this'));
    });

    test('with no code it degrades to the plain sentence, no dangling [',
        () {
      final shown = friendlyErrorWithCode('network is unreachable');
      expect(shown, isNot(contains('[')));
      expect(shown, friendlyError('network is unreachable'));
    });
  });

  group('end users never see a code', () {
    test('friendlyError itself carries no bracketed code', () {
      final message = friendlyError(_envelope, context: 'Could not load');
      expect(message, isNot(contains('P0001')));
      expect(message, isNot(contains('NO_SUCH_IMAGE')));
    });
  });
}

/// A thrown object whose toString() is pure prose — the transport failures.
class SocketishFailure {
  @override
  String toString() => 'Connection closed before full header was received';
}
