import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

/// Lane P: the engine skips a rule whose regex cannot match because a literal
/// it requires is absent from the body. These tests pin that the extracted
/// literals are always genuinely required, never more.
void main() {
  group('requiredLiterals', () {
    test('keeps literal words outside groups and classes, at most three', () {
      final got = requiredLiterals(
        r'\bsent\s+(?:rs\.?|inr)\s*(?<amt>\d+)\s+from\s+hdfc\s+bank',
      );
      expect(got, hasLength(3));
      expect(got.toSet().difference({'sent', 'from', 'hdfc', 'bank'}), isEmpty);
    });

    test('drops a literal made optional by a quantifier', () {
      expect(requiredLiterals(r'abcd?'), ['abc']);
      expect(requiredLiterals(r'xyzab*'), ['xyza']);
      expect(requiredLiterals(r'debit?ed'), ['debi']);
      expect(requiredLiterals(r'spent+ on'), ['spent', ' on']);
      expect(requiredLiterals(r'abcd{0,2}efg'), unorderedEquals(['abc', 'efg']));
    });

    test('gives up on top-level alternation and unreadable escapes', () {
      expect(requiredLiterals(r'credited|debited'), isEmpty);
      expect(requiredLiterals(r'abc\k<name>def'), isEmpty);
      expect(requiredLiterals(r'abc\u00e9def'), isEmpty);
      expect(requiredLiterals(r'(?:credited|debited) towards'), [' towards']);
    });

    test('treats escaped punctuation as a literal and lowercases', () {
      expect(requiredLiterals(r'A/C\.\s'), ['a/c.']);
      expect(requiredLiterals(r'Ref\.No\.'), ['ref.no.']);
      expect(requiredLiterals(r'[abc]UPIMandate\d'), ['upimandate']);
    });

    test('a rule is skipped only when its regex truly cannot match', () {
      final pattern = RegExp(r'\bspent\s+rs\.?\s*(\d+)', caseSensitive: false);
      final literals = requiredLiterals(pattern.pattern);
      for (final body in ['Spent  Rs.12 now', 'you SPENT rs 5', 'nothing here']) {
        final lower = body.toLowerCase();
        final could = literals.every(lower.contains);
        if (pattern.hasMatch(body)) expect(could, isTrue, reason: body);
      }
    });
  });
}
