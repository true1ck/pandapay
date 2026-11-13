import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/local_first_schema.dart';
import 'package:sqlite3/sqlite3.dart';

bool _hasTable(Database db, String name) => db
    .select("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [name])
    .isNotEmpty;

const _nsTable =
    'namespace TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(namespace, id)';

void main() {
  group('LocalFirstSchema', () {
    test('opening AppDatabase creates the module version table', () {
      final app = openInMemoryForTesting();
      addTearDown(app.close);
      expect(_hasTable(app.db, LocalFirstSchema.versionTable), isTrue);
      // It never touches the legacy user_version (that is AppDatabase's).
      expect(app.db.select('PRAGMA user_version').single.values.first, 3);
    });

    test('runs outstanding migrations in order and records the version', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final ran = <int>[];
      final migrations = <LocalFirstMigration>[
        (d) {
          ran.add(1);
          d.execute('CREATE TABLE IF NOT EXISTS lf_a ($_nsTable)');
        },
        (d) {
          ran.add(2);
          d.execute('CREATE TABLE IF NOT EXISTS lf_b ($_nsTable)');
        },
      ];
      expect(LocalFirstSchema.ensure(db, migrations: migrations), isTrue);
      expect(ran, [1, 2]);
      expect(LocalFirstSchema.installedVersion(db), 2);
      // A second call is a no-op.
      expect(LocalFirstSchema.ensure(db, migrations: migrations), isTrue);
      expect(ran, [1, 2]);
    });

    test('only the migrations after the installed version run', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final ran = <int>[];
      LocalFirstSchema.ensure(db, migrations: [(_) => ran.add(1)]);
      LocalFirstSchema.ensure(
        db,
        migrations: [(_) => ran.add(1), (_) => ran.add(2), (_) => ran.add(3)],
      );
      expect(ran, [1, 2, 3]);
      expect(LocalFirstSchema.installedVersion(db), 3);
    });

    test('a failing migration rolls the whole run back and can be repeated', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      var fail = true;
      final migrations = <LocalFirstMigration>[
        (d) => d.execute('CREATE TABLE IF NOT EXISTS lf_ok ($_nsTable)'),
        (d) {
          d.execute('CREATE TABLE IF NOT EXISTS lf_half ($_nsTable)');
          if (fail) throw StateError('boom');
        },
      ];
      expect(
        () => LocalFirstSchema.ensure(db, migrations: migrations),
        throwsStateError,
      );
      expect(_hasTable(db, 'lf_ok'), isFalse);
      expect(_hasTable(db, 'lf_half'), isFalse);
      expect(LocalFirstSchema.installedVersion(db), isNull);
      fail = false;
      expect(LocalFirstSchema.ensure(db, migrations: migrations), isTrue);
      expect(_hasTable(db, 'lf_ok'), isTrue);
      expect(_hasTable(db, 'lf_half'), isTrue);
      expect(LocalFirstSchema.installedVersion(db), 2);
    });

    test('a database from a newer app is left alone', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      LocalFirstSchema.ensure(db, migrations: [(_) {}, (_) {}, (_) {}]);
      var ran = false;
      expect(
        LocalFirstSchema.ensure(db, migrations: [(_) => ran = true]),
        isFalse,
      );
      expect(ran, isFalse);
      expect(LocalFirstSchema.installedVersion(db), 3);
    });

    test('addColumnIfMissing is idempotent and skips missing tables', () {
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      LocalFirstSchema.addColumnIfMissing(
        db,
        't',
        'c',
        'INTEGER NOT NULL DEFAULT 0',
      );
      LocalFirstSchema.addColumnIfMissing(
        db,
        't',
        'c',
        'INTEGER NOT NULL DEFAULT 0',
      );
      expect(
        db.select('PRAGMA table_info(t)').where((r) => r['name'] == 'c'),
        hasLength(1),
      );
      LocalFirstSchema.addColumnIfMissing(db, 'missing', 'c', 'TEXT');
      expect(_hasTable(db, 'missing'), isFalse);
    });

    test('opening AppDatabase twice on one connection is harmless', () {
      final raw = sqlite3.openInMemory();
      AppDatabase.forTesting(raw);
      final second = AppDatabase.forTesting(raw);
      addTearDown(second.close);
      expect(
        LocalFirstSchema.installedVersion(raw) ?? 0,
        LocalFirstSchema.version,
      );
    });
  });
}
