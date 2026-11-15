// The labelled-payee debit rules (GENZ-ACCT-DR-LABELED-PAYEE*): the account, the debit word and the amount are
// found first, then ANY filler, then a label ("Fvg:", "favouring", "in favour of", "Beneficiary:", "Payee:")
// and the name after it. No rule here is written per bank. Every message is synthetic.
//
// Run WITHOUT the bank's own Union rules, as a phone does while those are out of date, so the generalized rule
// is what reads the message. The reading must be complete and confident (no fact below 0.7: anything lower is
// sent to review), and must never invent a payee.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

void main() {
  test('label-anchored payee for any bank and layout, confident, never invented', () {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    final raw = Map<String, Object?>.of(source.bundle);
    raw['rules'] = [
      for (final r in raw['rules'] as List)
        if (!((r as Map)['id'] as String).startsWith('UNION-')) r,
    ];
    final bundle = parseUnsignedBundle(raw);
    final engine = RuleEngine();
    const ref = '612345678901';
    // label, sender, body, expected payee (null = this rule family must not name anyone)
    final cases = <(String, String, String, String?)>[
      ('mob bk, balance + footer', 'VA-UNIONB-T', 'Union Bank of India A/c *8565 Debited Rs:2900.00 on 21-10-2026 19:28:42 by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92. Not you?Call 1800000000/SMS BLOCK 8565 to 8879365472', 'Asha Rao'),
      ('initial in the name', 'JK-UNIONB-T', 'Union Bank of India A/c *8565 Debited Rs:81.00 on 25-10-2026 22:00:20 by Mob Bk ref no $ref, Fvg: Amazon P Avl Bal Rs:1723.92. Not you?Call 1800000000', 'Amazon P'),
      ('no balance', 'VM-NEWBNK-S', 'NewBank A/c *1234 Debited Rs:2500.00 on 21-10-2026 by Mob Bk ref no $ref, Fvg: Asha Rao. Not you?Call 1800000000', 'Asha Rao'),
      ('different rail, "for", favouring', 'VM-NEWBNK-S', 'NewBank A/c XX1234 Debited for Rs. 2,900.00 on 21-Oct-26 by NEFT UTR $ref favouring Ravi Kumar Avl Bal Rs. 594.92', 'Ravi Kumar'),
      ('in favour of', 'VM-NEWBNK-S', 'Your A/c No. XX1234 is debited for Rs. 750 on 25-Oct-26 through IMPS Ref $ref in favour of Kiran Shah. Avl Bal Rs 9,000.00', 'Kiran Shah'),
      ('amount first, beneficiary', 'VM-NEWBNK-S', 'NewBank: Rs 1,250.00 debited from A/c XX1234 on 22-Oct-26 by UPI ref $ref Beneficiary: Neha Das Avl Bal Rs 8,100.00', 'Neha Das'),
      ('amount first, payee, no date', 'VM-NEWBNK-S', 'INR 400 debited from your account no. 1234 by IMPS Ref $ref Payee: Omar Khan', 'Omar Khan'),
      // must not name anyone through these rules
      ('future debit', 'VM-NEWBNK-S', 'NewBank A/c *1234 will be Debited Rs:2500.00 on 21-10-2026 by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92', null),
      ('failed debit', 'VM-NEWBNK-S', 'NewBank A/c *1234 Debit of Rs:2500.00 on 21-10-2026 by Mob Bk ref no $ref, Fvg: Asha Rao failed. Avl Bal Rs:594.92', null),
      ('credit side', 'VM-NEWBNK-S', 'NewBank A/c *1234 Credited Rs:2500.00 on 21-10-2026 19:28:42 by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92', null),
      ('label but no debit', 'VM-NEWBNK-S', 'NewBank: payee Asha Rao was added to your account. Rs 500 limit set for new payees.', null),
      ('debit with no label', 'VM-NEWBNK-S', 'NewBank A/c *1234 Debited Rs:2500.00 on 21-10-2026 by Mob Bk ref no $ref Avl Bal Rs:594.92. Not you?Call 1800000000', null),
    ];
    final bad = <String>[];
    for (final (label, sender, body, want) in cases) {
      final o = engine.interpretDetailed(
        SmsMessage(sender: sender, body: body, observedAt: DateTime.utc(2026, 10, 21, 14), sourceKey: 'k'),
        bundle,
        appVersion: 'test',
      );
      final fromThisFamily = '${o.winnerId}'.startsWith('GENZ-ACCT-DR-LABELED-PAYEE');
      String? got;
      for (final f in o.result.facts) {
        final j = f.toJson();
        if (j['factType'] == 'movement') {
          final c = j['counterparty'] as Map?;
          got = (c?['name'] ?? c?['vpa']) as String?;
        }
      }
      if (want != null) {
        if (!fromThisFamily || got != want) bad.add('$label: ${o.winnerId} payee=$got want $want');
        if (o.result.facts.any((f) => f.confidence < 0.7)) bad.add('$label: a fact below 0.7 would go to review');
      } else if (fromThisFamily) {
        bad.add('$label: read by ${o.winnerId}, must not be');
      }
    }
    expect(bad, isEmpty);
  });
}
