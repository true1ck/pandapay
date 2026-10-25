import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_local_snapshot.dart';

const _account = '11111111-1111-4111-8111-111111111111';
const _namespace = 'user:$_account';

AppDatabase _database(
  String name, {
  required bool withAttachments,
  bool newerSchema = false,
}) {
  final owner = AppDatabase.openFile(name);
  final db = owner.db;
  for (final row in db.select(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
  )) {
    db.execute('DROP TABLE "${row['name']}"');
  }
  db.execute(
    'CREATE TABLE financial_entities(namespace TEXT, entity TEXT, id TEXT, payload TEXT); '
    'CREATE TABLE sync_pending_changes(namespace TEXT, id TEXT, mutation_id TEXT, in_flight INTEGER${newerSchema ? ', added_later TEXT' : ''});',
  );
  if (withAttachments) {
    db.execute(
      'CREATE TABLE transaction_attachments(id TEXT PRIMARY KEY, transaction_id TEXT, file_name TEXT, local_path TEXT);',
    );
  }
  return owner;
}

Map<String, dynamic> _decode(Uint8List payload) =>
    jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;

Uint8List _encode(Map<String, dynamic> data) =>
    Uint8List.fromList(utf8.encode(jsonEncode(data)));

Uint8List _archive(
  Map<String, Object?> tables, {
  bool includeUnsynced = true,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'format': 'pandapay-account-local-v1',
      'account_id': _account,
      'namespace': _namespace,
      'include_receipts': false,
      'include_unsynced': includeUnsynced,
      'tables': tables,
      'receipts': [],
    }),
  ),
);

