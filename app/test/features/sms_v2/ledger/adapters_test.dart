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
                  'attrs': {'dueDate': '2026-10-25'},
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
      final ledger = cardBillLedgersFromFacts(
        [first, partial],
        [moneyEvent(partial, EventType.cardBillPayment)],
        [instrument],
      )['card']!;
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
}
