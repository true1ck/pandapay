import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'helpers.dart';

// CCR-005: a forex markup fee posted as its own alert is an INR fee. When the
// alert carries enough to find the transaction (same card, and the same
// reference or the same foreign amount), the fee event takes that transaction
// as its `original` leg. The fee counts once, the transaction is untouched, and
// a fee that cannot be tied to exactly one transaction is an ordinary fee.

MovementFact purchase({
  int minor = 2000,
  String unit = 'USD',
  Map<String, Object?>? original,
  String at = '2026-11-01T09:00:00Z',
  Instrument? inst,
  Map<String, String> references = const {},
  String purpose = 'purchase',
}) => move(
  'debit',
  purpose,
  minor,
  at: at,
  inst: inst ?? hdfcCard,
  unit: unit,
  original: original,
  references: references,
  counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
  rail: purpose == 'atm' ? 'cash' : 'card',
);

MovementFact fee({
  int minor = 5250,
  Map<String, Object?>? original = const {'minor': 2000, 'currency': 'USD'},
  String at = '2026-11-03T09:00:00Z',
  Instrument? inst,
  Map<String, String> references = const {},
}) => move(
  'debit',
  'fee',
  minor,
  at: at,
  inst: inst ?? hdfcCard,
  original: original,
  references: references,
  rail: 'card',
);

Event eventOf(LinkResult r, Fact f) => eventsOf(r).firstWhere(
  (e) => e.legs.any((l) => l.factId == f.factId && l.role != LegRole.original),
);