void main() {
  test('rejects an archive that disclaims unsynced recovery before writes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'recovery-completeness-',
    );
    final owner = AppDatabase.openFile('${temp.path}/target.sqlite');
    final attachments = Directory('${temp.path}/attachments');
    try {
      final db = owner.db;
      for (final row in db.select(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
      )) {
        db.execute('DROP TABLE "${row['name']}"');
      }
      db.execute(
        'CREATE TABLE financial_entities(namespace TEXT, entity TEXT, id TEXT, payload TEXT); '
        'CREATE TABLE sync_pending_changes(namespace TEXT, id TEXT, mutation_id TEXT, in_flight INTEGER);',
      );

      final archive = _archive({
        'financial_entities': [
          {
            'namespace': _namespace,
            'entity': 'transactions',
            'id': 'txn-1',
            'payload': 'local transaction',
          },
        ],
        'sync_pending_changes': [],
      }, includeUnsynced: false);

      await expectLater(
        owner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
            lease: lease,
            payload: archive,
            accountId: _account,
            namespace: _namespace,
            attachmentsDirectory: attachments,
          ),
        ),
        throwsFormatException,
      );

      expect(db.select('SELECT * FROM financial_entities'), isEmpty);
      expect(db.select('SELECT * FROM sync_pending_changes'), isEmpty);
      expect(await attachments.exists(), isFalse);
    } finally {
      owner.close();
      await temp.delete(recursive: true);
    }
  });

  test(
    'accepts a legacy v1 archive when the destination has a newer table',
    () async {
      final temp = await Directory.systemTemp.createTemp('recovery-legacy-v1-');
      final owner = AppDatabase.openFile('${temp.path}/target.sqlite');
      final attachments = Directory('${temp.path}/attachments');
      try {
        final db = owner.db;
        for (final row in db.select(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
        )) {
          db.execute('DROP TABLE "${row['name']}"');
        }
        db.execute(
          'CREATE TABLE financial_entities(namespace TEXT, entity TEXT, id TEXT, payload TEXT); '
          'CREATE TABLE sync_pending_changes(namespace TEXT, id TEXT, mutation_id TEXT, in_flight INTEGER); '
          'CREATE TABLE added_after_archive_produced(namespace TEXT, id TEXT);',
        );

        // V1 has no producer schema version. A destination can have scoped
        // tables that did not exist when a valid archive was captured.
        final legacy = _archive({
          'financial_entities': [
            {
              'namespace': _namespace,
              'entity': 'transactions',
              'id': 'txn-1',
              'payload': 'local transaction',
            },
          ],
          'sync_pending_changes': [
            {
              'namespace': _namespace,
              'id': 'queue-1',
              'mutation_id': 'stable-mutation-id',
              'in_flight': 1,
            },
          ],
        });

        await owner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
            lease: lease,
            payload: legacy,
            accountId: _account,
            namespace: _namespace,
            attachmentsDirectory: attachments,
          ),
        );

        expect(
          db.select('SELECT id FROM financial_entities').single['id'],
          'txn-1',
        );
        final queue = db.select('SELECT * FROM sync_pending_changes').single;
        expect(queue['mutation_id'], 'stable-mutation-id');
        expect(queue['in_flight'], 0);
        expect(
          db.select('SELECT * FROM added_after_archive_produced'),
          isEmpty,
        );
      } finally {
        owner.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test('capture declares tables, columns, queues, and receipt bytes', () async {
    final temp = await Directory.systemTemp.createTemp('recovery-coverage-');
    final sourceOwner = _database(
      '${temp.path}/source.sqlite',
      withAttachments: true,
    );
    final targetOwner = _database(
      '${temp.path}/target.sqlite',
      withAttachments: true,
      newerSchema: true,
    );
    final sourceFiles = Directory('${temp.path}/source-files')..createSync();
    final targetFiles = Directory('${temp.path}/target-files');
    try {
      final receipt = File('${sourceFiles.path}/receipt.jpg')
        ..writeAsBytesSync([1, 2, 3, 4]);
      sourceOwner.db.execute('INSERT INTO financial_entities VALUES(?,?,?,?)', [
        _namespace,
        'transactions',
        'txn-coverage',
        'local transaction',
      ]);
      sourceOwner.db.execute(
        'INSERT INTO sync_pending_changes VALUES(?,?,?,?)',
        [_namespace, 'queue-coverage', 'stable-mutation-id', 1],
      );
      sourceOwner.db.execute(
        'INSERT INTO transaction_attachments VALUES(?,?,?,?)',
        ['receipt-coverage', 'txn-coverage', 'receipt.jpg', receipt.path],
      );

      final payload = await sourceOwner.withRecoveryDatabase(
        (lease) => AccountRecoveryLocalSnapshot.capture(
          lease: lease,
          accountId: _account,
          namespace: _namespace,
          includeReceipts: true,
        ),
      );
      final archive = _decode(payload);
      final coverage = archive['coverage'] as Map<String, dynamic>;
      expect(coverage['version'], 1);
      expect(coverage['account_id'], _account);
      expect(coverage['namespace'], _namespace);
      expect(coverage['include_receipts'], isTrue);
      expect(coverage['include_unsynced'], isTrue);
      final entries = (coverage['tables'] as List).cast<Map>();
      final names = entries.map((entry) => entry['name']).toSet();
      expect(names, {
        'financial_entities',
        'sync_pending_changes',
        'transaction_attachments',
      });
      final attachmentCoverage = entries.singleWhere(
        (entry) => entry['name'] == 'transaction_attachments',
      );
      expect(attachmentCoverage['columns'], contains('local_path'));
      expect(attachmentCoverage['row_count'], 1);
      expect((coverage['receipts'] as Map)['count'], 1);

      await targetOwner.withRecoveryDatabase(
        (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
          lease: lease,
          payload: payload,
          accountId: _account,
          namespace: _namespace,
          attachmentsDirectory: targetFiles,
        ),
      );
      expect(
        targetOwner.db.select('SELECT id FROM financial_entities').single['id'],
        'txn-coverage',
      );
      expect(
        targetOwner.db
            .select('SELECT mutation_id FROM sync_pending_changes')
            .single['mutation_id'],
        'stable-mutation-id',
      );
      expect(
        targetOwner.db
            .select('SELECT added_later FROM sync_pending_changes')
            .single['added_later'],
        isNull,
      );
      final installed = File(
        targetOwner.db
                .select('SELECT local_path FROM transaction_attachments')
                .single['local_path']
            as String,
      );
      expect(await installed.readAsBytes(), [1, 2, 3, 4]);
    } finally {
      sourceOwner.close();
      targetOwner.close();
      await temp.delete(recursive: true);
    }
  });

  test(
    'coverage rejects omitted or altered entries before filesystem writes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'recovery-coverage-tamper-',
      );
      final sourceOwner = _database(
        '${temp.path}/source.sqlite',
        withAttachments: true,
      );
      final targetOwner = _database(
        '${temp.path}/target.sqlite',
        withAttachments: true,
      );
      final sourceFiles = Directory('${temp.path}/source-files')..createSync();
      try {
        final receipt = File('${sourceFiles.path}/receipt.jpg')
          ..writeAsBytesSync([5, 6, 7]);
        sourceOwner.db.execute(
          'INSERT INTO financial_entities VALUES(?,?,?,?)',
          [_namespace, 'transactions', 'txn-tamper', 'transaction'],
        );
        sourceOwner.db.execute(
          'INSERT INTO sync_pending_changes VALUES(?,?,?,?)',
          [_namespace, 'queue-tamper', 'mutation-tamper', 0],
        );
        sourceOwner.db.execute(
          'INSERT INTO transaction_attachments VALUES(?,?,?,?)',
          ['receipt-tamper', 'txn-tamper', 'receipt.jpg', receipt.path],
        );
        final original = _decode(
          await sourceOwner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.capture(
              lease: lease,
              accountId: _account,
              namespace: _namespace,
              includeReceipts: true,
            ),
          ),
        );
        final corruptions = <void Function(Map<String, dynamic>)>[
          (data) => data['tables'].remove('sync_pending_changes'),
          (data) => (data['tables']['sync_pending_changes'] as List).clear(),
          (data) => (data['tables']['sync_pending_changes'][0] as Map).remove(
            'mutation_id',
          ),
          (data) => data['tables'].remove('transaction_attachments'),
          (data) => (data['receipts'] as List).clear(),
          (data) => (data['coverage']['tables'] as List).add(
            Map<String, dynamic>.from(data['coverage']['tables'][0] as Map),
          ),
          (data) => data['coverage']['namespace'] = 'user:other-account',
          (data) => data['coverage']['account_id'] =
              '33333333-3333-4333-8333-333333333333',
          (data) => data['coverage']['version'] = 2,
        ];

        for (var index = 0; index < corruptions.length; index++) {
          final data = _decode(_encode(original));
          corruptions[index](data);
          final attachments = Directory('${temp.path}/target-files-$index');
          await expectLater(
            targetOwner.withRecoveryDatabase(
              (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
                lease: lease,
                payload: _encode(data),
                accountId: _account,
                namespace: _namespace,
                attachmentsDirectory: attachments,
              ),
            ),
            throwsFormatException,
          );
          expect(await attachments.exists(), isFalse);
          expect(
            targetOwner.db.select('SELECT * FROM financial_entities'),
            isEmpty,
          );
          expect(
            targetOwner.db.select('SELECT * FROM sync_pending_changes'),
            isEmpty,
          );
        }
      } finally {
        sourceOwner.close();
        targetOwner.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'receipt opt-out omits receipt metadata and bytes from coverage',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'recovery-receipt-optout-',
      );
      final owner = _database(
        '${temp.path}/source.sqlite',
        withAttachments: true,
      );
      final sourceFiles = Directory('${temp.path}/source-files')..createSync();
      try {
        final receipt = File('${sourceFiles.path}/receipt.jpg')
          ..writeAsBytesSync([8, 9]);
        owner.db.execute('INSERT INTO financial_entities VALUES(?,?,?,?)', [
          _namespace,
          'transactions',
          'txn-no-receipt',
          'transaction',
        ]);
        owner.db.execute(
          'INSERT INTO transaction_attachments VALUES(?,?,?,?)',
          [
            'excluded-receipt-id',
            'txn-no-receipt',
            'receipt.jpg',
            receipt.path,
          ],
        );

        final payload = await owner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.capture(
            lease: lease,
            accountId: _account,
            namespace: _namespace,
            includeReceipts: false,
          ),
        );
        final archive = _decode(payload);
        final coverage = archive['coverage'] as Map<String, dynamic>;
        final coveredTables = (coverage['tables'] as List)
            .cast<Map>()
            .map((entry) => entry['name'])
            .toSet();
        expect(coveredTables, isNot(contains('transaction_attachments')));
      expect(
        (archive['tables'] as Map).containsKey('transaction_attachments'),
        isFalse,
      );
        expect(archive['receipts'], isEmpty);
        expect((coverage['receipts'] as Map)['count'], 0);
        expect(utf8.decode(payload).contains('excluded-receipt-id'), isFalse);
      } finally {
        owner.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
