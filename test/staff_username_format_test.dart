// Pins the staff username rule to exactly what the server accepts.
//
// The rule lives in three places that MUST agree: the Dart mirror
// (kStaffUsernamePattern), the edge functions
// (supabase/functions/_shared/staff_identity.ts) and the CHECK constraint on
// public.staff_credentials (migration 20260925160000). When these drift, the
// create sheet accepts something the gateway rejects — or worse, the gateway
// accepts a username the CHECK refuses, and staff creation 500s.
//
// The load-bearing compatibility guarantee is that BARE names keep working:
// staff created before the email format existed are already in the table, and
// the gateway maps that shape to the original synthetic auth email, so they
// log in unchanged with no password reset.
import 'package:birr5/core/services/staff_admin_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('legacy bare-name usernames (must keep working)', () {
    for (final u in [
      'aymen',
      'abc', // minimum length is 3
      'a.b',
      'a_b',
      'a-b',
      'user123',
      'a' * 32, // maximum length is 32
      // A dotted string with no "@" is a legal bare name — dots have always
      // been allowed, so this is NOT an email and must keep validating.
      'no-at-sign.com',
    ]) {
      test('accepts "$u"', () => expect(isValidStaffUsername(u), isTrue));
    }
  });

  group('email usernames (the new format)', () {
    for (final u in [
      'user@gmail.com',
      'aymen@gmail.com',
      'first.last@example.co',
      'a_b@sub.domain.org',
      'staff+tag@example.com',
    ]) {
      test('accepts "$u"', () => expect(isValidStaffUsername(u), isTrue));
    }
  });

  group('rejects malformed input', () {
    for (final u in [
      '', // empty
      'a', // below the 3-char minimum for the bare form
      'ab', // one below the 3-char minimum
      'a' * 33, // too long in the bare form
      '-leading', // bare form must start alphanumeric
      '.leading',
      'user@', // no domain
      'user@localhost', // no dotted domain
      '@gmail.com', // no local part
      'us er@gmail.com', // space
      'a@b@c.com', // two @s
    ]) {
      test('rejects "$u"', () => expect(isValidStaffUsername(u), isFalse));
    }
  });

  test('is case-insensitive, matching the lower(username) unique index', () {
    expect(isValidStaffUsername('AYMEN'), isTrue);
    expect(isValidStaffUsername('User@Gmail.com'), isTrue);
  });
}
