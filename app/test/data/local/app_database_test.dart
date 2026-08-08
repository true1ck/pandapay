import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';

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
}
