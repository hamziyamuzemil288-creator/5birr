// How one declared provider field reads on the customer's provider page.
//
// The value is stored in ONE of three columns, chosen by the field's declared
// input type on the server (`save_provider_profile_field`). That is the whole
// reason this formatting exists as a tested function rather than inline in a
// widget: the client must read the column the SERVER chose, and if it read the
// wrong one a price would render as an empty string with no error anywhere --
// the answer is stored, the row is returned, and the customer sees a blank.
//
// The two rules the report cares about are pinned here:
//   * a doctor's hourly rate and a hotel's nightly rate must show their UNIT,
//     because "500" on a price field says nothing about per what;
//   * a boolean must not reach the page as `true`.
import 'package:flutter_test/flutter_test.dart';

import 'package:birr5/core/utils/category_field_value.dart';

void main() {
  group('a PRICE field reads as money with its unit', () {
    test('a whole number keeps its unit and drops the decimals', () {
      // 0128 stores a PRICE in value_number; the provider typed "500".
      expect(
        categoryFieldValue(valueNumber: 500, unitLabel: 'ETB / hour'),
        '500 ETB / hour',
      );
    });

    test('a fractional price keeps its decimals', () {
      expect(
        categoryFieldValue(valueNumber: 12.5, unitLabel: 'ETB / km'),
        '12.5 ETB / km',
      );
    });

    test('a price with no unit is not given a trailing space', () {
      final rendered = categoryFieldValue(valueNumber: 200, unitLabel: '   ');
      expect(rendered, '200');
      expect(rendered.trim(), rendered);
    });
  });

  group('a NUMBER field is a count, not money', () {
    test('seats render bare', () {
      expect(categoryFieldValue(valueNumber: 12), '12');
    });

    test('a unit that is a noun is still shown', () {
      expect(categoryFieldValue(valueNumber: 8, unitLabel: 'years'), '8 years');
    });

    test('a whole number never gains a .00', () {
      // The failure this pins: "500.00 ETB / night" is a different claim from
      // "500 ETB / night", and the second one is what was typed.
      expect(categoryFieldValue(valueNumber: 500, unitLabel: 'ETB'),
          isNot(contains('.00')));
    });
  });

  group('a BOOLEAN field is an answer, not a database value', () {
    test('true reads as Yes', () {
      expect(categoryFieldValue(valueBoolean: true), 'Yes');
    });

    test('false reads as No', () {
      expect(categoryFieldValue(valueBoolean: false), 'No');
    });

    test('neither renders the words true or false', () {
      expect(categoryFieldValue(valueBoolean: true), isNot(equals('true')));
      expect(categoryFieldValue(valueBoolean: false), isNot(equals('false')));
    });
  });

  group('a TEXT field is returned as typed', () {
    test('a list of room types survives', () {
      expect(
        categoryFieldValue(valueText: 'Single, Double, Suite'),
        'Single, Double, Suite',
      );
    });

    test('surrounding whitespace is trimmed', () {
      expect(categoryFieldValue(valueText: '  Walk-ins welcome  '),
          'Walk-ins welcome');
    });

    test('an unanswered text field is empty, not "null"', () {
      expect(categoryFieldValue(valueText: null), '');
      expect(categoryFieldValue(valueText: ''), '');
    });
  });

  group('the column is chosen the way the server chooses it', () {
    test('a boolean wins over any stray text', () {
      // Guards the ordering inside the helper: the server writes EXACTLY one
      // value column, so a row carrying two would be a server bug -- but the
      // read must still not prefer text, or a real answer would be hidden
      // behind an empty string.
      expect(
        categoryFieldValue(valueBoolean: true, valueText: ''),
        'Yes',
      );
    });

    test('a number wins over an empty text for the same reason', () {
      expect(
        categoryFieldValue(valueNumber: 3, valueText: '', unitLabel: 'seats'),
        '3 seats',
      );
    });
  });
}
