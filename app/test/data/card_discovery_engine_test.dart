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
      expect(hits.first.score, greaterThanOrEqualTo(2.0));
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
        isSms: true,
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

    test('promotional SMS naming a card is ignored', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: [
          'Congratulations! You are eligible for the HDFC Millennia. Apply now for lifetime free.',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions, isEmpty);
    });

    test('transactional SMS with no card number and an ambiguous family match is ignored', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: ['Rs 1200 spent on your HDFC Bank card on 12-Aug'],
        catalogue: catalogue,
        isSms: true,
      );
      // Issuer-only placeholder is acceptable, but no named HDFC card should
      // be asserted without corroboration.
      expect(
        result.suggestions.where((s) => s.cardProductId == 'hdfc_millennia'),
        isEmpty,
      );
    });

    test('a debit-card spend alert produces no placeholder card', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: ['Rs 500 spent on your HDFC Bank Debit Card XX8708 at ATM on 12-Aug'],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions, isEmpty);
    });

    test('a credit-card alert worded with "debited" still yields a placeholder', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: [
          'Rs 500 debited from your HDFC Bank Credit Card XX8708. Avl limit Rs 20000',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions.length, 1);
      expect(result.suggestions.first.isPlaceholder, isTrue);
      expect(result.suggestions.first.last4, contains('8708'));
    });

    test('a placeholder is dropped when a real match shares its issuer + last-4', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: [
          'Rs 300 spent on your HDFC Bank card ending 7105 at AMAZON',
          'Rs 2,499 spent on your HDFC Millennia card ending 7105 at FLIPKART',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions.length, 1);
      expect(result.suggestions.first.cardProductId, 'hdfc_millennia');
    });

    test('a placeholder with a coincidental last-4 for another issuer is kept', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: [
          'Rs 900 spent on your HDFC Millennia card ending 1234 at Swiggy',
          'Rs 300 spent on your Axis Bank card ending 1234 at BigBazaar',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions.length, 2);
      expect(
        result.suggestions.where((s) => s.isPlaceholder && s.issuerName == 'Axis Bank'),
        isNotEmpty,
      );
    });

    test('real transaction alert with a card number is still discovered', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: [
          'Rs 2,499 spent on your HDFC Millennia card ending 7105 at FLIPKART',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      final hit = result.suggestions.firstWhere((s) => s.cardProductId == 'hdfc_millennia');
      expect(hit.last4, contains('7105'));
    });
  });

  // Email is a separate discovery channel: connecting Gmail must widen SMS
  // coverage, not inherit SMS's strict promo / mandatory-last-4 /
  // confident-only gating. These lock that in (isSms defaults to false).
  group('LocalCardDiscoveryEngine email path (isSms: false)', () {
    test('statement email with no masked card number is still discovered', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Your HDFC Bank Millennia Credit Card statement is ready. '
              'Total amount due Rs 4,200. View online at https://hdfcbank.com',
        ],
        catalogue: catalogue,
      );
      expect(
        result.suggestions.map((s) => s.cardProductId),
        contains('hdfc_millennia'),
      );
    });

    test('marketing-flavoured email footer does not suppress a real match', () {
      // Contains "www." / "https://" / "know more" — all promo markers that
      // would drop this on the SMS path.
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Amazon Pay ICICI Credit Card e-statement. Know more at www.icicibank.com',
        ],
        catalogue: catalogue,
      );
      expect(
        result.suggestions.map((s) => s.cardProductId),
        contains('icici_amazon_pay'),
      );
    });

    test('partial issuer + distinguishing token match is kept for email', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Dear Customer, your Axis Bank statement for the ACE card is attached.',
        ],
        catalogue: catalogue,
      );
      expect(
        result.suggestions.map((s) => s.cardProductId),
        contains('axis_ace'),
      );
    });

    test('an issuer name alone still suggests nothing on the email path', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const ['Your HDFC Bank account summary for August is ready.'],
        catalogue: catalogue,
      );
      expect(result.suggestions, isEmpty);
    });
  });

  group('LocalCardDiscoveryEngine.extractLast4 phrasing variants', () {
    test('"ending in 1234" is recognised', () {
      expect(
        LocalCardDiscoveryEngine.extractLast4('spent on card ending in 4568'),
        contains('4568'),
      );
    });

    test('"Card No. XXXX 1234" is recognised', () {
      expect(
        LocalCardDiscoveryEngine.extractLast4('Card No. XXXX XXXX XXXX 1234'),
        contains('1234'),
      );
    });

    test('an account-number suffix is NOT read as a card last-4', () {
      expect(
        LocalCardDiscoveryEngine.extractLast4('Rs 640 debited from A/c XX1797 via UPI'),
        isEmpty,
      );
      expect(
        LocalCardDiscoveryEngine.extractLast4(
            'INR 300 debited from your Canara Bank A/c ...1772 by UPI'),
        isEmpty,
      );
      // A real card number alongside an account ref still comes through.
      expect(
        LocalCardDiscoveryEngine.extractLast4('spent on card ending 4568 from A/c XX1797'),
        contains('4568'),
      );
    });
  });

  group('LocalCardDiscoveryEngine debit/account alerts', () {
    test('a UPI/debit alert carrying only an account number surfaces nothing', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Rs 640 debited from HDFC Bank A/c XX1797 via UPI to swiggy on 27-Aug',
          'INR 300 debited from your Axis Bank A/c ...1772 by UPI on 26-Aug',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions, isEmpty);
    });

    test('a debit alert poisons its issuer+last-4 against a wordless sibling', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Rs 500 spent on HDFC Bank card ending 1234 at BigBazaar on 20-Aug',
          'Rs 900 debited from HDFC Bank Debit Card ending 1234 at ATM on 21-Aug',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions, isEmpty);
    });

    test('real HDFC SMS shapes never leak the savings account as a card', () {
      const accountShapes = [
        'Update! INR 48,000.00 deposited in HDFC Bank A/c XX1797 on 29-AUG-26 for Salary',
        'PAYMENT ALERT! INR 1386.00 deducted from HDFC Bank A/C No 1797 towards Capital Float',
        'Sent Rs.1000.00 From HDFC Bank A/C *1797 To SOMEONE On 16/05/25 Ref 104892602823',
        'HDFC Bank:Rs. 2000.00 debited from a/c *1797 on 02/07/25 to a/c **1772 (UPI Ref No. 107392990952)',
        'UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26. Info: CC 000463202XXXXXX8708 Autopay',
        'UPI Transaction Declined for your HDFC Bank account ending 1797 for security reasons',
      ];
      for (final s in accountShapes) {
        expect(
          LocalCardDiscoveryEngine.extractLast4(s),
          isNot(contains('1797')),
          reason: '1797 leaked from: $s',
        );
      }
    });

    test('real HDFC corpus: credit card surfaces, savings account + debit card do not', () {
      const cat = [
        CardProduct(
          id: 'hdfc_tataneu',
          name: 'Tata Neu Infinity HDFC Bank Credit Card',
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
      ];
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Update! INR 48,000.00 deposited in HDFC Bank A/c XX1797 on 29-AUG-26 for Salary',
          'Sent Rs.1000.00 From HDFC Bank A/C *1797 To SOMEONE On 16/05/25 Ref 104892602823',
          'UPDATE: INR 15,660.00 debited from HDFC Bank XX1797 on 08-AUG-26. Info: CC 000463202XXXXXX8708 Autopay',
          'UPI Transaction Declined for your HDFC Bank account ending 1797 for security reasons',
          '370846 is your SECRET 6-digit OTP to complete your ATM withdrawal of Rs. 20000 via Card XX8406 at HDFC Bank ATM',
          'Spent Rs.210 From HDFC Bank Card x8406 At QUALITY FUEL STATION On 2025-08-14 SMS BLOCK DC 8406',
          'OTP is 047388 for txn of INR 335.00 at CHEQ DIGITA on HDFC Bank card ending 8708',
          'DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs. 4150.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 8708. YOUR AVAILABLE LIMIT IS RS. 96149',
        ],
        catalogue: cat,
        isSms: true,
      );
      final l4s = result.suggestions.expand((s) => s.last4).toList();
      expect(l4s, isNot(contains('1797')));
      expect(l4s, isNot(contains('8406')));
      expect(l4s, contains('8708'));
    });

    test('poisoning is scoped to the exact issuer+last-4', () {
      final result = LocalCardDiscoveryEngine.discoverAcrossMessages(
        smsBodies: const [
          'Rs 900 debited from HDFC Bank Debit Card ending 1111 at ATM',
          'Rs 500 spent on HDFC Bank card ending 2222 at Croma on 20-Aug',
        ],
        catalogue: catalogue,
        isSms: true,
      );
      expect(result.suggestions.length, 1);
      expect(result.suggestions.first.isPlaceholder, isTrue);
      expect(result.suggestions.first.last4, contains('2222'));
    });
  });
}
