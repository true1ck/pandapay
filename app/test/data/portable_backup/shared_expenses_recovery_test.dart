import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
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
      final first = AppDatabase.openUnencryptedFileForTesting(file);
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
      final reopened = AppDatabase.openUnencryptedFileForTesting(file);
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
        expect(owner.db.select('PRAGMA user_version').single.values.first, 2);
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
}
