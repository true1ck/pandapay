import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:path_provider/path_provider.dart';

import '../portable_backup/account_recovery_operation_gate.dart';
import 'local_database_key_custody.dart';

/// Fixed categories only: never propagate SQL, key literals or record values.
final class EncryptedDatabaseCopyFailure implements Exception {
  final String code;
  const EncryptedDatabaseCopyFailure(this.code);
  @override
  String toString() => 'EncryptedDatabaseCopyFailure($code)';
}

class SqliteCopyBounds {
  final int maxTables,
      maxColumns,
      maxRows,
      maxCellBytes,
      maxRowBytes,
      maxDatabaseBytes;
  final Duration deadline;
  const SqliteCopyBounds({
    this.maxTables = 128,
    this.maxColumns = 256,
    this.maxRows = 500000,
    this.maxCellBytes = 4 * 1024 * 1024,
    this.maxRowBytes = 8 * 1024 * 1024,
    this.maxDatabaseBytes = 128 * 1024 * 1024,
    this.deadline = const Duration(minutes: 2),
  });
  void validate() {
    if (maxTables < 1 ||
        maxTables > 512 ||
        maxColumns < 1 ||
        maxColumns > 512 ||
        maxRows < 1 ||
        maxRows > 1000000 ||
        maxCellBytes < 1 ||
        maxCellBytes > 16 * 1024 * 1024 ||
        maxRowBytes < maxCellBytes ||
        maxRowBytes > 32 * 1024 * 1024 ||
        maxDatabaseBytes < 4096 ||
        maxDatabaseBytes > 512 * 1024 * 1024 ||
        deadline <= Duration.zero ||
        deadline > const Duration(minutes: 5)) {
      throw const EncryptedDatabaseCopyFailure('invalid_bounds');
    }
  }
}

String _quote(String name) => '"${name.replaceAll('"', '""')}"';
final _digestPattern = RegExp(r'^[0-9a-f]{64}$');

class _DigestOutput implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) {
    digest = value;
  }

  @override
  void close() {}
}

/// A deterministic bounded schema/data contract. Values remain in the process;
/// results contain counts and digests. Ordinary rowids, SQLite storage classes,
/// text bytes, blobs, generated values and AUTOINCREMENT state are included.
final class SqliteDatabaseContract {
  final String schemaSha256, dataSha256;
  final Map<String, int> tableRows;
  final List<Map<String, Object?>> _objects;
  final List<_CopyTable> _tables;
  final int userVersion, applicationId;
  final String encoding;
  SqliteDatabaseContract._(
    this.schemaSha256,
    this.dataSha256,
    this.tableRows,
    this._objects,
    this._tables,
    this.userVersion,
    this.applicationId,
    this.encoding,
  );

