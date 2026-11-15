import 'package:pandapay_domain/sms_v2_template.dart';
import 'package:test/test.dart';

/// A card printed with digits at both ends is a mask, not a name. Before this,
/// its middle ("XXXXXXXX3456") fell into the "unknown capitalised word is a
/// name" net and became `<PARTY>`. Every number below is invented.
void main() {
  RedactedSms redact(String body) => redactSms(
    sender: 'HDFCBK',
    body: body,
    observedAt: DateTime.utc(2026, 9, 14),
    options: SmsRedactionOptions(salt: 'a-fixed-test-salt'),
  );

  test('a mask with digits at both ends stays a mask through redaction and skeleton', () {
    for (final body in [
      'Rs.450 spent on card 4012XXXXXXXX3456 at SWIGGY.',
      'INR 99.00 spent on card 12XXXXXX78 at SWIGGY.',
    ]) {
      final redacted = redact(body).body;
      expect(redacted, isNot(contains('<PARTY>')), reason: body);
      expect(redacted, contains('XX'), reason: 'the shape of the mask is kept');
      expect(redacted, isNot(contains('3456')));
      expect(redacted, isNot(contains('4012')));
      expect(smsSkeleton(redacted), contains('<MASK>'), reason: body);
    }
  });

  test('the layout is the same whatever the digits at the ends are', () {
    final a = smsSkeleton(redact('Rs.450 spent on card 4012XXXXXXXX3456.').body);
    final b = smsSkeleton(redact('Rs.999 spent on card 7788XXXXXXXX0021.').body);
    expect(a, b);
    expect(a, '<AMT> spent on card <MASK>.');
  });
}
