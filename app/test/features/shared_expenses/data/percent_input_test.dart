import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/shared_expenses/composer/shared_amount_input.dart';

// Mirrors Flutter: every formatter sees the same old value, and the text a
// previous formatter produced as the new one.
String type(String before, String after) {
  final old = TextEditingValue(text: before);
  var next = TextEditingValue(text: after);
  for (final f in percentInputFormatters) {
    next = f.formatEditUpdate(old, next);
  }
  return next.text;
}

void main() {
  test('percent box keeps whole numbers from 0 to 100 only', () {
    expect(type('', '5'), '5');
    expect(type('5', '50'), '50');
    expect(type('10', '100'), '100');
    expect(type('100', '1000'), '100'); // past 100: ignored
    expect(type('9', '99'), '99');
    expect(type('5', '5.'), '5'); // no decimal point
    expect(type('5', '5a'), '5'); // no letters
    expect(type('5', ''), ''); // can clear
  });
}
