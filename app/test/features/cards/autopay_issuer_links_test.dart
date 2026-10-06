import 'package:flutter_test/flutter_test.dart';

import '../../../lib/features/cards/autopay_issuer_links.dart';

void main() {
  test('maps HDFC cards to the HDFC official destination', () {
    expect(
      officialAutopayUrl(cardName: 'HDFC Swiggy Card'),
      'https://www.hdfcbank.com/',
    );
  });

  test('maps SBI cards to the SBI Card official destination', () {
    expect(
      officialAutopayUrl(cardName: 'SBI Cashback Card'),
      'https://www.sbicard.com/',
    );
  });

  test('does not invent a destination for an unknown issuer', () {
    expect(officialAutopayUrl(cardName: 'My Local Card'), isNull);
  });
}