  static SqliteDatabaseContract capture(
    Database db, {
    SqliteCopyBounds bounds = const SqliteCopyBounds(),
    void Function()? checkStillCurrent,
  }) {
    bounds.validate();
    final clock = Stopwatch()..start();
    void check() {
      if (clock.elapsed > bounds.deadline) {
        throw const EncryptedDatabaseCopyFailure('deadline');
      }
      checkStillCurrent?.call();
    }

    final pageCount = db.select('PRAGMA page_count').single.values.first as int;
    final pageSize = db.select('PRAGMA page_size').single.values.first as int;
    if (pageCount * pageSize > bounds.maxDatabaseBytes) {
      throw const EncryptedDatabaseCopyFailure('database_bound');
    }
    final catalogSize = db
        .select(
          'SELECT COUNT(*) n,COALESCE(MAX(length(CAST(sql AS BLOB))),0) bytes FROM main.sqlite_master',
        )
        .single;
    if ((catalogSize['n'] as int) >
            bounds.maxTables * (bounds.maxColumns + 4) ||
        (catalogSize['bytes'] as int) > 131072) {
      throw const EncryptedDatabaseCopyFailure('schema_bound');
    }
    final listed = db.select(
      "SELECT * FROM pragma_table_list WHERE schema='main' LIMIT ${bounds.maxTables + 2}",
    );
    if (listed.length > bounds.maxTables + 1) {
      throw const EncryptedDatabaseCopyFailure('table_bound');
    }
    if (listed.isEmpty) {
      throw const EncryptedDatabaseCopyFailure('unsupported_schema');
    }
    final tables = <_CopyTable>[];
    var totalRows = 0;
    for (final row in listed) {
      check();
      if (row['schema'] != 'main' ||
          row['name'] == 'sqlite_schema' ||
          row['type'] == 'view') {
        continue;
      }
      final name = row['name'] as String;
      if (row['type'] != 'table' ||
          (name.startsWith('sqlite_') && name != 'sqlite_sequence')) {
        throw const EncryptedDatabaseCopyFailure('unsupported_table');
      }
      if (tables.length >= bounds.maxTables) {
        throw const EncryptedDatabaseCopyFailure('table_bound');
      }
      final info = db.select('PRAGMA main.table_xinfo(${_quote(name)})');
      if (info.isEmpty || info.length > bounds.maxColumns) {
        throw const EncryptedDatabaseCopyFailure('column_bound');
      }
      final columns = [for (final c in info) c['name'] as String];
      final inserted = [
        for (final c in info)
          if (c['hidden'] == 0) c['name'] as String,
      ];
      final without = row['wr'] == 1;
      final primary = info.where((c) => (c['pk'] as int) > 0).toList()
        ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
      String? rowid;
      if (!without) {
        for (final alias in ['_rowid_', 'rowid', 'oid']) {
          if (!columns.any((c) => c.toLowerCase() == alias)) {
            rowid = alias;
            break;
          }
        }
        if (rowid == null) {
          throw const EncryptedDatabaseCopyFailure('hidden_rowid_unavailable');
        }
      }
      if (without && primary.isEmpty) {
        throw const EncryptedDatabaseCopyFailure('primary_key_unavailable');
      }
      final count =
          db
                  .select(
                    'SELECT COUNT(*) AS n FROM (SELECT 1 FROM ${_quote(name)} LIMIT ${bounds.maxRows + 1})',
                  )
                  .single['n']
              as int;
      totalRows += count;
      if (totalRows > bounds.maxRows) {
        throw const EncryptedDatabaseCopyFailure('row_bound');
      }
      // Length is checked inside SQLite before Dart fetches any complete cell.
      final maxima = db
          .select(
            'SELECT ${columns.map((c) => 'COALESCE(MAX(length(CAST(${_quote(c)} AS BLOB))),0)').join(',')} FROM ${_quote(name)}',
          )
          .single
          .values;
      if (maxima.any((n) => (n as int) > bounds.maxCellBytes)) {
        throw const EncryptedDatabaseCopyFailure('cell_bound');
      }
      final rowBytes =
          db
                  .select(
                    'SELECT COALESCE(MAX(${columns.map((c) => 'COALESCE(length(CAST(${_quote(c)} AS BLOB)),0)').join('+')}),0) n FROM ${_quote(name)}',
                  )
                  .single['n']
              as int;
      if (rowBytes > bounds.maxRowBytes) {
        throw const EncryptedDatabaseCopyFailure('row_byte_bound');
      }
      tables.add(
        _CopyTable(
          name,
          columns,
          inserted,
          rowid,
          primary.map((c) => c['name'] as String).toList(),
          count,
        ),
      );
    }
    tables.sort((a, b) => a.name.compareTo(b.name));
    final raw = db.select(
      "SELECT type,name,tbl_name,sql,length(sql) AS bytes FROM main.sqlite_master ORDER BY type,name",
    );
    if (raw.length > bounds.maxTables * (bounds.maxColumns + 4)) {
      throw const EncryptedDatabaseCopyFailure('schema_bound');
    }
    final objects = <Map<String, Object?>>[];
    for (final row in raw) {
      check();
      if ((row['bytes'] as int? ?? 0) > 131072) {
        throw const EncryptedDatabaseCopyFailure('schema_bound');
      }
      objects.add({
        'type': row['type'],
        'name': row['name'],
        'tbl_name': row['tbl_name'],
        'sql': row['sql'],
      });
    }
    final userVersion =
        db.select('PRAGMA user_version').single.values.first as int;
    final applicationId =
        db.select('PRAGMA application_id').single.values.first as int;
    final encoding = db.select('PRAGMA encoding').single.values.first as String;
    if (!const ['UTF-8', 'UTF-16le', 'UTF-16be'].contains(encoding)) {
      throw const EncryptedDatabaseCopyFailure('unsupported_encoding');
    }
    final schema = sha256
        .convert(
          utf8.encode(
            jsonEncode([objects, userVersion, applicationId, encoding]),
          ),
        )
        .toString();
    final output = _DigestOutput();
    // Use one ordered stream, rather than an unbounded list of row hashes.
    final data = sha256.startChunkedConversion(output);
    try {
      for (final table in tables) {
        data.add(utf8.encode(jsonEncode([table.name, table.rows])));
        final statement = db.prepare(table.selectSql);
        try {
          final cursor = statement.iterateWith(const StatementParameters([]));
          while (cursor.moveNext()) {
            check();
            data.add(
              utf8.encode(
                jsonEncode(cursor.current.values.map(_encodedValue).toList()),
              ),
            );
          }
        } finally {
          statement.dispose();
        }
      }
    } finally {
      data.close();
    }
    return SqliteDatabaseContract._(
      schema,
      output.digest!.toString(),
      Map.unmodifiable({for (final table in tables) table.name: table.rows}),
      objects,
      tables,
      userVersion,
      applicationId,
      encoding,
    );
  }

