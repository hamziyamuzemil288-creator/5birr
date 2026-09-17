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
  ///
  /// Returns `null` if the number is invalid.
  static String? formatToE164(String input) {
    // Strip all non-digit characters
    final digits = input.replaceAll(RegExp('[^0-9]'), '');

    if (digits.isEmpty) return null;

    // Already in E.164 format (12 digits after country code)
    if (digits.length == 12 && digits.startsWith('251')) {
      return '+$digits';
    }

    // 13 digits with leading 0 after country code — shouldn't happen but handle it
    if (digits.length == 13 && digits.startsWith('251')) {
      return '+${digits.substring(1)}';
    }

    // Local format: 10 digits starting with 0 (e.g., 0918968444)
    if (digits.length == 10 && digits.startsWith('0')) {
      return '+$_countryCode${digits.substring(1)}';
    }

    // Already has + prefix in original input and matches E.164
    if (input.trimLeft().startsWith('+') && digits.length == 12 &&
        digits.startsWith('251')) {
      return '+$digits';
    }

    return null;
  }

  /// Validate that a phone number is a plausible Ethiopian number.
  ///
  /// Returns a human-readable error message, or null if valid.
  static String? validateEthiopianPhone(String input) {
    final formatted = formatToE164(input);
    if (formatted == null) {
      return 'Enter a valid phone number (e.g. 0918968444)';
    }

    // Ethiopian mobile numbers: 09xx, 07xx after removing country code
    final localNumber = formatted.substring(4); // Remove +251
    final prefix = localNumber.substring(0, 2);

    // 09x, 07x = mobile; 01x = Addis Ababa landline
    if (prefix != '9' && prefix != '7' && prefix != '1') {
      return 'Enter a valid Ethiopian phone number';
    }

    return null;
  }
}
