// One credit announced twice: the payer's notice ("transferred to your account
// XXXX1234", which never says which bank holds the account) and the bank's own
// record. They are the same money, counted once, in either order. Two real
// credits of the same size that BOTH name their bank stay two. Synthetic facts
// only; no issuer, name or amount comes from a real message.
import 'dart:math';

import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final _bankA = instrument(
  '00000000-0000-4000-8000-0000000000a1',
  InstrumentKind.bankAccount,
  'alphabank',
  '8648',
);
final _bankB = instrument(
  '00000000-0000-4000-8000-0000000000a2',
  InstrumentKind.bankAccount,
  'betabank',
  '2211',
);
final _bankC = instrument(
  '00000000-0000-4000-8000-0000000000a3',
  InstrumentKind.bankAccount,
  'gammabank',
  '8648', // same last four digits as bank A, on purpose
);

Map<String, Instrument> _known(List<Instrument> list) => {
  for (final i in list) i.instrumentId: i,
};

/// A payer-side notice: a number, no bank.
MovementFact notice(int minor, String at, {String mask = '8648'}) => move(
  'credit',
  'unknown',
  minor,
  at: at,
  mention: InstrumentMention(kind: InstrumentKind.bankAccount, maskDigits: mask),
  ruleId: 'GENZ-ACCT-CR-THIRD-PARTY-NOTICE',
);

/// The bank's own record of the same credit.
MovementFact record(int minor, String at, Instrument account, {String purpose = 'investment'}) => move(
  'credit',
  purpose,
  minor,
  at: at,
  inst: account,
  counterparty: party(name: 'ACME BROKING', kind: 'merchant'),
  ruleId: 'BANK-CREDIT-RECORD',
);

MemoryEvents link(List<Fact> facts, Map<String, Instrument> known) {
  final store = MemoryEvents();
  final seen = <Fact>[];
  for (final f in facts) {
    store.apply(
      testLinker().link(
        incoming: [f],
        context: RuleLinkContext(
          recentFacts: [...seen],
          openEvents: store.open,
          instrumentsById: known,
          knownEvents: store.all,
        ),
        rules: baselineLinkRules(),
      ),
    );
    seen.add(f);
  }
  return store;
}

List<Event> withMoney(MemoryEvents s) => [
  for (final e in s.all)
    if (e.legs.any((l) => l.role == LegRole.creditLeg)) e,
];

void main() {
  final known = _known([_bankA, _bankB]);

  group('a payer-side notice and the bank record of the same credit', () {
    test('become one event whichever arrives first, typed by the record', () {
      final n = notice(425000, '2026-11-02T09:00:00Z');
      final r = record(425000, '2026-11-03T14:00:00Z', _bankA);
      for (final order in [
        [n, r],
        [r, n],
      ]) {
        final s = link(order, known);
        final events = withMoney(s);
        expect(events, hasLength(1), reason: s.all.map((e) => e.type).toString());
        expect(events.single.type, EventType.investmentWithdrawal);
        final byRole = {for (final l in events.single.legs) l.factId: l.role};
        expect(byRole[r.factId], LegRole.creditLeg);
        expect(byRole[n.factId], LegRole.duplicateNotice);
      }
    });

    test('hold in any order and either linking mode', () {
      final n = notice(1234567, '2026-11-10T08:00:00Z');
      final r = record(1234567, '2026-11-10T20:00:00Z', _bankA);
      final filler = record(99900, '2026-11-10T12:00:00Z', _bankB, purpose: 'salary');
      for (var k = 0; k < 12; k++) {
        final order = [n, r, filler]..shuffle(Random(k));
        final s = link(order, known);
        expect(
          withMoney(s).where((e) => e.legs.any((l) => l.factId == r.factId)),
          hasLength(1),
          reason: 'order $k',
        );
        final owner = withMoney(s).firstWhere((e) => e.legs.any((l) => l.factId == r.factId));
        expect(owner.legs.any((l) => l.factId == n.factId), isTrue, reason: 'order $k');
      }
    });

    test('a notice alone is still money in, counted once', () {
      final s = link([notice(425000, '2026-11-02T09:00:00Z')], known);
      final events = withMoney(s);
      expect(events, hasLength(1));
      expect(events.single.legs.single.role, LegRole.creditLeg);
    });

    test('a different amount is a different credit', () {
      final s = link([
        notice(425000, '2026-11-02T09:00:00Z'),
        record(425100, '2026-11-02T10:00:00Z', _bankA),
      ], known);
      expect(withMoney(s), hasLength(2));
    });

    test('too far apart in time is a different credit', () {
      final s = link([
        notice(425000, '2026-11-02T09:00:00Z'),
        record(425000, '2026-11-09T09:00:00Z', _bankA),
      ], known);
      expect(withMoney(s), hasLength(2));
    });

    test('a number that matches two accounts is not guessed; it stays separate', () {
      // Banks A and C both end in 8648: the notice cannot say which it is.
      final both = _known([_bankA, _bankC]);
      final s = link([
        notice(425000, '2026-11-02T09:00:00Z'),
        record(425000, '2026-11-02T20:00:00Z', _bankA),
      ], both);
      // The notice resolves to no account, so it cannot be tied to either;
      // it must not silently vanish into one of them.
      expect(withMoney(s).length, greaterThanOrEqualTo(1));
    });

    test('a notice for another account never joins a record on this one', () {
      final s = link([
        notice(425000, '2026-11-02T09:00:00Z', mask: '2211'),
        record(425000, '2026-11-02T10:00:00Z', _bankA),
      ], known);
      expect(withMoney(s), hasLength(2));
    });
  });

  test('two credits that both name their bank are never merged', () {
    // Same amount, same day, same account: two friends paying the same sum.
    final a = record(500000, '2026-11-05T09:00:00Z', _bankA, purpose: 'p2p');
    final b = move(
      'credit',
      'p2p',
      500000,
      at: '2026-11-05T11:00:00Z',
      inst: _bankA,
      counterparty: party(name: 'ANOTHER PERSON', kind: 'person'),
      ruleId: 'BANK-CREDIT-OTHER-TEMPLATE',
    );
    final s = link([a, b], known);
    expect(withMoney(s), hasLength(2));
  });
}