void main() {
  void expectLinked(LinkResult r, Fact p, Fact f) {
    final e = eventOf(r, f);
    expect(shape(e), 'fee[charge,original]', reason: shapes(r).toString());
    expect(
      e.legs.firstWhere((l) => l.role == LegRole.original).factId,
      p.factId,
    );
    expect(e.legs.firstWhere((l) => l.role == LegRole.charge).factId, f.factId);
    expect(
      e.amountMinor,
      f.amount(AmountRole.posted)!.minor,
      reason: 'the fee, never the purchase',
    );
    expect(
      eventOf(r, p).legs.map((l) => l.role),
      [LegRole.debitLeg],
      reason: 'the purchase keeps its own event',
    );
  }

  void expectPlainFee(LinkResult r, Fact f) {
    expect(
      shape(eventOf(r, f)),
      'fee[debit_leg]',
      reason: shapes(r).toString(),
    );
    expect(
      r.ambiguous,
      isEmpty,
      reason: 'an unlinked fee is never a review item',
    );
  }

  test(
    'a fee naming the foreign amount links to the foreign-only purchase',
    () {
      final p = purchase();
      final f = fee();
      final r = linkAll([p, f]);
      expectLinked(r, p, f);
      expect(eventOf(r, p).amountMinor, 0, reason: 'USD cents are never paise');
    },
  );

  test('the fee counts once and the foreign-only purchase not at all', () {
    final p = purchase();
    final f = fee();
    final r = linkAll([p, f]);
    final facts = {p.factId: p, f.factId: f};
    final projector = DefaultLedgerProjector();
    final rows = [
      for (final e in eventsOf(r))
        ...projector.project(e, facts, allInstruments, null),
    ];
    expect(rows, hasLength(1));
    expect(rows.single.amountMinor, 5250);
    expect(rows.single.isSpend, isTrue);
    expect(doubleCounted(eventsOf(r), facts), isEmpty);
  });

  test('a fee linked to a billed purchase adds only the fee', () {
    final p = purchase(
      minor: 175000,
      unit: 'INR',
      original: {'minor': 2000, 'currency': 'USD'},
    );
    final f = fee();
    final r = linkAll([p, f]);
    expectLinked(r, p, f);
    final facts = {p.factId: p, f.factId: f};
    final projector = DefaultLedgerProjector();
    final spend = [
      for (final e in eventsOf(r))
        ...projector.project(e, facts, allInstruments, null),
    ].where((row) => row.isSpend).fold(0, (s, row) => s + row.amountMinor);
    expect(spend, 175000 + 5250);
  });

  test('the fee arriving before the purchase ends the same', () {
    final p = purchase();
    final f = fee();
    final store = MemoryEvents();
    store.apply(linkAll([f]));
    final r = testLinker().link(
      incoming: [p],
      context: RuleLinkContext(
        recentFacts: [f],
        openEvents: store.open,
        instrumentsById: allInstruments,
        knownEvents: store.all,
      ),
      rules: baselineLinkRules(),
    );
    store.apply(r);
    final all = store.all;
    final feeEvent = all.firstWhere(
      (e) => e.legs.any((l) => l.factId == f.factId),
    );
    expect(shape(feeEvent), 'fee[charge,original]');
    expect(
      feeEvent.eventId,
      linkAll([
        p,
        f,
      ]).created.firstWhere((e) => e.type == EventType.fee).eventId,
    );
    expect(
      all.where((e) => e.type == EventType.purchase).single.legs.single.factId,
      p.factId,
    );
  });

  test('a shared transaction reference links without an amount', () {
    final p = purchase(minor: 10000, references: {'txnId': '612345678901'});
    final f = fee(original: null, references: {'txnId': '612345678901'});
    expectLinked(linkAll([p, f]), p, f);
  });

  test('an ATM withdrawal takes its fee too', () {
    final p = purchase(purpose: 'atm', minor: 20000);
    final f = fee(original: {'minor': 20000, 'currency': 'USD'});
    expectLinked(linkAll([p, f]), p, f);
  });

  group('not enough to link: an ordinary fee', () {
    test('no amount and no reference', () {
      final f = fee(original: null);
      expectPlainFee(linkAll([purchase(), f]), f);
    });

    test('another card', () {
      final f = fee();
      expectPlainFee(linkAll([purchase(inst: iciciCard), f]), f);
    });

    test('another amount or currency', () {
      final f = fee();
      expectPlainFee(
        linkAll([purchase(minor: 2001), purchase(unit: 'EUR'), f]),
        f,
      );
    });

    test('different references of the same kind', () {
      final f = fee(references: {'txnId': '700000000002'});
      expectPlainFee(
        linkAll([
          purchase(references: {'txnId': '700000000001'}),
          f,
        ]),
        f,
      );
    });

    test('two purchases fit: no guess, no review', () {
      final f = fee();
      final r = linkAll([purchase(), purchase(at: '2026-11-02T09:00:00Z'), f]);
      expectPlainFee(r, f);
      expect(
        eventsOf(r).where((e) => e.status == EventStatus.ambiguous),
        isEmpty,
      );
    });

    test('a purchase after the fee is not the one it was charged on', () {
      final f = fee(at: '2026-11-01T09:00:00Z');
      expectPlainFee(linkAll([f, purchase(at: '2026-11-08T09:00:00Z')]), f);
    });

    test('a purchase long before the fee', () {
      final f = fee(at: '2026-12-30T09:00:00Z');
      expectPlainFee(linkAll([purchase(at: '2026-10-01T09:00:00Z'), f]), f);
    });

    test('a refund is never the transaction a fee was charged on', () {
      final refund = move(
        'credit',
        'refund',
        2000,
        at: '2026-11-01T09:00:00Z',
        inst: hdfcCard,
        unit: 'USD',
        rail: 'card',
      );
      final f = fee();
      expectPlainFee(linkAll([refund, f]), f);
    });
  });

  test('a fee with no link evidence keeps the shape it always had', () {
    final f = fee(original: null);
    final e = eventsOf(linkAll([f])).single;
    expect(shape(e), 'fee[debit_leg]');
    expect(e.linkRuleId, isNull);
  });

  test('linking twice changes nothing', () {
    final p = purchase();
    final f = fee();
    final first = linkAll([p, f]);
    final store = MemoryEvents()..apply(first);
    final again = testLinker().link(
      incoming: [p, f],
      context: RuleLinkContext(
        recentFacts: [p, f],
        openEvents: store.open,
        instrumentsById: allInstruments,
        knownEvents: store.all,
      ),
      rules: baselineLinkRules(),
    );
    expect(again.created, isEmpty);
    expect(again.updated, isEmpty);
  });
}
