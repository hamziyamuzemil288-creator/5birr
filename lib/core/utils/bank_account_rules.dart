/// Bank-account rules, client mirror.
///
/// The server is the rule: migration 20261006000007 refuses any write that
/// breaks these with a trigger. This file exists so the provider is told
/// *which* rule they broke while they are still typing, instead of after a
/// round trip. Every function mirrors its SQL counterpart exactly —
/// `normalize_digits`, `text_looks_like_phone` and the banks-table
/// length/prefix checks — so a value accepted here is accepted there.

/// Digits only: Arabic-Indic (٠-٩), Extended (۰-۹) and Ethiopic (፩-፱ =>
/// 1-9) numerals converted to ASCII, every other character dropped.
String normalizeDigits(String input) {
  const ethiopic = '፩፪፫፬፭፮፯፰፱'; // 1..9 — Ethiopic has no zero glyph
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  const extended = '۰۱۲۳۴۵۶۷۸۹';
  final buffer = StringBuffer();
  for (final code in input.runes) {
    final ch = String.fromCharCode(code);
    if (arabic.contains(ch)) {
      buffer.write(arabic.indexOf(ch));
    } else if (extended.contains(ch)) {
      buffer.write(extended.indexOf(ch));
    } else if (ethiopic.contains(ch)) {
      buffer.write(ethiopic.indexOf(ch) + 1);
    } else if (code >= 0x30 && code <= 0x39) {
      buffer.write(ch);
    }
    // anything else is dropped, exactly like the SQL regexp_replace
  }
  return buffer.toString();
}

/// True when the text normalises to exactly an Ethiopian mobile number:
/// 09/07 + 8 digits or 2519/2517 + 8 digits, `+`/`00` tolerant — the shape
/// item 5 forbids in account numbers and in any text a buyer can read.
bool looksLikePhone(String? text) {
  if (text == null || text.trim().isEmpty) return false;
  var v = normalizeDigits(text);
  if (v.startsWith('00')) v = v.substring(2);
  final local = RegExp(r'^0(9|7)\d{8}$');
  final country = RegExp(r'^251(9|7)\d{8}$');
  return local.hasMatch(v) || country.hasMatch(v);
}

/// The bank-rule failure for [value], or null when it is acceptable.
/// Mirrors the trigger: digits only, length between the bank's min and max,
/// and the bank's prefix when it has one.
String? bankAccountError(
  String value, {
  required int digitMin,
  required int digitMax,
  String? prefix,
}) {
  final digits = normalizeDigits(value);
  if (digits.isEmpty) return 'Enter the account number';
  if (looksLikePhone(value)) {
    return 'That is a phone number — bank account numbers only';
  }
  if (digits.length < digitMin || digits.length > digitMax) {
    return '$digitMin–$digitMax digits required (${digits.length} found)';
  }
  if (prefix != null && prefix.isNotEmpty && !digits.startsWith(prefix)) {
    return 'Must start with $prefix';
  }
  return null;
}
