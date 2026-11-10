import 'package:flutter_test/flutter_test.dart';

import '../../../../lib/features/voice/understanding/en_pack.dart';
import '../../../../lib/features/voice/understanding/number_grammar.dart';
import '../../../../lib/features/voice/understanding/tokens.dart';

List<NumberSpan> numbers(String text) => findNumbers(tokenize(text), enPack);

void main() {
  group('tokenizer', () {
    test('keeps grouped numbers, suffixes and symbols whole', () {
      final t = tokenize('Paid ₹2,50,000 and 1.5k, 3rd, Rs. 250/-');
      expect(t.map((e) => e.raw).toList(), [
        'Paid',
        '₹',
        '2,50,000',
        'and',
        '1.5k',
        ',',
        '3rd',
        ',',
        'Rs.',
        '250/-',
      ]);
      expect(t[2].number, 250000);
      expect(t[4].suffix, 'k');
      expect(t[6].suffix, 'rd');
      expect(t.last.rupeeSlash, isTrue);
    });
  });

  group('numbers read as digits', () {
    const cases = <String, double>{
      '250': 250,
      '1,250': 1250,
      '2,50,000': 250000,
      '99.50': 99.5,
      '1.5k': 1500,
      '2k': 2000,
      '10K': 10000,
      '2 lakh': 200000,
      '2.5 lakh': 250000,
      '2.5lakh': 250000,
      '1 crore': 10000000,
      '5 hundred': 500,
      '2 thousand': 2000,
      '3 thousand 500': 3500,
      '2 k': 2000,
    };
    cases.forEach((text, value) {
      test('"$text" is $value', () {
        final spans = numbers(text);
        expect(spans, hasLength(1), reason: '$spans');
        expect(spans.single.value, closeTo(value, 0.0001));
      });
    });
  });

  group('numbers read as words', () {
    const cases = <String, double>{
      'two hundred and fifty': 250,
      'two hundred fifty': 250,
      'fifteen hundred': 1500,
      'twenty five hundred': 2500,
      'twenty-five hundred': 2500,
      'one thousand two hundred': 1200,
      'two lakh fifty thousand': 250000,
      'one lakh two thousand': 102000,
      'a thousand': 1000,
      'a lakh': 100000,
      'a hundred': 100,
      'hundred': 100,
      'half a lakh': 50000,
      'two and a half thousand': 2500,
      'one and a half lakh': 150000,
      'one point five lakh': 150000,
      'two k': 2000,
      'twenty five': 25,
      'twenty-five': 25,
      'ninety nine': 99,
      'one hundred': 100,
      'five hundred thousand': 500000,
      'a thousand five hundred': 1500,
      'one thousand and fifty': 1050,
      'fifty': 50,
      'fifteen': 15,
    };
    cases.forEach((text, value) {
      test('"$text" is $value', () {
        final spans = numbers(text);
        expect(spans, hasLength(1), reason: '$spans');
        expect(spans.single.value, closeTo(value, 0.0001));
      });
    });
  });

  group('spoken pairs keep both readings', () {
    const cases = <String, List<double>>{
      'two fifty': [250, 2.5],
      'twelve fifty': [1250, 12.5],
      'three twenty five': [325, 3.25],
      'nineteen ninety nine': [1999, 19.99],
      'one fifty': [150, 1.5],
    };
    cases.forEach((text, values) {
      test('"$text" is ${values[0]} or ${values[1]}', () {
        final spans = numbers(text);
        expect(spans, hasLength(1), reason: '$spans');
        expect(spans.single.value, closeTo(values[0], 0.0001));
        expect(spans.single.altValue, closeTo(values[1], 0.0001));
      });
    });
  });

  group('boundaries', () {
    test('two separate numbers stay separate', () {
      final spans = numbers('250 300');
      expect(spans.map((s) => s.value), [250, 300]);
    });

    test('finds numbers inside a sentence and reports their tokens', () {
      const text = 'spent two hundred and fifty rupees on 3 coffees';
      final tokens = tokenize(text);
      final spans = findNumbers(tokens, enPack);
      expect(spans.map((s) => s.value), [250, 3]);
      expect(spans.first.text(text, tokens), 'two hundred and fifty');
    });

    test('ordinals and times are not amounts', () {
      expect(numbers('on the 3rd'), isEmpty);
      expect(numbers('at 5pm'), isEmpty);
    });

    test('claimed tokens are skipped', () {
      final tokens = tokenize('2 days ago I spent 300');
      final spans = findNumbers(tokens, enPack, claimed: {0});
      expect(spans.map((s) => s.value), [300]);
    });

    test('"a" and "and" alone are not numbers', () {
      expect(numbers('a coffee and a tea'), isEmpty);
    });

    test('every integer from 1 to 999 survives a round trip through words', () {
      String words(int n) {
        const units = [
          '',
          'one',
          'two',
          'three',
          'four',
          'five',
          'six',
          'seven',
          'eight',
          'nine',
          'ten',
          'eleven',
          'twelve',
          'thirteen',
          'fourteen',
          'fifteen',
          'sixteen',
          'seventeen',
          'eighteen',
          'nineteen',
        ];
        const tens = [
          '',
          '',
          'twenty',
          'thirty',
          'forty',
          'fifty',
          'sixty',
          'seventy',
          'eighty',
          'ninety',
        ];
        final h = n ~/ 100;
        final r = n % 100;
        final parts = <String>[];
        if (h > 0) parts.add('${units[h]} hundred');
        if (r > 0) {
          if (h > 0) parts.add('and');
          parts.add(
            r < 20 ? units[r] : '${tens[r ~/ 10]} ${units[r % 10]}'.trim(),
          );
        }
        return parts.join(' ');
      }

      for (var n = 1; n <= 999; n++) {
        final spans = numbers(words(n));
        expect(spans, hasLength(1), reason: '${words(n)} -> $spans');
        expect(spans.single.value, n.toDouble(), reason: words(n));
      }
    });
  });
}
