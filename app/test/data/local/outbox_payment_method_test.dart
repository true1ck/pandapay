import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/transaction_outbox_repository.dart';
import 'package:pandapay/data/user_cards_repository.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:sqlite3/sqlite3.dart';

/// Builds a database exactly as the previous app version (local schema v1,
/// before transaction_outbox_entries.payment_method) left it on disk.
Database _v1Database() {
  final raw = sqlite3.openInMemory();
  // Run the real schema, then peel the column back off and stamp v1, so the
  // fixture cannot drift from the genuine pre-change table shape.
  AppDatabase.forTesting(raw);
  raw.execute(
    'ALTER TABLE transaction_outbox_entries DROP COLUMN payment_method',
  );
  raw.execute('PRAGMA user_version = 1');
  return raw;
}

List<String> _outboxColumns(Database db) => db
    .select('PRAGMA table_info(transaction_outbox_entries)')
    .map((r) => r['name'] as String)
    .toList();

void main() {
  group('outbox payment_method migration (v1 -> v2)', () {
    test('a fresh database is at v2 and has the nullable column', () {
      final fresh = openInMemoryForTesting();
      addTearDown(fresh.close);
      expect(fresh.db.select('PRAGMA user_version').single.values.first, 2);
      final column = fresh.db
          .select('PRAGMA table_info(transaction_outbox_entries)')
          .firstWhere((r) => r['name'] == 'payment_method');
      expect(column['notnull'], 0);
      expect(column['dflt_value'], isNull);
    });

    test('the v1 fixture really lacks the column (guards the fixture)', () {
      final raw = _v1Database();
      addTearDown(raw.dispose);
      expect(_outboxColumns(raw), isNot(contains('payment_method')));
      expect(raw.select('PRAGMA user_version').single.values.first, 1);
    });

    test('existing rows survive, load with a null method, and flush identically',
        () async {
      final raw = _v1Database();
      raw.execute(
        '''
        INSERT INTO transaction_outbox_entries
          (namespace, user_card_id, client_mutation_id, amount_paise,
           category_id, user_category_id, merchant_name, occurred_at, note,
           instrument, entry_kind, created_at, last_error)
        VALUES
          ('legacy', 'uc-old', 'old-1', 15000, NULL, NULL, NULL, NULL, NULL,
           'upi_bank', 'spend', 1000, NULL),
          ('legacy', NULL, 'old-2', 99900, 'dining', NULL, 'Cafe', 1700000000000,
           'lunch', 'cash', 'spend', 2000, 'offline')
        ''',
      );
      final before = raw
          .select('SELECT * FROM transaction_outbox_entries ORDER BY id')
          .map((r) => Map<String, Object?>.of(r))
          .toList();
      expect(before, hasLength(2));

      // Opening the database is the migration.
      final migrated = AppDatabase.forTesting(raw);
      addTearDown(migrated.close);

      expect(migrated.db.select('PRAGMA user_version').single.values.first, 2);
      expect(_outboxColumns(migrated.db), contains('payment_method'));

      // Every pre-existing column value is untouched; the new one is NULL.
      final after = migrated.db
          .select('SELECT * FROM transaction_outbox_entries ORDER BY id')
          .map((r) => Map<String, Object?>.of(r))
          .toList();
      expect(after, hasLength(2));
      for (var i = 0; i < before.length; i++) {
        for (final entry in before[i].entries) {
          expect(after[i][entry.key], entry.value, reason: entry.key);
        }
        expect(after[i]['payment_method'], isNull);
      }

      final outbox = TransactionOutboxRepository(migrated);
      final pending = await outbox.pending();
      expect(pending.map((e) => e.clientMutationId), ['old-1', 'old-2']);
      expect(pending.map((e) => e.paymentMethod), [null, null]);
      expect(pending[0].instrument, TxnInstrument.upiBank);
      expect(pending[1].instrument, TxnInstrument.cash);
      expect(pending[1].lastError, 'offline');

      // Flush through the real repository and capture the exact bytes sent.
      final bodies = <String>[];
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((http.Request request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/transactions');
          bodies.add(request.body);
          return http.Response(
            jsonEncode({
              'transaction': {'id': 'srv-${bodies.length}'},
            }),
            201,
          );
        }),
      );
      expect(await outbox.flush(repo), 2);
      expect(await outbox.pending(), isEmpty);

      // The request body is byte-identical to what the previous app version
      // produced for these rows: no paymentMethod key at all.
      expect(
        bodies[0],
        jsonEncode({
          'userCardId': 'uc-old',
          'amountInr': Money.fromPaise(15000).rupees,
          'occurredAt': null,
          'instrument': 'upi_bank',
          'entryKind': 'spend',
          'clientMutationId': 'old-1',
        }),
      );
      expect(
        bodies[1],
        jsonEncode({
          'amountInr': Money.fromPaise(99900).rupees,
          'categoryId': 'dining',
          'merchantName': 'Cafe',
          'occurredAt': DateTime.fromMillisecondsSinceEpoch(
            1700000000000,
          ).toIso8601String(),
          'note': 'lunch',
          'instrument': 'cash',
          'entryKind': 'spend',
          'clientMutationId': 'old-2',
        }),
      );
      for (final body in bodies) {
        expect(body, isNot(contains('paymentMethod')));
      }
    });

    test('re-opening an already migrated database is a no-op', () {
      final raw = _v1Database();
      final first = AppDatabase.forTesting(raw);
      first.db.execute(
        "INSERT INTO transaction_outbox_entries "
        "(namespace, client_mutation_id, amount_paise, created_at, payment_method) "
        "VALUES ('legacy', 'm1', 100, 1, 'cheque')",
      );
      final second = AppDatabase.forTesting(raw);
      addTearDown(second.close);
      expect(
        _outboxColumns(raw).where((c) => c == 'payment_method'),
        hasLength(1),
      );
      expect(
        raw
            .select('SELECT payment_method FROM transaction_outbox_entries')
            .single['payment_method'],
        'cheque',
      );
    });

    test('a pre-v1 (legacy card-only) outbox still upgrades all the way', () {
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
      expect(_outboxColumns(migrated.db), contains('payment_method'));
      final row =
          migrated.db.select('SELECT * FROM transaction_outbox_entries').single;
      expect(row['user_card_id'], 'legacy-card');
      expect(row['payment_method'], isNull);
      expect(migrated.db.select('PRAGMA user_version').single.values.first, 2);
    });
  });

  group('outbox carries paymentMethod', () {
    late AppDatabase appDb;
    late TransactionOutboxRepository outbox;
    setUp(() {
      appDb = openInMemoryForTesting();
      outbox = TransactionOutboxRepository(appDb);
    });
    tearDown(() => appDb.close());

    test('enqueue persists it, pending returns it, flush sends it', () async {
      await outbox.enqueue(
        amount: Money.fromRupees(25000),
        instrument: TxnInstrument.upiBank,
        paymentMethod: 'cheque',
        clientMutationId: 'chq-1',
      );
      expect(
        appDb.db
            .select('SELECT payment_method FROM transaction_outbox_entries')
            .single['payment_method'],
        'cheque',
      );
      expect((await outbox.pending()).single.paymentMethod, 'cheque');

      late Map<String, dynamic> sent;
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'transaction': {'id': 'srv-1'},
            }),
            201,
          );
        }),
      );
      expect(await outbox.flush(repo), 1);
      expect(sent['paymentMethod'], 'cheque');
      expect(sent['instrument'], 'upi_bank');
    });

    test('an entry without one stays null and sends no key', () async {
      await outbox.enqueue(
        userCardId: 'uc1',
        amount: Money.fromRupees(100),
        clientMutationId: 'plain-1',
      );
      expect((await outbox.pending()).single.paymentMethod, isNull);
      late String body;
      final repo = UserCardsRepository(
        apiBaseUrl: 'https://api.test',
        accessToken: 'token',
        client: MockClient((request) async {
          body = request.body;
          return http.Response(
            jsonEncode({
              'transaction': {'id': 'srv-1'},
            }),
            201,
          );
        }),
      );
      await outbox.flush(repo);
      expect(body, isNot(contains('paymentMethod')));
    });
  });
}
