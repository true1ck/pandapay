import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/data/local/sms_intake_repository.dart';
import 'package:pandapay/data/sms_amount_repair.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

void main() {
  late AppDatabase db;
  late FinancialStore store;
  late TransactionEntry original;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = openInMemoryForTesting();
    store = FinancialStore(db);
    const body =
        'USD .00 spent using ICICI Bank Card XX1234 on SYNTHETIC AI. Avl Limit: INR 286388.46.';
    final received = DateTime(2025, 12, 2);
    final key = SmsIntakeRepository(db).capture(
      'user:a',
      QueuedSms(sender: 'ICICIT-S', body: body, receivedAt: received),
    );
    original = TransactionEntry(
      id: 'synced',
      sourceKey: key,
      amount: Money.fromRupees(286388.46),
      occurredAt: received,
      source: 'sms',
      status: 'active',
    );
    store.saveTransactions('user:a', [original]);
  });
  tearDown(() {
    store.dispose();
    db.close();
  });

  test(
    'limit-change service notices are repaired even without a payment verb',
    () async {
      final received = DateTime(2025, 12, 2);
      final key = SmsIntakeRepository(db).capture(
        'user:a',
        QueuedSms(
          sender: 'ICICIT-S',
          body:
              'Dear Customer, we have changed the spend limit on your ICICI Bank Credit Card XX1234 from INR 100000 to INR 150000 on 2025-12-02.',
          receivedAt: received,
        ),
      );
      final limit = TransactionEntry(
        id: 'limit-change',
        sourceKey: key,
        amount: Money.fromRupees(150000),
        occurredAt: received,
        source: 'sms',
        status: 'active',
      );
      store.saveTransactions('user:a', [limit]);
      final ignored = <String>[];
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (id) async => id == limit.id ? limit : original,
          ignoreWrongTransaction: (id) async => ignored.add(id),
        ),
        2,
      );
      expect(ignored, contains('limit-change'));
    },
  );

  test(
    'synced correction uses the domain route and preserves the original in history',
    () async {
      final ignored = <String>[];
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (_) async => original,
          ignoreWrongTransaction: (id) async => ignored.add(id),
        ),
        1,
      );
      expect(ignored, ['synced']);
      expect(
        store.entities('user:a', 'transactions').single['status'],
        'ignored',
      );
      expect(db.db.select('SELECT * FROM local_needs_review'), hasLength(1));
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (_) async => throw StateError('Already repaired'),
          ignoreWrongTransaction: (_) async {},
        ),
        0,
      );
    },
  );
  test('a fresh server amount correction is never overwritten', () async {
    final corrected = TransactionEntry(
      id: original.id,
      sourceKey: original.sourceKey,
      amount: Money.fromRupees(1700),
      occurredAt: original.occurredAt,
      source: 'sms',
      status: 'active',
    );
    expect(
      await repairSyncedSmsAmounts(
        store: store,
        namespace: 'user:a',
        accountIsCurrent: () => true,
        fetch: (_) async => corrected,
        ignoreWrongTransaction: (_) async => fail('must preserve correction'),
      ),
      0,
    );
  });
  test('user annotations are preserved', () async {
    store.saveTransactions('user:a', [
      original.copyWith(note: 'Checked myself'),
    ]);
    expect(
      await repairSyncedSmsAmounts(
        store: store,
        namespace: 'user:a',
        accountIsCurrent: () => true,
        fetch: (_) async => fail('Annotated row must stay untouched'),
        ignoreWrongTransaction: (_) async {},
      ),
      0,
    );
  });
  test(
    'legacy detail without source key requires the exact saved receipt and ledger identity',
    () async {
      final legacy = TransactionEntry(
        id: original.id,
        amount: original.amount,
        occurredAt: original.occurredAt,
        source: 'sms',
        status: 'active',
      );
      final ignored = <String>[];
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (_) async => legacy,
          ignoreWrongTransaction: (id) async => ignored.add(id),
        ),
        1,
      );
      expect(ignored, ['synced']);
    },
  );
  test(
    'an omitted source key without a receipt cannot authorize correction',
    () async {
      db.db.execute('DELETE FROM financial_source_receipts');
      final legacy = TransactionEntry(
        id: original.id,
        amount: original.amount,
        occurredAt: original.occurredAt,
        source: 'sms',
        status: 'active',
      );
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (_) async => legacy,
          ignoreWrongTransaction: (_) async => fail('No source receipt'),
        ),
        0,
      );
    },
  );
  test(
    'account change after fetch stops before the financial mutation',
    () async {
      var current = true;
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => current,
          fetch: (_) async {
            current = false;
            return original;
          },
          ignoreWrongTransaction: (_) async => fail('wrong account'),
        ),
        0,
      );
    },
  );
  test(
    'failure of server reversal leaves the cached active row intact',
    () async {
      expect(
        await repairSyncedSmsAmounts(
          store: store,
          namespace: 'user:a',
          accountIsCurrent: () => true,
          fetch: (_) async => original,
          ignoreWrongTransaction: (_) async => throw StateError('offline'),
        ),
        0,
      );
      expect(
        store.entities('user:a', 'transactions').single['status'],
        'active',
      );
    },
  );
}
