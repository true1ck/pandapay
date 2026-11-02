import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/foreign_money.dart';

void main() {
  test('app and server share ISO accounting units, not display rounding', () {
    final server = jsonDecode(
      File('../api/src/currency_minor_units.json').readAsStringSync(),
    );
    expect(currencyMinorUnits, server);
    expect(currencyMinorUnits['PKR'], 2);
    expect(currencyMinorUnits['HUF'], 2);
    expect(currencyMinorUnits['IQD'], 3);
  });
  test(
    'foreign decimal validation preserves currency precision without rounding',
    () {
      expect(canonicalForeignAmount('20.00', 'USD'), '20');
      expect(canonicalForeignAmount('20.12', 'USD'), '20.12');
      expect(canonicalForeignAmount('20.123', 'USD'), isNull);
      expect(canonicalForeignAmount('20.000', 'JPY'), '20');
      expect(canonicalForeignAmount('20.01', 'JPY'), isNull);
      expect(canonicalForeignAmount('20.123', 'IQD'), '20.123');
      expect(canonicalForeignAmount('20.1234', 'CLF'), '20.1234');
      expect(canonicalForeignAmount('20.12', 'PKR'), '20.12');
    },
  );
  test(
    'missing, malformed, zero, unsupported and scientific amounts remain unresolved',
    () {
      for (final value in [
        null,
        '.00',
        '0',
        '0.000',
        '-20',
        'NaN',
        'Infinity',
        '1e3',
        '1,000',
        {},
      ]) {
        expect(canonicalForeignAmount(value, 'USD'), isNull);
      }
      expect(canonicalForeignAmount('20', 'XYZ'), isNull);
      expect(canonicalForeignAmount('20', 'INR'), isNull);
      expect(canonicalForeignAmount('20.12', null), '20.12');
    },
  );
}
