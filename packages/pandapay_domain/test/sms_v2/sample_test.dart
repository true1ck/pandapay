import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

/// Every name and number below is invented. `smsSample` is the wording of a
/// message that may be shown to the AI: the redacted text, or nothing.
void main() {
  const original =
      'Rs.4,821.50 debited from A/c XX1234 on 14-09-26 to RAHUL SHARMA. UPI Ref 427711903388. Avl bal Rs 61,204.17';
  String redact(String body) => redactSms(
    sender: 'HDFCBK',
    body: body,
    observedAt: DateTime.utc(2026, 9, 14),
    options: SmsRedactionOptions(salt: 'a-fixed-test-salt'),
  ).body;

  test('the wording of a redacted message goes as a sample, spaces collapsed', () {
    final sample = smsSample(original: original, redacted: redact(original));
    expect(sample, isNotNull);
    expect(sample, isNot(contains('  ')));
    for (final secret in ['4,821', '4821', '1234', '427711903388', 'RAHUL', 'SHARMA', '61,204']) {
      expect(sample!.toLowerCase(), isNot(contains(secret.toLowerCase())), reason: secret);
    }
    expect(sample, contains('debited from A/c'));
    // The sample has the layout the upload names: the same words, the same slots.
    expect(smsSkeleton(sample!), smsSkeleton(redact(original)));
  });

  test('nothing goes when a number of the original could still be in it', () {
    expect(smsSample(original: 'Rs.4821 paid to X', redacted: 'Rs.4821 paid to <PARTY>'), isNull);
    expect(smsSample(original: 'code 482910 sent', redacted: 'code 482910 sent'), isNull);
    // Three digits are found even inside a longer made-up number.
    expect(smsSample(original: 'ref 427 here', redacted: 'ref 9427118 here'), isNull);
    // And every such run counts, not just the first.
    expect(smsSample(original: 'Rs.100 and Rs.250', redacted: 'Rs.771 and Rs.250'), isNull);
  });

  test('years are public, so a date alone does not hold a sample back', () {
    expect(
      smsSample(original: 'paid on 20/11/2026 ok', redacted: 'paid on 05/02/2026 ok'),
      'paid on 05/02/2026 ok',
    );
  });

  test('links, addresses, and anything too long or empty never go', () {
    for (final redacted in [
      'see https://a.example now',
      'mail me at name@bank now',
      'visit www.example.com now',
      'open pay.in/x now',
      '   ',
      '',
      List.filled(1500, 'ab').join(' '),
    ]) {
      expect(smsSample(original: 'x', redacted: redacted), isNull, reason: redacted.length > 40 ? 'long text' : redacted);
    }
    // Tags for what was hidden are fine: they are not the values.
    expect(
      smsSample(original: 'x', redacted: 'Hi <PARTY>, call <PHONE> or mail <EMAIL> at <URL>'),
      'Hi <PARTY>, call <PHONE> or mail <EMAIL> at <URL>',
    );
  });
}
