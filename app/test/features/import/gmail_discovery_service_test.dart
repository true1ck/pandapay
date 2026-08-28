import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/import/gmail_discovery_service.dart';
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
  ];

  group('GmailDiscoveryService', () {
    test('discovers cards from raw snippets locally with email source', () async {
      final service = GmailDiscoveryService();
      final result = await service.scanGmailForCards(
        catalogue: catalogue,
        rawSnippets: [
          'Your HDFC Millennia statement of Rs 5000 is ready for card ending 1234',
          'Dear Customer, Rs. 250 spent on your Axis Bank ACE card ending with 5678 at Swiggy',
        ],
      );

      expect(result.emailsScanned, 2);
      expect(result.suggestions.length, 2);
      expect(result.suggestions.any((s) => s.cardProductId == 'hdfc_millennia'), isTrue);
      expect(result.suggestions.any((s) => s.cardProductId == 'axis_ace'), isTrue);
      expect(result.suggestions.first.sources, contains('email'));
    });

    test('returns empty result when no bank emails match catalogue', () async {
      final service = GmailDiscoveryService();
      final result = await service.scanGmailForCards(
        catalogue: catalogue,
        rawSnippets: [
          'Meeting reminder for tomorrow morning at 10am',
          'Your Amazon package has been delivered',
        ],
      );

      expect(result.emailsScanned, 2);
      expect(result.suggestions, isEmpty);
    });

    test('returns 0 emailsScanned when snippets list is empty', () async {
      final service = GmailDiscoveryService();
      final result = await service.scanGmailForCards(
        catalogue: catalogue,
        rawSnippets: [],
      );

      expect(result.emailsScanned, 0);
      expect(result.suggestions, isEmpty);
    });
  });
}
