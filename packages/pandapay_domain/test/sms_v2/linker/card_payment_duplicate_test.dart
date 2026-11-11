// One card payment confirmed twice, once under the card number and once under
// a number the user has no card for (the card account number). They are one
// payment. Two payments to two cards the user HAS stay two, even when the
// amounts match. Synthetic facts only.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:test/test.dart';

import 'helpers.dart';

final _cardTwo = instrument(
  '00000000-0000-4000-8000-0000000000c2',
  InstrumentKind.creditCard,
  'icici',
  '3344',
);

MemoryEvents link(List<Fact> facts) {
  final known = {...allInstruments, _cardTwo.instrumentId: _cardTwo};
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

MovementFact onCard(Instrument card, int minor, String at, String rule) => move(
  'credit',
  'card_payment',
  minor,
  at: at,
  inst: card,
  ruleId: rule,
);

MovementFact onAccountNumber(int minor, String at) => move(
  'credit',
  'card_payment',
  minor,
  at: at,
  mention: const InstrumentMention(
    kind: InstrumentKind.creditCard,
    issuerSlug: 'icici',
    maskDigits: '1724', // the card account number: no such card is known
  ),
  ruleId: 'ACCOUNT-NUMBER-RECEIPT',
);

List<Event> payments(MemoryEvents s) => [
  for (final e in s.all)
    if (e.type == EventType.cardBillPayment) e,
];

void main() {
  test('the card number and the account number confirm one payment, in either order', () {
    final byCard = onCard(iciciCard, 5062532, '2026-06-30T10:29:00Z', 'CARD-NUMBER-RECEIPT');
    final byAccount = onAccountNumber(5062532, '2026-06-30T03:49:00Z');
    for (final order in [
      [byAccount, byCard],
      [byCard, byAccount],
    ]) {
      final s = link(order);
      expect(payments(s), hasLength(1), reason: s.all.map((e) => e.type).toString());
      final legs = {for (final l in payments(s).single.legs) l.factId: l.role};
      expect(legs[byCard.factId], LegRole.creditLeg);
      expect(legs[byAccount.factId], LegRole.duplicateNotice);
    }
  });

  test('payments of the same size to two cards the user has stay two', () {
    final s = link([
      onCard(iciciCard, 1000000, '2026-06-30T10:00:00Z', 'CARD-NUMBER-RECEIPT'),
      onCard(_cardTwo, 1000000, '2026-06-30T10:20:00Z', 'CARD-NUMBER-RECEIPT'),
    ]);
    expect(payments(s), hasLength(2));
  });

  test('a different amount, or another day, is another payment', () {
    final byCard = onCard(iciciCard, 5062532, '2026-06-30T10:29:00Z', 'CARD-NUMBER-RECEIPT');
    expect(payments(link([byCard, onAccountNumber(5062533, '2026-06-30T09:00:00Z')])), hasLength(2));
    expect(payments(link([byCard, onAccountNumber(5062532, '2026-07-02T09:00:00Z')])), hasLength(2));
  });
}
