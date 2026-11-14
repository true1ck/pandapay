// A debit that a generic rule read without saying who was paid gets its payee
// from the evidence: the name that sits next to a payee cue word (the pack's
// `payeeDebit` list). No rule is written per bank or per wording, so a reworded
// alert needs no new rule. The payee is only ever FILLED IN: never invented,
// never taken from wording that is not a payee. Every message is synthetic.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/rules_source.dart';
import 'package:test/test.dart';

void main() {
  test('payee found by evidence for any bank, never invented', () {
    final source = readRulesFolder('../../rules/sms/v2');
    expect(source.problems, isEmpty);
    final bundle = parseUnsignedBundle(source.bundle);
    final engine = RuleEngine();
    const ref = '612345678901';
    const pre = 'NewBank A/c *1234 Debited Rs:2500.00 on 21-10-2026 19:28:42';
    // label, body, expected payee (null = no payee may be read)
    final cases = <(String, String, String?)>[
      ('mob bk fvg + balance', '$pre by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92. Not you?Call 1800000000', 'Asha Rao'),
      ('fvg, no balance', '$pre by Mob Bk ref no $ref, Fvg: Asha Rao. Not you?Call 1800000000', 'Asha Rao'),
      ('fvg shop', '$pre by Mobile Banking Ref No $ref, Fvg: Swiggy Avl Bal Rs:594.92', 'Swiggy'),
      ('fvg after imps', 'NewBank A/c XX1234 Debited for Rs. 2,500.00 on 21-Oct-26 by IMPS ref no $ref Fvg: Ravi Kumar Avl Bal Rs. 594.92', 'Ravi Kumar'),
      ('favouring after neft', '$pre by NEFT UTR $ref in favouring Meera Iyer Avl Bal Rs:594.92', 'Meera Iyer'),
      ('to after upi', 'INR500.00 debited from your A/c ending 3398 for UPI txn to SNEHA VERMA on 06-11-2026. Ref no $ref.', 'SNEHA VERMA'),
      ('towards after card', 'Debit notification: Rs 649.00 was debited from your card ending 1234 towards NETFLIX on 05-Nov-26.', 'NETFLIX'),
      // must stay without a payee
      ('no cue at all', '$pre by Mob Bk ref no $ref Avl Bal Rs:594.92', null),
      ('balance transfer to another bank', 'Rs.499.00 debited from A/c XX1234 for balance transfer to another bank', null),
      ('will be debited', 'NewBank A/c *1234 will be Debited Rs:2500.00 on 21-10-2026 by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92', null),
      ('credit side', 'NewBank A/c *1234 Credited Rs:2500.00 on 21-10-2026 19:28:42 by Mob Bk ref no $ref, Fvg: Asha Rao Avl Bal Rs:594.92', null),
      ('call footer is not a payee', '$pre by Mob Bk ref no $ref Avl Bal Rs:594.92. Not you? Call 1800000000 to report', null),
    ];
    final bad = <String>[];
    for (final (label, body, want) in cases) {
      final o = engine.interpretDetailed(
        SmsMessage(sender: 'VM-NEWBNK-S', body: body, observedAt: DateTime.utc(2026, 10, 21, 14), sourceKey: 'k'),
        bundle,
        appVersion: 'test',
      );
      String? got;
      for (final f in o.result.facts) {
        final j = f.toJson();
        if (j['factType'] == 'movement') {
          final c = j['counterparty'] as Map?;
          got = (c?['name'] ?? c?['vpa']) as String?;
        }
      }
      if (got != want) bad.add('$label: got $got want $want (${o.winnerId})');
    }
    expect(bad, isEmpty);
  });
}
