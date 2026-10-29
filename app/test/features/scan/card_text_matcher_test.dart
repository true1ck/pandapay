import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/scan/card_text_matcher.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

CardProduct _product(
  String id,
  String name,
  CardNetwork network, {
  String? issuerName,
}) => CardProduct(id: id, name: name, network: network, issuerName: issuerName);

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

  group('passesLuhn', () {
    test('validates standard Luhn-compliant PANs', () {
      // Standard Luhn test numbers
      expect(passesLuhn('4111111111111111'), isTrue);
      expect(passesLuhn('4532123456788909'), isTrue);
      expect(passesLuhn('4000001234567899'), isTrue);
      expect(passesLuhn('49927398716'), isFalse); // < 13 digits
    });

    test('rejects numbers that violate Luhn checksum', () {
      expect(passesLuhn('4111111111112222'), isFalse);
      expect(passesLuhn('4532123456788908'), isFalse);
      expect(passesLuhn('18002095577'), isFalse);
    });

    test('rejects strings that are too short, too long, or non-numeric', () {
      expect(passesLuhn('1234'), isFalse);
      expect(passesLuhn('123456789012'), isFalse);
      expect(passesLuhn('12345678901234567890'), isFalse);
      expect(passesLuhn('411111111111111a'), isFalse);
    });
  });

  group('isLikelyExpiryOrHelpline', () {
    test('identifies toll-free helpline prefixes and customer care numbers', () {
      expect(isLikelyExpiryOrHelpline('1800', '1800 209 5577'), isTrue);
      expect(isLikelyExpiryOrHelpline('1860', '1860 266 2666'), isTrue);
      expect(
        isLikelyExpiryOrHelpline('5577', 'Customer care 1800 209 5577'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('3800', 'Toll Free: 1800-425-3800'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('1234', 'Helpline: 080 6789 1234'),
        isTrue,
      );
    });

    test('identifies expiry years and dates', () {
      expect(
        isLikelyExpiryOrHelpline('2029', 'VALID THRU 2029'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('2026', 'VALID 2026'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('2030', 'GOOD THRU 2030'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('2028', 'EXP 2028'),
        isTrue,
      );
      expect(
        isLikelyExpiryOrHelpline('1228', 'VALID THRU 12/28'),
        isTrue,
      );
    });

    test('does not misclassify genuine card last 4 digits', () {
      expect(
        isLikelyExpiryOrHelpline('8908', 'HDFC BANK •••• •••• •••• 8908'),
        isFalse,
      );
      expect(
        isLikelyExpiryOrHelpline('4321', 'AXIS BANK 4321'),
        isFalse,
      );
      expect(
        isLikelyExpiryOrHelpline('5678', 'SBI CARD ending in 5678'),
        isFalse,
      );
    });
  });

  group('extractLastFourDigits', () {
    test('returns the last 4-digit group found', () {
      expect(extractLastFourDigits('4111 1111 1111 2222'), '2222');
    });

    test('returns null when no digit group exists', () {
      expect(extractLastFourDigits('no digits here'), isNull);
    });

    test('prefers a PAN-shaped run over a later four-digit label', () {
      expect(extractLastFourDigits('4111 1111 1111 2222 VALID 2026'), '2222');
    });

    test('handles multiple spaces between 4-digit blocks from ML Kit OCR', () {
      expect(extractLastFourDigits('4532   1234   5678   8908'), '8908');
      expect(extractLastFourDigits('4532  1234  5678  8908'), '8908');
    });

    test('handles newlines between 4-digit blocks from ML Kit OCR', () {
      expect(extractLastFourDigits('4532\n1234\n5678\n8908'), '8908');
      expect(extractLastFourDigits('4532\r\n1234\r\n5678\r\n8908'), '8908');
      expect(extractLastFourDigits('4532  1234\n5678  8908'), '8908');
    });

    test('handles dash and dot separated blocks', () {
      expect(extractLastFourDigits('4532-1234-5678-8908'), '8908');
      expect(extractLastFourDigits('4532.1234.5678.8908'), '8908');
      expect(extractLastFourDigits('4532 - 1234 - 5678 - 8908'), '8908');
    });

    test('extracts from masked card representations', () {
      expect(extractLastFourDigits('•••• •••• •••• 8908'), '8908');
      expect(extractLastFourDigits('**** **** **** 8908'), '8908');
      expect(extractLastFourDigits('xxxx 8908'), '8908');
      expect(extractLastFourDigits('XXXX XXXX XXXX 8908'), '8908');
      expect(extractLastFourDigits('•••• 8908'), '8908');
      expect(extractLastFourDigits('************8908'), '8908');
      expect(extractLastFourDigits('Card ending in 8908'), '8908');
    });

    test('prioritizes Luhn-passing PAN candidate over non-Luhn candidate', () {
      // 4532123456788909 passes Luhn, whereas 1234567890123456 fails Luhn
      final mixedText = 'ORDER 1234 5678 9012 3456 CARD 4532 1234 5678 8909';
      expect(extractLastFourDigits(mixedText), '8909');
    });

    test('prioritizes Luhn-passing PAN over customer care helplines', () {
      final cardWithHelpline = '''
HDFC BANK PLATINUM
4532 1234 5678 8909
VALID THRU 08/29
CUSTOMER CARE 1800 209 5577
''';
      expect(extractLastFourDigits(cardWithHelpline), '8909');
    });

    test('rejects customer care helplines when no card number is present', () {
      expect(extractLastFourDigits('CUSTOMER CARE 1800 209 5577'), isNull);
      expect(extractLastFourDigits('Toll Free: 1800-425-3800'), isNull);
      expect(extractLastFourDigits('Helpline 1860 266 2666'), isNull);
    });

    test('rejects expiry dates when no card number is present', () {
      expect(extractLastFourDigits('VALID THRU 2029'), isNull);
      expect(extractLastFourDigits('VALID 2026'), isNull);
      expect(extractLastFourDigits('GOOD THRU 2030'), isNull);
      expect(extractLastFourDigits('MEMBER SINCE 2021'), isNull);
    });

    test('rejects pincodes and generic non-card labels', () {
      expect(extractLastFourDigits('BRANCH BANGALORE PIN 560001'), isNull);
    });

    test('correctly extracts from masked statement text with expiry and helpline', () {
      final statementText = '''
SBI Card Statement
Account ending in •••• 8908
Valid Thru 12/28
For queries call 1800 180 1290
''';
      expect(extractLastFourDigits(statementText), '8908');
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
        expect(sbiMatch.confidence, MatchConfidence.high);
      },
    );

    test('exact product text wins when issuer words are shared', () {
      final matches = matchCardText(
        const ExtractedCardText('TATA NEUCARD+ HDFC BANK RUPAY PLATINUM'),
        [
          _product(
            'tata-neu-plus',
            'Tata Neu Plus HDFC Bank Credit Card',
            CardNetwork.rupay,
          ),
          _product('axis-aura', 'Axis Bank Aura Credit Card', CardNetwork.visa),
          _product(
            'axis-rewards',
            'Axis Bank REWARDS Credit Card',
            CardNetwork.unknown,
          ),
        ],
      );

      expect(matches.first.product.id, 'tata-neu-plus');
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.first.productHits, greaterThan(1));
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

    test('uses the NEUCARD infinity mark to prefer Tata Neu Infinity', () {
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

      final matches = matchCardText(
        const ExtractedCardText('TATA NEUCARD∞ HDFC BANK RuPay'),
        [plus, infinity],
      );

      expect(matches.first.product.id, infinity.id);
      expect(matches.first.confidence, MatchConfidence.high);
    });

    test('tolerates the common Tata Neo OCR/spoken-name variant', () {
      final tataNeu = _product(
        'tata-neu-infinity-hdfc',
        'Tata Neu Infinity HDFC Bank Credit Card',
        CardNetwork.rupay,
      );

      final matches = matchCardText(
        const ExtractedCardText('TATA NEO INFINITY HDFC BANK RuPay'),
        [tataNeu],
      );

      expect(matches, isNotEmpty);
      expect(matches.first.product.id, tataNeu.id);
      expect(matches.first.confidence, MatchConfidence.high);
    });

    test('does not rewrite the unrelated Axis Bank Neo card', () {
      final axisNeo = _product(
        'axis-neo',
        'Axis Bank Neo Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );
      final tataNeu = _product(
        'tata-neu-infinity-hdfc',
        'Tata Neu Infinity HDFC Bank Credit Card',
        CardNetwork.rupay,
      );

      final matches = matchCardText(
        const ExtractedCardText('AXIS BANK NEO VISA'),
        [axisNeo, tataNeu],
      );

      expect(matches.first.product.id, axisNeo.id);
      expect(matches.where((m) => m.product.id == tataNeu.id), isEmpty);
    });

    test('normalizes the stylized Cashback logo lockup', () {
      final matches = matchCardText(
        const ExtractedCardText('CASIH B<CK SBI card'),
        [
          _product(
            'sbi-cashback',
            'SBI Cashback Credit Card',
            CardNetwork.visa,
          ),
        ],
      );

      expect(matches, isNotEmpty);
      expect(matches.first.product.id, 'sbi-cashback');
      expect(matches.first.confidence, MatchConfidence.medium);
    });

    test('uses issuer text to disambiguate short catalogue names', () {
      final matches = matchCardText(
        const ExtractedCardText('YES BANK ACE VISA'),
        [
          _product(
            'yes-bank-ace',
            'ACE',
            CardNetwork.visa,
            issuerName: 'Yes Bank',
          ),
        ],
      );

      expect(matches, isNotEmpty);
      expect(matches.first.product.id, 'yes-bank-ace');
      expect(matches.first.confidence, MatchConfidence.high);
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

    test('generic word card never fuzzy-matches bobcard', () {
      final myZone = _product(
        'axis-my-zone',
        'Axis Bank MY ZONE Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );
      final bobcard = _product(
        'bobcard-easy',
        'BOBCARD Easy',
        CardNetwork.visa,
        issuerName: 'BOBCARD',
      );

      final matches = matchCardText(
        const ExtractedCardText(
          'AXIS BANK MY ZONE CREDIT CARD 4111 2222 3333 8908\nFOR EASY EMI CALL 1800 103 5577',
        ),
        [bobcard, myZone],
      );

      expect(matches.where((m) => m.product.id == 'bobcard-easy'), isEmpty);
      expect(matches.first.product.id, 'axis-my-zone');
    });

    test(
      'base card beats sub-variant when extra token is from disclaimer text',
      () {
        final myZone = _product(
          'axis-my-zone',
          'Axis Bank MY ZONE Credit Card',
          CardNetwork.visa,
          issuerName: 'Axis Bank',
        );
        final myZoneEasy = _product(
          'axis-my-zone-easy',
          'Axis Bank MY ZONE EASY Credit Card',
          CardNetwork.visa,
          issuerName: 'Axis Bank',
        );

        final matches = matchCardText(
          const ExtractedCardText(
            'AXIS BANK MY ZONE CREDIT CARD\nNOT VALID WITHOUT SIGNATURE\nFOR EASY EMI CALL 1800 103 5577',
          ),
          [myZoneEasy, myZone],
        );

        expect(matches.first.product.id, 'axis-my-zone');
        expect(matches.first.confidence, MatchConfidence.high);
        expect(matches.first.overlap, 1.0);
      },
    );

    test('sub-variant beats base card when sub-variant phrase is explicit', () {
      final myZone = _product(
        'axis-my-zone',
        'Axis Bank MY ZONE Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );
      final myZoneEasy = _product(
        'axis-my-zone-easy',
        'Axis Bank MY ZONE EASY Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );

      final matches = matchCardText(
        const ExtractedCardText(
          'AXIS BANK MY ZONE EASY CREDIT CARD 4111 2222 3333 8908',
        ),
        [myZone, myZoneEasy],
      );

      expect(matches.first.product.id, 'axis-my-zone-easy');
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.first.overlap, 1.0);
    });

    test('recognizes compound product tokens like myzone and simplyclick', () {
      final myZone = _product(
        'axis-my-zone',
        'Axis Bank MY ZONE Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );
      final simplyClick = _product(
        'sbi-simplyclick',
        'SBI SimplyClick Credit Card',
        CardNetwork.visa,
        issuerName: 'State Bank of India',
      );

      final myZoneMatches = matchCardText(
        const ExtractedCardText('AXIS BANK MYZONE CREDIT CARD'),
        [myZone],
      );
      expect(myZoneMatches.first.product.id, 'axis-my-zone');
      expect(myZoneMatches.first.confidence, MatchConfidence.high);

      final simplyClickMatches = matchCardText(
        const ExtractedCardText('SBI SIMPLYCLICK CREDIT CARD'),
        [simplyClick],
      );
      expect(simplyClickMatches.first.product.id, 'sbi-simplyclick');
      expect(simplyClickMatches.first.confidence, MatchConfidence.high);
    });

    test('deduplicates issuer tokens in searchable product name', () {
      final myZone = _product(
        'axis-my-zone',
        'Axis Bank MY ZONE Credit Card',
        CardNetwork.visa,
        issuerName: 'Axis Bank',
      );

      final matches = matchCardText(
        const ExtractedCardText('AXIS BANK MY ZONE CREDIT CARD'),
        [myZone],
      );
      expect(matches.first.confidence, MatchConfidence.high);
      expect(matches.first.overlap, 1.0);
      expect(matches.first.reason, contains('name match 100%'));
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
