// A credit notice is the account's bank speaking only when the text says so.
// A payer's notice ("transferred to your account XXXX1234 ... check with your
// bank") comes from someone else, so it must not name the sender's bank as the
// account's issuer. Every message is synthetic; the banks are invented.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

void main() {
  late RuleBundle bundle;
  final engine = RuleEngine();
  setUpAll(() => bundle = testRuleBundle());

  List<MovementFact> read(String sender, String body) => [
    for (final f in engine.interpretDetailed(
      SmsMessage(
        sender: sender,
        body: body,
        observedAt: DateTime.utc(2026, 11, 20, 10),
        sourceKey: 'n',
      ),
      bundle,
      appVersion: 'test',
    ).result.facts)
      if (f is MovementFact) f,
  ];

  test('payer-side wordings name a number and no bank, for any sender', () {
    const cases = <(String, String, String)>[
      (
        'AD-KOTAKB-S',
        'Rs: 4,138.90 has been transferred to your account XXXXXXX1234 on 05-Apr-2026. Please check with your bank for details. From Kotak Bank',
        '1234',
      ),
      (
        'VM-GENBNK-S',
        'Rs 7,200.00 has been transferred to your account XXXXXX4321 on 07-Nov-2026. Please check with your bank for details. From Sample Bank',
        '4321',
      ),
      (
        'AD-GENPAY-S',
        'Your account XX4455 has been credited with INR 9,250.50 by Example Payouts Ltd. Kindly check your bank statement for the credit.',
        '4455',
      ),
      (
        'JX-GENBRK-S',
        'INR 12,000 was remitted to your a/c no. 667788 on 11-Nov-2026. Contact your bank for details.',
        '667788',
      ),
    ];
    for (final (sender, body, mask) in cases) {
      final facts = read(sender, body);
      expect(facts, hasLength(1), reason: body);
      expect(facts.single.direction, Direction.credit, reason: body);
      expect(facts.single.instrument?.kind, InstrumentKind.bankAccount, reason: body);
      expect(facts.single.instrument?.maskDigits, mask, reason: body);
      expect(facts.single.instrument?.issuerSlug, isNull, reason: body);
    }
  });

  test('the account\'s own bank still names itself', () {
    // Own-bank alerts: the bank is named next to the account, or the message
    // carries a balance, which only the account's own bank prints.
    const cases = <(String, String)>[
      (
        'AD-KOTAKB-S',
        'Rs.5,000.00 has been transferred to your Kotak Bank account XX1234 on 12-Oct-26 from RAHUL KUMAR. Ref 123456789012.',
      ),
      (
        'AD-KOTAKB-S',
        'Rs.5,000.00 has been transferred to your Kotak Bank account XX1234 on 12-Oct-26 from RAHUL KUMAR. Ref 123456789012. Avl Bal Rs.12,345.67',
      ),
    ];
    for (final (sender, body) in cases) {
      final facts = read(sender, body);
      expect(facts, isNotEmpty, reason: body);
      expect(facts.first.instrument?.issuerSlug, 'kotak', reason: body);
    }
  });

  test('a debit, a future transfer, or a failed one is not a payer notice', () {
    for (final body in [
      'Rs 4,100.00 will be transferred to your account XXXX1234 on 05-Apr-2027. Please check with your bank for details.',
      'Rs 4,100.00 has not been transferred to your account XXXX1234 as the account is closed. Please check with your bank for details.',
      'Rs 4,100.00 debited from your account XXXX1234 for a transfer. Please check with your bank for details.',
    ]) {
      final facts = read('VM-GENBNK-S', body);
      expect(
        facts.where((f) => f.direction == Direction.credit && f.instrument?.issuerSlug == null),
        isEmpty,
        reason: body,
      );
    }
  });
}
