import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/commitments_repository.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/card_bill_ledger.dart';
import 'package:pandapay/data/local/sms_import_store.dart';
import 'package:pandapay/data/needs_review_repository.dart';
import 'package:pandapay/data/past_bill_receipts.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
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

    test('SQLite storage: saves, loads, and migrates from legacy SharedPreferences', () async {
      final prefs = await SharedPreferences.getInstance();
      const ns = 'user:sqlite-test';
      // Put a legacy item in SharedPreferences
      await prefs.setString(
        'pandapay_app.commitments_v1:$ns',
        '[{"id":"legacy-c1","title":"Electricity","category":"utility","due_on":"2026-10-25T00:00:00.000","cadence":"monthly","status":"due","source":"manual"}]',
      );

      final db = openInMemoryForTesting();
      final repo = CommitmentsRepository(
        namespace: ns,
        loadDatabase: () async => db,
      );

      // fetchAll should migrate the legacy item into SQLite
      final items = await repo.fetchAll();
      expect(items, hasLength(1));
      expect(items.single.id, 'legacy-c1');
      expect(items.single.title, 'Electricity');

      // SharedPreferences key should be cleaned up
      expect(prefs.getString('pandapay_app.commitments_v1:$ns'), isNull);

      // Verify row exists directly in local_commitments table
      final rows = db.db.select('SELECT id FROM local_commitments WHERE namespace=?', [ns]);
      expect(rows.map((r) => r['id']), ['legacy-c1']);

      // Add a new commitment via SQLite
      await repo.save(Commitment(
        id: 'new-c2',
        title: 'Water Bill',
        category: CommitmentCategory.utility,
        dueOn: DateTime(2026, 11, 5),
        cadence: CommitmentCadence.monthly,
      ));

      final allItems = await repo.fetchAll();
      expect(allItems, hasLength(2));
      expect(allItems.map((c) => c.id).toSet(), {'legacy-c1', 'new-c2'});

      // Delete one item
      await repo.delete('legacy-c1');
      final remaining = await repo.fetchAll();
      expect(remaining.map((c) => c.id), ['new-c2']);

      db.close();
    });
  });

  group('AutoPay & Mandate end-to-end integration', () {
    const ns = 'user:account-test';
    late AppDatabase db;
    late FinancialStore financialStore;
    late SmsImportStore smsImportStore;
    late CommitmentsRepository commitmentsRepo;
    late NeedsReviewRepository needsReviewRepo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      db = openInMemoryForTesting();
      financialStore = FinancialStore(db);
      smsImportStore = SmsImportStore(financialStore);
      commitmentsRepo = CommitmentsRepository(
        namespace: ns,
        loadDatabase: () async => db,
      );
      needsReviewRepo = NeedsReviewRepository(
        namespace: ns,
        loadDatabase: () async => db,
      );
    });

    tearDown(() {
      financialStore.dispose();
      db.close();
    });

    test('credit card AutoPay notice populates sms_observations and CardBillLedger without entering Needs Review', () async {
      final msg = QueuedSms(
        sender: 'HDFCBK',
        body: 'AutoPay Alert!\nYour HDFC Bank Credit Card 8708 bill of Rs 12,450.00 is scheduled for auto debit on 05-NOV-2026.',
        receivedAt: DateTime(2026, 10, 22),
      );

      smsImportStore.capture(ns, msg);

      // Verify sms_observations
      final observations = financialStore.entities(ns, 'sms_observations');
      expect(observations, hasLength(1));
      final obs = observations.single;
      expect(obs['card_last4'], '8708');
      expect(obs['amount_due_paise'], 1245000);
      expect(obs['due_date'], '2026-11-05T00:00:00.000');
      expect(obs['is_autopay'], isTrue);
      expect(obs['reason_codes'], containsAll(['autopay_notice', 'due_date_detected']));

      // Verify CardBillLedger derivation
      final card = UserCard.fromJson({
        'id': 'card_hdfc',
        'card_product_id': 'hdfc_regalia',
        'card_name': 'HDFC Bank Credit Card',
        'last4': '8708',
        'is_default': false,
      });
      final evidence = CardBillEvidence(
        cardLast4: obs['card_last4'] as String?,
        family: obs['sender_bank'] as String?,
        statementDate: DateTime.parse(obs['received_at'] as String),
        statementDateExplicit: false,
        dueDate: DateTime.parse(obs['due_date'] as String),
        amountDue: Money.fromPaise(obs['amount_due_paise'] as int),
        minimumDue: null,
        confidence: 0.95,
        isAutopay: obs['is_autopay'] == true,
      );
      final ledgers = deriveCardBills(
        cards: [card],
        evidence: [evidence],
        payments: [],
        now: DateTime(2026, 10, 25),
      );
      final ledger = ledgers[card.id];
      expect(ledger, isNotNull);
      expect(ledger!.current, isNotNull);
      expect(ledger.current!.amountDue?.rupees, 12450.0);
      expect(ledger.current!.dueDate, DateTime(2026, 11, 5));
      expect(ledger.current!.isAutopay, isTrue);
      expect(ledger.current!.statementDateVerified, isTrue);

      // Verify intake decision is financial_auto and not review
      final decisions = db.db.select(
        'SELECT decision, state FROM sms_source_decisions WHERE namespace=?',
        [ns],
      );
      expect(decisions, hasLength(1));
      expect(decisions.first['decision'], 'financial_auto');
      expect(decisions.first['state'], 'final');

      // Verify Needs Review remains clean
      final reviewItems = await needsReviewRepo.fetchAll();
      expect(reviewItems, isEmpty);
    });

    test('non-card utility/mandate notice populates CommitmentsRepository as recurring commitments without entering Needs Review', () async {
      final yojanaMsg = QueuedSms(
        sender: 'APYGOV',
        body: 'Dear Subscriber, your contribution amount for Atal Pension Yojana PRAN 123456789012 is Rs 46/-. Auto debit from your account will be on 05-NOV-2026. Keep sufficient balance.',
        receivedAt: DateTime(2026, 10, 22),
      );
      final broadbandMsg = QueuedSms(
        sender: 'ALEGRA',
        body: 'Payment of Rs.800/- is due towards your Alegra Broadband bill. AutoPay will be attempted on 20-Oct-2026.',
        receivedAt: DateTime(2026, 10, 15),
      );

      smsImportStore.capture(ns, yojanaMsg);
      smsImportStore.capture(ns, broadbandMsg);

      // Verify CommitmentsRepository
      final commitments = await commitmentsRepo.fetchAll();
      expect(commitments, hasLength(2));

      final yojana = commitments.firstWhere((c) => c.title.contains('Atal Pension Yojana'));
      expect(yojana.amount?.rupees, 46.0);
      expect(yojana.dueOn, DateTime(2026, 11, 5));
      expect(yojana.category, CommitmentCategory.tax);
      expect(yojana.source, CommitmentSource.sms);

      final broadband = commitments.firstWhere((c) => c.title.contains('Alegra Broadband'));
      expect(broadband.amount?.rupees, 800.0);
      expect(broadband.dueOn, DateTime(2026, 10, 20));
      expect(broadband.category, CommitmentCategory.telecom);
      expect(broadband.source, CommitmentSource.sms);

      // Verify intake decision is financial_auto and not review
      final decisions = db.db.select(
        'SELECT decision, state FROM sms_source_decisions WHERE namespace=?',
        [ns],
      );
      expect(decisions, hasLength(2));
      for (final row in decisions) {
        expect(row['decision'], 'financial_auto');
        expect(row['state'], 'final');
      }

      // Verify Needs Review remains clean
      final reviewItems = await needsReviewRepo.fetchAll();
      expect(reviewItems, isEmpty);
    });

    test(
      'upcoming bills with future due dates populate CommitmentsRepository, while past bills archive to PastBillReceipts without entering Needs Review',
      () async {
        final futureDue = DateTime.now().add(const Duration(days: 14));
        final pastDue = DateTime.now().subtract(const Duration(days: 14));
        final futureDueStr =
            '${futureDue.year}-${futureDue.month.toString().padLeft(2, '0')}-${futureDue.day.toString().padLeft(2, '0')}';
        final pastDueStr =
            '${pastDue.year}-${pastDue.month.toString().padLeft(2, '0')}-${pastDue.day.toString().padLeft(2, '0')}';

        final upcomingElectricityMsg = QueuedSms(
          sender: 'MYTNEU',
          body:
              'Your Goa Electricity bill of Rs. 927.00 is ready. Pay by $futureDueStr to avoid late charges.',
          receivedAt: DateTime.now(),
        );
        final pastWaterMsg = QueuedSms(
          sender: 'PWDGOA',
          body:
              'Dear Consumer, your PWD water bill of Rs. 420 is generated. Due date: $pastDueStr.',
          receivedAt: pastDue,
        );

        smsImportStore.capture(ns, upcomingElectricityMsg);
        smsImportStore.capture(ns, pastWaterMsg);

        // Verify upcoming bill went directly to CommitmentsRepository
        final commitments = await commitmentsRepo.fetchAll();
        expect(commitments, hasLength(1));
        final elec = commitments.single;
        expect(elec.title, contains('Electricity'));
        expect(elec.amount?.rupees, 927.0);
        expect(elec.dueOn.day, futureDue.day);
        expect(elec.dueOn.month, futureDue.month);

        // Verify past bill went directly to PastBillReceiptRepository
        final pastBills = PastBillReceiptRepository(db, namespace: ns).fetchAll();
        expect(pastBills, hasLength(1));
        final past = pastBills.single;
        expect(past.amount?.rupees, 420.0);
        expect(past.status, PastBillReceiptStatus.historicalUnpaid);

        // Verify Needs Review remains completely clean!
        final reviewItems = await needsReviewRepo.fetchAll();
        expect(reviewItems, isEmpty);
      },
    );
  });
}
