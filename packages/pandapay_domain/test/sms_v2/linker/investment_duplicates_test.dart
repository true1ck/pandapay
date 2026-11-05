// Lane S: one payment announced twice (a registrar and the bank, a broker and
// the bank) is counted once. Synthetic facts only.
import 'dart:math';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

const _unnamedAccount = InstrumentMention(kind: InstrumentKind.bankAccount);

/// How many money legs (debit, credit, charge, reversal) carry [minor].
int moneyLegs(Iterable<Event> events, List<Fact> facts, int minor) {
  final byId = {for (final f in facts) f.factId: f};
  var n = 0;
  for (final e in events) {
    for (final l in e.legs) {
      if (!{LegRole.debitLeg, LegRole.creditLeg}.contains(l.role)) continue;
      final f = byId[l.factId];
      if (f is MovementFact && f.amount(AmountRole.posted)?.minor == minor) n++;
    }
  }
  return n;
}

MovementFact registrarDebit(int minor, String at) => move(
  'debit',
  'investment',
  minor,
  at: at,
  mention: _unnamedAccount,
  counterparty: party(name: 'ACME', kind: 'merchant'),
  references: {'asbaRef': 'A100'},
  ruleId: 'IPO-REG-PARTIAL-ALLOTMENT',
);

MovementFact bankDebit(
  int minor,
  String at, {
  Map<String, String> references = const {},
}) => move(
  'debit',
  'investment',
  minor,
  at: at,
  inst: hdfcAcct,
  counterparty: party(name: 'ACME', kind: 'merchant'),
  references: references,
  ruleId: 'INV-IPO-ALLOT-01',
);

MovementFact brokerPayout(int minor, String at, {String? utr}) => move(
  'credit',
  'investment',
  minor,
  at: at,
  counterparty: party(name: 'ACME INVEST', kind: 'merchant'),
  references: {'txnId': ?utr},
  ruleId: 'BRK-PAYOUT-TRANSFER-OK-01',
);

MovementFact bankCredit(int minor, String at, {String? utr}) => move(
  'credit',
  'investment',
  minor,
  at: at,
  inst: hdfcAcct,
  counterparty: party(name: 'ACME INVEST', kind: 'merchant'),
  references: {'txnId': ?utr},
  ruleId: 'INV-BROKER-WITHDRAW-CREDIT-01',
);

/// Links [facts] in the given order, one call each, as live capture does.
MemoryEvents oneByOne(List<Fact> facts) {
  final store = MemoryEvents();
  final seen = <Fact>[];
  for (final f in facts) {
    store.apply(
      testLinker().link(
        incoming: [f],
        context: RuleLinkContext(
          recentFacts: [...seen],
          openEvents: store.open,
          instrumentsById: allInstruments,
          knownEvents: store.all,
        ),
        rules: baselineLinkRules(),
      ),
    );
    seen.add(f);
  }
  return store;
}

