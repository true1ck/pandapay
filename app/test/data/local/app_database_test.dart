import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
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
}
