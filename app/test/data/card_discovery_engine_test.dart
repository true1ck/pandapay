import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/card_discovery_engine.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  const catalogue = [
    CardProduct(
      id: 'hdfc_millennia',
      name: 'HDFC Millennia',
      issuerName: 'HDFC Bank',
      network: CardNetwork.visa,
      isUpiLinkable: false,
      pointValueInr: 1.0,
      rewardRules: [],
      capRules: [],
      milestoneRules: [],
      feeWaiverRules: [],
      benefits: [],
    ),
    CardProduct(
      id: 'axis_ace',
      name: 'Axis Bank ACE',
      issuerName: 'Axis Bank',
      network: CardNetwork.visa,
      isUpiLinkable: false,
      pointValueInr: 1.0,
      rewardRules: [],
      capRules: [],
      milestoneRules: [],
      feeWaiverRules: [],
      benefits: [],
    ),
    CardProduct(
      id: 'sbi_cashback',
      name: 'Cashback SBI Card',
      issuerName: 'SBI Card',
      network: CardNetwork.visa,
      isUpiLinkable: false,
      pointValueInr: 1.0,
      rewardRules: [],
      capRules: [],
      milestoneRules: [],
      feeWaiverRules: [],
      benefits: [],
    ),
    CardProduct(
      id: 'icici_amazon_pay',
      name: 'Amazon Pay ICICI Credit Card',
      issuerName: 'ICICI Bank',
      network: CardNetwork.visa,
      isUpiLinkable: false,
      pointValueInr: 1.0,
      rewardRules: [],
      capRules: [],
      milestoneRules: [],
      feeWaiverRules: [],
      benefits: [],
    ),
  ];

  group('LocalCardDiscoveryEngine', () {
    test('extracts last4 accurately', () {
      expect(
        LocalCardDiscoveryEngine.extractLast4('Spent Rs. 500 on card ending 4568 at Swiggy'),
        contains('4568'),
      );
      expect(
        LocalCardDiscoveryEngine.extractLast4('Alert: INR 1200 debited from card XX1234 on 28-Aug'),
        contains('1234'),
      );
      expect(
        LocalCardDiscoveryEngine.extractLast4('Used card ****9876 for payment of Rs 340'),
        contains('9876'),
      );
    });

    test('exact product match in SMS body', () {
      final hits = LocalCardDiscoveryEngine.discoverInMessage(
        body: 'Rs 1,450.00 spent on your HDFC Millennia card at Amazon on 28-Aug-26',
        catalogue: catalogue,
      );
      expect(hits.length, 1);
      expect(hits.first.cardProductId, 'hdfc_millennia');
      expect(hits.first.name, 'HDFC Millennia');
      expect(hits.first.score, 1.0);
    });

    test('issuer plus distinguishing token match', () {
      final hits = LocalCardDiscoveryEngine.discoverInMessage(
        body: 'Alert: Your Axis Bank ACE credit card was charged INR 299 for Netflix. Ending 4321',
        catalogue: catalogue,
      );
      expect(hits.length, 1);
      expect(hits.first.cardProductId, 'axis_ace');
      expect(hits.first.last4, contains('4321'));
    });

    test('prevents substring false positive on common words', () {
      // "ace" should not trigger from "interface", "place", "space"
      final hits = LocalCardDiscoveryEngine.discoverInMessage(
        body: 'Welcome to our workplace workspace interface from Axis Bank',
        catalogue: catalogue,
      );
      expect(hits, isEmpty);
    });

    test('aggregates multiple SMS and counts frequency', () {
      final smsList = [
        'HDFC Millennia: Rs 500 spent at Swiggy ending with 1111',
        'HDFC Millennia: Rs 1200 spent at Amazon ending with 1111',
        'Axis Bank ACE: Rs 300 spent at Uber ending with 2222',
      ];
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: smsList,
        catalogue: catalogue,
      );
      expect(result.smsScanned, 3);
      expect(result.suggestions.length, 2);

      final hdfc = result.suggestions.firstWhere((s) => s.cardProductId == 'hdfc_millennia');
      expect(hdfc.messageCount, 2);
      expect(hdfc.last4, contains('1111'));

      final axis = result.suggestions.firstWhere((s) => s.cardProductId == 'axis_ace');
      expect(axis.messageCount, 1);
      expect(axis.last4, contains('2222'));
    });
  });
}
