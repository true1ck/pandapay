import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:sqlite3/sqlite3.dart';

/// Builds a database exactly as the previous app version (user_version 2, the
/// payment_method step applied, none of the v3 retry columns) left it on disk.
Database _v2Database() {
  final raw = sqlite3.openInMemory();
  // Real schema first, then peel the v3 columns back off and stamp v2, so the
  // fixture cannot drift from the genuine pre-change table shape.
  AppDatabase.forTesting(raw);
  for (final column in ['attempts', 'next_attempt_at', 'parked']) {
    raw.execute('ALTER TABLE transaction_outbox_entries DROP COLUMN $column');
  }
  raw.execute('PRAGMA user_version = 2');
  return raw;
}

Map<String, Map<String, Object?>> _columns(Database db) => {
  for (final row in db.select('PRAGMA table_info(transaction_outbox_entries)'))
    row['name'] as String: Map<String, Object?>.of(row),
};

void main() {
  group('transaction outbox retry columns (v2 -> v3)', () {
    test('a fresh database is at v3 with defaulted columns', () {
      final fresh = openInMemoryForTesting();
      addTearDown(fresh.close);
      expect(fresh.db.select('PRAGMA user_version').single.values.first, 3);
      final columns = _columns(fresh.db);
      for (final name in ['attempts', 'next_attempt_at', 'parked']) {
        expect(columns[name], isNotNull, reason: name);
        expect(columns[name]!['notnull'], 1, reason: name);
        expect(columns[name]!['dflt_value'], '0', reason: name);
      }
      // Already there since v1; the plan asked to verify, not to add.
      expect(columns['last_error'], isNotNull);
      expect(columns['last_error']!['notnull'], 0);
    });

    test('the v2 fixture really lacks the columns (guards the fixture)', () {
      final raw = _v2Database();
      addTearDown(raw.dispose);
      final names = _columns(raw).keys;
      expect(names, isNot(contains('attempts')));
      expect(names, isNot(contains('next_attempt_at')));
      expect(names, isNot(contains('parked')));
      expect(raw.select('PRAGMA user_version').single.values.first, 2);
    });

    test('rows survive, new columns default, version becomes 3', () {
      final raw = _v2Database();
      raw.execute('''
        INSERT INTO transaction_outbox_entries
          (namespace, user_card_id, client_mutation_id, amount_paise,
           category_id, merchant_name, occurred_at, note, instrument,
           entry_kind, created_at, last_error, payment_method)
        VALUES
          ('ns-a', 'uc-1', 'm-1', 15000, NULL, NULL, NULL, NULL,
           'upi_bank', 'spend', 1000, NULL, NULL),
          ('ns-a', NULL, 'm-2', 99900, 'dining', 'Cafe', 1700000000000,
           'lunch', 'cash', 'spend', 2000, 'offline', 'cheque')
      ''');
      final before = raw
          .select('SELECT * FROM transaction_outbox_entries ORDER BY id')
          .map((r) => Map<String, Object?>.of(r))
          .toList();

      final migrated = AppDatabase.forTesting(raw);
      addTearDown(migrated.close);

      expect(migrated.db.select('PRAGMA user_version').single.values.first, 3);
      final after = migrated.db
          .select('SELECT * FROM transaction_outbox_entries ORDER BY id')
          .map((r) => Map<String, Object?>.of(r))
          .toList();
      expect(after, hasLength(2));
      for (var i = 0; i < before.length; i++) {
        for (final entry in before[i].entries) {
          expect(after[i][entry.key], entry.value, reason: entry.key);
        }
        expect(after[i]['attempts'], 0);
        expect(after[i]['next_attempt_at'], 0);
        expect(after[i]['parked'], 0);
      }
    });

    test('re-opening an already migrated database is a no-op', () {
      final raw = _v2Database();
      final first = AppDatabase.forTesting(raw);
      first.db.execute(
        'INSERT INTO transaction_outbox_entries '
        '(namespace, client_mutation_id, amount_paise, created_at, attempts, '
        "next_attempt_at, parked) VALUES ('ns-a', 'm1', 100, 1, 3, 77, 1)",
      );
      final second = AppDatabase.forTesting(raw);
      addTearDown(second.close);
      final names = second.db
          .select('PRAGMA table_info(transaction_outbox_entries)')
          .map((r) => r['name'] as String)
          .toList();
      for (final name in ['attempts', 'next_attempt_at', 'parked']) {
        expect(names.where((c) => c == name), hasLength(1), reason: name);
      }
      final row = second.db
          .select(
            'SELECT attempts, next_attempt_at, parked '
            'FROM transaction_outbox_entries',
          )
          .single;
      expect([row['attempts'], row['next_attempt_at'], row['parked']], [
        3,
        77,
        1,
      ]);
    });

    test('a pre-v1 card-only outbox upgrades all the way to v3', () {
      final legacy = sqlite3.openInMemory();
      legacy.execute('''
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
      legacy.execute(
        'INSERT INTO transaction_outbox_entries '
        '(user_card_id, amount_paise, created_at) VALUES (?, ?, ?)',
        ['legacy-card', 9900, 123456],
      );
      final migrated = AppDatabase.forTesting(legacy);
      addTearDown(migrated.close);
      final row = migrated.db
          .select('SELECT * FROM transaction_outbox_entries')
          .single;
      expect(row['user_card_id'], 'legacy-card');
      expect([row['attempts'], row['next_attempt_at'], row['parked']], [
        0,
        0,
        0,
      ]);
      expect(migrated.db.select('PRAGMA user_version').single.values.first, 3);
    });
  });
}
