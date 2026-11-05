@Tags(['benchmark'])
library;

import 'dart:math';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// 20,000 facts over a year: card and UPI spends, card bill pairs, refunds,
/// own transfers, wallet top-ups, IPO holds, mandate charges and receipts.
/// Gate: one link call under 5 seconds.
void main() {
  test('links 20,000 facts in under 5 seconds', () {
    final rnd = Random(7);
    final start = DateTime.utc(2026, 1, 1);
    String at(int minutes) =>
        start.add(Duration(minutes: minutes)).toIso8601String();
    final facts = <Fact>[];
    var t = 0;
    while (facts.length < 20000) {
      t += 20 + rnd.nextInt(30);
      final amount = (1 + rnd.nextInt(5000)) * 100;
      switch (rnd.nextInt(10)) {
        case 0:
          facts
            ..add(
              debit(
                'card_payment',
                amount,
                at: at(t),
                inst: hdfcAcct,
                counterparty: party(kind: 'own', mask: '5678'),
              ),
            )
            ..add(
              credit('card_payment', amount, at: at(t + 2), inst: hdfcCard),
            );
        case 1:
          facts
            ..add(
              debit(
                'purchase',
                amount,
                at: at(t),
                inst: hdfcCard,
                counterparty: party(name: 'SHOP${rnd.nextInt(50)}'),
              ),
            )
            ..add(
              credit('refund', amount ~/ 2, at: at(t + 600), inst: hdfcCard),
            );
        case 2:
          facts
            ..add(
              debit(
                'transfer',
                amount,
                at: at(t),
                inst: hdfcAcct,
                counterparty: party(kind: 'own', mask: '9999'),
              ),
            )
            ..add(credit('p2p', amount, at: at(t + 1), inst: hdfcSaving));
        case 3:
          facts
            ..add(
              debit(
                'wallet_topup',
                amount,
                at: at(t),
                inst: hdfcAcct,
                counterparty: party(vpa: 'add-money@paytm', kind: 'own'),
              ),
            )
            ..add(
              credit('wallet_topup', amount, at: at(t + 1), inst: paytmWallet),
            );
        case 4:
          facts
            ..add(
              hold(
                'placed',
                amount,
                at: at(t),
                inst: hdfcAcct,
                issue: 'ISSUE$t',
              ),
            )
            ..add(
              debit(
                'investment',
                amount,
                at: at(t + 5000),
                inst: hdfcAcct,
                counterparty: party(name: 'ISSUE$t'),
              ),
            );
        case 5:
          facts
            ..add(
              mandate(
                'created',
                at: at(t),
                merchant: 'SUB${rnd.nextInt(20)}',
                ceiling: 500000,
              ),
            )
            ..add(
              debit(
                'purchase',
                amount % 400000 + 100,
                at: at(t + 100),
                inst: hdfcAcct,
                counterparty: party(name: 'SUB${rnd.nextInt(20)}'),
              ),
            );
        case 6:
          facts
            ..add(
              debit(
                'bill_payment',
                amount,
                at: at(t),
                inst: hdfcAcct,
                counterparty: party(name: 'BILLER'),
              ),
            )
            ..add(
              debit(
                'bill_payment',
                amount,
                at: at(t + 3),
                counterparty: party(name: 'BILLER'),
                evidenceOnly: true,
              ),
            );
        default:
          facts.add(
            debit(
              rnd.nextBool() ? 'purchase' : 'p2p',
              amount,
              at: at(t),
              inst: rnd.nextBool() ? hdfcAcct : iciciCard,
              counterparty: party(name: 'M${rnd.nextInt(500)}'),
              ruleId: 'R${rnd.nextInt(3)}',
            ),
          );
      }
    }
    final rules = baselineLinkRules();
    final sw = Stopwatch()..start();
    final r = linkAll(facts, rules: rules);
    sw.stop();
    final events = eventsOf(r);
    // ignore: avoid_print
    print(
      'linked ${facts.length} facts into ${events.length} events in ${sw.elapsedMilliseconds} ms',
    );
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(
      doubleCounted(events, {for (final f in facts) f.factId: f}),
      isEmpty,
    );
  });
}
