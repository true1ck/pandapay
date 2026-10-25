import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/portable_backup/account_recovery_operation_gate.dart';

void main() {
  test(
    'gate drains admitted jobs and permits their nested work before exclusive',
    () async {
      final gate = AccountRecoveryOperationGate(),
          started = Completer<void>(),
          finish = Completer<void>();
      final job = gate.run(() async {
        started.complete();
        await finish.future;
        await gate.run(() async {});
      });
      await started.future;
      var recovering = false;
      final exclusive = gate.exclusive(() async {
        recovering = true;
        expect(gate.activeOperations, 0);
      });
      await Future<void>.delayed(Duration.zero);
      expect(recovering, false);
      expect(() => gate.admit(), throwsA(isA<AccountRecoveryBusy>()));
      finish.complete();
      await job;
      await exclusive;
      expect(recovering, true);
      expect(gate.isRecovering, false);
      await gate.run(() async {});
    },
  );
  test('nested work keeps admission until it ends after its parent', () async {
    final gate = AccountRecoveryOperationGate(), finish = Completer<void>();
    late Future<void> child;
    await gate.run(() async {
      child = gate.run(() => finish.future);
    });
    expect(gate.activeOperations, 1);
    var acquired = false;
    final exclusive = gate.exclusive(() async {
      acquired = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(acquired, false);
    finish.complete();
    await child;
    await exclusive;
    expect(acquired, true);
    expect(gate.activeOperations, 0);
  });
  test('gate timeout never cancels or loses an admitted operation', () async {
    final gate = AccountRecoveryOperationGate(), finish = Completer<void>();
    final job = gate.run(() => finish.future);
    await expectLater(
      gate.exclusive(() async {
        fail('must not acquire');
      }, drainTimeout: Duration.zero),
      throwsA(isA<TimeoutException>()),
    );
    expect(gate.isRecovering, false);
    expect(gate.activeOperations, 1);
    finish.complete();
    await job;
    expect(gate.activeOperations, 0);
  });
  test(
    'native lease blocks normal and independent writers and expires after rollback',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'recovery-native-fence-',
      );
      final location = '${root.path}/main.sqlite';
      final database = AppDatabase.openFile(location);
      final other = sqlite3.open(location);
      other.execute('PRAGMA busy_timeout=0');
      AppDatabaseRecoveryLease? expired;
      try {
        await expectLater(
          database.withRecoveryDatabase((lease) async {
            expired = lease;
            expect(
              () => database.db.execute(
                "INSERT INTO profile_name_cache VALUES('user:test','normal')",
              ),
              throwsA(isA<SqliteException>()),
            );
            expect(
              () => other.execute(
                "INSERT INTO profile_name_cache VALUES('user:test','independent')",
              ),
              throwsA(isA<SqliteException>()),
            );
            expect(() => AppDatabase.openFile(location), throwsStateError);
            lease.database.execute(
              "INSERT INTO profile_name_cache VALUES('user:test','restored')",
            );
            throw StateError('synthetic failure');
          }),
          throwsStateError,
        );
        expect(database.db.select('SELECT * FROM profile_name_cache'), isEmpty);
        expect(() => expired!.database, throwsStateError);
        database.db.execute(
          "INSERT INTO profile_name_cache VALUES('user:test','preserved')",
        );
        expect(
          other
              .select('SELECT display_name FROM profile_name_cache')
              .single['display_name'],
          'preserved',
        );
      } finally {
        other.dispose();
        database.close();
        await root.delete(recursive: true);
      }
    },
  );
}
