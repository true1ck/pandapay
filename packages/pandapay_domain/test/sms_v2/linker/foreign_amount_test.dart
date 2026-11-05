import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import 'helpers.dart';

// CCR-004: a foreign-only amount (unit USD) is never an INR amount. It never
// equals paise, never becomes an event amount, never reaches the ledger.

MovementFact foreignDebit(
  int minor, {
  String at = '2026-11-10T09:00:00Z',
  String currency = 'USD',
  String purpose = 'purchase',
  String direction = 'debit',
}) => move(
  direction,
  purpose,
  minor,
  at: at,
  inst: hdfcCard,
  unit: currency,
  counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
  rail: 'card',
);

void main() {
  test('a foreign-only purchase makes an event with no amount', () {
    final r = linkAll([foreignDebit(2000)]);
    final e = eventsOf(r).single;
    expect(e.amountMinor, 0, reason: 'USD cents are not paise');
  });

  test('a foreign price equal in digits to an INR payment does not join it', () {
    // USD 20.00 is 2000; Rs 20.00 is 2000 paise. They are different money. An
    // app notice with no instrument would join a bank debit of the same amount.
    final notice = move(
      'debit',
      'purchase',
      2000,
      at: '2026-11-10T09:00:00Z',
      unit: 'USD',
      counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
    );
    final bank = debit(
      'purchase',
      2000,
      at: '2026-11-10T09:02:00Z',
      inst: hdfcCard,
      counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
    );
    final r = linkAll([notice, bank]);
    final all = eventsOf(r);
    expect(all, hasLength(2), reason: shapes(r).toString());
    expect(all.every((e) => e.legs.length == 1), isTrue);
  });

  test('the same app notice in INR does join the bank debit (control)', () {
    final notice = move(
      'debit',
      'purchase',
      2000,
      at: '2026-11-10T09:00:00Z',
      counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
    );
    final bank = debit(
      'purchase',
      2000,
      at: '2026-11-10T09:02:00Z',
      inst: hdfcCard,
      counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
    );
    expect(eventsOf(linkAll([notice, bank])), hasLength(1));
  });

  test('foreign notices with the same digits in different currencies stay apart', () {
    final r = linkAll([
      foreignDebit(2000),
      foreignDebit(2000, at: '2026-11-10T09:03:00Z', currency: 'EUR'),
    ]);
    expect(eventsOf(r), hasLength(2), reason: shapes(r).toString());
  });

  test('a foreign-only purchase and a foreign-only refund do not move the ledger', () {
    final spend = foreignDebit(2000);
    final refund = foreignDebit(
      2000,
      at: '2026-11-12T09:00:00Z',
      purpose: 'refund',
      direction: 'credit',
    );
    final r = linkAll([spend, refund]);
    final facts = {for (final f in [spend, refund]) f.factId: f};
    final projector = DefaultLedgerProjector();
    for (final e in eventsOf(r)) {
      expect(projector.project(e, facts, allInstruments, null), isEmpty);
    }
  });

  test('an INR posting with an original counts once, as INR', () {
    final settled = move(
      'debit',
      'purchase',
      175000,
      at: '2026-11-10T09:00:00Z',
      inst: hdfcCard,
      original: {'minor': 2000, 'currency': 'USD'},
      counterparty: party(name: 'SAMPLE AI', kind: 'merchant'),
      rail: 'card',
    );
    final r = linkAll([settled]);
    final e = eventsOf(r).single;
    expect(e.amountMinor, 175000);
    final rows = DefaultLedgerProjector().project(
      e,
      {settled.factId: settled},
      allInstruments,
      null,
    );
    expect(rows.single.amountMinor, 175000);
    expect(rows.single.unit, LedgerUnit.inr);
  });
}
