// Pins the login routing decision: which typed identifier goes to the normal
// Supabase email sign-in, and which goes to the staff gateway.
//
// The bug this prevents: an admin creates a staff member with a short
// username, the staff member types that username into the app's login screen,
// and it is rejected as "not a valid email" (or fails the credential check
// against the synthetic auth address) — the login interface never recognised
// the account the admin had just created.
import 'package:birr5/core/services/login_identity.dart';
import 'package:birr5/core/services/staff_admin_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('email identifiers use the normal sign-in', () {
    for (final id in [
      'user@example.com',
      'aymen@gmail.com',
      '  spaced@example.com  ',
      'a_b@sub.domain.org',
    ]) {
      test('"$id" -> email', () {
        expect(classifyLoginIdentifier(id), LoginIdentityKind.email);
      });
    }
  });

  group('bare usernames use the staff gateway', () {
    for (final id in [
      'aymen',
      'abc',
      'user123',
      'a.b-c_d',
      'no-at-sign.com', // legal bare staff name: dots allowed, no "@"
      'AYMEN', // case-insensitive
    ]) {
      test('"$id" -> staffUsername', () {
        expect(classifyLoginIdentifier(id), LoginIdentityKind.staffUsername);
      });
    }
  });

  test('every bare identifier the staff rule accepts is treated as staff', () {
    // The two rules must not disagree: anything the staff create-sheet would
    // accept as a *bare* username (i.e. the server would map it to the legacy
    // synthetic email) must be routed to the staff gateway, never the normal
    // email path.
    for (final id in ['aymen', 'user123', 'a.b-c_d']) {
      expect(isValidStaffUsername(id), isTrue);
      expect(classifyLoginIdentifier(id), LoginIdentityKind.staffUsername);
    }
  });

  test('email-shaped staff usernames classify as email (documented asymmetry)',
      () {
    // These are valid staff usernames AND valid emails by shape. The login
    // screen retries the staff gateway after a failed ordinary sign-in, so
    // this asymmetry is handled there rather than here.
    for (final id in ['aymen@gmail.com', 'first.last@example.co']) {
      expect(isValidStaffUsername(id), isTrue);
      expect(classifyLoginIdentifier(id), LoginIdentityKind.email);
    }
  });

  test('whitespace does not change the classification', () {
    expect(classifyLoginIdentifier('  aymen  '),
        LoginIdentityKind.staffUsername);
    expect(classifyLoginIdentifier('\tuser@example.com\n'),
        LoginIdentityKind.email);
  });

  group('staff login-gate key is always a valid, per-account email key', () {
    // login-gate rejects any key without "@" (400 invalid_email), so the
    // CAPTCHA + lockout could never cover bare staff usernames unless they
    // are normalized to the same synthetic address the gateway derives.
    test('bare usernames get the synthetic staff address', () {
      expect(staffLoginGateKey('aymen'), 'aymen@staff-gateway.invalid');
      expect(staffLoginGateKey('  Aymen  '), 'aymen@staff-gateway.invalid');
      expect(staffLoginGateKey('user123'), 'user123@staff-gateway.invalid');
    });

    test('email-shaped staff usernames pass through, lowercased', () {
      expect(staffLoginGateKey('Ayman@Example.com'),
          'ayman@example.com');
      expect(staffLoginGateKey('a.b-c_d@sub.domain.org'),
          'a.b-c_d@sub.domain.org');
    });

    test('every key is accepted shape-wise by login-gate (contains @)', () {
      for (final id in ['aymen', 'user123', 'a.b-c_d', 'u@e.com']) {
        final key = staffLoginGateKey(id);
        expect(key, contains('@'));
        expect(key, key.trim().toLowerCase()); // gate lowercases before use
      }
    });

    test('the key matches the legacy synthetic email for bare usernames', () {
      // staff_gateway_email() server-side: <name>@staff-gateway.invalid.
      // Gate/record keys must land on the SAME account bucket.
      for (final id in ['aymen', 'user123', 'a.b-c_d']) {
        expect(staffLoginGateKey(id), '$id@staff-gateway.invalid');
      }
    });
  });
}
