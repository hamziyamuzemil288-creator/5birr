// Pins the staff-create-gateway error mapping the operator actually sees.
//
// WHY THIS EXISTS
// ---------------
// Every failure the gateway's error switch did not recognise collapsed into
// one message — "The staff account was created but linking it failed" — while
// the real cause went only to the server console. STAFF_AUTH_IDENTITY_MISMATCH
// was the most likely cause and the least visible, which is what made the
// live failure undiagnosable from the app. These tests fail if a raise ever
// goes back to hiding behind the generic code, or if the server detail stops
// reaching the message.
import 'package:birr5/core/services/staff_admin_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('previously-hidden raises now name their own cause', () {
    test('identity mismatch is not reported as a generic linking failure', () {
      final message = StaffAdminService.describeError({
        'error': 'staff_auth_identity_mismatch',
      });
      expect(message, contains('identity mismatch'));
      expect(message, isNot(contains('different staff ID')));
    });

    test('an unrecognised branch is reported as a branch problem', () {
      final message = StaffAdminService.describeError({
        'error': 'invalid_staff_branch',
      });
      expect(message, contains('branch'));
    });

    test('a refused gateway domain is reported as a backend defect', () {
      final message = StaffAdminService.describeError({
        'error': 'staff_gateway_domain_not_allowed',
      });
      expect(message, contains('backend fix'));
    });
  });

  group('already-mapped codes keep their messages', () {
    test('username taken', () {
      expect(
        StaffAdminService.describeError({'error': 'staff_username_taken'}),
        contains('already taken'),
      );
    });

    test('super admin exists', () {
      expect(
        StaffAdminService.describeError({
          'error': 'super_admin_already_exists',
        }),
        contains('super admin'),
      );
    });

    test('only the CEO may create staff', () {
      expect(
        StaffAdminService.describeError({
          'error': 'only_ceo_can_create_staff_gateway',
        }),
        contains('CEO'),
      );
    });

    test('the generic code is still reachable for an unknown failure', () {
      expect(
        StaffAdminService.describeError({'error': 'staff_gateway_setup_failed'}),
        contains('linking it failed'),
      );
    });

    test('a body with no error code does not produce an empty message', () {
      final message = StaffAdminService.describeError(const {});
      expect(message, isNotEmpty);
      expect(message, contains('staff_gateway_creation_failed'));
    });
  });

  group('server detail reaches the operator', () {
    test('detail is appended so the app names the cause itself', () {
      final message = StaffAdminService.describeError({
        'error': 'staff_auth_identity_mismatch',
        'detail': 'ERROR:  STAFF_AUTH_IDENTITY_MISMATCH',
      });
      expect(message, contains('identity mismatch'));
      expect(message, contains('[ERROR:  STAFF_AUTH_IDENTITY_MISMATCH]'));
    });

    test('a blank or absent detail does not leave empty brackets', () {
      expect(
        StaffAdminService.describeError({
          'error': 'staff_username_taken',
          'detail': '   ',
        }),
        isNot(contains('[]')),
      );
      expect(
        StaffAdminService.describeError({
          'error': 'staff_username_taken',
        }),
        isNot(contains('[')),
      );
    });

    test('a non-string detail is coerced rather than crashing', () {
      final message = StaffAdminService.describeError({
        'error': 'staff_gateway_setup_failed',
        'detail': 42,
      });
      expect(message, contains('[42]'));
    });
  });
}
