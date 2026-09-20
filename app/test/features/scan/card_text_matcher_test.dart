import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/card_text_matcher.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _product(String id, String name, CardNetwork network) =>
    CardProduct(id: id, name: name, network: network);

void main() {
  group('detectNetworkFromText', () {
    test('finds a known network keyword case-insensitively', () {
      expect(
        detectNetworkFromText('some text VISA platinum'),
        CardNetwork.visa,
      );
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

    test(
      'medium confidence on a strong name match without network confirmation',
      () {
        final matches = matchCardText(
          const ExtractedCardText('sbi cashback credit card statement'),
          catalogue,
        );
        final sbiMatch = matches.firstWhere((m) => m.product.id == 'c2');
        expect(sbiMatch.confidence, MatchConfidence.medium);
      },
    );

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
        const ExtractedCardText(
          'HDFC BANK MILLENNIA VISA and also sbi cashback mention',
        ),
        catalogue,
      );
      for (var i = 1; i < matches.length; i++) {
        expect(
          matches[i - 1].confidence.index,
          greaterThanOrEqualTo(matches[i].confidence.index),
        );
      }
    });

    test('recognizes the Tata Neu sample ahead of a generic Platinum row', () {
      final tataNeu = _product(
        'tata-neu-infinity-hdfc',
        'Tata Neu Infinity HDFC Bank Credit Card',
        CardNetwork.rupay,
      );
      final platinum = _product(
        'indusind-platinum',
        'Platinum Credit Card',
        CardNetwork.visa,
      );

      final matches = matchCardText(
        const ExtractedCardText('TATA NEUCARD HDFC BANK RuPay PLATINUM'),
        [tataNeu, platinum],
      );

      expect(matches.first.product.id, tataNeu.id);
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.where((m) => m.product.id == platinum.id), isEmpty);
    });

    test('uses the NEUCARD+ mark to prefer Tata Neu Plus', () {
      final plus = _product(
        'tata-neu-plus-hdfc',
        'Tata Neu Plus HDFC Bank Credit Card',
        CardNetwork.rupay,
      );
      final infinity = _product(
        'tata-neu-infinity-hdfc',
        'Tata Neu Infinity HDFC Bank Credit Card',
        CardNetwork.rupay,
      );
      final platinum = _product(
        'indusind-platinum',
        'Platinum Credit Card',
        CardNetwork.visa,
      );

      final matches = matchCardText(
        const ExtractedCardText('TATA NEUCARD+ HDFC BANK RuPay PLATINUM'),
        [infinity, platinum, plus],
      );

      expect(matches.first.product.id, plus.id);
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.where((m) => m.product.id == platinum.id), isEmpty);
    });

    test('normalizes the stylized Cashback logo lockup', () {
      final matches = matchCardText(
        const ExtractedCardText('CASIH B<CK SBI card'),
        [_product('sbi-cashback', 'SBI Cashback Credit Card', CardNetwork.visa)],
      );

      expect(matches, isNotEmpty);
      expect(matches.first.product.id, 'sbi-cashback');
      expect(matches.first.confidence, MatchConfidence.medium);
    });

    test(
      'does not treat a single generic tier word as card identification',
      () {
        final matches = matchCardText(
          const ExtractedCardText('PLATINUM VISA'),
          [_product('platinum', 'Platinum Credit Card', CardNetwork.visa)],
        );

        expect(
          matches,
          isNotEmpty,
          reason:
              'network-only low suggestions remain available for diagnostics',
        );
        expect(matches.single.confidence, MatchConfidence.low);
      },
    );

    test('does not promote a network plus tier label to a real card', () {
      final matches = matchCardText(const ExtractedCardText('RuPay Platinum'), [
        _product(
          'rupay-platinum',
          'RuPay Platinum Credit Card',
          CardNetwork.rupay,
        ),
        _product(
          'tata-neu',
          'Tata Neu Infinity HDFC Bank Credit Card',
          CardNetwork.rupay,
        ),
      ]);

      expect(matches, hasLength(2));
      expect(matches.every((m) => m.confidence == MatchConfidence.low), isTrue);
    });
  });

  group('redactDigitRuns', () {
    // UA-4 (extended): the front of a physical card usually prints a full
    // or partial card number. Anything from the OCR path that could ever
    // reach the screen must have digit runs masked first.
    test('masks a full 16-digit card number', () {
      expect(redactDigitRuns('4111 1111 1111 1111'), '•••• •••• •••• ••••');
    });

    test('masks digits embedded in surrounding issuer text', () {
      expect(
        redactDigitRuns(
          'HDFC BANK MILLENNIA 5241 8765 3412 9087 VALID THRU 04/29',
        ),
        'HDFC BANK MILLENNIA •••• •••• •••• •••• VALID THRU 04/29',
      );
    });

    test('leaves a 1-2 digit run alone — below CVV length, not PAN-shaped', () {
      expect(redactDigitRuns('exp 04/29'), 'exp 04/29');
      expect(redactDigitRuns('branch 7'), 'branch 7');
    });

    test(
      'masks a 3-digit run — the CVV length is exactly the line to hold',
      () {
        expect(redactDigitRuns('123'), '•••');
      },
    );

    test('leaves letters and punctuation untouched', () {
      expect(redactDigitRuns('HDFC Bank — Millennia'), 'HDFC Bank — Millennia');
    });

    test('masks a single very long run once, not digit-by-digit oddly', () {
      final redacted = redactDigitRuns('a1234567890123456b');
      expect(redacted, 'a${'•' * 16}b');
    });
  });
}
