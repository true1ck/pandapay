import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
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

String _hexId(String id) =>
    id.codeUnits.map((c) => c.toRadixString(16)).join().padRight(64, '0');

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
  group('card bill worst cases', () {
    BillDueFact statement(
      String id,
      String stmt,
      String due,
      int total, {
      Map<String, Object?>? instrument,
      int? minimum,
    }) =>
        fixture('bill_due.total_only', changes: {
          'factId': _hexId(id),
          'sourceKey': 'sms:$id',
          if (instrument != null) 'instrument': instrument,
          'observedAt': '${stmt}T06:00:00Z',
          'occurredAt': null,
          'attrs': {'dueDate': due, 'statementDate': stmt},
          'amounts': [
            {'role': 'due_total', 'minor': total, 'unit': 'INR'},
            if (minimum != null)
              {'role': 'due_minimum', 'minor': minimum, 'unit': 'INR'},
          ],
        }) as BillDueFact;
    MovementFact payment(
      String id,
      String at,
      int minor,
      Map<String, Object?>? instrument,
    ) =>
        fixture('movement.card_spend', changes: {
          'factId': _hexId(id),
          'sourceKey': 'sms:$id',
          'instrument': instrument,
          'observedAt': '${at}T06:00:00Z',
          'occurredAt': null,
          'amounts': [
            {'role': 'posted', 'minor': minor, 'unit': 'INR'},
          ],
        }) as MovementFact;

    test('WP-C7: a manual paid/dismissed copy overrides the derived bill', () {
      final bill = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final derived = billsFromFacts([bill], const []).single;
      expect(derived.status.name, 'due');
      Commitment copy(String status, {String? id}) => derived.copyWith(
        id: id,
        status: CommitmentStatus.values.byName(status),
        paidOn: DateTime(2026, 10, 20),
        isUserConfirmed: true,
      );
      final paid = billsFromFacts([bill], const [],
          manualCopies: [copy('paid')]).single;
      expect(paid.status.name, 'paid');
      // Re-projected under a new fact id: identity + due day still match.
      final reprojected = statement('zz9', '2026-10-10', '2026-10-25', 10000);
      expect(
        billsFromFacts([reprojected], const [],
            manualCopies: [copy('paid', id: 'v2:old')]).single.status.name,
        'paid',
      );
      expect(
        billsFromFacts([bill], const [], manualCopies: [copy('dismissed')]),
        isEmpty,
      );
    });

    test('a payment made before the statement exists does not settle it', () {
      final bill = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final early = payment('p1', '2026-10-05', 10000, bill.instrument?.toJson());
      final rows = billsFromFacts(
        [bill, early],
        [moneyEvent(early, EventType.cardBillPayment)],
      );
      expect(rows.single.status.name, 'due');
    });

    test('a payment on the other card never settles this card', () {
      final bill = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final other = {...?bill.instrument?.toJson(), 'maskDigits': '9999'};
      final pay = payment('p1', '2026-10-20', 10000, other);
      final rows = billsFromFacts(
        [bill, pay],
        [moneyEvent(pay, EventType.cardBillPayment)],
      );
      expect(rows.single.status.name, 'due');
    });

    test('paying after the due date still settles that statement', () {
      final bill = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final late = payment('p1', '2026-10-30', 10000, bill.instrument?.toJson());
      final rows = billsFromFacts(
        [bill, late],
        [moneyEvent(late, EventType.cardBillPayment)],
      );
      expect(rows.single.status.name, 'paid');
    });

    test('a payment after the next statement belongs to the next cycle', () {
      final oct = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final nov = statement('a2', '2026-11-10', '2026-11-25', 12000);
      final pay = payment('p1', '2026-11-12', 12000, oct.instrument?.toJson());
      final rows = billsFromFacts(
        [oct, nov, pay],
        [moneyEvent(pay, EventType.cardBillPayment)],
      );
      // October stays in history as "not detected"; November is paid.
      rows.sort((a, b) => a.dueOn.compareTo(b.dueOn));
      expect(rows, hasLength(2));
      expect(rows.first.status.name, 'paymentNotDetected');
      expect(rows.last.status.name, 'paid');
    });

    test('a newer statement marks an unpaid older one "not detected"; a paid one stays paid', () {
      final oct = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final nov = statement('a2', '2026-11-10', '2026-11-25', 12000);
      final unpaid = billsFromFacts([oct, nov], const [])
        ..sort((a, b) => a.dueOn.compareTo(b.dueOn));
      expect(unpaid, hasLength(2), reason: 'history is kept');
      expect(unpaid.first.status.name, 'paymentNotDetected');
      expect(unpaid.last.status.name, 'due');
      // Paid before the newer statement arrived: still shown as paid history.
      final pay = payment('p1', '2026-10-20', 10000, oct.instrument?.toJson());
      final both = billsFromFacts(
        [oct, nov, pay],
        [moneyEvent(pay, EventType.cardBillPayment)],
      );
      expect(both, hasLength(2));
      expect(both.map((b) => b.status.name).toSet(), {'paid', 'due'});
      // Another card's newer statement retires nothing of this card's.
      final other = statement(
        'a3',
        '2026-11-10',
        '2026-11-25',
        12000,
        instrument: {...?oct.instrument?.toJson(), 'maskDigits': '9999'},
      );
      expect(
        billsFromFacts([oct, other], const []).map((b) => b.status.name).toSet(),
        {'due'},
      );
      // The per-card history still has every statement.
    });

    test('a guessed (inferred) later bill never retires a real statement', () {
      final oct = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final guess = fixture('bill_due.total_only', changes: {
        'factId': _hexId('g1'),
        'sourceKey': 'sms:g1',
        'observedAt': '2026-11-10T06:00:00Z',
        'occurredAt': null,
        'confidence': 0.6,
        'attrs': {'dueDate': '2026-11-25', 'statementDate': '2026-11-10'},
        'amounts': [
          {'role': 'due_total', 'minor': 10000, 'unit': 'INR'},
        ],
      }) as BillDueFact;
      expect(
        billsFromFacts([oct, guess], const []).map((b) => b.status.name).toSet(),
        {'due'},
      );
    });

    test('a minimum-only payment leaves the rest outstanding, not paid', () {
      final bill = statement('a1', '2026-10-10', '2026-10-25', 10000, minimum: 1000);
      final min = payment('p1', '2026-10-20', 1000, bill.instrument?.toJson());
      final rows = billsFromFacts(
        [bill, min],
        [moneyEvent(min, EventType.cardBillPayment)],
      );
      expect(rows.single.status.name, 'due');
    });

    test('a statement re-sent with the same due date is one bill, not two', () {
      final one = statement('a1', '2026-10-10', '2026-10-25', 10000);
      final again = statement('a2', '2026-10-10', '2026-10-25', 10000);
      expect(billsFromFacts([one, again], const []).length, 1);
    });
  });

  group('a biller receipt chained to its bill by consumer number and amount', () {
    BillDueFact bill(String name, {String due = '2026-11-20', String stmt = '2026-11-05'}) =>
        fixture('bill_due.total_only', changes: {
          'instrument': null,
          'amounts': [
            {'role': 'due_total', 'minor': 92700, 'unit': 'INR'},
          ],
          'attrs': {'dueDate': due, 'statementDate': stmt, 'billerName': name},
          'observedAt': '2026-11-05T00:00:00Z',
          'occurredAt': null,
        }) as BillDueFact;
    MovementFact receipt(String name, {int minor = 92700, String at = '2026-11-09T06:00:00Z'}) =>
        fixture('movement.card_spend', changes: {
          'instrument': null,
          'counterparty': {'name': name, 'vpa': null, 'kind': null, 'accountMask': null},
          'amounts': [
            {'role': 'posted', 'minor': minor, 'unit': 'INR'},
          ],
          'attrs': {
            'direction': 'debit',
            'purpose': 'bill_payment',
            'rail': 'unknown',
            'evidenceOnly': true,
          },
          'observedAt': at,
          'occurredAt': null,
        }) as MovementFact;

    test('same number and amount: the bill is paid on the receipt date', () {
      final rows = billsFromFacts([
        bill('STATE ELECTRICITY 60008413407'),
        receipt('Bill 60008413407'),
      ], const []);
      expect(rows.single.status.name, 'paid');
      expect(rows.single.paidOn, DateTime.utc(2026, 11, 9, 6));
    });

    test('a different number or amount never settles it', () {
      expect(
        billsFromFacts([
          bill('STATE ELECTRICITY 60008413407'),
          receipt('Bill 60099999999'),
        ], const []).single.status.name,
        'due',
      );
      expect(
        billsFromFacts([
          bill('STATE ELECTRICITY 60008413407'),
          receipt('Bill 60008413407', minor: 50000),
        ], const []).single.status.name,
        'due',
      );
    });

    test('a bill that printed no number is settled when the amount singles it out', () {
      expect(
        billsFromFacts([bill('ALEGRA POWER'), receipt('Bill 60008413407')], const [])
            .single
            .status
            .name,
        'paid',
      );
    });
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
