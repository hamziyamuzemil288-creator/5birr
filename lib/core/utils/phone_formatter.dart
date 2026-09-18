/// Phone number formatting utilities for Ethiopian numbers.
///
/// Supabase Auth requires phone numbers in E.164 format (e.g. +251918968444).
/// Ethiopian mobile numbers typically start with 09, 07, or 01 when entered
/// in local format. This utility converts them to E.164 automatically.

class PhoneFormatter {
  PhoneFormatter._();

  /// Ethiopian country code.
  static const String _countryCode = '251';

  /// Convert a local Ethiopian phone number to E.164 format.
  ///
  /// Accepts:
  ///   - `0918968444` → `+251918968444`
  ///   - `0718968444` → `+251718968444`
  ///   - `251918968444` → `+251918968444`
  ///   - `+251918968444` → `+251918968444`
  ///   - `0918 968 444` → `+251918968444`
  ///   - `918968444` → `+251918968444` (9-digit mobile without leading 0)
  ///
  /// Returns `null` if the number is invalid.
  static String? formatToE164(String input) {
    // Strip all non-digit characters
    final digits = input.replaceAll(RegExp('[^0-9]'), '');

    if (digits.isEmpty) return null;

    // 13 digits with leading 0 after country code (e.g. +2510918968444 — malformed but handle it)
    if (digits.length == 13 && digits.startsWith('2510')) {
      return '+${digits.substring(0, 3)}${digits.substring(4)}';
    }

    // Already in E.164 format (12 digits starting with 251)
    if (digits.length == 12 && digits.startsWith('251')) {
      return '+$digits';
    }

    // Local format: 10 digits starting with 0 (e.g., 0918968444)
    if (digits.length == 10 && digits.startsWith('0')) {
      return '+$_countryCode${digits.substring(1)}';
    }

    // 9-digit mobile without leading 0 (e.g., 918968444)
    if (digits.length == 9 && (digits.startsWith('9') || digits.startsWith('7') || digits.startsWith('1'))) {
      return '+$_countryCode$digits';
    }

    return null;
  }

  /// Validate that a phone number is a plausible Ethiopian number.
  ///
  /// Returns a human-readable error message, or null if valid.
  static String? validateEthiopianPhone(String input) {
    if (input.trim().isEmpty) {
      return 'Phone number is required';
    }

    final formatted = formatToE164(input);
    if (formatted == null) {
      return 'Please enter a valid Ethiopian phone number\nFormat: 09XXXXXXXX, +2519XXXXXXXX, or 2519XXXXXXXX';
    }

    // Ethiopian mobile numbers: 9x = mobile (09xx), 7x = mobile (07xx), 1x = Addis Ababa landline (01xx)
    final localNumber = formatted.substring(4); // Remove +251
    final prefix = localNumber.isNotEmpty ? localNumber.substring(0, 1) : '';

    if (prefix != '9' && prefix != '7' && prefix != '1') {
      return 'Ethiopian numbers start with 09, 07, or 01\nPlease use a valid Ethiopian phone number';
    }

    // Check length: should be 9 digits after +251
    if (localNumber.length != 9) {
      return 'Ethiopian phone numbers should be 9 digits after the country code\nExample: +251918968444';
    }

    return null;
  }
}
