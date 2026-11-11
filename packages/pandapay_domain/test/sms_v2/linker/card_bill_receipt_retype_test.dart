// A "your card bill has been paid" receipt that joins a bank debit says what
// the debit was: a credit card bill payment, whatever name the bank printed for
// the payee. This holds for any bill-pay app, not one brand, and it must not
// depend on the order the two messages arrive in. Synthetic facts only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A receipt: the app says the bill of the card ending [mask] was paid.
MovementFact receipt(
  int minor,
  String at, {
  String issuer = 'HDFC Bank',
  String? mask = '5678',
  String purpose = 'card_payment',
}) => debit(
  purpose,
  minor,
  at: at,
  counterparty: party(name: issuer, kind: 'own', mask: mask),
  evidenceOnly: true,
);

/// The bank debit, typed from the payee name the bank printed.
MovementFact bankDebit(
  int minor,
  String at, {
  String purpose = 'p2p',
  String payee = 'SOME BILLPAY APP PRIV',
  Instrument? from,
}) => debit(
  purpose,
  minor,
  at: at,
  inst: from ?? hdfcAcct,
  counterparty: party(name: payee, kind: 'merchant'),
);

MemoryEvents link(List<Fact> facts, {Map<String, Instrument>? known}) {
  final store = MemoryEvents();
  final seen = <Fact>[];
  for (final f in facts) {
    store.apply(
      testLinker().link(
        incoming: [f],
        context: RuleLinkContext(
          recentFacts: [...seen],
          openEvents: store.open,
          instrumentsById: known ?? allInstruments,
          knownEvents: store.all,
        ),
        rules: baselineLinkRules(),
      ),
    );
    seen.add(f);
  }
  return store;
}

List<LedgerEntry> project(
  MemoryEvents store,
  List<Fact> facts, {
  Map<String, Instrument>? known,
}) {
  final byId = {for (final f in facts) f.factId: f};
  final projector = DefaultLedgerProjector();
  return [
    for (final e in store.all)
      ...projector.project(e, byId, known ?? allInstruments, null),
  ];
}

Event only(MemoryEvents s) {
  // Receipts never make an event of their own, so one debit is one event.
  expect(s.all, hasLength(1), reason: s.all.map((e) => e.type).toString());
  return s.all.single;
}