void main() {
  group('registrar partial allotment debit and the bank debit alert', () {
    final held = hold(
      'placed',
      1000000,
      at: '2026-11-22T09:00:00Z',
      inst: hdfcAcct,
      issue: 'ACME',
    );
    final release = hold(
      'released',
      750000,
      at: '2026-11-30T09:00:00Z',
      inst: hdfcAcct,
      issue: 'ACME',
    );

    test(
      'a bank alert hours later joins as a duplicate notice, in every order',
      () {
        final reg = registrarDebit(250000, '2026-11-30T09:00:00Z');
        final bank = bankDebit(
          250000,
          '2026-11-30T15:30:00Z',
          references: {'txnId': 'T9'},
        );
        final all = [held, reg, release, bank];
        for (var k = 0; k < 20; k++) {
          final order = k == 0 ? all : ([...all]..shuffle(Random(k)));
          for (final events in [
            MemoryEvents()..apply(linkAll(order)),
            oneByOne(order),
          ]) {
            expect(moneyLegs(events.all, all, 250000), 1, reason: 'order $k');
            // The event that holds the money: one notice is the debit, one the duplicate.
            final withMoney = events.all
                .where((e) => e.legs.any((l) => l.role == LegRole.debitLeg))
                .toList();
            expect(
              withMoney,
              hasLength(1),
              reason: 'order $k: ${events.all.map(shape)}',
            );
            final roles = withMoney.single.legs.map((l) => l.role).toList();
            expect(
              roles.where((r) => r == LegRole.duplicateNotice),
              hasLength(1),
            );
            expect(withMoney.single.type, EventType.ipoApplication);
            expect(withMoney.single.amountMinor, 250000);
            // The notice that names the account is the money.
            final money = withMoney.single.legs.firstWhere(
              (l) => l.role == LegRole.debitLeg,
            );
            expect(money.factId, bank.factId, reason: 'order $k');
            expect(
              doubleCounted(events.all, {for (final f in all) f.factId: f}),
              isEmpty,
            );
          }
        }
      },
    );

    test('with no hold seen, the two debits are still one investment', () {
      final reg = registrarDebit(250000, '2026-11-30T09:00:00Z');
      final bank = bankDebit(250000, '2026-11-30T20:00:00Z');
      final r = linkAll([reg, bank]);
      expect(shapes(r), ['investment[debit_leg,duplicate_notice]']);
    });

    test(
      'a different amount, or more than a day later, is another payment',
      () {
        final reg = registrarDebit(250000, '2026-11-30T09:00:00Z');
        expect(
          shapes(linkAll([reg, bankDebit(260000, '2026-11-30T12:00:00Z')])),
          ['investment[debit_leg]', 'investment[debit_leg]'],
        );
        expect(
          shapes(linkAll([reg, bankDebit(250000, '2026-12-01T10:00:01Z')])),
          ['investment[debit_leg]', 'investment[debit_leg]'],
        );
      },
    );

    test('two real payments of one template on one account stay two', () {
      final a = bankDebit(250000, '2026-11-30T09:00:00Z');
      final b = bankDebit(250000, '2026-11-30T15:00:00Z');
      expect(shapes(linkAll([a, b])), [
        'investment[debit_leg]',
        'investment[debit_leg]',
      ]);
    });

    test('two bank alerts with different transaction ids stay two', () {
      final a = bankDebit(
        250000,
        '2026-11-30T09:00:00Z',
        references: {'txnId': 'T1'},
      );
      final other = move(
        'debit',
        'investment',
        250000,
        at: '2026-11-30T15:00:00Z',
        inst: hdfcAcct,
        references: {'txnId': 'T2'},
        ruleId: 'OTHER-TEMPLATE',
      );
      expect(shapes(linkAll([a, other])), [
        'investment[debit_leg]',
        'investment[debit_leg]',
      ]);
    });
  });

  group('broker payout notice and the bank credit alert', () {
    test('same amount and UTR join as one withdrawal, in either order', () {
      final broker = brokerPayout(500000, '2026-11-05T09:00:00Z', utr: 'CMS1');
      final bank = bankCredit(500000, '2026-11-05T11:00:00Z', utr: 'CMS1');
      for (final order in [
        [broker, bank],
        [bank, broker],
      ]) {
        for (final events in [
          MemoryEvents()..apply(linkAll(order)),
          oneByOne(order),
        ]) {
          expect(events.all, hasLength(1));
          final e = events.all.single;
          expect(
            shape(e),
            'investment_withdrawal[credit_leg,duplicate_notice]',
          );
          expect(moneyLegs(events.all, order, 500000), 1);
          expect(e.amountMinor, 500000);
          expect(
            e.legs.firstWhere((l) => l.role == LegRole.creditLeg).factId,
            bank.factId,
          );
        }
      }
    });

    test('a bank alert without a UTR still joins within the window', () {
      final broker = brokerPayout(500000, '2026-11-05T09:00:00Z', utr: 'CMS1');
      final bank = bankCredit(500000, '2026-11-05T20:00:00Z');
      expect(shapes(linkAll([broker, bank])), [
        'investment_withdrawal[credit_leg,duplicate_notice]',
      ]);
    });

    test(
      'another UTR, another amount or another day is a separate withdrawal',
      () {
        final broker = brokerPayout(
          500000,
          '2026-11-05T09:00:00Z',
          utr: 'CMS1',
        );
        const two = [
          'investment_withdrawal[credit_leg]',
          'investment_withdrawal[credit_leg]',
        ];
        expect(
          shapes(
            linkAll([
              broker,
              bankCredit(500000, '2026-11-05T11:00:00Z', utr: 'CMS2'),
            ]),
          ),
          two,
        );
        expect(
          shapes(
            linkAll([
              broker,
              bankCredit(510000, '2026-11-05T11:00:00Z', utr: 'CMS1'),
            ]),
          ),
          two,
        );
        expect(
          shapes(
            linkAll([
              broker,
              bankCredit(500000, '2026-11-06T09:00:01Z', utr: 'CMS1'),
            ]),
          ),
          two,
        );
      },
    );

    test('two payouts of one template on one account are two withdrawals', () {
      final a = bankCredit(500000, '2026-11-05T09:00:00Z', utr: 'U1');
      final b = bankCredit(500000, '2026-11-05T12:00:00Z', utr: 'U2');
      expect(shapes(linkAll([a, b])).length, 2);
    });

    test('a credit of another purpose never joins', () {
      final broker = brokerPayout(500000, '2026-11-05T09:00:00Z');
      final salary = credit(
        'salary',
        500000,
        at: '2026-11-05T10:00:00Z',
        inst: hdfcAcct,
      );
      expect(shapes(linkAll([broker, salary])), [
        'income[credit_leg]',
        'investment_withdrawal[credit_leg]',
      ]);
    });
  });
}
