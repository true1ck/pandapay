// Synthetic tests for the scorer. No private data: every message is invented.
import 'package:pandapay_domain/sms_v2.dart';
import 'package:sms_rules_cli/scoring.dart';
import 'package:test/test.dart';

FactEnvelope envelope({
  String ruleId = 'TEST-RULE-01',
  List<Amount> amounts = const [],
  InstrumentMention? instrument,
}) => FactEnvelope(
  factId: 'f',
  sourceKey: 's',
  observedAt: DateTime.utc(2026, 1, 1),
  instrument: instrument,
  amounts: amounts,
  provenance: Provenance(
    engine: Engine.rules,
    ruleId: ruleId,
    ruleVersion: 1,
    bundleVersion: 0,
    engineVersion: '1',
    appVersion: '2.0.0',
  ),
  confidence: 0.9,
);

Amount amount(int minor, {String unit = 'INR', AmountRole? role}) =>
    Amount(role: role ?? AmountRole.posted, minor: minor, unit: unit);

MovementFact movement({
  MovementPurpose purpose = MovementPurpose.purchase,
  Direction direction = Direction.debit,
  Rail rail = Rail.card,
  bool? evidenceOnly,
  String ruleId = 'TEST-RULE-01',
  int minor = 10000,
}) => MovementFact(
  envelope(ruleId: ruleId, amounts: [amount(minor)]),
  direction: direction,
  purpose: purpose,
  rail: rail,
  evidenceOnly: evidenceOnly,
);

AttemptFact attempt({
  AttemptStatus status = AttemptStatus.pending,
  Direction direction = Direction.debit,
  MovementPurpose purpose = MovementPurpose.unknown,
  String ruleId = 'ANY-RULE-NAME',
  int minor = 25000,
  String unit = 'INR',
}) => AttemptFact(
  envelope(
    ruleId: ruleId,
    amounts: [amount(minor, unit: unit, role: AmountRole.scheduled)],
  ),
  status: status,
  direction: direction,
  purpose: purpose,
);

InterpretResult result(
  Fact? fact, {
  String? ruleId,
  InterpretOutcome? outcome,
}) => InterpretResult(
  outcome:
      outcome ??
      (fact == null ? InterpretOutcome.unknown : InterpretOutcome.matched),
  facts: [?fact],
  ruleId: ruleId ?? fact?.provenance.ruleId,
  templateHash: '',
);

Map<String, Object?> labelRow(
  Map<String, Object?> expected, {
  String body = 'synthetic message',
  String family = 'other',
  int? population,
  int? sample,
}) => {
  'sampling_family': family,
  'family_population': ?population,
  'family_sample': ?sample,
  'message': {
    'sender': 'TESTBK',
    'body': body,
    'observedAt': '2026-01-01T00:00:00Z',
  },
  'expected': {'confidence': 'sure', 'countsAs': 'none', ...expected},
};

Map<String, Object?> score(
  Map<String, Object?> row,
  InterpretResult r, {
  Map? phone,
  Map<String, String> families = const {},
  int index = 0,
}) => scoreRow(
  index: index,
  row: row,
  result: r,
  phoneRow: phone,
  ruleFamilies: families,
);

Map<String, Object?> leg(
  String type,
  String role, {
  bool spend = false,
  bool income = false,
  bool investment = false,
  int? minor,
  String? entryId,
}) => {
  'eventId': 'e-$type',
  'type': type,
  'role': role,
  'ledger': [
    {
      'entryId': ?entryId,
      'amountMinor': ?minor,
      'isSpend': spend,
      'isIncome': income,
      'isInvestment': investment,
    },
  ],
};

