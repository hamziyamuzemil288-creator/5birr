import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Server-side password rule (staff-create-gateway): 10..200 characters.
const int kStaffPasswordMinLength = 10;
const int kStaffPasswordMaxLength = 200;

/// Server-side username rule (staff-create-gateway + staff-login + the
/// staff_credentials CHECK constraint). A username is EITHER the original
/// bare form — 3–32 chars, lowercase letters/digits with . _ - inside,
/// starting alphanumeric — OR an email address.
///
/// Both forms are accepted because the account's real login identity is an
/// email everywhere else in the product, and a staff username that cannot
/// look like an email is confusing. Bare names keep working unchanged: the
/// gateway maps that shape to the original synthetic email, so staff created
/// before this rule are unaffected.
///
/// Keep in lockstep with supabase/functions/_shared/staff_identity.ts. This
/// is a client-side convenience only — the server re-validates.
final RegExp kStaffUsernamePattern =
    RegExp(r'^([a-z0-9][a-z0-9._-]{2,31}|[^\s@]+@[^\s@]+\.[^\s@]{2,})$');

/// True when [value] is an acceptable staff username (see
/// [kStaffUsernamePattern]).
bool isValidStaffUsername(String value) =>
    kStaffUsernamePattern.hasMatch(value.trim().toLowerCase());

/// Human-readable form of the [kStaffUsernamePattern] rule, used by the
/// create-sheet and login validators so both screens say the same thing.
const String kStaffUsernameHint =
    'Use an email address, or 3–32 letters, numbers, dots, underscores, or hyphens';

/// Staff ID rule. `staff.staff_code` is `text NOT NULL UNIQUE` and the gateway
/// rejects anything outside 2–60 characters before it reaches the database
/// (staff-create-gateway: `invalid_staff_details`).
const int kStaffCodeMinLength = 2;
const int kStaffCodeMaxLength = 60;

/// True when [value] is an acceptable staff ID (see [kStaffCodeMinLength]).
/// Pure so the create sheet can share the exact rule with the server.
bool isValidStaffCode(String value) {
  final length = value.trim().length;
  return length >= kStaffCodeMinLength && length <= kStaffCodeMaxLength;
}

/// The staff row that already owns [code], or null when the ID is free.
///
/// WHY THIS EXISTS
/// ---------------
/// Both create paths (the staff-create-gateway edge function and the
/// create_staff RPC) write straight into the `staff_staff_code_key` unique
/// index with no pre-check, so reusing a Staff ID failed server-side with a
/// raw `duplicate key value violates unique constraint` message. The admin
/// staff screen already loads the whole staff directory, so the collision can
/// be caught on the form for free.
///
/// The comparison is trimmed and case-SENSITIVE on purpose: the index is a
/// plain `text UNIQUE`, so `10000` and `Abc` are genuinely different IDs and
/// warning about them would block a legitimate create. Editing a row keeps its
/// own code — pass its `id` as [editingId] to leave it out of the comparison.
Map<String, dynamic>? findStaffCodeConflict(
  List<Map<String, dynamic>> staff, {
  required String code,
  String? editingId,
}) {
  final wanted = code.trim();
  if (wanted.isEmpty) return null;
  for (final row in staff) {
    if (editingId != null && row['id']?.toString() == editingId) continue;
    if ((row['staff_code']?.toString() ?? '').trim() == wanted) return row;
  }
  return null;
}

/// Says who already holds [code], so the operator does not have to guess
/// which of their test Staff IDs collided.
String kStaffCodeTakenHint(String code, String? ownerName) {
  final who = (ownerName ?? '').trim();
  return 'Staff ID ${code.trim()} is already used'
      '${who.isEmpty ? '' : ' by $who'}. Choose a different one.';
}

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
      throw Exception(describeError(data));
    }
  }

  /// Turns a gateway error body into the message the operator sees.
  ///
  /// Public and static so the mapping is unit-testable without a live
  /// Supabase client. The gateway appends a `detail` field carrying the
  /// server-side reason on its 5xx responses; appending it here means a
  /// failure names its own cause instead of requiring the operator to pull
  /// the Edge Function logs out of the Dashboard.
  @visibleForTesting
  static String describeError(Map<dynamic, dynamic> data) {
    final message = _friendlyStaffError(
      data['error']?.toString() ?? 'staff_gateway_creation_failed',
    );
    final detail = data['detail']?.toString().trim();
    if (detail == null || detail.isEmpty) return message;
    return '$message [$detail]';
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
        return 'Could not create the staff account. Please try again; if it '
            'keeps failing, contact technical support — the account system '
            'rejected the creation.';
      case 'staff_gateway_setup_failed':
        return 'The staff account was created but linking it failed. Please '
            'try again with a different staff ID.';
      case 'staff_auth_identity_mismatch':
        return 'The staff account was created but its identity could not be '
            'linked (identity mismatch). This is a backend linkage defect, '
            'not a problem with your input — please report it.';
      case 'staff_gateway_domain_not_allowed':
        return 'The gateway refused to authorise the account address. This '
            'needs a backend fix — please report it.';
      case 'invalid_staff_branch':
        return 'That branch is not recognised. Choose a different branch.';
      case 'staff_email_already_exists':
        return 'That username is already registered. Choose a different one.';
      case 'staff_username_taken':
        return 'That username is already taken. Choose a different one.';
      case 'staff_code_taken':
        return 'That Staff ID is already in use. Choose a different one.';
      case 'super_admin_already_exists':
        return 'A super admin already exists. Only one is allowed.';
      case 'staff_gateway_trigger_rejected':
        return 'The account system is refusing staff creation (trigger '
            'mismatch). This needs a backend fix — please report it.';
      default:
        return 'Could not create the staff account ($code).';
    }
  }
}
