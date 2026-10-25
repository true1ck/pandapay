import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/portable_backup.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late AppDatabase appDb;
  late Directory staging;
  const namespace = 'acct-A';

  setUp(() async {
    appDb = AppDatabase.forTesting(sqlite.sqlite3.openInMemory());
    staging = await Directory.systemTemp.createTemp('local-snapshot-');
    appDb.db.execute('''
      CREATE TABLE financial_entities (
        namespace TEXT NOT NULL, entity TEXT NOT NULL, id TEXT NOT NULL,
        payload TEXT NOT NULL, observed_at INTEGER NOT NULL,
        pending INTEGER NOT NULL DEFAULT 0, source_key TEXT,
        occurred_at INTEGER, amount_paise INTEGER,
        PRIMARY KEY(namespace, entity, id)
      );
      CREATE TABLE IF NOT EXISTS local_commitments (
        namespace TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
        PRIMARY KEY(namespace, id)
      );
    ''');
    void entity(
      String entity,
      String id,
      Map<String, Object?> payload, {
      int pending = 0,
    }) => appDb.db.execute(
      'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at,pending) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [namespace, entity, id, jsonEncode(payload), 1700000000000, pending],
    );
    entity('transactions', 'txn-1', {'note': 'Swiggy', 'amount': '249.00'});
    entity('transactions', 'txn-2', {
      'note': 'Fuel',
      'amount': '1100.00',
    }, pending: 1);
    entity('cards', 'card-1', {'bank': 'HDFC', 'last4': '1234'});
    entity('sms_observations', 'obs-1', {'sender': 'HDFCBK', 'amount': 249});
    appDb.db.execute(
      'INSERT INTO local_user_cards(id, card_product_id, nickname, last4, is_default, '
      'is_archived, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        'luc-1',
        'card_product-1',
        'Daily driver',
        '5678',
        1,
        0,
        1.5,
        1700000000000,
      ],
    );
    appDb.db.execute(
      'INSERT INTO user_categories(namespace,id,name,slug,match_terms_json,created_at,updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        namespace,
        'lc-1',
        'Groceries',
        'groceries',
        '["big","basket"]',
        1700000000000,
        1700000000000,
      ],
    );
    appDb.db.execute(
      'INSERT INTO transaction_tags(namespace,id,name,normalized_name,updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [namespace, 'tag-1', 'Vacation', 'vacation', '2026-01-01T00:00:00.000Z'],
    );
    appDb.db.execute(
      'INSERT INTO transaction_tag_links(namespace,transaction_id,tag_id,updated_at) '
      'VALUES (?, ?, ?, ?)',
      [namespace, 'txn-1', 'tag-1', '2026-01-01T00:00:00.000Z'],
    );
    appDb.db.execute(
      'INSERT INTO local_commitments(namespace,id,payload) VALUES (?, ?, ?)',
      [
        namespace,
        'cm-1',
        jsonEncode({'card': 'card-1', 'due_day': 5}),
      ],
    );
    appDb.db.execute(
      'INSERT INTO local_needs_review(namespace,id,payload) VALUES (?, ?, ?)',
      [
        namespace,
        'nr-1',
        jsonEncode({'reason': 'amount_mismatch'}),
      ],
    );
    appDb.db.execute(
      'INSERT INTO sync_pending_changes(entity, entity_id, op, payload_json, field_clocks_json, '
      'created_at, namespace) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'user_categories',
        'lc-1',
        'update',
        '{}',
        '{}',
        1700000000000,
        namespace,
      ],
    );
    appDb.db.execute(
      'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?)',
      [
        'att-1',
        'txn-1',
        'receipt.png',
        'docs/att-1.png',
        'image/png',
        1700000000000,
      ],
    );
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        if (!await staging.exists()) return;
        await staging.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  test(
    'drainAndVerifyOutboxes reports every queue and surfaces pending work',
    () async {
      final source = LocalPortableSnapshotSource(
        appDb: appDb,
        namespace: namespace,
      );
      final status = await source.drainAndVerifyOutboxes();
      expect(status.isDrained, isFalse);
      expect(status.totalPending, 2);
      expect(status.nonZeroQueues, {
        'sync_pending_changes': 1,
        'financial_pending': 1,
      });

      appDb.db.execute('UPDATE sync_pending_changes SET in_flight = 0 WHERE 0');
      appDb.db.execute('DELETE FROM sync_pending_changes');
      appDb.db.execute(
        'UPDATE financial_entities SET pending = 0 WHERE namespace = ?',
        [namespace],
      );
      final drained = await source.drainAndVerifyOutboxes();
      expect(drained.isDrained, isTrue);
      expect(
        drained.pendingByQueue.values.every((count) => count == 0),
        isTrue,
      );
    },
  );

  test('a queue whose table does not exist yet counts zero', () async {
    appDb.db.execute('DROP TABLE sync_pending_changes');
    appDb.db.execute('DELETE FROM financial_entities WHERE pending = 1');
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final status = await source.drainAndVerifyOutboxes();
    expect(status.pendingByQueue['sync_pending_changes'], 0);
  });

  test('drain hooks run before counting', () async {
    final drainedQueues = <String>[];
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
      drainHooks: {
        'sync_pending_changes': () async {
          drainedQueues.add('sync_pending_changes');
          appDb.db.execute('DELETE FROM sync_pending_changes');
        },
      },
    );
    final status = await source.drainAndVerifyOutboxes();
    expect(drainedQueues, ['sync_pending_changes']);
    expect(status.pendingByQueue['sync_pending_changes'], 0);
    expect(status.pendingByQueue['financial_pending'], 1);
  });

  test('capture writes canonical sections under a consistent read', () async {
    appDb.db.execute('DELETE FROM sync_pending_changes');
    appDb.db.execute(
      'UPDATE financial_entities SET pending = 0 WHERE namespace = ?',
      [namespace],
    );
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final sections = await source.capturePortableSections(
      stagingDirectory: staging,
    );

    expect(sections.keys.toList(), [
      'transactions',
      'cards',
      'sms_observations',
      'user_categories',
      'transaction_tags',
      'transaction_tag_links',
      'local_user_cards',
      'local_commitments',
      'local_needs_review',
    ]);

    final transactions = utf8
        .decode(sections['transactions']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(transactions, hasLength(2));
    expect(transactions[0]['id'], 'txn-1');
    expect(transactions[0]['payload'], {'note': 'Swiggy', 'amount': '249.00'});
    expect(transactions[0]['pending'], 0);

    final categories = utf8
        .decode(sections['user_categories']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(categories.single['match_terms_json'], ['big', 'basket']);

    final links = utf8
        .decode(sections['transaction_tag_links']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(links.single, {
      'namespace': namespace,
      'transaction_id': 'txn-1',
      'tag_id': 'tag-1',
      'updated_at': '2026-01-01T00:00:00.000Z',
      'deleted_at': null,
    });

    final userCards = utf8
        .decode(sections['local_user_cards']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(userCards.single['id'], 'luc-1');
    expect(userCards.single['sort_order'], 1.5);

    final commitments = utf8
        .decode(sections['local_commitments']!.readAsBytesSync())
        .trim()
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(commitments.single['payload'], {'card': 'card-1', 'due_day': 5});
  });

  test('sections skip empty tables so digests stay meaningful', () async {
    appDb.db.execute('DELETE FROM sync_pending_changes');
    appDb.db.execute('DELETE FROM financial_entities WHERE pending = 1');
    appDb.db.execute('DELETE FROM local_user_cards');
    appDb.db.execute('DELETE FROM transaction_tag_links');
    appDb.db.execute('DELETE FROM local_needs_review');
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final sections = await source.capturePortableSections(
      stagingDirectory: staging,
    );
    expect(sections.containsKey('local_user_cards'), isFalse);
    expect(sections.containsKey('transaction_tag_links'), isFalse);
    expect(sections.containsKey('local_needs_review'), isFalse);
    expect(sections.containsKey('transactions'), isTrue);
  });

  test('rows from other namespaces are never exported', () async {
    appDb.db.execute('DELETE FROM sync_pending_changes');
    appDb.db.execute(
      'UPDATE financial_entities SET pending = 0 WHERE namespace = ?',
      [namespace],
    );
    appDb.db.execute(
      'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        'acct-B',
        'transactions',
        'txn-other',
        jsonEncode({'note': 'other'}),
        1700000000000,
      ],
    );
    appDb.db.execute(
      "INSERT INTO user_categories(namespace,id,name,slug,match_terms_json,created_at,updated_at) "
      "VALUES ('acct-B', 'lc-other', 'Gym', 'gym', '[]', 1700000000000, 1700000000000)",
    );
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final sections = await source.capturePortableSections(
      stagingDirectory: staging,
    );
    final transactionsBody = utf8.decode(
      sections['transactions']!.readAsBytesSync(),
    );
    expect(transactionsBody.contains('txn-other'), isFalse);
    final categoriesBody = utf8.decode(
      sections['user_categories']!.readAsBytesSync(),
    );
    expect(categoriesBody.contains('Gym'), isFalse);
  });

  test(
    'legacy-namespace rows are excluded without account ownership proof',
    () async {
      appDb.db.execute('DELETE FROM sync_pending_changes');
      appDb.db.execute(
        'UPDATE financial_entities SET pending = 0 WHERE namespace = ?',
        [namespace],
      );
      appDb.db.execute(
        'INSERT INTO financial_entities(namespace,entity,id,payload,observed_at) '
        "VALUES ('legacy', 'transactions', 'txn-legacy', ?, ?)",
        [
          jsonEncode({'note': 'legacy'}),
          1690000000000,
        ],
      );
      final source = LocalPortableSnapshotSource(
        appDb: appDb,
        namespace: namespace,
      );
      final sections = await source.capturePortableSections(
        stagingDirectory: staging,
      );
      final body = utf8.decode(sections['transactions']!.readAsBytesSync());
      expect(body.contains('txn-legacy'), isFalse);
    },
  );

  test(
    'missing queue table counts zero, but schema drift fails closed',
    () async {
      final source = LocalPortableSnapshotSource(
        appDb: appDb,
        namespace: namespace,
      );
      appDb.db.execute('DROP TABLE sync_pending_changes');
      // never-created table: nothing can be pending in it
      final status = await source.drainAndVerifyOutboxes();
      expect(status.pendingByQueue['sync_pending_changes'], 0);

      // schema drift (old table without the namespace column) must fail loudly
      appDb.db.execute(
        'CREATE TABLE sms_facts_outbox (entity TEXT, id TEXT, created_at INTEGER)',
      );
      await expectLater(
        source.drainAndVerifyOutboxes(),
        throwsA(isA<sqlite.SqliteException>()),
      );
    },
  );

  test('attachments are listed with metadata only', () async {
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final attachments = await source.listPortableAttachments();
    expect(attachments.single.id, 'att-1');
    expect(attachments.single.transactionId, 'txn-1');
    expect(attachments.single.localPath, 'docs/att-1.png');
  });

  test('capture surfaces cancellation and leaves no partial files', () async {
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    await expectLater(
      source.capturePortableSections(
        stagingDirectory: staging,
        isCancelled: () async => true,
      ),
      throwsA(isA<PortableBackupCancelled>()),
    );
    expect(await staging.exists(), isTrue);
    expect(staging.listSync().length, 0);
  });

  test('coordinator + concrete source produce a verifiable archive', () async {
    appDb.db.execute('DELETE FROM sync_pending_changes');
    appDb.db.execute(
      'UPDATE financial_entities SET pending = 0 WHERE namespace = ?',
      [namespace],
    );
    final source = LocalPortableSnapshotSource(
      appDb: appDb,
      namespace: namespace,
    );
    final coordinator = PortableLocalSnapshotCoordinator(source);
    final snapshot = await coordinator.capture(stagingDirectory: staging);
    expect(snapshot.outboxStatus.isDrained, isTrue);
    expect(snapshot.sectionFiles, isNotEmpty);
    expect(snapshot.attachmentSources.single.id, 'att-1');
  });
}
