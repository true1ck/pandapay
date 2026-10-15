import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/app/design/display_text.dart';

void main() {
  test('humanizes catalogue identifiers without changing natural copy', () {
    expect(
      humanizeIdentifier('visa_or_rupay_domestic_lounge_program'),
      'Visa or RuPay Domestic Lounge Program',
    );
    expect(humanizeIdentifier('cashbackPercent'), 'Cashback Percent');
    expect(
      humanizeIdentifier('Domestic lounge access'),
      'Domestic lounge access',
    );
  });
}
