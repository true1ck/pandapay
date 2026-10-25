import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/secure_storage/encrypted_database_copy.dart';
import 'package:pandapay/data/secure_storage/flutter_secure_key_value_store.dart';
import 'package:pandapay/data/secure_storage/local_database_key_custody.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'full application schema copies encrypted with guest/account queues and preserved IDs',
    (tester) async {
      final owned = await AppPrivateDatabaseCopyDirectory.documents(
        subdirectory: 'copy-fixture-${DateTime.now().microsecondsSinceEpoch}',
      );
      final dir = owned.directory;
      final source = File('${dir.path}/source.sqlite'),
          target = File('${dir.path}/encrypted.sqlite');
      final adapter = FlutterSecureKeyValueStore(
        prefix: 'fixture-copy-${DateTime.now().microsecondsSinceEpoch}.',
      );
      final custody = LocalDatabaseKeyCustody(adapter);
      final key = (await custody.openKey(
        installId: 'fixture-install',
        encryptedManifestExists: false,
      )).handle!;
      final app = AppDatabase.openFile(source.path);
      try {
        app.db.execute(
          "INSERT INTO profile_name_cache VALUES('guest:fixture','Guest'),('user:fixture','Account')",
        );
        app.db.execute(
          "INSERT INTO transaction_outbox_entries(id,amount_paise,created_at,client_mutation_id,namespace) VALUES(17,50000,1,'original-mutation','user:fixture')",
        );
        final before = SqliteDatabaseContract.capture(app.db);
        var reserveChecked = false;
        final result = await const EncryptedDatabaseCopy().createVerified(
          privateDirectory: owned,
          source: source,
          destination: target,
          key: key,
          expectedSchemaSha256: before.schemaSha256,
          reserveSpace: (required) async {
            reserveChecked = true;
            expect(required, greaterThan(16 * 1024 * 1024));
            expect(
              () => app.db.execute(
                "UPDATE profile_name_cache SET display_name='blocked'",
              ),
              throwsA(isA<SqliteException>()),
            );
            return true; // Synthetic fixture only; production needs real native disk policy.
          },
        );
        expect(reserveChecked, true);
        expect(result.contract.matches(before), true);
        expect(SqliteDatabaseContract.capture(app.db).matches(before), true);
        final reopened = EncryptedDatabaseCopy.openEncrypted(target, key);
        try {
          expect(
            reopened
                .select(
                  'SELECT client_mutation_id FROM transaction_outbox_entries WHERE id=17',
                )
                .single
                .values
                .first,
            'original-mutation',
          );
          expect(
            reopened
                .select('SELECT COUNT(*) n FROM profile_name_cache')
                .single['n'],
            2,
          );
        } finally {
          reopened.dispose();
        }
        app.db.execute(
          "UPDATE profile_name_cache SET display_name='after-copy' WHERE namespace='guest:fixture'",
        );
        final missing = sqlite3.open(target.path, mode: OpenMode.readOnly);
        try {
          expect(
            () => missing.select('SELECT * FROM profile_name_cache'),
            throwsA(isA<SqliteException>()),
          );
        } finally {
          missing.dispose();
        }
      } finally {
        app.close();
        key.dispose();
        await adapter.delete('pandapay.localdb.key_metadata.v1');
        await adapter.delete('pandapay.localdb.key.v1.1');
        await dir.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'copy preserves rowids, raw text bytes, generated columns and sequence; failures preserve source',
    (tester) async {
      final owned = await AppPrivateDatabaseCopyDirectory.documents(
        subdirectory: 'rich-fixture-${DateTime.now().microsecondsSinceEpoch}',
      );
      final dir = owned.directory;
      final file = File('${dir.path}/source.sqlite');
      final db = sqlite3.open(file.path);
      final adapter = FlutterSecureKeyValueStore(
        prefix: 'fixture-rich-${DateTime.now().microsecondsSinceEpoch}.',
      );
      final key = (await LocalDatabaseKeyCustody(adapter).openKey(
        installId: 'fixture-rich',
        encryptedManifestExists: false,
      )).handle!;
      try {
        db.execute(
          "CREATE TABLE items(id TEXT PRIMARY KEY,value BLOB,derived TEXT GENERATED ALWAYS AS (id || '!') VIRTUAL)",
        );
        db.execute(
          "INSERT INTO items(rowid,id,value) VALUES(-9,'kept',CAST(x'ff' AS TEXT)),(52,'blob',x'00ff')",
        );
        db.execute(
          'CREATE TABLE queue(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT)',
        );
        db.execute("INSERT INTO queue VALUES(100,'gone')");
        db.execute('DELETE FROM queue');
        db.execute(
          'CREATE TABLE keyed(a TEXT,b INTEGER,value REAL,PRIMARY KEY(a,b)) WITHOUT ROWID',
        );
        db.execute("INSERT INTO keyed VALUES('value',3,1.5)");
        db.execute('CREATE INDEX item_value ON items(value)');
        db.execute('CREATE VIEW item_view AS SELECT id FROM items');
        db.execute('PRAGMA user_version=27');
        db.execute('PRAGMA application_id=1234');
        final before = SqliteDatabaseContract.capture(db),
            target = File('${dir.path}/encrypted.sqlite');
        final result = await const EncryptedDatabaseCopy().createVerified(
          privateDirectory: owned,
          source: file,
          destination: target,
          key: key,
          expectedSchemaSha256: before.schemaSha256,
          reserveSpace: (_) async => true,
        );
        expect(result.contract.matches(before), true);
        final reopened = EncryptedDatabaseCopy.openEncrypted(target, key);
        try {
          expect(
            reopened
                .select("SELECT hex(value) v FROM items WHERE id='kept'")
                .single['v'],
            'FF',
          );
          expect(
            reopened.select('PRAGMA user_version').single.values.first,
            27,
          );
          reopened.execute("INSERT INTO queue(value) VALUES('next')");
          expect(reopened.select('SELECT id FROM queue').single['id'], 101);
        } finally {
          reopened.dispose();
        }
        final denied = File('${dir.path}/denied.sqlite');
        await expectLater(
          const EncryptedDatabaseCopy().createVerified(
            privateDirectory: owned,
            source: file,
            destination: denied,
            key: key,
            expectedSchemaSha256: before.schemaSha256,
            reserveSpace: (_) async => false,
          ),
          throwsA(isA<EncryptedDatabaseCopyFailure>()),
        );
        expect(await denied.exists(), false);
        expect(before.matches(SqliteDatabaseContract.capture(db)), true);
        final cancelled = File('${dir.path}/cancelled.sqlite');
        var copiedRows = 0;
        await expectLater(
          const EncryptedDatabaseCopy().createVerified(
            privateDirectory: owned,
            source: file,
            destination: cancelled,
            key: key,
            expectedSchemaSha256: before.schemaSha256,
            reserveSpace: (_) async {
              return true;
            },
            onCopyProgress: (rows) => copiedRows = rows,
            shouldStop: () => copiedRows > 0,
          ),
          throwsA(isA<EncryptedDatabaseCopyFailure>()),
        );
        expect(before.matches(SqliteDatabaseContract.capture(db)), true);
        expect(copiedRows, 1);
        expect(
          await cancelled.exists(),
          true,
        ); // Unpublished private partial; original is authoritative.
        db.execute(
          "INSERT INTO queue(value) VALUES('source-remains-writable')",
        );
      } finally {
        db.dispose();
        key.dispose();
        await adapter.delete('pandapay.localdb.key_metadata.v1');
        await adapter.delete('pandapay.localdb.key.v1.1');
        await dir.delete(recursive: true);
      }
    },
  );
}
