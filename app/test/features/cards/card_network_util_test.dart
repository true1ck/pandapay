import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay/features/cards/card_network_util.dart';

CardProduct _p(String id, String name, String issuer, CardNetwork network) => CardProduct(
      id: id,
      name: name,
      issuerName: issuer,
      network: network,
      isUpiLinkable: network == CardNetwork.rupay,
      pointValueInr: 1.0,
      rewardRules: const [],
      capRules: const [],
      milestoneRules: const [],
      feeWaiverRules: const [],
      benefits: const [],
    );

void main() {
  group('networkAgnosticCardName', () {
    test('strips the network word regardless of position or spacing', () {
      expect(networkAgnosticCardName('ICICI Coral RuPay'), 'icici coral');
      expect(networkAgnosticCardName('Canara MasterCard World Credit Card'),
          'canara world credit card');
      expect(networkAgnosticCardName('Axis Flipkart Card'), 'axis flipkart card');
    });
  });

  group('networkVariantsOf', () {
    final catalogue = [
      _p('flipkart-rupay', 'Axis Flipkart Card', 'Axis Bank', CardNetwork.rupay),
      _p('flipkart-mc', 'Axis Flipkart Card', 'Axis Bank', CardNetwork.mastercard),
      _p('coral-rupay', 'ICICI Coral RuPay', 'ICICI Bank', CardNetwork.rupay),
      _p('coral-visa', 'ICICI Coral', 'ICICI Bank', CardNetwork.visa),
      _p('sbi-cashback', 'SBI Cashback Card', 'SBI', CardNetwork.mastercard),
    ];

    test('groups same-issuer rows that differ only by network', () {
      final v = networkVariantsOf(catalogue[0], catalogue);
      expect(v.map((c) => c.id), containsAll(['flipkart-rupay', 'flipkart-mc']));
      expect(v, hasLength(2));
    });

    test('matches a network-in-name row to its bare sibling', () {
      final v = networkVariantsOf(catalogue[2], catalogue);
      expect(v.map((c) => c.id), containsAll(['coral-rupay', 'coral-visa']));
    });

    test('returns just the card when it has no siblings', () {
      expect(networkVariantsOf(catalogue[4], catalogue), [catalogue[4]]);
    });

    test('does not cross issuer boundaries', () {
      final crossIssuer = [
        _p('a', 'Cashback Card', 'Bank A', CardNetwork.visa),
        _p('b', 'Cashback Card', 'Bank B', CardNetwork.mastercard),
      ];
      expect(networkVariantsOf(crossIssuer[0], crossIssuer), [crossIssuer[0]]);
    });
  });
}
