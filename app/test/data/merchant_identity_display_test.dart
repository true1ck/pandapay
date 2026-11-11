import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/merchant_identity.dart';

void main() {
  group('displayName', () {
    test('the ledger marker for "nobody was named" reads as a sender or a merchant', () {
      expect(MerchantIdentity.displayName('UNKNOWN', incoming: true), 'Unknown sender');
      expect(MerchantIdentity.displayName('UNKNOWN', incoming: false), 'Unknown merchant');
    });

    test('whatever the case or spacing', () {
      expect(MerchantIdentity.displayName(' unknown ', incoming: false), 'Unknown merchant');
      expect(MerchantIdentity.displayName('Unknown', incoming: true), 'Unknown sender');
    });

    test('every other name is returned as it is', () {
      for (final name in ['Zepto', 'RAVI KUMAR', 'Unknown merchant', 'UNKNOWN CAFE', 'Credit card payment']) {
        expect(MerchantIdentity.displayName(name, incoming: false), name);
        expect(MerchantIdentity.displayName(name, incoming: true), name);
      }
    });

    test('a missing name stays missing, so the caller keeps its own fallback', () {
      expect(MerchantIdentity.displayName(null, incoming: true), isNull);
      expect(MerchantIdentity.displayName('', incoming: false), '');
    });
  });
}
