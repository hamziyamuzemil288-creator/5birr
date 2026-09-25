import 'package:supabase_flutter/supabase_flutter.dart';

/// Server-side password rule (staff-create-gateway): 10..200 characters.
const int kStaffPasswordMinLength = 10;
const int kStaffPasswordMaxLength = 200;

/// Server-side username rule (staff-create-gateway): 3–32 chars,
/// lowercase letters/digits with . _ - inside, starting alphanumeric.
final RegExp kStaffUsernamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{2,31}$');

class StaffAdminService {
  const StaffAdminService();

  Future<void> createGateway({
    required String name,
    required String staffCode,
    required String username,
    required String password,
    required String confirmPassword,
    required List<String> permissions,
    required double salesTarget,
    required bool isSuperAdmin,
    required String branch,
    required List<String> assignedCategories,
  }) async {
    final response = await Supabase.instance.client.functions.invoke(
      'staff-create-gateway',
      body: {
        'name': name,
        'staff_code': staffCode,
        'username': username,
        'password': password,
        'confirm_password': confirmPassword,
        'permissions': permissions,
        'sales_target': salesTarget,
        'is_super_admin': isSuperAdmin,
        'branch': branch,
        'assigned_categories': assignedCategories,
      },
    );
    if (response.status != 201) {
      final data = response.data is Map ? response.data as Map : const {};
      throw Exception(_friendlyStaffError(
        data['error']?.toString() ?? 'staff_gateway_creation_failed',
      ));
    }
  }

  /// Maps the gateway's stable error codes to operator-readable messages.
  /// The form validates the same rules before submit; this is the net for
  /// anything that still slips through (or a race with the server rules).
  static String _friendlyStaffError(String code) {
    switch (code) {
      case 'password_must_be_10_to_200_characters':
        return 'Password must be between $kStaffPasswordMinLength and '
            '$kStaffPasswordMaxLength characters.';
      case 'passwords_do_not_match':
        return 'The passwords do not match.';
      case 'invalid_username':
        return 'Username must be 3–32 characters: lowercase letters or '
            'digits, with dots, underscores or dashes inside.';
      case 'invalid_staff_details':
        return 'Name must be 2–100 characters and staff ID 2–60 characters.';
      case 'invalid_sales_target':
        return 'Sales target must be zero or a positive number.';
      case 'only_ceo_can_create_staff_gateway':
        return 'Only the CEO can create staff gateway credentials.';
      case 'unauthorized':
        return 'Your session expired. Please sign in again.';
      case 'staff_account_creation_failed':
      case 'staff_gateway_setup_failed':
        return 'Could not create the staff account. Please try again; if it '
            'keeps failing, the username may already be taken.';
      default:
        return 'Could not create the staff account ($code).';
    }
  }
}
