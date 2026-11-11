// Who a movement was with when its own message names nobody. Every fact below is
// invented: no merchant, wallet or amount comes from a real message.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';

import '../linker/helpers.dart';
import '../support/rules.dart';

final _zeptoWallet = instrument(
  '00000000-0000-4000-8000-0000000000b1',
  InstrumentKind.wallet,
  'zepto_cash',
  null,
);
final _sbiLikeAccount = instrument(
  '00000000-0000-4000-8000-0000000000b2',
  InstrumentKind.bankAccount,
  'alphabank',
  '4455',
);
final _known = {
  ...allInstruments,
  _zeptoWallet.instrumentId: _zeptoWallet,
  _sbiLikeAccount.instrumentId: _sbiLikeAccount,
};

/// Links [facts], projects the ledger, and returns each event's entry with the
/// name on the outside of it.
class Result {
  Result(this.events, this.snapshot, this.facts);
  final List<Event> events;
  final LedgerSnapshot snapshot;
  final Map<String, Fact> facts;

  Event eventOf(Fact f) => events.firstWhere((e) => e.legs.any((l) => l.factId == f.factId));
  LedgerEntry entryOf(Fact f) => snapshot.entries.firstWhere((e) => e.eventId == eventOf(f).eventId);
  String outside(Fact f) {
    final e = entryOf(f);
    final x = e.to is ExternalEndpoint ? e.to : e.from;
    return (x as ExternalEndpoint).counterpartyKey;
  }

  String category(Fact f) => snapshot.categoryByEvent[eventOf(f).eventId]?.slug ?? 'none';
}

Result run(List<Fact> facts) {
  final r = linkAll(facts, instruments: _known);
  final events = eventsOf(r);
  final byId = {for (final f in facts) f.factId: f};
  return Result(
    events,
    LedgerSnapshot.project(events: events, factsById: byId, instrumentsById: _known, bundle: testRuleBundle()),
    byId,
  );
}

