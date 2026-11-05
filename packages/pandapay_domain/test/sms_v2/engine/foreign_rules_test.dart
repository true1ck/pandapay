import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import '../support/rules.dart';

// The real foreign-currency rules (rules/sms/v2/foreign and the card-spend
// foreign family), run through the engine with synthetic messages.

SmsMessage _m(String sender, String body) => SmsMessage(
  sender: sender,
  body: body,
  observedAt: DateTime.utc(2026, 11, 3, 10),
  sourceKey: 'sms:fx:${body.hashCode}',
);

void main() {
  final bundle = testRuleBundle();
  final engine = RuleEngine();

  EngineOutcome run(String body, {String sender = 'VM-HDFCBK-S'}) =>
      engine.interpretDetailed(_m(sender, body), bundle, appVersion: 'x');

  Amount posted(String body, {String sender = 'VM-HDFCBK-S'}) {
    final out = run(body, sender: sender);
    expect(out.result.outcome, InterpretOutcome.matched, reason: body);
    final movement = out.result.facts.whereType<MovementFact>().single;
    return movement.amount(AmountRole.posted)!;
  }

  group('foreign only: the price stays in its own currency', () {
    const cases = <(String, int, String)>[
      ('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.', 2000, 'USD'),
      ('Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11. Avl Lmt: Rs.100000.00', 2000, 'USD'),
      ('AED 100.00 spent using Axis Bank Card XX4321 at SAMPLE MART on 01-11-2026.', 10000, 'AED'),
      ('Transaction of EUR 15.50 done on HDFC Bank Credit Card ending 1234 at SAMPLE on 01-11-2026.', 1550, 'EUR'),
      ('Your card ending 1234 has been used for an international transaction of GBP 9.99 at SAMPLE on 01-11-2026.', 999, 'GBP'),
      ('Spent SGD 1,045.50 on HDFC Bank Card x1234 at SAMPLE on 2026-11-01:07:00:11.', 104550, 'SGD'),
      ('Spent JPY 1,500 on HDFC Bank Debit Card x1234 at SAMPLE on 2026-11-01:07:00:11.', 1500, 'JPY'),
      ('Spent KWD 3.250 on HDFC Bank Card x1234 at SAMPLE on 2026-11-01:07:00:11.', 3250, 'KWD'),
      ('Spent US\$ 9.99 on HDFC Bank Card x1234 at SAMPLE on 2026-11-01:07:00:11.', 999, 'USD'),
      ('Spent € 10 on HDFC Bank Card x1234 at SAMPLE on 2026-11-01:07:00:11.', 1000, 'EUR'),
      ('Txn of \$20 on Card XX1234 at SAMPLE approved', 2000, 'XXX'),
    ];
    for (final (body, minor, unit) in cases) {
      test(body, () {
        final a = posted(body);
        expect((a.minor, a.unit), (minor, unit));
        expect(a.isInr, isFalse);
        expect(a.original, isNull);
        expect(a.foreign?.currency, unit);
      });
    }

    test('an INR available limit is never the price', () {
      final out = run(
        'Spent USD 20.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11. Avl Lmt: Rs.100000.00',
      );
      for (final f in out.result.facts) {
        if (f is MovementFact) {
          expect(f.amount(AmountRole.posted)!.unit, 'USD');
        } else {
          expect(f.factType, FactType.balanceSnapshot);
        }
      }
    });
  });

  group('INR posted with the foreign amount beside it', () {
    const cases = <(String, String, int, int, String)>[
      ('Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-01:07:00:11.', 'VM-HDFCBK-S', 175000, 2000, 'USD'),
      ('Rs.1,750.00 spent on your SBI Credit Card ending 1234 at SAMPLE AI on 01/11/26 (USD 20.00)', 'VM-SBICRD-S', 175000, 2000, 'USD'),
      ('Rs 1750.00 spent on Kotak Credit Card XX1234 at SAMPLE AI. Foreign currency amount USD 20.00 with forex markup of Rs 52.50 applied.', 'VM-KOTAKB-S', 175000, 2000, 'USD'),
      ('USD 25.00 (approx INR 2,100.00) spent on your HDFC Bank Credit Card ending 1234 at SAMPLE on 22-10-26', 'VM-AXISBK-S', 210000, 2500, 'USD'),
      ('USD 20 spent using HDFC Bank Card XX1234 at SAMPLE AI. Billed INR 1742. Avl Limit INR 100000.', 'VM-HDFCBK-S', 174200, 2000, 'USD'),
      ('Spent Rs.5,000.00 on HDFC Bank Card x1234 at SAMPLE (EUR 52.10) on 2026-11-01:07:00:11.', 'VM-HDFCBK-S', 500000, 5210, 'EUR'),
    ];
    for (final (body, sender, inr, fx, cur) in cases) {
      test(body, () {
        final a = posted(body, sender: sender);
        expect(a.isInr, isTrue);
        expect(a.minor, inr, reason: 'the INR posting, never the markup or the limit');
        expect(a.original?.minor, fx);
        expect(a.original?.currency, cur);
      });
    }

    test('the INR available limit still becomes a balance snapshot', () {
      final out = run(
        'Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI (USD 20.00) on 2026-11-01:07:00:11. Avl Lmt: Rs.98,250.00',
      );
      expect(out.result.facts.map((f) => f.factType), [FactType.movement, FactType.balanceSnapshot]);
      expect(out.result.facts.first.amounts.single.minor, 175000);
    });

    test('a plain INR spend has no original', () {
      final a = posted('Spent Rs.1,750.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
      expect(a.original, isNull);
    });
  });

  group('refunds and reversals', () {
    test('foreign-only refund and reversal are credits in their own currency', () {
      final r = run('Refund of USD 20.00 credited to your HDFC Bank Card x1234 from SAMPLE AI on 2026-11-02.');
      final f = r.result.facts.single as MovementFact;
      expect((f.direction, f.purpose), (Direction.credit, MovementPurpose.refund));
      expect(f.amount(AmountRole.posted)!.unit, 'USD');
      final v = run('Reversal of EUR 15.50 credited to your HDFC Bank Card x1234 from SAMPLE on 2026-11-02.');
      expect((v.result.facts.single as MovementFact).purpose, MovementPurpose.reversal);
    });

    test('a refund with INR credited keeps the foreign amount as the original', () {
      final a = posted('Refund of INR 1750.00 (USD 20.00) credited to your HDFC Bank Credit Card x1234 from SAMPLE AI on 2026-11-02.');
      expect((a.minor, a.original?.minor, a.original?.currency), (175000, 2000, 'USD'));
    });
  });

  group('never a purchase', () {
    test('a zero-value verification is ignored', () {
      final o = run('Spent USD 0.00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.');
      expect(o.result.outcome, InterpretOutcome.ignored);
    });

    for (final body in [
      'Spent USD .00 on HDFC Bank Card x1234 at SAMPLE AI on 2026-11-01:07:00:11.',
      'Txn of \$20 on Card XX1234 at SAMPLE AI declined',
      'Spent USD 1.00 pre-authorization hold on HDFC Bank Card x1234 at HOTEL on 2026-11-01:07:00:11.',
      'USD 20.00 spent using HDFC Bank Card x1234 at SAMPLE AI failed.',
    ]) {
      test('review, not spend: $body', () {
        final o = run(body);
        expect(o.result.outcome, InterpretOutcome.unknown);
      });
    }
  });
}