void main() {
  group('reading table', () {
    test(
      'a dollar sign infers USD, so a USD amount is not an INR mismatch',
      () {
        final row = labelRow({
          'reading': 'failed_attempt',
          'amount': 0.02,
          'unit': null,
        }, body: 'Payment of \$0.02 failed');
        final scored = score(
          row,
          result(attempt(status: AttemptStatus.failed, minor: 2, unit: 'USD')),
        );
        expect(scored['amountOk'], isTrue);
        expect(expectedUnit({}, 'Charged US\$5'), 'USD');
        expect(expectedUnit({}, 'Charged Rs 5'), 'INR');
        expect(expectedUnit({'reading': 'reward_points'}, '500'), 'POINTS');
      },
    );

    test('a collect request reads as payment_request from its facts', () {
      expect(reading(attempt(ruleId: 'SOME-NEW-RULE')), 'payment_request');
      expect(reading(attempt(status: AttemptStatus.failed)), 'failed_attempt');
      expect(
        reading(attempt(status: AttemptStatus.scheduled)),
        'upcoming_charge',
      );
      expect(
        reading(attempt(purpose: MovementPurpose.purchase)),
        'failed_attempt',
      );
      expect(reading(attempt(direction: Direction.credit)), 'failed_attempt');
    });

    test('an ignored notice may read as not_financial', () {
      expect(readingsAgree('not_financial', 'service_notice'), isTrue);
      expect(readingsAgree('not_financial', 'promo'), isTrue);
      expect(readingsAgree('not_financial', 'otp'), isTrue);
      expect(readingsAgree('not_financial', 'unknown'), isFalse);
      expect(readingsAgree('not_financial', 'card_spend'), isFalse);
      expect(readingsAgree('promo', 'service_notice'), isFalse);
      final info = InfoFact(envelope(), category: InfoCategory.service);
      final scored = score(
        labelRow({'reading': 'not_financial'}),
        result(info, outcome: InterpretOutcome.ignored),
      );
      expect(scored['ok'], isTrue);
      expect(scored['financial'], isFalse);
    });

    test('a biller receipt reads as bill_receipt, a recharge as recharge', () {
      expect(
        reading(
          movement(
            purpose: MovementPurpose.billPayment,
            evidenceOnly: true,
            rail: Rail.unknown,
          ),
        ),
        'bill_receipt',
      );
      expect(
        reading(
          movement(
            purpose: MovementPurpose.billPayment,
            evidenceOnly: true,
            rail: Rail.unknown,
            ruleId: 'SUB-RCH-SUCCESS-01',
          ),
        ),
        'recharge',
      );
      expect(
        reading(
          movement(purpose: MovementPurpose.emi, evidenceOnly: true),
          ruleFamily: 'bill_receipt',
        ),
        'bill_receipt',
      );
      // A real bill payment that is not evidence only stays a movement.
      expect(
        reading(
          movement(purpose: MovementPurpose.billPayment, rail: Rail.unknown),
        ),
        'movement',
      );
    });

    test('a card statement reads as statement, another bill as bill_due', () {
      final due = BillDueFact(envelope(), dueDate: '2026-02-01');
      expect(reading(due, ruleFamily: 'card_statement'), 'statement');
      expect(reading(due, ruleFamily: 'bill_due'), 'bill_due');
      expect(reading(due), 'bill_due');
    });

    test('an info fact amount is read but is never money', () {
      final info = InfoFact(
        envelope(ruleId: 'ANY-IPO-RULE'),
        category: InfoCategory.service,
        amountMinor: 1500000,
      );
      expect(reading(info, ruleFamily: 'ipo_notice'), 'ipo_application_notice');
      final row = labelRow({
        'reading': 'ipo_application_notice',
        'amount': 15000.0,
      });
      final scored = score(
        row,
        result(info),
        families: {'ANY-IPO-RULE': 'ipo_notice'},
      );
      final got = scored['got'] as Map;
      expect(got['amountMinor'], 1500000);
      expect(got['amountInformational'], isTrue);
      expect(scored['amountOk'], isTrue);
      expect(scored['ok'], isTrue);
      expect(got['countsAs'], 'none');
      expect(scored['totalsMinor'], isNull);
      expect(scored['totals'], 'neutral_ok');
    });
  });

  group('totals metrics', () {
    test('a correct effect with a wrong amount is not totals-correct', () {
      final row = labelRow({
        'reading': 'card_spend',
        'countsAs': 'spending',
        'amount': 100.0,
      });
      expect(score(row, result(movement(minor: 10000)))['totals'], 'change_ok');
      expect(
        score(row, result(movement(minor: 12000)))['totals'],
        'change_amount',
      );
    });

    test('a row that should change totals but reads none is missed', () {
      final row = labelRow({
        'reading': 'recharge',
        'countsAs': 'spending',
        'amount': 100.0,
      });
      final scored = score(
        row,
        result(
          movement(
            purpose: MovementPurpose.billPayment,
            evidenceOnly: true,
            ruleId: 'SUB-RCH-SUCCESS-01',
          ),
        ),
      );
      expect(scored['totals'], 'change_missed');
      final wrong = score(
        labelRow({'reading': 'card_spend', 'countsAs': 'money_in'}),
        result(movement()),
      );
      expect(wrong['totals'], 'change_wrong_effect');
    });

    test('a row that must not change totals but counts is a false count', () {
      final scored = score(
        labelRow({'reading': 'card_bill_payment', 'countsAs': 'transfer'}),
        result(movement()),
      );
      expect(scored['totals'], 'false_count');
      expect(scored['totalsMinor'], 10000);
      final fine = score(
        labelRow({'reading': 'card_bill_payment', 'countsAs': 'transfer'}),
        result(movement(purpose: MovementPurpose.cardPayment)),
      );
      expect(fine['totals'], 'neutral_ok');
    });

    test('a phone replay counts the distinct ledger rows once', () {
      final outcome = ledgerOutcome([
        leg('purchase', 'debit_leg', spend: true, minor: 5000, entryId: 'a'),
        leg('purchase', 'charge', spend: true, minor: 5000, entryId: 'a'),
        leg(
          'purchase',
          'duplicate_notice',
          spend: true,
          minor: 5000,
          entryId: 'b',
        ),
      ]);
      expect(outcome.effect, 'spending');
      expect(outcome.amountMinor, 5000);
      expect(outcome.eventTypes, {'purchase'});
    });

    test('summary reports totals-correct, false counts and their money', () {
      final rows = [
        score(
          labelRow({
            'reading': 'card_spend',
            'countsAs': 'spending',
            'amount': 100.0,
          }),
          result(movement()),
          index: 0,
        ),
        score(
          labelRow({
            'reading': 'card_spend',
            'countsAs': 'spending',
            'amount': 100.0,
          }),
          result(movement(minor: 99)),
          index: 1,
        ),
        score(
          labelRow({'reading': 'card_bill_payment', 'countsAs': 'transfer'}),
          result(movement(minor: 7000)),
          index: 2,
        ),
        score(
          labelRow({'reading': 'promo'}),
          result(InfoFact(envelope(), category: InfoCategory.promotion)),
          index: 3,
        ),
      ];
      final totals = summarize(rows, deep: true)['totals'] as Map;
      expect(totals['shouldChangeRows'], 2);
      expect(totals['shouldChangeCorrect'], 1);
      expect(totals['totalsCorrectRate'], 0.5);
      expect(totals['shouldChangeWrongAmount'], 1);
      expect(totals['mustNotChangeRows'], 2);
      expect(totals['falseCounts'], 1);
      expect(totals['falseCountRate'], 0.5);
      expect(totals['falseCountMinor'], 7000);
      expect(totals['falseCountsByEffect'], {'spending': 1});
      expect(totals['shouldChangeByEffect'], {
        'spending': {'rows': 2, 'correct': 1},
      });
    });
  });

  group('weighting', () {
    test('rows weigh family population over rows of that family', () {
      final rows = [
        {'family': 'big', 'familyPopulation': 900, 'ok': true},
        {'family': 'big', 'familyPopulation': 900, 'ok': false},
        {'family': 'small', 'familyPopulation': 10, 'ok': false},
        {'family': 'none', 'familyPopulation': null, 'ok': true},
      ];
      expect(rowWeights(rows), [450, 450, 10, 1]);
    });

    test('weighted accuracy reflects the inbox, not the sample', () {
      Map<String, Object?> row(String family, int pop, bool ok) => {
        'family': family,
        'familyPopulation': pop,
        'confidence': 'sure',
        'financial': true,
        'unknown': false,
        'ignored': false,
        'ok': ok,
      };
      // Sample: 1 of 2 correct. Inbox: the correct family is 99x bigger.
      final summary = summarize([
        row('common', 990, true),
        row('rare', 10, false),
      ]);
      expect(summary['accuracy'], 0.5);
      expect(summary['weightedAccuracy'], closeTo(0.99, 1e-9));
      expect(summary['weightedPopulation'], 1000);
    });

    test('the sure subset is reweighted to the whole family', () {
      Map<String, Object?> row(bool ok, String confidence) => {
        'family': 'f',
        'familyPopulation': 100,
        'confidence': confidence,
        'financial': true,
        'unknown': false,
        'ignored': false,
        'ok': ok,
        'totals': 'neutral_ok',
        'expected': {'countsAs': 'none'},
        'got': {'countsAs': 'none'},
      };
      final summary = buildSummary([
        row(true, 'sure'),
        row(false, 'sure'),
        row(false, 'unsure'),
      ], phone: false);
      final sure = summary['sure'] as Map;
      expect(sure['weightedPopulation'], 100);
      expect(sure['weightedAccuracy'], 0.5);
      final head = (summary['headline'] as Map)['sure'] as Map;
      expect(head['weightedAccuracy'], 0.5);
      expect(head['accuracy'], 0.5);
    });
  });

  group('event fidelity per feature', () {
    Map phoneWith(List<Map<String, Object?>> events) => {
      'index': 0,
      'decision': 'matched',
      'events': events,
    };

    test('an IPO application needs the right event type and effect', () {
      final row = labelRow({
        'reading': 'ipo_hold',
        'countsAs': 'investment_invested',
        'amount': 100.0,
      });
      final hold = HoldFact(
        envelope(amounts: [amount(10000, role: AmountRole.held)]),
        phase: HoldPhase.placed,
        purpose: HoldPurpose.ipoAsba,
      );
      final good = score(
        row,
        result(hold),
        phone: phoneWith([
          leg('ipo_application', 'debit_leg', investment: true, minor: 10000),
        ]),
      );
      expect(good['feature'], 'ipo');
      expect(good['eventOk'], isTrue);
      final wrongType = score(
        row,
        result(hold),
        phone: phoneWith([
          leg('investment', 'debit_leg', investment: true, minor: 10000),
        ]),
      );
      expect(wrongType['eventOk'], isFalse);
      final summary = summarize([good, wrongType], deep: true);
      final ipo = (summary['eventFidelity'] as Map)['ipo'] as Map;
      expect(ipo['rows'], 2);
      expect(ipo['fidelity'], 1);
      expect(ipo['fidelityRate'], 0.5);
    });

    test('features without a replay report event types as unmeasured', () {
      final scored = score(
        labelRow({
          'reading': 'refund_credited',
          'countsAs': 'refund',
          'amount': 100.0,
        }),
        result(
          movement(
            purpose: MovementPurpose.refund,
            direction: Direction.credit,
          ),
        ),
      );
      expect(scored['feature'], 'refund');
      expect(scored['eventOk'], isNull);
      final refund =
          (summarize([scored], deep: true)['eventFidelity'] as Map)['refund']
              as Map;
      expect(refund['eventTypeMeasured'], 0);
      expect(refund['fidelity'], 1);
    });

    test('investments and subscriptions have their own event types', () {
      final investment = score(
        labelRow({
          'reading': 'investment_topup',
          'countsAs': 'investment_invested',
        }),
        result(movement(purpose: MovementPurpose.investment)),
        phone: phoneWith([
          leg('investment', 'debit_leg', investment: true, minor: 10000),
        ]),
      );
      expect(investment['feature'], 'investment');
      expect(investment['eventOk'], isTrue);
      final subscription = score(
        labelRow({'reading': 'mandate_created'}),
        result(MandateFact(envelope(), phase: MandatePhase.created)),
        phone: phoneWith([]),
      );
      expect(subscription['feature'], 'subscription');
      expect(subscription['eventOk'], isTrue);
    });
  });

  group('disagreement export', () {
    test('most consequential first, then heaviest, with the message', () {
      final rows = [
        score(
          labelRow(
            {'reading': 'card_spend'},
            family: 'big',
            population: 900,
            sample: 2,
            body: 'body one',
          ),
          result(null),
          index: 0,
        ),
        score(
          labelRow(
            {'reading': 'card_bill_payment', 'countsAs': 'transfer'},
            family: 'small',
            population: 10,
            sample: 1,
            body: 'body two',
          ),
          result(movement()),
          index: 1,
        ),
        score(
          labelRow(
            {'reading': 'upi_spend', 'countsAs': 'spending'},
            family: 'mid',
            population: 50,
            sample: 1,
            body: 'body three',
          ),
          result(movement()),
          index: 2,
        ),
      ];
      final messages = [
        for (final body in ['body one', 'body two', 'body three'])
          <String, Object?>{
            'sender': 'TESTBK',
            'observedAt': 'now',
            'body': body,
          },
      ];
      final export = disagreementExport(rows, messages.cast<Map>());
      expect(export.map((d) => d['index']), [1, 0, 2]);
      expect(export.first['severity'], 0);
      expect(export.first['weight'], 10);
      final sheet = reviewSheet(export);
      expect(sheet, contains('body two'));
      expect(sheet.indexOf('#1'), lessThan(sheet.indexOf('#0')));
    });
  });

  test('ledger effect behaviour is unchanged', () {
    expect(ledgerEffect([leg('card_bill_payment', 'credit_leg')]), 'none');
    expect(ledgerEffect([leg('card_bill_payment', 'debit_leg')]), 'transfer');
    expect(ledgerEffect([leg('refund', 'reversal')]), 'refund');
    expect(isFinancial({'reading': 'promo'}), isFalse);
    expect(isFinancial({'reading': 'card_spend'}), isTrue);
  });
}
