import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// A message that says "credit card" must read as a credit card, whatever the
// bank and even when no bank-specific rule matches (synthetic messages).
void main() {
  final bundle = testRuleBundle();
  final engine = RuleEngine();

  MovementFact read(String body, {String sender = 'VM-HDFCBK-S'}) {
    final out = engine.interpretDetailed(
      SmsMessage(
        sender: sender,
        body: body,
        observedAt: DateTime.utc(2026, 11, 7, 10),
        sourceKey: 'sms:gen-cc:${body.hashCode}',
      ),
      bundle,
      appVersion: 'x',
    );
    expect(out.result.outcome, InterpretOutcome.matched, reason: body);
    return out.result.facts.whereType<MovementFact>().single;
  }

  for (final body in const [
    'Rs 500.00 credited to your credit card ending 4321 on 24-10-26.',
    'Rs 500.00 credited to your Example Credit Card XX4321 on 24-10-26.',
    'Rs.10.11 has been credited to your credit card ending with 4321 as reversal of UPI trxn. dated 07-11-26 at EXAMPLE STORE (UPI Ref No. •••• 9876) - Example Card',
  ]) {
    test('credit card: $body', () {
      final m = read(body, sender: 'SBICRD-S').instrument!;
      expect(m.kind, InstrumentKind.creditCard);
      expect(m.maskDigits, '4321');
    });
  }

  test('a plain "card" is not typed as a credit card', () {
    final m = read('Rs 500.00 credited to your card ending 4321 on 24-10-26.').instrument!;
    expect(m.kind, isNot(InstrumentKind.creditCard));
  });
}
