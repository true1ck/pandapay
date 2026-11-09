import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay_domain/sms_v2.dart';

Fact fixture(
  String name, {
  Map<String, Object?> changes = const {},
}) => Fact.fromJson(
  (jsonDecode(
            jsonEncode({
              ...(jsonDecode(
                        File(
                          '../contracts/sms/v2/fixtures/valid/fact/$name.json',
                        ).readAsStringSync(),
                      )
                      as Map)
                  .cast<String, Object?>(),
              ...changes,
            }),
          )
          as Map)
      .cast<String, Object?>(),
);
Event moneyEvent(Fact f, EventType type, {List<EventLeg>? legs}) => Event(
  eventId: f.factId,
  type: type,
  status: EventStatus.complete,
  legs: legs ?? [EventLeg(factId: f.factId, role: LegRole.debitLeg)],
  confidence: .99,
  occurredAt: f.effectiveAt,
  amountMinor: f.amounts.first.minor,
);

void main() {
  test(
    'subscriptions keep cancelled history and exclude one-time IPO mandates',
    () {
      final setup = fixture('mandate.subscription_created') as MandateFact;
      final cancelled = fixture(
        'mandate.revoked',
        changes: {
          'instrument': setup.instrument?.toJson(),
          'attrs': {...setup.toJson()['attrs'] as Map, 'phase': 'revoked'},
          'references': setup.references,
          'observedAt': '2026-12-01T00:00:00Z',
          'occurredAt': null,
        },
      );
      final ipo = fixture('mandate.one_time_ipo');
      final rows = subscriptionsFromLedger(
        [setup, cancelled, ipo],
        const [],
        now: DateTime.utc(2026, 12, 2),
      );
      expect(rows.length, 1);
      expect(rows.single.lifecycleStatus, 'cancelled');
      expect(rows.single.occurrenceCount, 0);
      expect(rows.single.amountKnown, isFalse);
    },
  );
  test('monthly renewal keeps the Indian calendar day and time', () {
    final mandate = fixture('mandate.subscription_created') as MandateFact;
    final charge = fixture(
      'movement.card_spend',
      changes: {'occurredAt': '2026-10-31T18:30:00Z'},
    );
    final event = moneyEvent(
      charge,
      EventType.subscriptionCharge,
      legs: [
        EventLeg(factId: charge.factId, role: LegRole.charge),
        EventLeg(factId: mandate.factId, role: LegRole.original),
      ],
    );
    final rows = subscriptionsFromLedger(
      [mandate, charge],
      [event],
      now: DateTime.utc(2026, 11, 15),
    );
    expect(rows.single.nextExpectedOn, DateTime.utc(2026, 11, 30, 18, 30));
  });

  test('an announced renewal sets the next expected date but adds no charge or amount', () {
    final setup = fixture('mandate.subscription_created') as MandateFact;
    final announced = fixture(
      'attempt.failed_si',
      changes: {
        'instrument': setup.instrument?.toJson(),
        'counterparty': {
          'name': setup.merchantName,
          'vpa': null,
          'kind': 'merchant',
          'accountMask': null,
        },
        'amounts': [
          {'role': 'scheduled', 'minor': 9900, 'unit': 'INR'},
        ],
        'attrs': {
          'status': 'scheduled',
          'direction': 'debit',
          'purpose': 'purchase',
          'dueAt': '2026-12-12T18:30:00Z',
        },
        'observedAt': '2026-12-01T00:00:00Z',
        'occurredAt': null,
      },
    );
    final rows = subscriptionsFromLedger(
      [setup, announced],
      const [],
      now: DateTime.utc(2026, 12, 2),
    );
    expect(rows.single.nextExpectedOn, DateTime.utc(2026, 12, 12, 18, 30));
    expect(rows.single.occurrenceCount, 0);
    expect(rows.single.amountKnown, isFalse);
    expect(rows.single.annualCost.paise, 0);
    // A date already in the past is not an announcement of anything to come.
    final stale = subscriptionsFromLedger(
      [setup, announced],
      const [],
      now: DateTime.utc(2026, 12, 20),
    );
    expect(stale.single.nextExpectedOn, isNull);
  });

  test('a scheduled or failed attempt never becomes a charge', () {
    final setup = fixture('mandate.subscription_created') as MandateFact;
    final failed = fixture(
      'attempt.failed_si',
      changes: {
        'instrument': setup.instrument?.toJson(),
        'counterparty': {
          'name': setup.merchantName,
          'vpa': null,
          'kind': 'merchant',
          'accountMask': null,
        },
        'observedAt': '2026-12-01T00:00:00Z',
        'occurredAt': null,
      },
    );
    final rows = subscriptionsFromLedger(
      [setup, failed],
      const [],
      now: DateTime.utc(2026, 12, 2),
    );
    expect(rows.single.occurrenceCount, 0);
    expect(rows.single.lifecycleStatus, 'failed_payment');
    expect(rows.single.annualCost.paise, 0);
  });
  test('a bill is paid only by a matching instrument and a later payment', () {
    final bill = fixture('bill_due.total_only') as BillDueFact;
    final payment = fixture(
      'movement.card_spend',
      changes: {
        'instrument': bill.instrument?.toJson(),
        'amounts': [
          {'role': 'posted', 'minor': bill.amounts.first.minor, 'unit': 'INR'},
        ],
        'observedAt': '2026-12-01T00:00:00Z',
        'occurredAt': null,
      },
    );
    final event = moneyEvent(payment, EventType.cardBillPayment);
    final paid = billsFromFacts([bill, payment], [event]);
    expect(paid.single.status.name, 'paid');
    expect(paid.single.linkedTransactionId, 'v2:${event.eventId}');
    expect(
      billsFromFacts(
        [bill, payment],
        [event],
        transactionIdByEvent: {event.eventId: 'legacy-payment'},
      ).single.linkedTransactionId,
      'legacy-payment',
    );
    expect(billsFromFacts([bill], const []).single.status.name, 'due');
  });
  test(
    'one payment cannot settle two statement cycles and partial card payments reduce outstanding',
    () {
      final first =
          fixture(
                'bill_due.total_only',
                changes: {
                  'observedAt': '2026-10-10T00:00:00Z',
                  'occurredAt': null,
                  'attrs': {
                    'dueDate': '2026-10-25',
                    'statementDate': '2026-10-10',
                  },
                  'amounts': [
                    {'role': 'due_total', 'minor': 10000, 'unit': 'INR'},
                  ],
                },
              )
              as BillDueFact;
      final second = fixture(
        'bill_due.total_only',
        changes: {
          'factId': 'c' * 64,
          'sourceKey': 'sms:second-statement',
          'observedAt': '2026-11-10T00:00:00Z',
          'occurredAt': null,
          'attrs': {'dueDate': '2026-11-25'},
          'amounts': [
            {'role': 'due_total', 'minor': 10000, 'unit': 'INR'},
          ],
        },
      );
      final payment = fixture(
        'movement.card_spend',
        changes: {
          'instrument': first.instrument?.toJson(),
          'observedAt': '2026-11-12T00:00:00Z',
          'occurredAt': null,
          'amounts': [
            {'role': 'posted', 'minor': 10000, 'unit': 'INR'},
          ],
        },
      );
      final paymentEvent = moneyEvent(payment, EventType.cardBillPayment);
      final bills = billsFromFacts([first, second, payment], [paymentEvent]);
      expect(bills.where((b) => b.status.name == 'paid').length, 1);
      final partial = fixture(
        'movement.card_spend',
        changes: {
          'instrument': first.instrument?.toJson(),
          'observedAt': '2026-10-12T00:00:00Z',
          'occurredAt': null,
          'amounts': [
            {'role': 'posted', 'minor': 4000, 'unit': 'INR'},
          ],
        },
      );
      final instrument = Instrument(
        instrumentId: '00000000-0000-4000-8000-000000000001',
        kind: InstrumentKind.creditCard,
        issuerSlug: first.instrument!.issuerSlug!,
        maskDigits: first.instrument!.maskDigits,
        status: InstrumentStatus.confirmed,
        displayName: 'Card',
        userCardId: 'card',
        firstSeenAt: first.observedAt,
        lastSeenAt: first.observedAt,
        evidenceCount: 1,
      );
      final reminder = fixture(
        'bill_due.total_only',
        changes: {
          'factId': 'd' * 64,
          'sourceKey': 'sms:minimum-reminder',
          'observedAt': '2026-10-15T00:00:00Z',
          'occurredAt': null,
          'attrs': {'dueDate': '2026-10-25'},
          'amounts': [
            {'role': 'due_minimum', 'minor': 1000, 'unit': 'INR'},
          ],
        },
      );
      final ledger = cardBillLedgersFromFacts(
        [first, reminder, partial],
        [moneyEvent(partial, EventType.cardBillPayment)],
        [instrument],
      )['card']!;
      expect(ledger.current!.statementDateVerified, isTrue);
      expect(ledger.current!.paidToward.paise, 4000);
      expect(ledger.current!.outstanding!.paise, 6000);
    },
  );

  test(
    'money in excludes own transfers and identifies repeated salary payer',
    () {
      final first = fixture(
        'movement.upi_salary_credit',
        changes: {'observedAt': '2026-10-05T00:00:00Z', 'occurredAt': null},
      );
      final second = fixture(
        'movement.upi_salary_credit',
        changes: {
          'factId': 'a' * 64,
          'sourceKey': 'sms:synthetic:second',
          'observedAt': '2026-11-07T00:00:00Z',
          'occurredAt': null,
        },
      );
      final events = [
        moneyEvent(first, EventType.income),
        moneyEvent(second, EventType.income),
      ];
      final rows = moneyIn(
        [first, second],
        events,
        DateTime.utc(2026, 11),
        DateTime.utc(2026, 12),
      );
      expect(rows.length, 1);
      expect(rows.single.kind, 'salary');
      expect(
        moneyIn(
          [second],
          [moneyEvent(second, EventType.ownTransfer)],
          DateTime.utc(2026, 11),
          DateTime.utc(2026, 12),
        ),
        isEmpty,
      );
    },
  );
  test(
    'a partial IPO allotment subtracts released residual money from active holds',
    () {
      final hold = fixture(
        'hold.ipo_placed',
        changes: {
          'amounts': [
            {'role': 'held', 'minor': 50000, 'unit': 'INR'},
          ],
        },
      );
      final release = fixture(
        'hold.ipo_released',
        changes: {
          'amounts': [
            {'role': 'released', 'minor': 40000, 'unit': 'INR'},
          ],
        },
      );
      final money = fixture(
        'movement.card_spend',
        changes: {
          'amounts': [
            {'role': 'posted', 'minor': 10000, 'unit': 'INR'},
          ],
        },
      );
      final event = Event(
        eventId: hold.factId,
        type: EventType.ipoApplication,
        status: EventStatus.complete,
        legs: [
          EventLeg(factId: hold.factId, role: LegRole.holdPlaced),
          EventLeg(factId: money.factId, role: LegRole.debitLeg),
          EventLeg(factId: release.factId, role: LegRole.holdReleased),
        ],
        confidence: 1,
        occurredAt: hold.effectiveAt,
        amountMinor: 10000,
      );
      final application = ipoApplications(
        [hold, money, release],
        [event],
      ).single;
      expect(application.investedMinor, 10000);
      expect(application.releasedMinor, 40000);
      expect(application.remainingHoldMinor, 0);
    },
  );
}
