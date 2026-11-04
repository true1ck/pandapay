// Lane F: a debit made under a mandate must always keep its ledger row, even
// when several mandate-created notices exist for the same merchant.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// Links [facts] one message at a time, carrying stored events forward the way
/// the pipeline does, then projects every event.
({List<Event> events, List<LedgerEntry> entries}) _run(List<Fact> facts) {
  final linker = testLinker();
  final rules = baselineLinkRules();
  final store = MemoryEvents();
  final seen = <Fact>[];
  for (final f in facts) {
    final r = linker.link(
      incoming: [f],
      context: RuleLinkContext(
        recentFacts: List.of(seen),
        openEvents: store.open,
        instrumentsById: allInstruments,
        knownEvents: store.all,
      ),
      rules: rules,
    );
    store.apply(r);
    seen.add(f);
  }
  final byId = {for (final f in facts) f.factId: f};
  final projector = DefaultLedgerProjector();
  final entries = [
    for (final e in store.all) ...projector.project(e, byId, allInstruments, null),
  ];
  return (events: store.all, entries: entries);
}

MovementFact _charge(String at, {int minor = 64900, String? mandateRef}) => debit(
  'purchase',
  minor,
  at: at,
  inst: hdfcAcct,
  counterparty: party(name: 'NETFLIX', kind: 'merchant'),
  mandateRef: mandateRef,
);

int _spend(Iterable<LedgerEntry> rows) =>
    rows.where((r) => r.isSpend).fold(0, (s, r) => s + r.amountMinor);

Iterable<EventLeg> _moneyLegs(Iterable<Event> events) =>
    events.expand((e) => e.legs).where((l) => moneyLegRoles.contains(l.role));

void main() {
  // Two notices for one merchant: one names the account, one does not.
  MandateFact withAccount(String at, {Map<String, String> refs = const {}}) => mandate(
    'created',
    at: at,
    merchant: 'NETFLIX',
    ceiling: 149900,
    inst: hdfcAcct,
    references: refs,
  );
  MandateFact withoutAccount(String at, {Map<String, String> refs = const {}}) =>
      mandate('created', at: at, merchant: 'NETFLIX', ceiling: 149900, references: refs);

  for (final withRef in [false, true]) {
    final label = withRef ? 'with mandateRef' : 'by merchant name';
    final refs = withRef ? {'umrn': 'M-1'} : <String, String>{};

    test('two mandate notices then a charge: the debit counts once ($label)', () {
      final m1 = withAccount('2026-11-01T08:00:00Z', refs: refs);
      final m2 = withoutAccount('2026-11-04T08:00:00Z', refs: refs);
      final charge = _charge('2026-11-08T06:00:00Z', mandateRef: withRef ? 'M-1' : null);
      final out = _run([m1, m2, charge]);
      expect(out.entries, hasLength(1), reason: out.events.map(shape).toString());
      expect(_spend(out.entries), 64900);
      expect(_moneyLegs(out.events).map((l) => l.factId), [charge.factId]);
    });
  }

  test('a notice with a reference and one without: the charge is not left ambiguous', () {
    final withRef = withoutAccount('2026-11-01T08:00:00Z', refs: {'umrn': 'M-1'});
    final noRef = withoutAccount('2026-11-04T08:00:00Z');
    final charge = _charge('2026-11-08T06:00:00Z');
    final out = _run([withRef, noRef, charge]);
    expect(out.events.where((e) => e.status == EventStatus.ambiguous), isEmpty);
    expect(out.entries, hasLength(1), reason: out.events.map(shape).toString());
    expect(_spend(out.entries), 64900);
    expect(_moneyLegs(out.events).map((l) => l.factId), [charge.factId]);
  });

  test('two mandates with different references and no way to tell them apart: counted once', () {
    final a = mandate(
      'created',
      at: '2026-11-01T08:00:00Z',
      merchant: 'NETFLIX',
      ceiling: 149900,
      references: {'umrn': 'M-1'},
    );
    final b = mandate(
      'created',
      at: '2026-11-04T08:00:00Z',
      merchant: 'NETFLIX',
      ceiling: 149900,
      references: {'umrn': 'M-2'},
    );
    final charge = _charge('2026-11-08T06:00:00Z');
    final out = _run([a, b, charge]);
    expect(out.events.where((e) => e.status == EventStatus.ambiguous), isEmpty);
    expect(_spend(out.entries), 64900);
    // The most recent active mandate is the one it joins.
    final chargeEvent = out.events.singleWhere((e) => e.legs.any((l) => l.role == LegRole.charge));
    expect(chargeEvent.legs.singleWhere((l) => l.role == LegRole.original).factId, b.factId);
    expect(doubleCounted(out.events, {for (final f in [a, b, charge]) f.factId: f}), isEmpty);
  });

  test('the same two notices in the other arrival order still count the debit', () {
    final m1 = withAccount('2026-11-01T08:00:00Z');
    final m2 = withoutAccount('2026-11-04T08:00:00Z');
    final charge = _charge('2026-11-08T06:00:00Z');
    final out = _run([m2, m1, charge]);
    expect(_spend(out.entries), 64900, reason: out.events.map(shape).toString());
  });

  test('two real charges under one mandate both count', () {
    final m1 = withAccount('2026-11-01T08:00:00Z');
    final m2 = withoutAccount('2026-11-04T08:00:00Z');
    final c1 = _charge('2026-11-08T06:00:00Z');
    final c2 = _charge('2026-12-08T06:00:00Z');
    final out = _run([m1, m2, c1, c2]);
    expect(out.entries, hasLength(2), reason: out.events.map(shape).toString());
    expect(_spend(out.entries), 129800);
    expect(_moneyLegs(out.events).map((l) => l.factId).toSet(), {c1.factId, c2.factId});
  });

  test('mandate notices alone never count as money', () {
    final out = _run([withAccount('2026-11-01T08:00:00Z'), withoutAccount('2026-11-04T08:00:00Z')]);
    expect(out.entries, isEmpty);
    expect(_moneyLegs(out.events), isEmpty);
  });
}
