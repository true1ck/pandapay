import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_amount_input.dart';

int? _units(String raw) =>
    SharedDecimalInput.parse(sharedNormalizeAmountText(raw)).units;

void main() {
  test('a decimal comma is a decimal point, never a x100 grouping', () {
    expect(_units('12,50'), 1250); // 12.50 rupees, not 1,250 rupees
    expect(_units('12,5'), 1250);
    expect(_units('0,75'), 75);
  });
  test('grouping commas are removed in Indian and Western shapes', () {
    expect(_units('1,200'), 120000);
    expect(_units('1,20,000'), 12000000);
    expect(_units('1,234,567.50'), 123456750);
    expect(_units('₹ 1,200.25'), 120025);
  });
  test('ambiguous or malformed commas are rejected, not guessed', () {
    expect(_units('1,2,3'), isNull);
    expect(_units('12,345,6'), isNull);
    expect(_units('1.200,50'), isNull);
    expect(_units(',50'), isNull);
  });
  test('plain amounts are unchanged', () {
    expect(_units('500'), 50000);
    expect(_units('99.9'), 9990);
  });
}
