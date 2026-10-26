import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/pending_bills.dart';
import 'package:pandapay/features/insights/bills_horizon.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

final _now = DateTime(2026, 10, 25, 14, 30);

BillsHorizonFilter _filter(BillsHorizon horizon) =>
    BillsHorizonFilter(horizon, _now);

SmsBillRow _smsBill({
  String id = 'bill-1',
  String title = 'Electricity bill',
  DateTime? dueDate,
  DateTime? receivedAt,
  SmsBillState state = SmsBillState.pending,
}) => SmsBillRow(
  id: id,
  title: title,
  category: CommitmentCategory.utility,
  amountDue: Money.fromRupees(500),
  minimumDue: null,
  isMinimumOnly: false,
  dueDate: dueDate,
  receivedAt: receivedAt ?? DateTime(2026, 9, 1),
  isAutopay: false,
  sawFailedAttempt: false,
  state: state,
);

PastBillReceipt _receipt(DateTime occurredAt) => PastBillReceipt(
  id: 'receipt-1',
  sourceKey: 'receipt-1',
  merchant: 'Airtel',
  amount: Money.fromRupees(799),
  occurredAt: occurredAt,
  receivedAt: occurredAt,
  status: PastBillReceiptStatus.paidLinked,
);

void main() {
  group('label', () {
    test('names each horizon for the fixed today', () {
      expect(_filter(BillsHorizon.upcoming).label, 'Upcoming');
      expect(_filter(BillsHorizon.currentMonth).label, 'Oct 2026');
      expect(_filter(BillsHorizon.lastMonth).label, 'Sep 2026');
      expect(_filter(BillsHorizon.lastThreeMonths).label, 'Aug – Oct 2026');
      expect(_filter(BillsHorizon.allHistory).label, 'All history');
    });
  });

  group('matchesDue', () {
    test('classifies UTC instants by their local calendar day', () {
      final october = _filter(BillsHorizon.currentMonth);
      final novFirst = DateTime(2026, 11, 1).toUtc();
      final octFirstEarly = DateTime(2026, 10, 1, 2).toUtc();

      expect(october.matchesDue(novFirst), isFalse);
      expect(_filter(BillsHorizon.upcoming).matchesDue(novFirst), isTrue);
      expect(october.matchesDue(octFirstEarly), isTrue);
      expect(
        _filter(BillsHorizon.lastMonth).matchesDue(octFirstEarly),
        isFalse,
      );
    });

    test('upcoming accepts today and later, rejects yesterday', () {
      final filter = _filter(BillsHorizon.upcoming);
      expect(filter.matchesDue(DateTime(2026, 10, 25)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 26)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 24)), isFalse);
    });

    test('currentMonth spans the whole of October', () {
      final filter = _filter(BillsHorizon.currentMonth);
      expect(filter.matchesDue(DateTime(2026, 10, 1)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 31)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 9, 30)), isFalse);
      expect(filter.matchesDue(DateTime(2026, 11, 1)), isFalse);
    });

    test('lastMonth spans the whole of September', () {
      final filter = _filter(BillsHorizon.lastMonth);
      expect(filter.matchesDue(DateTime(2026, 9, 1)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 9, 30)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 1)), isFalse);
    });

    test('lastThreeMonths spans August through October', () {
      final filter = _filter(BillsHorizon.lastThreeMonths);
      expect(filter.matchesDue(DateTime(2026, 8, 1)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 31)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 7, 31)), isFalse);
      expect(filter.matchesDue(DateTime(2026, 11, 1)), isFalse);
    });

    test('allHistory accepts past and today, rejects tomorrow', () {
      final filter = _filter(BillsHorizon.allHistory);
      expect(filter.matchesDue(DateTime(2026, 10, 25)), isTrue);
      expect(filter.matchesDue(DateTime(2026, 10, 26)), isFalse);
    });
  });

  group('matchesOpenDue', () {
    test('upcoming accepts today and future, rejects past dates', () {
      final filter = _filter(BillsHorizon.upcoming);
      expect(filter.matchesOpenDue(DateTime(2026, 10, 25)), isTrue);
      expect(filter.matchesOpenDue(DateTime(2026, 10, 26)), isTrue);
      expect(filter.matchesOpenDue(DateTime(2026, 10, 24)), isFalse);
    });

    test('month windows behave like matchesDue', () {
      expect(
        _filter(BillsHorizon.lastMonth).matchesOpenDue(DateTime(2026, 10, 20)),
        isFalse,
      );
    });
  });

  group('showsAutopay', () {
    test('is true only while the horizon is now or this month', () {
      expect(_filter(BillsHorizon.upcoming).showsAutopay, isTrue);
      expect(_filter(BillsHorizon.currentMonth).showsAutopay, isTrue);
      expect(_filter(BillsHorizon.lastMonth).showsAutopay, isFalse);
      expect(_filter(BillsHorizon.lastThreeMonths).showsAutopay, isFalse);
      expect(_filter(BillsHorizon.allHistory).showsAutopay, isFalse);
    });
  });

  group('matchesSmsBill', () {
    test('upcoming hides linked rows and past pending rows', () {
      final filter = _filter(BillsHorizon.upcoming);
      expect(
        filter.matchesSmsBill(
          _smsBill(dueDate: DateTime(2026, 10, 26), state: SmsBillState.linked),
        ),
        isFalse,
      );
      expect(
        filter.matchesSmsBill(_smsBill(dueDate: DateTime(2026, 10, 26))),
        isTrue,
      );
      expect(
        filter.matchesSmsBill(_smsBill(dueDate: DateTime(2026, 10, 20))),
        isFalse,
      );
      expect(
        _filter(BillsHorizon.currentMonth).matchesSmsBill(
          _smsBill(dueDate: DateTime(2026, 10, 20)),
        ),
        isTrue,
      );
    });

    test('lastMonth keeps a linked September row', () {
      expect(
        _filter(BillsHorizon.lastMonth).matchesSmsBill(
          _smsBill(dueDate: DateTime(2026, 9, 15), state: SmsBillState.linked),
        ),
        isTrue,
      );
    });

    test('undated rows fall back to the local day of receivedAt', () {
      final bill = _smsBill(receivedAt: DateTime(2026, 10, 1, 2).toUtc());
      expect(_filter(BillsHorizon.currentMonth).matchesSmsBill(bill), isTrue);
      expect(_filter(BillsHorizon.lastMonth).matchesSmsBill(bill), isFalse);
    });

    test('currentMonth drops a September row', () {
      expect(
        _filter(BillsHorizon.currentMonth).matchesSmsBill(
          _smsBill(dueDate: DateTime(2026, 9, 15), state: SmsBillState.linked),
        ),
        isFalse,
      );
    });

    test('falls back to receivedAt when the SMS has no due date', () {
      final noDue = _smsBill(receivedAt: DateTime(2026, 9, 20));
      expect(_filter(BillsHorizon.lastMonth).matchesSmsBill(noDue), isTrue);
      expect(_filter(BillsHorizon.currentMonth).matchesSmsBill(noDue), isFalse);
      expect(
        _filter(
          BillsHorizon.currentMonth,
        ).matchesSmsBill(_smsBill(receivedAt: DateTime(2026, 10, 1))),
        isTrue,
      );
      expect(
        _filter(
          BillsHorizon.upcoming,
        ).matchesSmsBill(_smsBill(receivedAt: DateTime(2026, 10, 25))),
        isTrue,
      );
      expect(
        _filter(
          BillsHorizon.upcoming,
        ).matchesSmsBill(_smsBill(receivedAt: DateTime(2026, 10, 24))),
        isFalse,
      );
    });
  });

  group('matchesReceipt', () {
    test('upcoming keeps all receipts, lastMonth keeps September only', () {
      final receipt = _receipt(DateTime(2026, 9, 15));
      expect(_filter(BillsHorizon.upcoming).matchesReceipt(receipt), isTrue);
      expect(_filter(BillsHorizon.lastMonth).matchesReceipt(receipt), isTrue);
      expect(
        _filter(BillsHorizon.currentMonth).matchesReceipt(receipt),
        isFalse,
      );
    });
  });

  group('year and month boundaries', () {
    test('rolls windows and labels across a year boundary', () {
      final january = BillsHorizonFilter(
        BillsHorizon.currentMonth,
        DateTime(2026, 1, 10),
      );
      expect(january.label, 'Jan 2026');
      expect(january.matchesDue(DateTime(2026, 1, 1)), isTrue);
      expect(january.matchesDue(DateTime(2025, 12, 31)), isFalse);

      final december = BillsHorizonFilter(
        BillsHorizon.lastMonth,
        DateTime(2026, 1, 10),
      );
      expect(december.label, 'Dec 2025');
      expect(december.matchesDue(DateTime(2025, 12, 1)), isTrue);
      expect(december.matchesDue(DateTime(2026, 1, 1)), isFalse);

      final quarter = BillsHorizonFilter(
        BillsHorizon.lastThreeMonths,
        DateTime(2026, 1, 10),
      );
      expect(quarter.label, 'Nov 2025 – Jan 2026');
      expect(quarter.matchesDue(DateTime(2025, 11, 1)), isTrue);
      expect(quarter.matchesDue(DateTime(2025, 10, 31)), isFalse);
    });

    test('clamps a 31st due day to the real end of February', () {
      expect(
        BillsHorizonFilter(
          BillsHorizon.lastMonth,
          DateTime(2026, 3, 10),
        ).scheduledOccurrence(31),
        DateTime(2026, 2, 28),
      );
      expect(
        BillsHorizonFilter(
          BillsHorizon.lastMonth,
          DateTime(2028, 3, 10),
        ).scheduledOccurrence(31),
        DateTime(2028, 2, 29),
      );
    });
  });

  group('scheduledOccurrence', () {
    test('upcoming has no scheduled occurrence', () {
      expect(_filter(BillsHorizon.upcoming).scheduledOccurrence(16), isNull);
    });

    test('currentMonth maps the due day into October', () {
      expect(
        _filter(BillsHorizon.currentMonth).scheduledOccurrence(16),
        DateTime(2026, 10, 16),
      );
    });

    test('lastMonth maps and clamps the due day into September', () {
      final filter = _filter(BillsHorizon.lastMonth);
      expect(filter.scheduledOccurrence(16), DateTime(2026, 9, 16));
      expect(filter.scheduledOccurrence(31), DateTime(2026, 9, 30));
    });

    test('lastThreeMonths rolls a future day back one month', () {
      final filter = _filter(BillsHorizon.lastThreeMonths);
      expect(filter.scheduledOccurrence(16), DateTime(2026, 10, 16));
      expect(filter.scheduledOccurrence(30), DateTime(2026, 9, 30));
    });

    test('allHistory rolls a future day back one month', () {
      expect(
        _filter(BillsHorizon.allHistory).scheduledOccurrence(30),
        DateTime(2026, 9, 30),
      );
    });
  });
}
