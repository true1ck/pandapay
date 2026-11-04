import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

// Lane O (security audit LO-03): ambiguous alternation under an unbounded
// quantifier backtracks exponentially. Mirrors
// api/test/sms_v2/security_audit.test.js; the two linters must agree.
void main() {
  List<String> codes(String pattern) =>
      [for (final issue in lintRegexDialect(pattern, '')) issue.code];

  test('ambiguous alternation under an unbounded quantifier is refused', () {
    for (final pattern in [
      r'^(a|aa)+$',
      r'(?:a|a)*b',
      r'(?:\d|\d\d)+$',
      r'(?:\w|\d)+x',
      r'(?:[a-z ]|\d|\s)*$',
      r'(?:a|aa){1,}$',
      r'^((a|aa))+$',
      r'(?:ab|abc)+$',
      r'(?:a|)+b',
    ]) {
      expect(codes(pattern), contains('lint.regex.nested_quantifier'),
          reason: pattern);
    }
  });

  test('ordinary rule shapes still pass', () {
    for (final pattern in [
      r'^(?:rs\.?|inr)\s*(?<amt>[\d,]+(?:\.\d{1,2})?)\s+spent on card x(?<mask>\d{4})',
      r'(?:a|b){2}',
      r'(?:a|b)?c',
      r'(?:x|y)*',
      r'(?:\s|,)*x',
      r'(?:ab|ac)+',
      r'(?:\d|[a-f])+',
      r'(?:\d|\s)+$',
      r'(?:credited|debited)\s+by',
      r'(?=a|b)[a-z]+',
      r'(?<m>.+?) on (?<d>\d{2})',
    ]) {
      expect(codes(pattern), isEmpty, reason: pattern);
    }
  });
}
