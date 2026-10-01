/// Render one declared provider field for display.
///
/// Public and top-level so it can be unit-tested directly, in the same spirit
/// as `rankLocationLessLast` in the search screen: a formatting rule that a
/// customer reads is worth a test, and a private method inside a State cannot
/// have one.
///
/// The value arrives in ONE of three columns, chosen by the field's declared
/// input type on the server (`save_provider_profile_field`). So this reads
/// them in the order a person would: a real boolean first, then a number, then
/// text.
///
/// Two rules that are not cosmetic:
///
///   * a boolean renders as Yes / No, never as `true` / `false`. "true" is a
///     database value, not an answer, and a page that shows it reads as a
///     system message;
///   * a whole number renders WITHOUT a trailing `.00`. A price shown as
///     "500.00 ETB / night" is a different claim from "500 ETB / night", and
///     the provider typed the second one.
///
/// A null `unitLabel` means the field is a bare number (seats, years) and gets
/// no suffix at all -- an empty unit must not leave a trailing space.
String categoryFieldValue({
  String? valueText,
  num? valueNumber,
  bool? valueBoolean,
  String? unitLabel,
}) {
  if (valueBoolean != null) return valueBoolean ? 'Yes' : 'No';

  if (valueNumber != null) {
    final text = _trimNumber(valueNumber);
    final unit = (unitLabel ?? '').trim();
    return unit.isEmpty ? text : '$text $unit';
  }

  final text = (valueText ?? '').trim();
  final unit = (unitLabel ?? '').trim();
  // A text field with a unit keeps it; a text field without one is returned
  // as typed.
  if (text.isEmpty || unit.isEmpty) return text;
  return '$text $unit';
}

/// A whole number prints without its decimals; anything else keeps them.
String _trimNumber(num n) {
  if (n == n.roundToDouble()) return n.round().toString();
  return n.toString();
}