  bool matches(SqliteDatabaseContract other) =>
      schemaSha256 == other.schemaSha256 && dataSha256 == other.dataSha256;
  @override
  String toString() =>
      'SqliteDatabaseContract(schema: $schemaSha256, tables: ${tableRows.length})';
}

Object? _encodedValue(Object? value) {
  if (value == null) return null;
  if (value is int) return ['i', value.toString()];
  if (value is double) {
    final b = ByteData(8)..setFloat64(0, value, Endian.big);
    return ['r', base64Encode(b.buffer.asUint8List())];
  }
  if (value is String) return ['s', base64Encode(utf8.encode(value))];
  if (value is List<int>) return ['b', base64Encode(value)];
  throw const EncryptedDatabaseCopyFailure('unsupported_value');
}

class _CopyTable {
  final String name;
  final List<String> columns, inserted, primary;
  final String? rowid;
  final int rows;
  _CopyTable(
    this.name,
    this.columns,
    this.inserted,
    this.rowid,
    this.primary,
    this.rows,
  );
  String get selectSql =>
      'SELECT ${rowid == null ? '' : '${_quote(rowid!)},'}${columns.map((c) => "typeof(${_quote(c)}),CASE WHEN typeof(${_quote(c)})='text' THEN CAST(${_quote(c)} AS BLOB) ELSE ${_quote(c)} END").join(',')} FROM ${_quote(name)} ORDER BY ${rowid == null ? primary.map(_quote).join(',') : _quote(rowid!)}';
}

/// Capability obtained only from the mobile OS app-documents provider. Desktop
/// Documents folders are shared, so they are deliberately unsupported here.
final class AppPrivateDatabaseCopyDirectory {
  final Directory directory;
  AppPrivateDatabaseCopyDirectory._(this.directory);
  static Future<AppPrivateDatabaseCopyDirectory> documents({
    String? subdirectory,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const EncryptedDatabaseCopyFailure('platform_unsupported');
    }
    if (subdirectory != null &&
        (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,64}$').hasMatch(subdirectory))) {
      throw const EncryptedDatabaseCopyFailure('invalid_private_directory');
    }
    try {
      final supplied = await getApplicationDocumentsDirectory();
      await supplied.create(recursive: true);
      final root = Directory(await supplied.resolveSymbolicLinks());
      if (subdirectory == null) return AppPrivateDatabaseCopyDirectory._(root);
      final child = Directory(
        '${root.path}${Platform.pathSeparator}$subdirectory',
      );
      final kind = await FileSystemEntity.type(child.path, followLinks: false);
      if (kind != FileSystemEntityType.notFound &&
          kind != FileSystemEntityType.directory) {
        throw const EncryptedDatabaseCopyFailure('private_directory_state');
      }
      await child.create();
      if (await child.resolveSymbolicLinks() != child.absolute.path) {
        throw const EncryptedDatabaseCopyFailure('symlink_refused');
      }
      return AppPrivateDatabaseCopyDirectory._(child);
    } on EncryptedDatabaseCopyFailure {
      rethrow;
    } on Object {
      throw const EncryptedDatabaseCopyFailure('private_directory_unavailable');
    }
  }
}

