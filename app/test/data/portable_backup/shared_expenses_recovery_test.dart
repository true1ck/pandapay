import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_local_snapshot.dart';
import 'package:pandapay/data/portable_backup/local_snapshot_source.dart';
import 'package:pandapay/features/shared_expenses/data/shared_commands.dart';
import 'package:pandapay/features/shared_expenses/storage/shared_store.dart';

const account = '11111111-1111-4111-8111-111111111111';
const namespace = 'user:$account';
const otherNamespace = 'user:22222222-2222-4222-8222-222222222222';
const operation = '33333333-3333-4333-8333-333333333333';
const contextId = '44444444-4444-4444-8444-444444444444';
SharedCommand command() => SharedCommand(
  operationId: operation,
  kind: 'context.create',
  payload: {
    'contextId': contextId,
    'contextKind': 'group',
    'name': 'Flatmates',
  },
);

void main() {
  test(
    'future split schema does not stop reopening existing personal finance data',
    () async {
      final folder = await Directory.systemTemp.createTemp('shared-forward-');
      final file = '${folder.path}/personal.sqlite';
      final first = AppDatabase.openFile(file);
      first.db.execute(
        'CREATE TABLE personal_preserved(id TEXT PRIMARY KEY,amount INTEGER)',
      );
      first.db.execute(
        "INSERT INTO personal_preserved VALUES('existing',120000)",
      );
      first.db.execute(
        "UPDATE shared_schema_version SET version=999 WHERE module='shared_expenses'",
      );
      first.close();
      final reopened = AppDatabase.openFile(file);
      try {
        expect(
          reopened.db
              .select('SELECT amount FROM personal_preserved')
              .single['amount'],
          120000,
        );
        expect(
          () => SharedExpensesStore(reopened, namespace: namespace),
          throwsFormatException,
        );
        expect(
          reopened.db
              .select('SELECT version FROM shared_schema_version')
              .single['version'],
          999,
        );
      } finally {
        reopened.close();
        await folder.delete(recursive: true);
      }
    },
  );
  test(
    'opening the existing account database prepares additive shared storage',
    () {
      final owner = AppDatabase.forTesting(sqlite3.openInMemory());
      try {
        expect(
          owner.db.select(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='shared_commands'",
          ),
          hasLength(1),
        );
        expect(owner.db.select('PRAGMA user_version').single.values.first, 1);
      } finally {
        owner.close();
      }
    },
  );
  test(
    'portable backup reports pending shared commands and isolates the account',
    () async {
      final owner = AppDatabase.forTesting(sqlite3.openInMemory());
      try {
        await SharedExpensesStore(
          owner,
          namespace: namespace,
        ).enqueue(command());
        await SharedExpensesStore(
          owner,
          namespace: otherNamespace,
        ).enqueue(command());
        final source = LocalPortableSnapshotSource(
          appDb: owner,
          namespace: namespace,
        );
        final status = await source.drainAndVerifyOutboxes();
        expect(status.pendingByQueue['shared_commands'], 1);
        expect(status.pendingByQueue['shared_command_dependencies'], 0);
      } finally {
        owner.close();
      }
    },
  );
  test(
    'account recovery preserves immutable requests but resets device leases and cursors',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'shared-recovery-',
      );
      final owner = AppDatabase.openFile('${directory.path}/source.sqlite');
      final target = AppDatabase.openFile('${directory.path}/target.sqlite');
      try {
        final store = SharedExpensesStore(owner, namespace: namespace);
        await store.enqueue(command(), provisional: {'title': 'Draft'});
        await store.saveEditorDraft(
          operation,
          contextId: contextId,
          expectedVersion: 0,
          value: {'billText': '100.', 'title': 'Unsaved dinner'},
        );
        await SharedExpensesStore(
          owner,
          namespace: otherNamespace,
        ).enqueue(command());
        owner.db.execute(
          "UPDATE shared_commands SET state='sending',lease_id='old-phone',lease_expires=999999,next_attempt=999999 WHERE namespace=?",
          [namespace],
        );
        owner.db.execute(
          "INSERT INTO shared_sync_state(namespace,key,value) VALUES(?,'cursor','old-device-cursor')",
          [namespace],
        );
        final archive = await owner.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.capture(
            lease: lease,
            accountId: account,
            namespace: namespace,
            includeReceipts: false,
          ),
        );
        final decoded = jsonDecode(utf8.decode(archive)) as Map;
        final tables = decoded['tables'] as Map;
        expect(tables.containsKey('shared_schema_version'), isFalse);
        expect(tables.containsKey('shared_sync_state'), isFalse);
        expect(tables['shared_commands'], hasLength(1));
        expect(
          (tables['shared_commands'] as List).single['operation_id'],
          operation,
        );
        await target.withRecoveryDatabase(
          (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
            lease: lease,
            payload: archive,
            accountId: account,
            namespace: namespace,
            attachmentsDirectory: Directory('${directory.path}/receipts'),
          ),
        );
        final restored = SharedExpensesStore(target, namespace: namespace);
        expect(
          restored.operation(operation)!.command.canonicalJson,
          command().canonicalJson,
        );
        expect(
          restored.operation(operation)!.command.requestHash,
          command().requestHash,
        );
        expect(restored.operation(operation)!.state, SharedCommandState.retry);
        expect(restored.provisional(operation), {'title': 'Draft'});
        expect(restored.editorDraft(operation)!.value, {
          'billText': '100.',
          'title': 'Unsaved dinner',
        });
        expect(
          target.db.select('SELECT * FROM shared_commands WHERE namespace=?', [
            otherNamespace,
          ]),
          isEmpty,
        );
        final row = target.db.select(
          'SELECT lease_id,lease_expires,next_attempt FROM shared_commands WHERE namespace=?',
          [namespace],
        ).single;
        expect(row['lease_id'], isNull);
        expect(row['lease_expires'], 0);
        expect(row['next_attempt'], 0);
        expect(target.db.select('SELECT * FROM shared_sync_state'), isEmpty);
      } finally {
        owner.close();
        target.close();
        await directory.delete(recursive: true);
      }
    },
  );
  for (final include in [false, true]) {
    test(
      'shared receipt recovery respects includeReceipts=$include without creating a transaction',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'shared-receipt-recovery-',
        );
        final owner = AppDatabase.openFile('${directory.path}/source.sqlite');
        final target = AppDatabase.openFile('${directory.path}/target.sqlite');
        try {
          final store = SharedExpensesStore(owner, namespace: namespace);
          await store.saveEditorDraft(
            operation,
            contextId: contextId,
            expectedVersion: 0,
            value: {'title': 'Dinner'},
          );
          final receipt = await store.saveEditorReceipt(
            operation,
            name: 'Bill.jpg',
            bytes: Uint8List.fromList([1, 2, 3, 4]),
          );
          final archive = await owner.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.capture(
              lease: lease,
              accountId: account,
              namespace: namespace,
              includeReceipts: include,
            ),
          );
          final tables =
              (jsonDecode(utf8.decode(archive)) as Map)['tables'] as Map;
          expect(tables.containsKey('shared_editor_receipts'), include);
          await target.withRecoveryDatabase(
            (lease) => AccountRecoveryLocalSnapshot.restoreFresh(
              lease: lease,
              payload: archive,
              accountId: account,
              namespace: namespace,
              attachmentsDirectory: Directory('${directory.path}/receipts'),
            ),
          );
          final restored = SharedExpensesStore(
            target,
            namespace: namespace,
          ).editorReceipt(operation, receipt.hash);
          expect(restored?.bytes, include ? [1, 2, 3, 4] : isNull);
          expect(
            target.db
                .select('SELECT count(*) n FROM transaction_outbox_entries')
                .single['n'],
            0,
          );
        } finally {
          owner.close();
          target.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