void main() {
  group('a card-bill receipt joins a debit and settles what it was', () {
    for (final purpose in ['p2p', 'purchase', 'bill_payment', 'unknown']) {
      test('a $purpose-typed debit becomes a card bill payment, in either order', () {
        final r = receipt(2431134, '2026-03-31T18:00:00Z');
        final d = bankDebit(2431134, '2026-03-31T18:05:00Z', purpose: purpose);
        for (final order in [
          [r, d],
          [d, r],
        ]) {
          final s = link(order);
          final e = only(s);
          expect(e.type, EventType.cardBillPayment);
          final legs = {for (final l in e.legs) l.factId: l.role};
          expect(legs[d.factId], LegRole.debitLeg);
          expect(legs[r.factId], LegRole.duplicateNotice);
          final entries = project(s, order);
          expect(entries, hasLength(1));
          expect(entries.single.isSpend, isFalse);
          expect(entries.single.countsAsTransaction, isFalse);
        }
      });
    }

    test('the card the receipt names becomes the destination of the payment', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z', mask: '5678');
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      for (final order in [
        [r, d],
        [d, r],
      ]) {
        final entry = project(link(order), order).single;
        expect(entry.from, isA<InstrumentEndpoint>());
        expect((entry.from as InstrumentEndpoint).instrumentId, hdfcAcct.instrumentId);
        expect(entry.to, isA<InstrumentEndpoint>());
        expect((entry.to as InstrumentEndpoint).instrumentId, hdfcCard.instrumentId);
      }
    });

    test('a card the user has no record of is not invented: the card stays unresolved', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z', mask: '0000');
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      final entry = project(link([r, d]), [r, d]).single;
      expect(entry.isSpend, isFalse);
      expect(entry.to, isA<OwnUnresolvedEndpoint>());
      expect((entry.to as OwnUnresolvedEndpoint).kind, InstrumentKind.creditCard);
    });

    test('two cards that end in the same digits are told apart by the issuer name', () {
      final other = instrument(
        '00000000-0000-4000-8000-0000000000aa',
        InstrumentKind.creditCard,
        'icici',
        '5678',
      );
      final known = {...allInstruments, other.instrumentId: other};
      final r = receipt(50000, '2026-03-31T18:00:00Z', issuer: 'ICICI Bank', mask: '5678');
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      final entry = project(link([r, d], known: known), [r, d], known: known).single;
      expect((entry.to as InstrumentEndpoint).instrumentId, other.instrumentId);
    });

    test('two cards with the same digits and no issuer to tell them apart: unresolved, not guessed', () {
      final other = instrument(
        '00000000-0000-4000-8000-0000000000ab',
        InstrumentKind.creditCard,
        'icici',
        '5678',
      );
      final known = {...allInstruments, other.instrumentId: other};
      final r = receipt(50000, '2026-03-31T18:00:00Z', issuer: 'Some App', mask: '5678');
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      final entry = project(link([r, d], known: known), [r, d], known: known).single;
      expect(entry.to, isA<OwnUnresolvedEndpoint>());
    });

    test('a receipt with no card number still settles the type', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z', mask: null);
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      final s = link([r, d]);
      expect(only(s).type, EventType.cardBillPayment);
      expect(project(s, [r, d]).single.to, isA<OwnUnresolvedEndpoint>());
    });
  });

  group('what must NOT become a card bill payment', () {
    test('a receipt for something else (a food order) leaves the debit a purchase', () {
      final r = receipt(30000, '2026-03-31T18:00:00Z', purpose: 'purchase');
      final d = bankDebit(30000, '2026-03-31T18:05:00Z', purpose: 'purchase');
      expect(only(link([r, d])).type, EventType.purchase);
    });

    test('a different amount is a different payment', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z');
      final d = bankDebit(50001, '2026-03-31T18:05:00Z');
      final s = link([r, d]);
      expect(s.all.single.type, EventType.p2pOut);
      expect(s.all.single.legs.every((l) => l.role != LegRole.duplicateNotice), isTrue);
    });

    test('an amount far outside the join window is not the same payment', () {
      final r = receipt(50000, '2026-03-01T18:00:00Z');
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      expect(link([r, d]).all.single.type, EventType.p2pOut);
    });

    test('a purchase made ON a credit card is never a bill payment', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z');
      final d = debit(
        'purchase',
        50000,
        at: '2026-03-31T18:05:00Z',
        inst: hdfcCard,
        counterparty: party(name: 'ZOMATO', kind: 'merchant'),
      );
      expect(only(link([r, d])).type, EventType.purchase);
    });

    for (final purpose in ['investment', 'wallet_topup', 'atm', 'emi']) {
      test('a $purpose debit keeps its own type', () {
        final r = receipt(50000, '2026-03-31T18:00:00Z');
        final d = bankDebit(50000, '2026-03-31T18:05:00Z', purpose: purpose);
        final s = link([r, d]);
        expect(s.all.every((e) => e.type != EventType.cardBillPayment), isTrue, reason: '$purpose');
      });
    }

    test('a debit that is already a card payment stays one and keeps its card-side leg', () {
      final r = receipt(50000, '2026-03-31T18:00:00Z');
      final d = debit(
        'card_payment',
        50000,
        at: '2026-03-31T18:05:00Z',
        inst: hdfcAcct,
        counterparty: party(name: 'HDFC Bank', kind: 'own', mask: '5678'),
      );
      final c = credit(
        'card_payment',
        50000,
        at: '2026-03-31T18:06:00Z',
        inst: hdfcCard,
      );
      for (final order in [
        [r, d, c],
        [d, c, r],
        [c, r, d],
      ]) {
        final s = link(order);
        final payments = s.all.where((e) => e.type == EventType.cardBillPayment).toList();
        expect(payments, hasLength(1), reason: s.all.map((e) => e.type).toString());
        final roles = payments.single.legs.map((l) => l.role).toSet();
        expect(roles, containsAll([LegRole.debitLeg, LegRole.creditLeg]));
        expect(doubleCounted(s.all, {for (final f in order) f.factId: f}), isEmpty);
      }
    });

    test('two payments of the same amount, two receipts: each stays with its own debit', () {
      final r1 = receipt(50000, '2026-03-10T10:00:00Z');
      final d1 = bankDebit(50000, '2026-03-10T10:02:00Z');
      final r2 = receipt(50000, '2026-03-20T10:00:00Z');
      final d2 = bankDebit(50000, '2026-03-20T10:02:00Z');
      final s = link([r1, d1, r2, d2]);
      expect(s.all.where((e) => e.type == EventType.cardBillPayment), hasLength(2));
      expect(s.all.where((e) => e.type == EventType.p2pOut), isEmpty);
    });

    test('a plain debit with no receipt is unchanged', () {
      final d = bankDebit(50000, '2026-03-31T18:05:00Z');
      expect(only(link([d])).type, EventType.p2pOut);
    });
  });

  test('replaying the same facts twice gives the same events (idempotent)', () {
    final r = receipt(50000, '2026-03-31T18:00:00Z');
    final d = bankDebit(50000, '2026-03-31T18:05:00Z');
    final first = link([d, r]);
    final second = link([d, r]);
    String shape(MemoryEvents s) => [
      for (final e in s.all) '${e.type.wire}:${(e.legs.map((l) => l.role.wire).toList()..sort()).join('+')}',
    ].join(',');
    expect(shape(second), shape(first));
    expect(shape(first), 'card_bill_payment:debit_leg+duplicate_notice');
  });
}