final class VerifiedEncryptedDatabaseCopy {
  final File file;
  final int keyVersion;
  final SqliteDatabaseContract contract;
  const VerifiedEncryptedDatabaseCopy(
    this.file,
    this.keyVersion,
    this.contract,
  );
}

/// Stages and verifies a complete encrypted copy. This does not switch normal
/// startup, delete a source/partial file or promise resumable page copying.
/// Destination must be absent in the SAME trusted app-private directory.
/// Callers supply a real native disk-reserve check; it is never assumed true.
final class EncryptedDatabaseCopy {
  final SqliteCopyBounds bounds;
  const EncryptedDatabaseCopy({this.bounds = const SqliteCopyBounds()});
  Future<VerifiedEncryptedDatabaseCopy> createVerified({
    required AppPrivateDatabaseCopyDirectory privateDirectory,
    required File source,
    required File destination,
    required LocalDatabaseKeyHandle key,
    required String expectedSchemaSha256,
    required Future<bool> Function(int requiredBytes) reserveSpace,
    AccountRecoveryOperationGate? gate,
    void Function()? checkStillCurrent,
    bool Function()? shouldStop,
    void Function(int copiedRows)? onCopyProgress,
  }) async {
    bounds.validate();
    if (!_digestPattern.hasMatch(expectedSchemaSha256)) {
      throw const EncryptedDatabaseCopyFailure('reviewed_schema_required');
    }
    var createdDestination = false;
    try {
      return await (gate ?? AccountRecoveryOperationGate.process).exclusive(() async {
        await _safePaths(source, destination);
        if (await source.parent.resolveSymbolicLinks() !=
            privateDirectory.directory.path) {
          throw const EncryptedDatabaseCopyFailure(
            'private_destination_required',
          );
        }
        checkStillCurrent?.call();
        // Ordinary SQLite silently ignores PRAGMA key. Verify capability first.
        final capability = sqlite3.openInMemory();
        try {
          if (capability.select('PRAGMA cipher').isEmpty) {
            throw const EncryptedDatabaseCopyFailure('cipher_unavailable');
          }
        } finally {
          capability.dispose();
        }
        final fence = sqlite3.open(source.path, mode: OpenMode.readWrite);
        Database? reader, target;
        var locked = false, readTransaction = false, targetTransaction = false;
        final clock = Stopwatch()..start();
        var copiedRows = 0;
        void check() {
          checkStillCurrent?.call();
          if (shouldStop?.call() == true) {
            throw const EncryptedDatabaseCopyFailure('cancelled');
          }
          if (clock.elapsed > bounds.deadline) {
            throw const EncryptedDatabaseCopyFailure('deadline');
          }
        }

        try {
          fence.execute('PRAGMA busy_timeout=0');
          fence.execute('BEGIN IMMEDIATE');
          locked = true;
          reader = sqlite3.open(source.path, mode: OpenMode.readOnly);
          reader.execute('PRAGMA query_only=ON');
          reader.execute('PRAGMA temp_store=MEMORY');
          reader.execute('BEGIN');
          readTransaction = true;
          final before = SqliteDatabaseContract.capture(
            reader,
            bounds: bounds,
            checkStillCurrent: check,
          );
          if (before.schemaSha256 != expectedSchemaSha256) {
            throw const EncryptedDatabaseCopyFailure('schema_changed');
          }
          if (reader
              .select('SELECT * FROM pragma_foreign_key_check LIMIT 1')
              .isNotEmpty) {
            throw const EncryptedDatabaseCopyFailure('source_foreign_keys');
          }
          final bytes =
              (reader.select('PRAGMA page_count').single.values.first as int) *
              (reader.select('PRAGMA page_size').single.values.first as int);
          if (!await reserveSpace(
            bytes * 4 + 16 * 1024 * 1024,
          ).timeout(bounds.deadline - clock.elapsed)) {
            throw const EncryptedDatabaseCopyFailure('disk_reserve');
          }
          check();
          await destination.create(exclusive: true);
          createdDestination = true;
          target = openEncrypted(destination, key);
          target.execute("PRAGMA encoding='${before.encoding}'");
          target.execute('PRAGMA foreign_keys=OFF');
          target.execute('BEGIN IMMEDIATE');
          targetTransaction = true;
          for (final object in before._objects.where(
            (o) => o['type'] == 'table' && o['name'] != 'sqlite_sequence',
          )) {
            check();
            _createObject(target, object);
          }
          final ordered = before._tables.toList()
            ..sort(
              (a, b) => a.name == 'sqlite_sequence'
                  ? 1
                  : b.name == 'sqlite_sequence'
                  ? -1
                  : a.name.compareTo(b.name),
            );
          for (final table in ordered) {
            check();
            if (table.name == 'sqlite_sequence') {
              target.execute('DELETE FROM sqlite_sequence');
            }
            final names = [
              if (table.rowid != null) table.rowid!,
              ...table.inserted,
            ];
            final sql =
                'INSERT INTO ${_quote(table.name)} (${names.map(_quote).join(',')}) VALUES (${[if (table.rowid != null) '?', ...table.inserted.map((_) => "CASE WHEN ?='text' THEN CAST(? AS TEXT) ELSE ? END")].join(',')})';
            final query = reader.prepare(table.selectSql),
                insert = target.prepare(sql);
            try {
              final cursor = query.iterateWith(const StatementParameters([]));
              while (cursor.moveNext()) {
                check();
                final row = cursor.current,
                    values = <Object?>[
                      if (table.rowid != null) row.columnAt(0),
                    ];
                for (final name in table.inserted) {
                  final index =
                      table.columns.indexOf(name) * 2 +
                      (table.rowid == null ? 0 : 1);
                  final kind = row.columnAt(index),
                      value = row.columnAt(index + 1);
                  values.addAll([kind, value, value]);
                }
                insert.execute(values);
                onCopyProgress?.call(++copiedRows);
              }
            } finally {
              query.dispose();
              insert.dispose();
            }
          }
          for (final object in before._objects.where(
            (o) => o['type'] != 'table' && o['sql'] != null,
          )) {
            check();
            _createObject(target, object);
          }
          target.execute('PRAGMA user_version=${before.userVersion}');
          target.execute('PRAGMA application_id=${before.applicationId}');
          if (target
                  .select('SELECT * FROM pragma_foreign_key_check LIMIT 1')
                  .isNotEmpty ||
              target.select('PRAGMA integrity_check(1)').single.values.first !=
                  'ok') {
            throw const EncryptedDatabaseCopyFailure('target_integrity');
          }
          final copied = SqliteDatabaseContract.capture(
            target,
            bounds: bounds,
            checkStillCurrent: check,
          );
          if (!before.matches(copied)) {
            throw const EncryptedDatabaseCopyFailure('copy_mismatch');
          }
          target.execute('COMMIT');
          targetTransaction = false;
          target.dispose();
          target = null;
          // Reopen with the normal encrypted-reader helper before returning success.
          target = openEncrypted(destination, key);
          final reopened = SqliteDatabaseContract.capture(
            target,
            bounds: bounds,
            checkStillCurrent: check,
          );
          if (!before.matches(reopened)) {
            throw const EncryptedDatabaseCopyFailure('reopen_mismatch');
          }
          final unkeyed = sqlite3.open(
            destination.path,
            mode: OpenMode.readOnly,
          );
          var keyRequired = false;
          try {
            unkeyed.select('SELECT COUNT(*) FROM sqlite_master');
          } on SqliteException catch (error) {
            if (error.resultCode == 11 || error.resultCode == 26) {
              keyRequired = true;
            }
          } finally {
            unkeyed.dispose();
          }
          if (!keyRequired) {
            throw const EncryptedDatabaseCopyFailure('plaintext_target');
          }
          final header = await destination.open();
          try {
            if (String.fromCharCodes(await header.read(16)) ==
                'SQLite format 3\u0000') {
              throw const EncryptedDatabaseCopyFailure('plaintext_target');
            }
          } finally {
            await header.close();
          }
          return VerifiedEncryptedDatabaseCopy(
            destination,
            key.version,
            reopened,
          );
        } finally {
          if (targetTransaction) {
            try {
              target?.execute('ROLLBACK');
            } catch (_) {
              /* preserve uncertain encrypted output */
            }
          }
          target?.dispose();
          if (readTransaction) {
            try {
              reader?.execute('ROLLBACK');
            } catch (_) {}
          }
          reader?.dispose();
          if (locked) {
            try {
              fence.execute('ROLLBACK');
            } catch (_) {}
          }
          fence.dispose();
        }
      });
    } on EncryptedDatabaseCopyFailure catch (error) {
      if (createdDestination && error.code == 'plaintext_target') {
        // No success handle/path was published. Remove only this operation's
        // exclusively created output; source remains the readable authority.
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          final file = File('${destination.path}$suffix');
          if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file) {
            try {
              await file.delete();
            } catch (_) {
              /* private-root repair still required */
            }
          }
        }
      }
      rethrow;
    } on Object {
      throw const EncryptedDatabaseCopyFailure('copy_unavailable');
    }
  }

  static Database openEncrypted(File file, LocalDatabaseKeyHandle key) {
    Database? db;
    try {
      db = sqlite3.open(file.path, mode: OpenMode.readWrite);
      if (db.select('PRAGMA cipher').isEmpty) {
        throw const EncryptedDatabaseCopyFailure('cipher_unavailable');
      }
      db.execute("PRAGMA cipher='chacha20'");
      if (db.select('PRAGMA cipher').single.values.first != 'chacha20') {
        throw const EncryptedDatabaseCopyFailure('cipher_unavailable');
      }
      key.withKeyBytes((bytes) {
        final hex = bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        db!.execute("PRAGMA key='raw:$hex'");
      });
      db.execute('PRAGMA hmac_check=1');
      db.execute('PRAGMA temp_store=MEMORY');
      db.execute('PRAGMA busy_timeout=0');
      db.execute('PRAGMA synchronous=FULL');
      db.select('SELECT COUNT(*) FROM sqlite_master');
      return db;
    } on Object {
      db?.dispose();
      throw const EncryptedDatabaseCopyFailure('encrypted_open_failed');
    }
  }

  static void _createObject(Database target, Map<String, Object?> object) {
    final sql = object['sql'];
    final kind = object['type'];
    if (sql is! String ||
        !RegExp(
          '^CREATE\\s+(?:UNIQUE\\s+)?$kind\\b',
          caseSensitive: false,
        ).hasMatch(sql)) {
      throw const EncryptedDatabaseCopyFailure('unsupported_definition');
    }
    final statement = target.prepare(sql, checkNoTail: true);
    try {
      statement.execute();
    } finally {
      statement.dispose();
    }
  }

  static Future<void> _safePaths(File source, File destination) async {
    for (final file in [source, destination]) {
      var directory = file.absolute.parent;
      while (true) {
        if (await FileSystemEntity.type(directory.path, followLinks: false) ==
            FileSystemEntityType.link) {
          final expected = (Platform.isMacOS || Platform.isIOS)
              ? const {
                  '/var': '/private/var',
                  '/tmp': '/private/tmp',
                }[directory.path]
              : null;
          if (expected == null ||
              await directory.resolveSymbolicLinks() != expected) {
            throw const EncryptedDatabaseCopyFailure('symlink_refused');
          }
        }
        if (directory.parent.path == directory.path) break;
        directory = directory.parent;
      }
    }
    final parent = await source.parent.resolveSymbolicLinks();
    if (await destination.parent.resolveSymbolicLinks() != parent ||
        source.absolute.path == destination.absolute.path) {
      throw const EncryptedDatabaseCopyFailure('private_destination_required');
    }
    for (final file in [source, destination]) {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const EncryptedDatabaseCopyFailure('symlink_refused');
      }
    }
    for (final suffix in ['-wal', '-shm', '-journal']) {
      if (await FileSystemEntity.type(
            '${destination.path}$suffix',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw const EncryptedDatabaseCopyFailure('file_state');
      }
    }
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const EncryptedDatabaseCopyFailure('file_state');
    }
  }
}
