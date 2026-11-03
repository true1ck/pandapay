import 'package:pandapay_domain/sms_v2.dart';
import 'package:pandapay_domain/sms_v2_ledger.dart';
import 'package:test/test.dart';
import '../linker/helpers.dart' as h;

final at = DateTime.utc(2026, 11, 5, 12);
const dining = CategoryDecision(
  slug: 'dining',
  source: CategorySource.user,
  confidence: 1,
);

Event event(
  EventType type,
  List<Fact> facts, {
  List<LegRole>? roles,
  EventStatus status = EventStatus.complete,
}) => Event(
  eventId: facts.first.factId,
  type: type,
  status: status,
  legs: [
    for (var i = 0; i < facts.length; i++)
      EventLeg(factId: facts[i].factId, role: roles?[i] ?? LegRole.debitLeg),
  ],
  confidence: .99,
  occurredAt: at,
  amountMinor: 10000,
);

void main() {
  final projector = DefaultLedgerProjector();
  final debit = h.debit(
    'purchase',
    10000,
    at: at.toIso8601String(),
    inst: h.hdfcCard,
    counterparty: h.party(name: 'SWIGGY', kind: 'merchant'),
  );
  final credit = h.credit(
    'refund',
    10000,
    at: at.toIso8601String(),
    inst: h.hdfcCard,
    counterparty: h.party(name: 'SWIGGY', kind: 'merchant'),
  );
  Map<String, Fact> facts(Iterable<Fact> fs) => {
    for (final f in fs) f.factId: f,
  };

  test('each event type follows the contract totals classification', () {
    const spend = {
      EventType.purchase,
      EventType.subscriptionCharge,
      EventType.fee,
      EventType.emi,
      EventType.billPayment,
      EventType.atmWithdrawal,
      EventType.p2pOut,
    };
    const income = {
      EventType.income,
      EventType.p2pIn,
      EventType.cashback,
      EventType.dividend,
    };
    const transfer = {
      EventType.ownTransfer,
      EventType.cardBillPayment,
      EventType.walletTopup,
    };
    for (final type in EventType.values) {
      final e = event(type, [
        income.contains(type) ||
                type == EventType.refund ||
                type == EventType.investmentWithdrawal
            ? credit
            : debit,
      ]);
      final rows = projector.project(
        e,
        facts([debit, credit]),
        h.allInstruments,
        dining,
      );
      if (type == EventType.unknown) {
        expect(rows, isEmpty);
        continue;
      }
      expect(rows.length, 1, reason: type.wire);
      final row = rows.single;
      expect(
        row.validate().ok,
        isTrue,
        reason: '${type.wire}: ${row.validate().errors}',
      );
      expect(row.isSpend, spend.contains(type), reason: type.wire);
      expect(row.isIncome, income.contains(type), reason: type.wire);
      expect(
        row.isInvestment,
        {
          EventType.investment,
          EventType.ipoApplication,
          EventType.investmentWithdrawal,
        }.contains(type),
        reason: type.wire,
      );
      expect(
        row.countsAsTransaction,
        !transfer.contains(type),
        reason: type.wire,
      );
      expect(row.category, spend.contains(type) ? 'dining' : null);
    }
  });

  test('a card bill has one own-to-own entry and no spend or count', () {
    final bank = h.debit(
      'card_payment',
      10000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final receipt = h.credit(
      'card_payment',
      10000,
      at: at.toIso8601String(),
      inst: h.hdfcCard,
    );
    final e = event(
      EventType.cardBillPayment,
      [bank, receipt],
      roles: [LegRole.debitLeg, LegRole.creditLeg],
    );
    final row = projector
        .project(e, facts([bank, receipt]), h.allInstruments, null)
        .single;
    expect(
      (row.from as InstrumentEndpoint).instrumentId,
      h.hdfcAcct.instrumentId,
    );
    expect(
      (row.to as InstrumentEndpoint).instrumentId,
      h.hdfcCard.instrumentId,
    );
    expect(row.countsAsTransaction, isFalse);
    expect(row.amountMinor, 10000);
    final lone = projector
        .project(
          event(EventType.cardBillPayment, [bank]),
          facts([bank]),
          h.allInstruments,
          null,
        )
        .single;
    expect((lone.to as OwnUnresolvedEndpoint).kind, InstrumentKind.creditCard);
  });

  test('IPO holds and releases create no money; allotment uses only debit', () {
    final held = h.hold(
      'placed',
      50000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final released = h.hold(
      'released',
      40000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final paid = h.debit(
      'investment',
      10000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final byId = facts([held, released, paid]);
    expect(
      projector.project(
        event(EventType.ipoApplication, [held], roles: [LegRole.holdPlaced]),
        byId,
        h.allInstruments,
        null,
      ),
      isEmpty,
    );
    final e = event(
      EventType.ipoApplication,
      [held, released, paid],
      roles: [LegRole.holdPlaced, LegRole.holdReleased, LegRole.debitLeg],
    );
    expect(
      projector.project(e, byId, h.allInstruments, null).single.amountMinor,
      10000,
    );
  });

  test(
    'duplicates and original legs never add money; ambiguous events stay out',
    () {
      final e = event(
        EventType.purchase,
        [debit, credit],
        roles: [LegRole.debitLeg, LegRole.duplicateNotice],
      );
      final rows = projector.project(
        e,
        facts([debit, credit]),
        h.allInstruments,
        dining,
      );
      expect(rows.single.amountMinor, 10000);
      expect(
        projector.project(
          e.copyWith(status: EventStatus.ambiguous),
          facts([debit, credit]),
          h.allInstruments,
          dining,
        ),
        isEmpty,
      );
      expect(
        projector.project(e, facts([debit, credit]), h.allInstruments, dining),
        rows,
      );
    },
  );

  test(
    'refunds net the linked purchase category even outside the reporting period',
    () {
      final purchase = event(EventType.purchase, [
        debit,
      ]).copyWith(occurredAt: at.subtract(const Duration(days: 31)));
      final refund = event(
        EventType.refund,
        [credit, debit],
        roles: [LegRole.reversal, LegRole.original],
      );
      final byId = facts([credit, debit]);
      final rows = [
        for (final e in [purchase, refund])
          ...projector.project(e, byId, h.allInstruments, dining),
      ];
      final totals = projector.totals(
        rows,
        [purchase, refund],
        DateTime.utc(2026, 11),
        DateTime.utc(2026, 12),
      );
      expect(totals.spendMinor, -10000);
      expect(totals.refundMinor, 10000);
      expect(totals.incomeMinor, 0);
      expect(totals.byCategory, {'dining': -10000});
      expect(totals.transactionCount, 1);
    },
  );

  test(
    'standalone refunds use explicit category context without invalid ledger fields',
    () {
      final refund = event(
        EventType.refund,
        [credit],
        roles: [LegRole.reversal],
      );
      final p = DefaultLedgerProjector(
        categoryByEvent: {refund.eventId: dining},
      );
      final rows = p.project(refund, facts([credit]), h.allInstruments, dining);
      expect(rows.single.category, isNull);
      expect(rows.single.validate().ok, isTrue);
      expect(
        p
            .totals(
              rows,
              [refund],
              DateTime.utc(2026, 11),
              DateTime.utc(2026, 12),
            )
            .byCategory,
        {'dining': -10000},
      );
    },
  );

  test(
    'totals deduplicate entry ids, count events once, net withdrawals, and use half-open dates',
    () {
      final invest = event(EventType.investment, [debit]);
      final payout = event(
        EventType.investmentWithdrawal,
        [credit],
        roles: [LegRole.creditLeg],
      );
      final rows = [
        for (final e in [invest, payout])
          ...projector.project(
            e,
            facts([debit, credit]),
            h.allInstruments,
            null,
          ),
      ];
      final t = projector.totals(
        [...rows, ...rows],
        [invest, payout],
        at,
        at.add(const Duration(days: 1)),
      );
      expect(t.investmentMinor, 0);
      expect(t.transactionCount, 2);
      expect(
        projector
            .totals(
              rows,
              [invest, payout],
              at.subtract(const Duration(days: 1)),
              at,
            )
            .transactionCount,
        0,
      );
    },
  );

  test('partial IPO allotments sum actual debit legs, never the block', () {
    final first = h.debit(
      'investment',
      10000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final second = h.debit(
      'investment',
      5000,
      at: at.toIso8601String(),
      inst: h.hdfcAcct,
    );
    final e = event(
      EventType.ipoApplication,
      [first, second],
      roles: [LegRole.debitLeg, LegRole.debitLeg],
    ).copyWith(amountMinor: 15000);
    expect(
      projector
          .project(e, facts([first, second]), h.allInstruments, null)
          .single
          .amountMinor,
      15000,
    );
  });

  test(
    'a known broker is the own destination and rejected instruments never create money',
    () {
      final broker = h.instrument(
        '00000000-0000-4000-8000-000000000099',
        InstrumentKind.broker,
        'groww',
        null,
      );
      final paid = h.debit(
        'investment',
        10000,
        at: at.toIso8601String(),
        inst: h.hdfcAcct,
        counterparty: h.party(name: 'GROWW', kind: 'own'),
      );
      final row = projector.project(
        event(EventType.investment, [paid]),
        facts([paid]),
        {...h.allInstruments, broker.instrumentId: broker},
        null,
      ).single;
      expect(row.to, InstrumentEndpoint(broker.instrumentId));
      final rejected = Instrument.fromJson({
        ...h.hdfcAcct.toJson(),
        'status': 'rejected',
      });
      expect(
        projector.project(event(EventType.purchase, [paid]), facts([paid]), {
          rejected.instrumentId: rejected,
        }, dining),
        isEmpty,
      );
    },
  );

  test(
    'a lone own transfer resolves its destination mask without another credit',
    () {
      final paid = h.debit(
        'transfer',
        10000,
        at: at.toIso8601String(),
        inst: h.hdfcAcct,
        counterparty: h.party(kind: 'own', mask: h.hdfcSaving.maskDigits),
      );
      final row = projector
          .project(
            event(EventType.ownTransfer, [paid]),
            facts([paid]),
            h.allInstruments,
            null,
          )
          .single;
      expect(row.to, InstrumentEndpoint(h.hdfcSaving.instrumentId));
    },
  );

  test('card usage is unknown without both limit and available credit', () {
    expect(cardUsage(h.hdfcCard), isNull);
    final card = Instrument.fromJson({
      ...h.hdfcCard.toJson(),
      'creditLimitMinor': 30000,
      'availableMinor': 20000,
    });
    expect(cardUsage(card), 10000);
  });
}
