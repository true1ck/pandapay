import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/features/sms_v2/ledger/adapters.dart';
import 'package:pandapay/features/sms_v2/ledger/premium_notices.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;
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

/// What the month-only rule emits: a bill with no amount, month's last day.
Fact monthOnly(
  String key, {
  required String dueDate,
  String observed = '2026-08-20T04:00:00Z',
  String? biller,
  String? kind = 'insurance',
  String? policy,
}) => fixture('bill_due.month_only', {
  'factId': _id(key),
  'sourceKey': 'sms:$key',
  'observedAt': observed,
  'occurredAt': null,
  'counterparty': policy == null
      ? null
      : {'name': null, 'vpa': null, 'kind': 'merchant', 'accountMask': policy},
  'attrs': {
    'dueDate': dueDate,
    'dueMonthOnly': true,
    if (kind != null) 'billKind': kind,
    if (biller != null) 'billerName': biller,
  },
});

void main() {
  final now = DateTime(2026, 11, 15, 12);

  group('premiumNoticesFromFacts', () {
    test('reads the month, the kind, the policy digits and the sender key', () {
      final n = premiumNoticesFromFacts([
        monthOnly('a', dueDate: '2026-09-30', policy: '6789', biller: 'SUNRISE'),
      ]).single;
      expect(n.month, DateTime(2026, 9));
      expect(n.category, CommitmentCategory.insurance);
      expect(n.policyLast4, '6789');
      expect(n.title, 'SUNRISE');
      expect(n.sourceKey, 'sms:a');
    });

    test('a dated bill is not a notice', () {
      expect(
        premiumNoticesFromFacts([fixture('bill_due.total_only', {})]),
        isEmpty,
      );
    });

    test('the kind comes from the rule; none named is "other", never guessed',
        () {
      expect(
        premiumNoticesFromFacts([
          monthOnly('u', dueDate: '2026-12-31', kind: 'utility'),
          monthOnly('x', dueDate: '2026-12-31', kind: null),
        ]).map((n) => n.category).toSet(),
        {CommitmentCategory.utility, CommitmentCategory.other},
      );
    });

    test('a short mask is kept whole; a long one reduced to its last four', () {
      expect(
        premiumNoticesFromFacts([
          monthOnly('s', dueDate: '2026-12-31', policy: '89'),
        ]).single.policyLast4,
        '89',
      );
      expect(
        premiumNoticesFromFacts([
          monthOnly('l', dueDate: '2026-12-31', policy: '123456'),
        ]).single.policyLast4,
        '3456',
      );
    });

    test('no title falls back to the category label', () {
      expect(
        premiumNoticesFromFacts([monthOnly('t', dueDate: '2026-12-31')])
            .single
            .displayTitle,
        CommitmentCategory.insurance.label,
      );
    });
  });

  group('upcoming reminders', () {
    List<PremiumNotice> ns(List<Fact> f) => premiumNoticesFromFacts(f);

    test('a month still ahead is a reminder; the current month too', () {
      final r = premiumRemindersFromNotices(
        ns([
          monthOnly('dec', dueDate: '2026-12-31', policy: '1111'),
          monthOnly('nov', dueDate: '2026-11-30', policy: '2222'),
        ]),
        now: now,
      );
      expect(r.map((x) => x.premiumMonth), [DateTime(2026, 11), DateTime(2026, 12)]);
    });

    test('a month gone by is not an upcoming reminder', () {
      expect(
        premiumRemindersFromNotices(
          ns([monthOnly('sep', dueDate: '2026-09-30')]),
          now: now,
        ),
        isEmpty,
      );
    });

    test('one reminder per policy: the furthest month, the latest message', () {
      final r = premiumRemindersFromNotices(
        ns([
          monthOnly('a', dueDate: '2026-12-31', policy: '1111'),
          monthOnly('b', dueDate: '2027-03-31', policy: '1111'),
          monthOnly('c', dueDate: '2027-03-31', policy: '1111',
              observed: '2026-11-10T04:00:00Z'),
        ]),
        now: now,
      );
      expect(r, hasLength(1));
      expect(r.single.premiumMonth, DateTime(2027, 3));
      expect(r.single.sourceKey, 'sms:c');
    });

    test('two policies stay two reminders', () {
      final r = premiumRemindersFromNotices(
        ns([
          monthOnly('a', dueDate: '2026-12-31', policy: '1111'),
          monthOnly('b', dueDate: '2026-12-31', policy: '2222'),
        ]),
        now: now,
      );
      expect(r.map((x) => x.accountLast4).toSet(), {'1111', '2222'});
    });

    Commitment live(CommitmentStatus s) => Commitment(
      id: 'v2:z',
      title: CommitmentCategory.insurance.label,
      category: CommitmentCategory.insurance,
      amount: Money.fromRupees(2500),
      dueOn: DateTime(2026, 12, 20),
      identifier: '1111',
      status: s,
    );

    test('a policy with a live unpaid bill is not also a reminder', () {
      expect(
        premiumRemindersFromNotices(
          ns([monthOnly('a', dueDate: '2026-12-31', policy: '1111')]),
          commitments: [live(CommitmentStatus.due)],
          now: now,
        ),
        isEmpty,
      );
    });

    test('a paid bill does not hide the next reminder', () {
      expect(
        premiumRemindersFromNotices(
          ns([monthOnly('a', dueDate: '2026-12-31', policy: '1111')]),
          commitments: [live(CommitmentStatus.paid)],
          now: now,
        ),
        hasLength(1),
      );
    });
  });

  group('past history', () {
    test('only past months, one row per policy and month, to confirm', () {
      final past = pastPremiumReceiptsFromNotices(
        premiumNoticesFromFacts([
          monthOnly('a', dueDate: '2026-09-30', policy: '6789'),
          monthOnly('b', dueDate: '2026-09-30', policy: '6789',
              observed: '2026-08-25T04:00:00Z'),
          monthOnly('c', dueDate: '2026-10-31', policy: '6789'),
          monthOnly('d', dueDate: '2026-12-31', policy: '6789'),
          monthOnly('e', dueDate: '2026-11-30', policy: '6789'),
        ]),
        now,
      );
      expect(past, hasLength(2)); // Sep (once) and Oct; Nov is this month
      expect(
        past.map((r) => r.status).toSet(),
        {PastBillReceiptStatus.needsConfirmation},
      );
      expect(past.every((r) => r.dueMonthOnly), isTrue);
      expect(past.every((r) => r.amount == null), isTrue);
      expect(past.map((r) => r.dueDate!.day).toSet(), {30, 31});
      // The latest message of September, and October's.
      expect(past.map((r) => r.sourceKey).toSet(), {'sms:b', 'sms:c'});
    });

    test('survives a save and a reload', () {
      final r = pastPremiumReceiptsFromNotices(
        premiumNoticesFromFacts([
          monthOnly('a', dueDate: '2026-09-30', policy: '6789'),
        ]),
        now,
      ).single;
      final back = PastBillReceipt.fromJson(
        (jsonDecode(jsonEncode(r.toJson())) as Map).cast<String, dynamic>(),
      );
      expect(back.dueMonthOnly, isTrue);
      expect(back.categoryName, 'insurance');
      expect(back.accountLast4, '6789');
    });

    test('an older saved row without the flag still loads', () {
      final json = PastBillReceipt(
        id: 'x',
        sourceKey: 'k',
        merchant: 'Old row',
        amount: null,
        occurredAt: DateTime(2026, 8, 1),
        receivedAt: DateTime(2026, 8, 1),
        status: PastBillReceiptStatus.needsConfirmation,
      ).toJson()
        ..remove('dueMonthOnly')
        ..remove('categoryName');
      final back = PastBillReceipt.fromJson(json);
      expect(back.dueMonthOnly, isFalse);
      expect(back.categoryName, isNull);
    });
  });

  group('beside dated bills', () {
    test('a month-only notice never becomes a bill with a made-up day', () {
      expect(
        billsFromFacts([monthOnly('a', dueDate: '2026-12-31')], const [], now: now),
        isEmpty,
      );
    });

    test('and it does not disturb a dated bill from the same insurer', () {
      final dated = fixture('bill_due.total_only', {
        'factId': _id('dated'),
        'sourceKey': 'sms:dated',
        'observedAt': '2026-11-01T06:00:00Z',
        'occurredAt': null,
        'instrument': null,
        'attrs': {'dueDate': '2026-11-20', 'billerName': 'SUNRISE LIFE INSURANCE'},
        'amounts': [
          {'role': 'due_total', 'minor': 250000, 'unit': 'INR'},
        ],
      });
      final rows = billsFromFacts(
        [dated, monthOnly('m', dueDate: '2026-12-31')],
        const [],
        now: now,
      );
      expect(rows, hasLength(1));
      expect(rows.single.amount!.paise, 250000);
      expect(rows.single.category, CommitmentCategory.insurance);
    });

    test('a rule that says what a dated bill is wins over the title', () {
      final bill = fixture('bill_due.total_only', {
        'factId': _id('kind'),
        'sourceKey': 'sms:kind',
        'observedAt': '2026-11-01T06:00:00Z',
        'occurredAt': null,
        'instrument': null,
        'attrs': {
          'dueDate': '2026-11-20',
          // A name no list knows, and one that would read as a utility.
          'billerName': 'POWER AND LIGHT FRIENDS',
          'billKind': 'insurance',
        },
        'amounts': [
          {'role': 'due_total', 'minor': 100000, 'unit': 'INR'},
        ],
      });
      expect(
        billsFromFacts([bill], const [], now: now).single.category,
        CommitmentCategory.insurance,
      );
    });

    test('with no billKind the biller name still classifies as before', () {
      final bill = fixture('bill_due.total_only', {
        'factId': _id('nokind'),
        'sourceKey': 'sms:nokind',
        'observedAt': '2026-11-01T06:00:00Z',
        'occurredAt': null,
        'instrument': null,
        'attrs': {'dueDate': '2026-11-20', 'billerName': 'CITY POWER BOARD'},
        'amounts': [
          {'role': 'due_total', 'minor': 100000, 'unit': 'INR'},
        ],
      });
      expect(
        billsFromFacts([bill], const [], now: now).single.category,
        CommitmentCategory.utility,
      );
    });
  });

  test('billKind names map to the page categories', () {
    expect({
      for (final k in ['utility', 'telecom', 'insurance', 'loan', 'rent', 'education', 'tax'])
        k: categoryOfBillKind(k),
    }, {
      'utility': CommitmentCategory.utility,
      'telecom': CommitmentCategory.telecom,
      'insurance': CommitmentCategory.insurance,
      'loan': CommitmentCategory.loanOrEmi,
      'rent': CommitmentCategory.rent,
      'education': CommitmentCategory.education,
      'tax': CommitmentCategory.tax,
    });
    expect(categoryOfBillKind(null), isNull);
    expect(categoryOfBillKind('spaceship'), isNull);
  });
}