void main() {
  group('a refund is with the merchant of the purchase it reverses', () {
    test('and takes its category too', () {
      final purchase = move('debit', 'purchase', 140185, at: '2026-03-01T09:00:00Z', inst: iciciCard, counterparty: party(name: 'AMAZON', kind: 'merchant'));
      final refund = move('credit', 'refund', 140185, at: '2026-03-05T09:00:00Z', inst: iciciCard);
      final r = run([purchase, refund]);
      expect(r.eventOf(refund).legs.any((l) => l.role == LegRole.original), isTrue, reason: 'the linker joined them');
      expect(r.outside(refund), 'AMAZON');
      expect(r.category(refund), r.category(purchase));
    });

    test('a merchant the refund prints itself is never replaced', () {
      final purchase = move('debit', 'purchase', 50000, at: '2026-03-01T09:00:00Z', inst: iciciCard, counterparty: party(name: 'AMAZON', kind: 'merchant'));
      final refund = move('credit', 'refund', 50000, at: '2026-03-05T09:00:00Z', inst: iciciCard, counterparty: party(name: 'FLIPKART', kind: 'merchant'));
      final r = run([purchase, refund]);
      expect(r.outside(refund), isNot('AMAZON'));
    });

    test('with nothing to inherit from it stays unnamed', () {
      final refund = move('credit', 'refund', 12300, at: '2026-03-05T09:00:00Z', inst: iciciCard);
      expect(run([refund]).outside(refund), 'UNKNOWN');
    });

  });

  group('a notice that names no payer is with whoever the bank record names', () {
    test('the record supplies the name when the notice is the money leg', () {
      final bank = instrument('00000000-0000-4000-8000-0000000000b3', InstrumentKind.bankAccount, 'alphabank', '8648');
      final known = {..._known, bank.instrumentId: bank};
      final notice = move(
        'credit',
        'unknown',
        425000,
        at: '2026-11-02T09:00:00Z',
        mention: const InstrumentMention(kind: InstrumentKind.bankAccount, maskDigits: '8648'),
        ruleId: 'NOTICE',
      );
      final record = move('credit', 'investment', 425000, at: '2026-11-03T09:00:00Z', inst: bank, counterparty: party(name: 'ACME BROKING', kind: 'merchant'));
      final linked = linkAll([notice, record], instruments: known);
      final events = eventsOf(linked);
      final event = events.firstWhere((e) => e.legs.any((l) => l.factId == notice.factId));
      final resolved = resolveMissingCounterparty(
        event: event,
        money: notice,
        factsById: {for (final f in [notice, record]) f.factId: f},
        instrument: bank,
      );
      expect(resolved?.origin, CounterpartyOrigin.linked);
      expect(resolved?.counterparty.name, 'ACME BROKING');
    });
  });

  group('a wallet\'s own movements are with the wallet provider', () {
    test('a cashback or balance credit with no sender', () {
      final credit = move('credit', 'cashback', 1706, at: '2026-03-05T09:00:00Z', inst: paytmWallet);
      final r = run([credit]);
      expect(r.outside(credit), 'PAYTM');
    });

    test('a payment from the wallet takes the provider\'s category where a rule knows it', () {
      final pay = move('debit', 'purchase', 4500, at: '2026-03-05T09:00:00Z', inst: _zeptoWallet);
      final r = run([pay]);
      expect(r.outside(pay), 'ZEPTO CASH');
      expect(r.category(pay), 'groceries');
    });

    test('a merchant the message prints wins over the provider', () {
      final pay = move('debit', 'purchase', 4500, at: '2026-03-05T09:00:00Z', inst: paytmWallet, counterparty: party(name: 'SWIGGY', kind: 'merchant'));
      expect(run([pay]).outside(pay), 'SWIGGY');
    });
  });

  group('a fee is charged by the bank that holds the account or card', () {
    test('on an account', () {
      final fee = move('debit', 'fee', 35400, at: '2026-03-05T09:00:00Z', inst: hdfcAcct);
      expect(run([fee]).outside(fee), 'HDFC BANK');
    });

    test('on a card', () {
      final fee = move('debit', 'fee', 59000, at: '2026-03-05T09:00:00Z', inst: iciciCard);
      expect(run([fee]).outside(fee), 'ICICI BANK');
    });

    test('a printed name wins', () {
      final fee = move('debit', 'fee', 35400, at: '2026-03-05T09:00:00Z', inst: hdfcAcct, counterparty: party(name: 'FASTAG', kind: 'merchant'));
      expect(run([fee]).outside(fee), 'FASTAG');
    });
  });

  group('where the issuer is NOT the other side, nobody is invented', () {
    test('a credit into a bank account with no sender', () {
      final credit = move('credit', 'unknown', 77700, at: '2026-03-05T09:00:00Z', inst: hdfcAcct);
      expect(run([credit]).outside(credit), 'UNKNOWN');
    });

    test('a card purchase with no merchant', () {
      final buy = move('debit', 'purchase', 77700, at: '2026-03-05T09:00:00Z', inst: iciciCard);
      expect(run([buy]).outside(buy), 'UNKNOWN');
    });

    test('a payment to someone from a bank account with no name', () {
      final pay = move('debit', 'p2p', 100000, at: '2026-03-05T09:00:00Z', inst: hdfcAcct);
      expect(run([pay]).outside(pay), 'UNKNOWN');
    });

    test('one of the person\'s own accounts is never taken as the counterparty', () {
      final purchase = move('debit', 'purchase', 90000, at: '2026-03-01T09:00:00Z', inst: iciciCard, counterparty: party(name: 'MY OWN ACCOUNT', kind: 'own'));
      final refund = move('credit', 'refund', 90000, at: '2026-03-05T09:00:00Z', inst: iciciCard);
      final r = run([purchase, refund]);
      expect(r.outside(refund), 'UNKNOWN');
    });
  });

  test('counterpartyIsNamed reads a name or a UPI id, never an own account', () {
    expect(counterpartyIsNamed(null), isFalse);
    expect(counterpartyIsNamed(const Counterparty()), isFalse);
    expect(counterpartyIsNamed(const Counterparty(name: '  ')), isFalse);
    expect(counterpartyIsNamed(const Counterparty(name: 'ACME')), isTrue);
    expect(counterpartyIsNamed(const Counterparty(vpa: 'shop@bank')), isTrue);
    expect(counterpartyIsNamed(const Counterparty(name: 'ME', kind: CounterpartyKind.own)), isFalse);
  });
}
