import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/card_text_matcher.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _product(String id, String name, CardNetwork network) =>
    CardProduct(id: id, name: name, network: network);

void main() {
  group('detectNetworkFromText', () {
    test('finds a known network keyword case-insensitively', () {
      expect(detectNetworkFromText('some text VISA platinum'), CardNetwork.visa);
      expect(detectNetworkFromText('MasterCard World'), CardNetwork.mastercard);
      expect(detectNetworkFromText('RuPay Select'), CardNetwork.rupay);
      expect(detectNetworkFromText('American Express Gold'), CardNetwork.amex);
    });

    test('returns null when no synonym appears', () {
      expect(detectNetworkFromText('just some garbage ocr text 12345'), isNull);
    });
  });

  group('extractLastFourDigits', () {
    test('returns the last 4-digit group found', () {
      expect(extractLastFourDigits('4111 1111 1111 2222'), '2222');
    });

    test('returns null when no digit group exists', () {
      expect(extractLastFourDigits('no digits here'), isNull);
    });
  });

  group('matchCardText', () {
    final catalogue = [
      _product('c1', 'HDFC Millennia', CardNetwork.visa),
      _product('c2', 'SBI Cashback', CardNetwork.rupay),
      _product('c3', 'ICICI Amazon Pay', CardNetwork.visa),
    ];

    test('high confidence when both name tokens and network match', () {
      final matches = matchCardText(
        const ExtractedCardText('HDFC BANK MILLENNIA VISA 4242'),
        catalogue,
      );
      expect(matches, isNotEmpty);
      expect(matches.first.product.id, 'c1');
      expect(matches.first.confidence, MatchConfidence.high);
    });

    test('medium confidence on a strong name match without network confirmation', () {
      final matches = matchCardText(
        const ExtractedCardText('sbi cashback credit card statement'),
        catalogue,
      );
      final sbiMatch = matches.firstWhere((m) => m.product.id == 'c2');
      expect(sbiMatch.confidence, MatchConfidence.medium);
    });

    test('no candidates returned when text matches nothing at all', () {
      final matches = matchCardText(
        const ExtractedCardText('totally unrelated grocery receipt text'),
        catalogue,
      );
      expect(matches, isEmpty);
    });

    test('does not fabricate a high-confidence guess from network alone', () {
      final matches = matchCardText(const ExtractedCardText('VISA'), catalogue);
      for (final m in matches) {
        expect(m.confidence, isNot(MatchConfidence.high));
      }
    });

    test('results are sorted best confidence first', () {
      final matches = matchCardText(
        const ExtractedCardText('HDFC BANK MILLENNIA VISA and also sbi cashback mention'),
        catalogue,
      );
      for (var i = 1; i < matches.length; i++) {
        expect(matches[i - 1].confidence.index, greaterThanOrEqualTo(matches[i].confidence.index));
      }
    });
  });
}
