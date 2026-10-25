import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/sms_fact_contract.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase appDb;

  setUp(() => appDb = openInMemoryForTesting());
  tearDown(() => appDb.close());

  test('cached_responses table accepts an upsert and reads it back', () {
    appDb.db.execute(
      'INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)',
      ['catalogue', '{"cards":[]}', DateTime.now().millisecondsSinceEpoch],
    );
    final rows = appDb.db.select('SELECT raw_json FROM cached_responses WHERE key = ?', ['catalogue']);
    expect(rows.single['raw_json'], '{"cards":[]}');
  });

  test('cached_responses upsert overwrites the same key', () {
    appDb.db.execute(
      'INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)',
      ['catalogue', 'first', DateTime.now().millisecondsSinceEpoch],
    );
    appDb.db.execute(
      'INSERT OR REPLACE INTO cached_responses (key, raw_json, fetched_at) VALUES (?, ?, ?)',
      ['catalogue', 'second', DateTime.now().millisecondsSinceEpoch],
    );
    final rows = appDb.db.select('SELECT raw_json FROM cached_responses');
    expect(rows, hasLength(1));
    expect(rows.single['raw_json'], 'second');
  });

  test('transaction_outbox_entries auto-increments id and stores a queued quick-add', () {
    appDb.db.execute(
      'INSERT INTO transaction_outbox_entries (user_card_id, amount_paise, created_at) VALUES (?, ?, ?)',
      ['uc-1', 150000, DateTime.now().millisecondsSinceEpoch],
    );
    final id = appDb.db.lastInsertRowId;
    expect(id, greaterThan(0));
    final rows = appDb.db.select('SELECT * FROM transaction_outbox_entries WHERE id = ?', [id]);
    expect(rows.single['user_card_id'], 'uc-1');
    expect(rows.single['amount_paise'], 150000);
    expect(rows.single['category_id'], isNull);
  });

  test('legacy card-only outbox is upgraded without losing queued writes', () {
    final legacyDb = sqlite3.openInMemory();
    legacyDb.execute('''
      CREATE TABLE transaction_outbox_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_card_id TEXT NOT NULL,
        amount_paise INTEGER NOT NULL,
        category_id TEXT,
        merchant_name TEXT,
        occurred_at INTEGER,
        note TEXT,
        created_at INTEGER NOT NULL,
        last_error TEXT
      )
    ''');
    legacyDb.execute(
      'INSERT INTO transaction_outbox_entries '
      '(user_card_id, amount_paise, created_at) VALUES (?, ?, ?)',
      ['legacy-card', 9900, 123456],
    );

    final migrated = AppDatabase.forTesting(legacyDb);
    addTearDown(migrated.close);

    final columns = migrated.db.select('PRAGMA table_info(transaction_outbox_entries)');
    final userCardColumn = columns.firstWhere((row) => row['name'] == 'user_card_id');
    expect(userCardColumn['notnull'], 0);
    expect(columns.any((row) => row['name'] == 'instrument'), isTrue);
    expect(columns.any((row) => row['name'] == 'entry_kind'), isTrue);

    final row = migrated.db.select('SELECT * FROM transaction_outbox_entries').single;
    expect(row['user_card_id'], 'legacy-card');
    expect(row['amount_paise'], 9900);
    expect(row['instrument'], 'credit_card');
    expect(row['entry_kind'], 'spend');
    expect(row['client_mutation_id'], 'legacy-outbox-1-123456');
  });

  test('auto-resolved history table and index exist with every column', () {
    final tables = appDb.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='local_auto_resolved_history'",
    );
    expect(tables, hasLength(1));
    final columns = appDb.db
        .select('PRAGMA table_info(local_auto_resolved_history)')
        .map((row) => row['name'])
        .toSet();
    expect(
      columns,
      containsAll([
        'id',
        'namespace',
        'source_key',
        'sender',
        'resolved_kind',
        'title',
        'amount_paise',
        'category_slug',
        'due_date',
        'occurred_at',
        'instrument',
        'account_last4',
        'confidence',
        'resolved_by',
        'auto_resolved_at',
        'is_user_modified',
      ]),
    );
    final indexes = appDb.db
        .select('PRAGMA index_list(local_auto_resolved_history)')
        .map((row) => row['name'])
        .toSet();
    expect(indexes, contains('idx_auto_resolved_time'));
  });

  test('user merchant category rules table and index exist', () {
    final tables = appDb.db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='user_merchant_category_rules'",
    );
    expect(tables, hasLength(1));
    final columns = appDb.db
        .select('PRAGMA table_info(user_merchant_category_rules)')
        .map((row) => row['name'])
        .toSet();
    expect(
      columns,
      containsAll([
        'namespace',
        'pattern',
        'category_slug',
        'confidence',
        'source',
        'updated_at',
        'synced',
      ]),
    );
    final indexes = appDb.db
        .select('PRAGMA index_list(user_merchant_category_rules)')
        .map((row) => row['name'])
        .toSet();
    expect(indexes, contains('idx_user_merchant_rules_namespace'));
  });

  test('spend category contract mirrors the 15 canonical categories', () {
    expect(smsSpendCategories, hasLength(15));
    expect(smsSpendCategories.toSet(), hasLength(15));
    final shape = smsPayloadFieldShapes['category']!;
    expect(shape['in'], equals(smsSpendCategories));
    expect(smsPayloadFieldShapes['isComplete'], {'boolean': true});
    expect(smsPayloadFieldShapes['confidence'], {'number': true});
    for (final category in smsSpendCategories) {
      final result = validateSmsFactPayload('posted_movement', {
        'amountRole': 'posted',
        'amountInr': 100,
        'entryKind': 'spend',
        'merchant': 'MERCHANT',
        'occurredAt': '2026-10-24T00:00:00.000Z',
        'instrument': 'upi_bank',
        'category': category,
        'isComplete': true,
        'confidence': 0.9,
      });
      expect(result.valid, isTrue, reason: '$category: ${result.errors}');
    }
    final invalid = validateSmsFactPayload('posted_movement', {
      'amountRole': 'posted',
      'amountInr': 100,
      'entryKind': 'spend',
      'merchant': 'MERCHANT',
      'occurredAt': '2026-10-24T00:00:00.000Z',
      'category': 'not-a-category',
    });
    expect(invalid.valid, isFalse);
    expect(
      invalid.errors.any((error) => error.startsWith('category must be one of')),
      isTrue,
    );
  });

  test('confidence must be a unit-interval number and isComplete a boolean', () {
    Map<String, Object?> payload(Object? confidence, Object? isComplete) => {
      'amountRole': 'posted',
      'amountInr': 100,
      'entryKind': 'spend',
      'merchant': 'MERCHANT',
      'occurredAt': '2026-10-24T00:00:00.000Z',
      'category': 'dining',
      'confidence': confidence,
      'isComplete': isComplete,
    };

    expect(validateSmsFactPayload('posted_movement', payload(0.0, true)).valid, isTrue);
    expect(validateSmsFactPayload('posted_movement', payload(1.0, false)).valid, isTrue);
    expect(validateSmsFactPayload('posted_movement', payload(1.4, true)).valid, isFalse);
    expect(validateSmsFactPayload('posted_movement', payload(-0.1, true)).valid, isFalse);
    expect(validateSmsFactPayload('posted_movement', payload('high', true)).valid, isFalse);
    expect(validateSmsFactPayload('posted_movement', payload(0.5, 'yes')).valid, isFalse);
  });
}
