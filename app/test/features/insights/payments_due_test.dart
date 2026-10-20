import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/features/insights/payments_due_screen.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('nextOccurrenceOf', () {
    test('returns today when the due day is today', () {
      expect(
        nextOccurrenceOf(15, DateTime(2026, 8, 15)),
        DateTime(2026, 8, 15),
      );
    });

    test('stays in this month when the day is still ahead', () {
      expect(
        nextOccurrenceOf(20, DateTime(2026, 8, 11)),
        DateTime(2026, 8, 20),
      );
    });

    test('rolls to next month once the day has passed', () {
      expect(nextOccurrenceOf(5, DateTime(2026, 8, 11)), DateTime(2026, 9, 5));
    });

    test('rolls across a year boundary', () {
      expect(nextOccurrenceOf(5, DateTime(2026, 12, 11)), DateTime(2027, 1, 5));
    });

    test('clamps a 31st due day into a 30-day month', () {
      expect(
        nextOccurrenceOf(31, DateTime(2026, 9, 15)),
        DateTime(2026, 9, 30),
      );
    });

    test('clamps a 31st due day into February', () {
      expect(
        nextOccurrenceOf(31, DateTime(2026, 2, 10)),
        DateTime(2026, 2, 28),
      );
    });

    test('clamps into a leap February', () {
      expect(
        nextOccurrenceOf(30, DateTime(2028, 2, 10)),
        DateTime(2028, 2, 29),
      );
    });
  });

  group('previousOccurrenceOf', () {
    test('returns today when the statement day is today', () {
      expect(
        previousOccurrenceOf(15, DateTime(2026, 8, 15)),
        DateTime(2026, 8, 15),
      );
    });

    test('stays in this month when the day has already passed', () {
      expect(
        previousOccurrenceOf(5, DateTime(2026, 8, 11)),
        DateTime(2026, 8, 5),
      );
    });

    test('walks back a month when the day is still ahead', () {
      expect(
        previousOccurrenceOf(20, DateTime(2026, 8, 11)),
        DateTime(2026, 7, 20),
      );
    });

    test('walks back across a year boundary', () {
      expect(
        previousOccurrenceOf(20, DateTime(2026, 1, 11)),
        DateTime(2025, 12, 20),
      );
    });

    test('clamps a 31st statement day into a short previous month', () {
      expect(
        previousOccurrenceOf(31, DateTime(2026, 5, 10)),
        DateTime(2026, 4, 30),
      );
    });

    test('never returns a date in the future', () {
      for (var day = 1; day <= 31; day++) {
        final from = DateTime(2026, 3, 15);
        expect(
          previousOccurrenceOf(day, from).isAfter(from),
          isFalse,
          reason: 'statement day $day resolved to a future cycle start',
        );
      }
    });
  });

  group('commitment category detection', () {
    test('keeps common biller types in the right category', () {
      expect(
        CommitmentCategory.fromText('Electricity bill BESCOM'),
        CommitmentCategory.utility,
      );
      expect(
        CommitmentCategory.fromText('LIC vehicle insurance premium'),
        CommitmentCategory.insurance,
      );
      expect(
        CommitmentCategory.fromText('Netflix subscription renewal'),
        CommitmentCategory.subscription,
      );
      expect(
        CommitmentCategory.fromText('Alegra Communication TNBPAY'),
        CommitmentCategory.telecom,
      );
    });
  });

  group('Commitment domain arithmetic & policy grace period', () {
    final baseDue = DateTime(2026, 10, 15);

    test('calculates daysUntilDue correctly relative to reference date', () {
      final bill = Commitment(
        id: 'b1',
        title: 'Bescom Electricity',
        category: CommitmentCategory.utility,
        amount: Money.fromRupees(1450),
        dueOn: baseDue,
      );

      expect(bill.daysUntilDue(DateTime(2026, 10, 10)), 5);
      expect(bill.daysUntilDue(DateTime(2026, 10, 15)), 0);
      expect(bill.isDueToday(DateTime(2026, 10, 15)), isTrue);
      expect(bill.daysUntilDue(DateTime(2026, 10, 18)), -3);
    });

    test('evidence-based policy grace period behaves truthfully', () {
      final licPolicy = Commitment(
        id: 'lic-1',
        title: 'LIC of India',
        category: CommitmentCategory.insurance,
        amount: Money.fromRupees(24500),
        dueOn: baseDue,
        identifier: '••••4521',
        cadence: CommitmentCadence.annual,
        gracePeriodDays: 30,
      );

      // 1. Before due date: not in grace period, not past grace
      final beforeDue = DateTime(2026, 10, 10);
      expect(licPolicy.isWithinGracePeriod(beforeDue), isFalse);
      expect(licPolicy.isPastGrace(beforeDue), isFalse);

      // 2. On due date: not yet in grace period
      expect(licPolicy.isWithinGracePeriod(baseDue), isFalse);

      // 3. 10 days after due date: INSIDE grace period (cover still active)
      final inGrace = DateTime(2026, 10, 25);
      expect(licPolicy.isWithinGracePeriod(inGrace), isTrue);
      expect(
        licPolicy.daysRemainingInGrace(inGrace),
        20,
      ); // 30 - 10 = 20 days left
      expect(licPolicy.isPastGrace(inGrace), isFalse);

      // 4. 31 days after due date: Grace period has expired (lapsed risk)
      final afterGrace = DateTime(2026, 11, 16);
      expect(licPolicy.isWithinGracePeriod(afterGrace), isFalse);
      expect(licPolicy.isPastGrace(afterGrace), isTrue);
    });

    test(
      'commitment without grace period is past due immediately after due date',
      () {
        final internetBill = Commitment(
          id: 'net-1',
          title: 'Airtel Broadband',
          category: CommitmentCategory.telecom,
          amount: Money.fromRupees(999),
          dueOn: baseDue,
        );

        expect(internetBill.gracePeriodEndsOn, isNull);
        expect(
          internetBill.isWithinGracePeriod(DateTime(2026, 10, 20)),
          isFalse,
        );
        expect(internetBill.isPastGrace(DateTime(2026, 10, 20)), isTrue);
      },
    );

    test('cadence labels format cleanly', () {
      expect(CommitmentCadence.annual.label, 'Annual');
      expect(CommitmentCadence.quarterly.label, 'Quarterly');
      expect(CommitmentCadence.halfYearly.label, 'Half-yearly');
      expect(CommitmentCadence.monthly.label, 'Monthly');
      expect(CommitmentCadence.oneTime.label, 'One-time');
    });
  });

  group('CommitmentsRepository durable persistence & recurring rollover', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('saves and loads commitments from durable storage', () async {
      final repo = CommitmentsRepository(namespace: 'user:account-a');

      expect(await repo.fetchAll(), isEmpty);

      final item = Commitment(
        id: 'water-1',
        title: 'Water Board',
        category: CommitmentCategory.utility,
        amount: Money.fromRupees(350),
        dueOn: DateTime(2026, 10, 20),
        cadence: CommitmentCadence.monthly,
      );

      await repo.save(item);

      final loaded = await repo.fetchAll();
      expect(loaded.length, 1);
      expect(loaded.first.title, 'Water Board');
      expect(loaded.first.amount, Money.fromRupees(350));
    });

    test(
      'marking a recurring monthly commitment as paid advances due date to next month',
      () async {
        final repo = CommitmentsRepository();
        final originalDue = DateTime(2026, 10, 15);

        final item = Commitment(
          id: 'rent-1',
          title: 'Apartment Rent',
          category: CommitmentCategory.rent,
          amount: Money.fromRupees(25000),
          dueOn: originalDue,
          cadence: CommitmentCadence.monthly,
        );

        await repo.save(item);
        await repo.markAsPaid('rent-1', paidOn: DateTime(2026, 10, 14));

        final updated = await repo.fetchAll();
        expect(updated.length, 1);
        // Recurring commitment remains active and advances due date by 1 month
        expect(updated.first.dueOn, DateTime(2026, 11, 15));
        expect(updated.first.status, CommitmentStatus.due);
        expect(updated.first.paidOn, DateTime(2026, 10, 14));
      },
    );

    test(
      'marking a one-time commitment as paid sets status to paid without rollover',
      () async {
        final repo = CommitmentsRepository();
        final originalDue = DateTime(2026, 10, 15);

        final item = Commitment(
          id: 'fee-1',
          title: 'Application Fee',
          category: CommitmentCategory.other,
          amount: Money.fromRupees(500),
          dueOn: originalDue,
          cadence: CommitmentCadence.oneTime,
        );

        await repo.save(item);
        await repo.markAsPaid('fee-1', paidOn: DateTime(2026, 10, 15));

        final updated = await repo.fetchAll();
        expect(updated.length, 1);
        expect(updated.first.status, CommitmentStatus.paid);
        expect(updated.first.dueOn, originalDue);
      },
    );

    test('delete removes commitment permanently from storage', () async {
      final repo = CommitmentsRepository(namespace: 'user:account-a');

      await repo.save(
        Commitment(
          id: 'c1',
          title: 'Gas Bill',
          category: CommitmentCategory.utility,
          dueOn: DateTime(2026, 10, 20),
        ),
      );

      expect(await repo.fetchAll(), hasLength(1));

      await repo.delete('c1');
      expect(await repo.fetchAll(), isEmpty);
    });

    test('commitments are isolated between account namespaces', () async {
      final accountA = CommitmentsRepository(namespace: 'user:account-a');
      final accountB = CommitmentsRepository(namespace: 'user:account-b');

      await accountA.save(
        Commitment(
          id: 'a-only',
          title: 'Private bill',
          category: CommitmentCategory.utility,
          dueOn: DateTime(2026, 10, 20),
        ),
      );

      expect((await accountA.fetchAll()).map((c) => c.id), contains('a-only'));
      expect(
        (await accountB.fetchAll()).map((c) => c.id),
        isNot(contains('a-only')),
      );
    });

    test(
      'dismissing an SMS commitment survives refresh as a tombstone',
      () async {
        final repo = CommitmentsRepository(namespace: 'user:account-a');
        await repo.save(
          Commitment(
            id: 'sms-commitment-1',
            title: 'Alegra Communication',
            category: CommitmentCategory.telecom,
            dueOn: DateTime(2026, 10, 20),
            source: CommitmentSource.sms,
          ),
        );

        await repo.dismiss('sms-commitment-1');
        expect(
          (await repo.fetchAll()).single.status,
          CommitmentStatus.dismissed,
        );
      },
    );

    test(
      'marking a detected commitment as paid persists it before rollover',
      () async {
        final repo = CommitmentsRepository(namespace: 'user:account-a');
        final detected = Commitment(
          id: 'sms-detected-1',
          title: 'Internet Bill',
          category: CommitmentCategory.telecom,
          amount: Money.fromRupees(1600),
          dueOn: DateTime(2026, 10, 20),
          cadence: CommitmentCadence.monthly,
          source: CommitmentSource.sms,
        );

        await repo.markAsPaid(
          detected.id,
          paidOn: DateTime(2026, 10, 19),
          detectedCommitment: detected,
        );

        final updated = (await repo.fetchAll()).single;
        expect(updated.dueOn, DateTime(2026, 11, 20));
        expect(updated.status, CommitmentStatus.due);
        expect(updated.paidOn, DateTime(2026, 10, 19));
      },
    );

    test(
      'monthly rollover preserves a 31st-day commitment across short months',
      () async {
        final repo = CommitmentsRepository(namespace: 'user:account-a');
        await repo.save(
          Commitment(
            id: 'month-end-1',
            title: 'Month-end bill',
            category: CommitmentCategory.utility,
            dueOn: DateTime(2026, 1, 31),
            cadence: CommitmentCadence.monthly,
          ),
        );

        await repo.markAsPaid('month-end-1', paidOn: DateTime(2026, 1, 30));
        await repo.markAsPaid('month-end-1', paidOn: DateTime(2026, 2, 27));

        expect((await repo.fetchAll()).single.dueOn, DateTime(2026, 3, 31));
      },
    );
  });
}
