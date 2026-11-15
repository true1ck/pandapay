import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay_domain/sms_v2.dart';

// Synthetic names and numbers only: the repository is public.
Fact fixture(String name, Map<String, Object?> changes) => Fact.fromJson(
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

String _id(String s) =>
    s.codeUnits.map((c) => c.toRadixString(16)).join().padRight(64, '0');

Map<String, Object?> _prov(String rule) => {
  'engine': 'rules',
  'ruleId': rule,
  'ruleVersion': 1,
  'bundleVersion': 1,
  'engineVersion': '2.0.0',
  'appVersion': '1.0.0+1',
};

const _fund = {
  'name': 'FLEXI CAP FUND',
  'vpa': null,
  'kind': 'merchant',
  'accountMask': null,
};

/// "Will be debited on <due>" notice read by [rule].
Fact notice(
  String key,
  String rule, {
  required String purpose,
  required String due,
  int minor = 500000,
  Object? counterparty = _fund,
  String observed = '2026-11-01T06:00:00Z',
}) => fixture('attempt.scheduled_debit', {
  'factId': _id(key),
  'sourceKey': 'sms:$key',
  'observedAt': observed,
  'occurredAt': null,
  'counterparty': counterparty,
  'amounts': [
    {'role': 'scheduled', 'minor': minor, 'unit': 'INR'},
  ],
  'attrs': {
    'status': 'scheduled',
    'direction': 'debit',
    'purpose': purpose,
    'dueAt': due,
  },
  'provenance': _prov(rule),
});

Fact debit(
  String key,
  String at, {
  int minor = 500000,
  String purpose = 'investment',
  Object? counterparty = _fund,
}) => fixture('movement.card_spend', {
  'factId': _id(key),
  'sourceKey': 'sms:$key',
  'observedAt': at,
  'occurredAt': null,
  'counterparty': counterparty,
  'amounts': [
    {'role': 'posted', 'minor': minor, 'unit': 'INR'},
  ],
  'attrs': {'direction': 'debit', 'purpose': purpose, 'rail': 'nach'},
});

Fact sipMandate(String key, String at, String phase) =>
    fixture('mandate.subscription_created', {
      'factId': _id(key),
      'sourceKey': 'sms:$key',
      'observedAt': at,
      'occurredAt': null,
      'counterparty': _fund,
      'amounts': [
        {'role': 'ceiling', 'minor': 500000, 'unit': 'INR'},
      ],
      'attrs': {
        'phase': phase,
        'frequency': 'monthly',
        'merchantName': 'FLEXI CAP FUND',
        'oneTime': false,
        'mandatePurpose': 'sip',
      },
    });

final _now = DateTime(2026, 10, 25, 12);

List<Commitment> bills(List<Fact> facts, {List<Event> events = const []}) =>
    billsFromFacts(facts, events, now: _now);

void main() {
  group('scheduled debits', () {
    test('a SIP instalment notice becomes a SIP row on its date', () {
      final rows = bills([
        notice('a', 'INV-MF-SIP-UPCOMING-01',
            purpose: 'investment', due: '2026-11-05T00:00:00Z'),
      ]);
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r.category, CommitmentCategory.investment);
      expect(r.title, 'Flexi Cap Fund');
      expect(r.dueOn, DateTime(2026, 11, 5));
      expect(r.amount!.paise, 500000);
      expect(r.cadence, CommitmentCadence.monthly);
      expect(r.status, CommitmentStatus.due);
      expect(r.sourceKey, 'sms:a');
    });

    test('a repeated reminder for the same instalment is one row', () {
      final rows = bills([
        notice('a', 'INV-MF-SIP-UPCOMING-01',
            purpose: 'investment', due: '2026-11-05T00:00:00Z'),
        notice('b', 'INV-MF-SIP-UPCOMING-01',
            purpose: 'investment',
            due: '2026-11-05T00:00:00Z',
            observed: '2026-11-04T06:00:00Z'),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.sourceKey, 'sms:b');
    });

    test('the debit that follows settles it', () {
      final paid = debit('d', '2026-11-05T05:00:00Z');
      final event = Event(
        eventId: paid.factId,
        type: EventType.investment,
        status: EventStatus.complete,
        legs: [EventLeg(factId: paid.factId, role: LegRole.debitLeg)],
        confidence: .99,
        occurredAt: paid.effectiveAt,
        amountMinor: 500000,
      );
      final rows = billsFromFacts(
        [
          notice('a', 'INV-MF-SIP-UPCOMING-01',
              purpose: 'investment', due: '2026-11-05T00:00:00Z'),
          paid,
        ],
        [event],
        now: DateTime(2026, 11, 6),
      );
      expect(rows.single.status, CommitmentStatus.paid);
      expect(rows.single.paidOn, paid.effectiveAt);
      expect(rows.single.linkedTransactionId, 'v2:${event.eventId}');
    });

    test('a debit of another amount does not settle it', () {
      final rows = bills([
        notice('a', 'INV-MF-SIP-UPCOMING-01',
            purpose: 'investment', due: '2026-11-05T00:00:00Z'),
        debit('d', '2026-11-05T05:00:00Z', minor: 100000),
      ]);
      expect(rows.single.status, CommitmentStatus.due);
    });

    test('an EMI notice is a loan EMI', () {
      final rows = bills([
        notice('e', 'GENZ-EMI-UPCOMING-DEBIT',
            purpose: 'emi',
            due: '2026-11-07T00:00:00Z',
            minor: 1234500,
            counterparty: null),
      ]);
      expect(rows.single.category, CommitmentCategory.loanOrEmi);
      expect(rows.single.title, 'Loan / EMI');
      expect(rows.single.amount!.paise, 1234500);
    });

    test('an insurance premium notice is typed by its rule, whatever the name', () {
      // "SUNRISE" is in no list: the rule's purpose says it is insurance.
      final rows = bills([
        notice('i', 'ANY-RULE-AT-ALL',
            purpose: 'insurance',
            due: '2026-11-25T00:00:00Z',
            minor: 250000,
            counterparty: {...(_fund as Map), 'name': 'SUNRISE'}),
      ]);
      expect(rows.single.category, CommitmentCategory.insurance);
      expect(rows.single.title, 'Sunrise');
      expect(rows.single.cadence, CommitmentCadence.oneTime);
    });

    test('a bill debit that names nobody is left out', () {
      expect(
        bills([
          notice('x', 'SYN-RULE-ATTEMPT',
              purpose: 'bill_payment',
              due: '2026-11-05T00:00:00Z',
              counterparty: null),
        ]),
        isEmpty,
      );
    });

    test('the rule id decides nothing: the typed purpose does', () {
      // Same wording class, a rule id that names nothing the app knows.
      final rows = bills([
        notice('z', 'ANY-RULE-AT-ALL',
            purpose: 'emi',
            due: '2026-11-07T00:00:00Z',
            counterparty: null),
        notice('w', 'ANY-RULE-AT-ALL',
            purpose: 'investment', due: '2026-11-08T00:00:00Z'),
      ]);
      expect(
        {for (final r in rows) r.category},
        {CommitmentCategory.loanOrEmi, CommitmentCategory.investment},
      );
    });

    test('a named biller is classified by the same classifier as any bill', () {
      final rows = bills([
        notice('n', 'ANY-RULE-AT-ALL',
            purpose: 'bill_payment',
            due: '2026-11-05T00:00:00Z',
            counterparty: {...(_fund as Map), 'name': 'CITY POWER BOARD'}),
      ]);
      expect(rows.single.title, 'City Power Board');
    });
  });

  group('running SIP', () {
    final lastDebit = debit('d', '2026-10-05T05:00:00Z');

    test('next instalment is the month after the last debit', () {
      final rows = bills([
        sipMandate('m', '2026-06-01T06:00:00Z', 'created'),
        lastDebit,
      ]);
      final sip = rows.where((r) => r.title == 'Flexi Cap Fund').single;
      expect(sip.dueOn, DateTime(2026, 11, 5));
      expect(sip.amount!.paise, 500000);
      expect(sip.category, CommitmentCategory.investment);
    });

    test('a cancelled SIP shows nothing', () {
      expect(
        bills([
          sipMandate('m', '2026-06-01T06:00:00Z', 'created'),
          sipMandate('n', '2026-10-10T06:00:00Z', 'revoked'),
          lastDebit,
        ]),
        isEmpty,
      );
    });

    test('a dated notice wins over the worked-out date', () {
      final rows = bills([
        sipMandate('m', '2026-06-01T06:00:00Z', 'created'),
        lastDebit,
        notice('a', 'INV-MF-SIP-UPCOMING-01',
            purpose: 'investment', due: '2026-11-06T00:00:00Z'),
      ]);
      expect(rows, hasLength(1));
      expect(rows.single.dueOn, DateTime(2026, 11, 6));
    });

    test('with no debit seen there is no date to guess', () {
      expect(
        bills([sipMandate('m', '2026-06-01T06:00:00Z', 'created')]),
        isEmpty,
      );
    });
  });

  test('an EMI due notice on a loan account lands under Loans and EMIs', () {
    final emi = fixture('bill_due.total_only', {
      'factId': _id('emi'),
      'sourceKey': 'sms:emi',
      'observedAt': '2026-10-20T06:00:00Z',
      'occurredAt': null,
      'instrument': {
        'kind': 'loan',
        'issuerSlug': null,
        'maskDigits': '1234',
        'maskLength': null,
        'productName': null,
        'raw': 'XX1234',
      },
      'attrs': {'dueDate': '2026-11-05'},
      'amounts': [
        {'role': 'due_total', 'minor': 1234500, 'unit': 'INR'},
      ],
    });
    final r = bills([emi]).single;
    expect(r.category, CommitmentCategory.loanOrEmi);
    expect(r.title, 'Loan EMI');
    expect(r.identifier, '1234');
  });

  group('more scenarios', () {
    const nov5 = '2026-11-05T00:00:00Z';
    Fact sip(String key,
            {String name = 'FLEXI CAP FUND',
            int minor = 500000,
            String due = nov5}) =>
        notice(key, 'ANY-RULE',
            purpose: 'investment',
            due: due,
            minor: minor,
            counterparty: {...(_fund as Map), 'name': name});

    Map<String, Object?> attempt(String key, Map<String, Object?> attrs) =>
        {
          'factId': _id(key),
          'sourceKey': 'sms:$key',
          'counterparty': _fund,
          'amounts': [
            {'role': 'scheduled', 'minor': 500000, 'unit': 'INR'},
          ],
          'attrs': attrs,
          'provenance': _prov('ANY-RULE'),
        };

    test('two funds on one day are two rows', () {
      expect(
        bills([sip('a'), sip('b', name: 'INDEX FUND')])
            .map((r) => r.title)
            .toSet(),
        {'Flexi Cap Fund', 'Index Fund'},
      );
    });

    test('one fund with two amounts on a day is two rows', () {
      expect(bills([sip('a'), sip('b', minor: 300000)]), hasLength(2));
    });

    test('an EMI and a SIP of the same amount and day stay apart', () {
      final rows = bills([
        sip('a'),
        notice('e', 'ANY-RULE', purpose: 'emi', due: nov5, counterparty: null),
      ]);
      expect(
        rows.map((r) => r.category).toSet(),
        {CommitmentCategory.investment, CommitmentCategory.loanOrEmi},
      );
    });

    test('a failed, cancelled or pending attempt is not an upcoming debit', () {
      for (final status in ['failed', 'cancelled', 'pending', 'declined']) {
        final f = fixture(
          'attempt.scheduled_debit',
          attempt('s$status', {
            'status': status,
            'direction': 'debit',
            'purpose': 'investment',
            'dueAt': nov5,
          }),
        );
        expect(bills([f]), isEmpty, reason: status);
      }
    });

    test('money coming in is not a payment due', () {
      final f = fixture(
        'attempt.scheduled_debit',
        attempt('credit', {
          'status': 'scheduled',
          'direction': 'credit',
          'purpose': 'investment',
          'dueAt': nov5,
        }),
      );
      expect(bills([f]), isEmpty);
    });

    test('a date near midnight is read on the Indian calendar', () {
      // 19:00 UTC on 4 Nov is 00:30 on 5 Nov in India.
      final rows = bills([sip('a', due: '2026-11-04T19:00:00Z')]);
      expect(rows.single.dueOn, DateTime(2026, 11, 5));
    });

    group('settling', () {
      Commitment statusFor(String debitAt, {String purpose = 'investment'}) =>
          billsFromFacts(
            [sip('a'), debit('d', debitAt, purpose: purpose)],
            const [],
            now: DateTime(2026, 11, 20),
          ).single;

      test('five days early and seven days late still settle it', () {
        expect(statusFor('2026-10-31T05:00:00Z').status, CommitmentStatus.paid);
        expect(statusFor('2026-11-12T05:00:00Z').status, CommitmentStatus.paid);
      });

      test('six days early or eight days late does not', () {
        expect(statusFor('2026-10-30T05:00:00Z').status, CommitmentStatus.due);
        expect(statusFor('2026-11-13T05:00:00Z').status, CommitmentStatus.due);
      });

      test('only a debit of the same purpose settles it', () {
        expect(
          statusFor('2026-11-05T05:00:00Z', purpose: 'purchase').status,
          CommitmentStatus.due,
        );
        expect(
          statusFor('2026-11-05T05:00:00Z', purpose: 'emi').status,
          CommitmentStatus.due,
        );
      });

      test('a debit of another amount does not', () {
        final r = billsFromFacts(
          [sip('a'), debit('d', '2026-11-05T05:00:00Z', minor: 100000)],
          const [],
          now: DateTime(2026, 11, 20),
        ).single;
        expect(r.status, CommitmentStatus.due);
      });

      test('the same amount from another fund does not settle it', () {
        final r = billsFromFacts(
          [
            sip('a'),
            debit(
              'd',
              '2026-11-05T05:00:00Z',
              counterparty: {...(_fund as Map), 'name': 'GOLD FUND'},
            ),
          ],
          const [],
          now: DateTime(2026, 11, 20),
        ).single;
        expect(r.status, CommitmentStatus.due);
      });

      test('a debit that names no payee still settles it', () {
        final r = billsFromFacts(
          [sip('a'), debit('d', '2026-11-05T05:00:00Z', counterparty: null)],
          const [],
          now: DateTime(2026, 11, 20),
        ).single;
        expect(r.status, CommitmentStatus.paid);
      });

      test('a missed debit stays due, with its date in the past', () {
        final r = billsFromFacts(
          [sip('a')],
          const [],
          now: DateTime(2026, 11, 20),
        ).single;
        expect(r.status, CommitmentStatus.due);
        expect(r.dueOn.isBefore(DateTime(2026, 11, 20)), isTrue);
      });
    });

    group('a running SIP', () {
      List<Commitment> run(List<Fact> facts, DateTime now) =>
          billsFromFacts(facts, const [], now: now);

      test('a lapsed history still gets the next date, never a past one', () {
        final rows = run(
          [
            sipMandate('m', '2026-01-01T06:00:00Z', 'created'),
            debit('d', '2026-07-05T05:00:00Z'),
          ],
          DateTime(2026, 10, 25),
        );
        expect(rows.single.dueOn, DateTime(2026, 11, 5));
      });

      test('the 31st lands on the last day of a short month', () {
        final rows = run(
          [
            sipMandate('m', '2026-01-01T06:00:00Z', 'created'),
            debit('d', '2026-01-31T05:00:00Z'),
          ],
          DateTime(2026, 2, 10),
        );
        expect(rows.single.dueOn, DateTime(2026, 2, 28));
      });

      test('paused hides it; resumed brings it back', () {
        final base = [
          debit('d', '2026-10-05T05:00:00Z'),
          sipMandate('m', '2026-06-01T06:00:00Z', 'created'),
          sipMandate('p', '2026-10-06T06:00:00Z', 'paused'),
        ];
        expect(run(base, DateTime(2026, 10, 25)), isEmpty);
        expect(
          run(
            [...base, sipMandate('r', '2026-10-10T06:00:00Z', 'resumed')],
            DateTime(2026, 10, 25),
          ),
          hasLength(1),
        );
      });

      test('a new SIP after a cancelled one shows', () {
        expect(
          run(
            [
              sipMandate('m', '2026-01-01T06:00:00Z', 'created'),
              sipMandate('x', '2026-05-01T06:00:00Z', 'revoked'),
              sipMandate('n', '2026-08-01T06:00:00Z', 'created'),
              debit('d', '2026-10-05T05:00:00Z'),
            ],
            DateTime(2026, 10, 25),
          ),
          hasLength(1),
        );
      });

      test('a one-time or non-SIP mandate is not a SIP', () {
        final oneTime = fixture('mandate.subscription_created', {
          'factId': _id('o'),
          'sourceKey': 'sms:o',
          'counterparty': _fund,
          'amounts': [
            {'role': 'ceiling', 'minor': 500000, 'unit': 'INR'},
          ],
          'attrs': {
            'phase': 'created',
            'frequency': 'monthly',
            'merchantName': 'FLEXI CAP FUND',
            'oneTime': true,
            'mandatePurpose': 'sip',
          },
        });
        final sub = fixture('mandate.subscription_created', {
          'factId': _id('sub'),
          'sourceKey': 'sms:sub',
          'counterparty': _fund,
        });
        final d = debit('d', '2026-10-05T05:00:00Z');
        expect(run([oneTime, d], DateTime(2026, 10, 25)), isEmpty);
        expect(run([sub, d], DateTime(2026, 10, 25)), isEmpty);
      });

      test('a debit whose fund name carries more words is still that fund', () {
        final rows = run(
          [
            sipMandate('m', '2026-01-01T06:00:00Z', 'created'),
            debit(
              'd',
              '2026-10-05T05:00:00Z',
              counterparty: {
                ...(_fund as Map),
                'name': 'FLEXI CAP FUND DIRECT GROWTH',
              },
            ),
          ],
          DateTime(2026, 10, 25),
        );
        expect(rows, hasLength(1));
      });

      test('a debit of another fund is not this SIP history', () {
        expect(
          run(
            [
              sipMandate('m', '2026-01-01T06:00:00Z', 'created'),
              debit(
                'd',
                '2026-10-05T05:00:00Z',
                counterparty: {...(_fund as Map), 'name': 'GOLD FUND'},
              ),
            ],
            DateTime(2026, 10, 25),
          ),
          isEmpty,
        );
      });
    });

    test('a dismissed copy hides the row; a paid copy marks it paid', () {
      final base = bills([sip('a')]).single;
      Commitment copy(CommitmentStatus s) => base.copyWith(
        status: s,
        isUserConfirmed: true,
        paidOn: DateTime(2026, 11, 5),
      );
      expect(
        billsFromFacts(
          [sip('a')],
          const [],
          now: _now,
          manualCopies: [copy(CommitmentStatus.dismissed)],
        ),
        isEmpty,
      );
      expect(
        billsFromFacts(
          [sip('a')],
          const [],
          now: _now,
          manualCopies: [copy(CommitmentStatus.paid)],
        ).single.status,
        CommitmentStatus.paid,
      );
    });
  });
}

