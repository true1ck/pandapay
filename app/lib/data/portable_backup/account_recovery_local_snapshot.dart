import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqlite3/sqlite3.dart';

import '../local/app_database.dart';
import 'account_recovery_crypto.dart';

/// A bounded account-only SQLite recovery format, distinct from the portable
/// export which deliberately requires drained outboxes. This format preserves
/// pending flags, mutation UUIDs and queue rows. It never copies another account,
/// guest wallet or server-derived unscoped cache into an account recovery upload.
class AccountRecoveryLocalSnapshot {
  static const _recoveryReceiptDirectory = 'account_recovery_receipts';
  static const _recoveryReceiptJournal = '.receipt-intents.json';
  static final _ownedReceiptName = RegExp(r'^receipt-[0-9a-f]{32}\.bin$');
  static const _maxJournalBytes = 32 * 1024;
  static const _maxTables = 128;
  static const _maxColumns = 2048;
  static const _maxScannedCells = 500000;
  static const _maxScannedBytes = 64 * 1024 * 1024;
  static const _maxScanDuration = Duration(seconds: 4);
  static const _excluded = {
    'cached_responses',
    'cache_refresh_requests',
    'local_user_cards',
    // Device registration and pull cursors must never be replayed on a new
    // device. Pending mutation rows above retain their original UUIDs.
    'sync_state',
  };
  static final _name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  static String _quote(String value) {
    if (!_name.hasMatch(value)) {
      throw const FormatException('Unsupported local table name');
    }
    return '"$value"';
  }

  static Map<String, List<String>> _tables(Database db) => {
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ))
      row['name'] as String: [
        for (final column in db.select(
          'PRAGMA table_info(${_quote(row['name'] as String)})',
        ))
          column['name'] as String,
      ],
  };
  static void _requireAccountNamespace(String accountId, String namespace) {
    if (!RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(accountId) ||
        namespace != 'user:${accountId.toLowerCase()}') {
      throw const FormatException(
        'Account recovery namespace does not match account',
      );
    }
  }

  static Object? _encodeValue(Object? value) =>
      value is Uint8List ? {'bytes_base64': base64Encode(value)} : value;
  static Object? _decodeValue(Object? value) {
    if (value is Map && value.length == 1 && value['bytes_base64'] is String) {
      return base64Decode(value['bytes_base64'] as String);
    }
    if (value == null || value is String || value is num) return value;
    throw const FormatException('Unsupported SQLite recovery value');
  }

  static Object? _canonicalJsonValue(Object? value) {
    if (value is Map) {
      if (value.keys.any((key) => key is! String)) {
        throw const FormatException('Invalid recovery coverage value');
      }
      final keys = value.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: _canonicalJsonValue(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalJsonValue).toList();
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    throw const FormatException('Invalid recovery coverage value');
  }

  static String _digestJson(Object? value) => sha256
      .convert(utf8.encode(jsonEncode(_canonicalJsonValue(value))))
      .toString();

  static Map<String, Object?> _coverageManifest({
    required String accountId,
    required String namespace,
    required bool includeReceipts,
    required Map<String, List<String>> inventory,
    required Map<String, Object?> capturedTables,
    required List<Map<String, Object?>> receipts,
  }) => {
    'version': 1,
    'account_id': accountId,
    'namespace': namespace,
    'include_receipts': includeReceipts,
    'include_unsynced': true,
    'tables': [
      for (final name in inventory.keys.toList()..sort())
        {
          'name': name,
          'columns': inventory[name],
          'row_count': (capturedTables[name] as List).length,
          'sha256': _digestJson(capturedTables[name]),
        },
    ],
    'receipts': {'count': receipts.length, 'sha256': _digestJson(receipts)},
  };

  static void _validateCoverage({
    required Map data,
    required Map<String, List<String>> schema,
    required String accountId,
    required String namespace,
  }) {
    if (!data.containsKey('coverage')) return; // Legacy v1 archive.
    final coverage = data['coverage'];
    if (coverage is! Map ||
        coverage['version'] is! int ||
        coverage['version'] != 1 ||
        coverage['account_id'] != accountId ||
        coverage['namespace'] != namespace ||
        coverage['include_receipts'] != data['include_receipts'] ||
        coverage['include_unsynced'] != data['include_unsynced'] ||
        coverage['tables'] is! List ||
        coverage['receipts'] is! Map) {
      throw const FormatException('Invalid recovery coverage manifest');
    }

    final payloadTables = data['tables'] as Map;
    if (payloadTables.keys.any((key) => key is! String)) {
      throw const FormatException('Invalid recovery coverage table');
    }
    final tableNames = <String>{};
    final declared = <String, List<String>>{};
    var columnCount = 0;
    for (final item in coverage['tables'] as List) {
      if (item is! Map ||
          item['name'] is! String ||
          !_name.hasMatch(item['name'] as String) ||
          item['columns'] is! List ||
          item['row_count'] is! int ||
          (item['row_count'] as int) < 0 ||
          item['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(item['sha256'] as String)) {
        throw const FormatException('Invalid recovery coverage table');
      }
      final name = item['name'] as String;
      if (!tableNames.add(name) || !schema.containsKey(name)) {
        throw const FormatException('Duplicate or unsupported coverage table');
      }
      if (tableNames.length > _maxTables) {
        throw const FormatException('Recovery coverage table limit exceeded');
      }
      final columns = <String>[];
      for (final column in item['columns'] as List) {
        if (column is! String ||
            !_name.hasMatch(column) ||
            !schema[name]!.contains(column) ||
            columns.contains(column)) {
          throw const FormatException('Invalid recovery coverage columns');
        }
        columns.add(column);
        if (++columnCount > _maxColumns) {
          throw const FormatException(
            'Recovery coverage column limit exceeded',
          );
        }
      }
      if (columns.isEmpty ||
          (schema[name]!.contains('namespace') &&
              !columns.contains('namespace')) ||
          _excluded.contains(name) ||
          (name != 'transaction_attachments' &&
              !schema[name]!.contains('namespace'))) {
        throw const FormatException('Invalid recovery coverage scope');
      }
      declared[name] = columns;
    }
    if (tableNames.length != payloadTables.length ||
        !tableNames.containsAll(payloadTables.keys.cast<String>())) {
      throw const FormatException('Recovery coverage table set mismatch');
    }

    for (final entry in declared.entries) {
      final rows = payloadTables[entry.key];
      final tableRecord = (coverage['tables'] as List).cast<Map>().singleWhere(
        (item) => item['name'] == entry.key,
      );
      if (rows is! List ||
          rows.length != tableRecord['row_count'] ||
          _digestJson(rows) != tableRecord['sha256']) {
        throw const FormatException('Recovery coverage table mismatch');
      }
      for (final row in rows) {
        if (row is! Map ||
            row.keys.any((key) => key is! String) ||
            row.length != entry.value.length ||
            !entry.value.toSet().containsAll(row.keys.cast<String>())) {
          throw const FormatException('Recovery coverage columns mismatch');
        }
        for (final value in row.values) {
          _decodeValue(value);
        }
        if (row.containsKey('namespace') && row['namespace'] != namespace) {
          throw const FormatException('Recovery namespace mismatch');
        }
      }
    }

    final receiptCoverage = coverage['receipts'] as Map;
    final receipts = data['receipts'] as List;
    if (data['include_receipts'] != true &&
        (declared.containsKey('transaction_attachments') ||
            receipts.isNotEmpty)) {
      throw const FormatException('Recovery receipt scope mismatch');
    }
    if (receiptCoverage['count'] is! int ||
        receiptCoverage['count'] != receipts.length ||
        receiptCoverage['sha256'] is! String ||
        !RegExp(
          r'^[0-9a-f]{64}$',
        ).hasMatch(receiptCoverage['sha256'] as String) ||
        _digestJson(receipts) != receiptCoverage['sha256']) {
      throw const FormatException('Recovery receipt coverage mismatch');
    }
  }

  static Future<Set<String>> _readReceiptJournal(Directory directory) async {
    final journal = File(path.join(directory.path, _recoveryReceiptJournal));
    if (!await journal.exists()) return <String>{};
    if (await FileSystemEntity.type(journal.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('Recovery receipt journal is unsafe');
    }
    if (await journal.length() > _maxJournalBytes) {
      throw const FormatException('Recovery receipt journal exceeds limit');
    }
    final handle = await journal.open();
    final builder = BytesBuilder(copy: false);
    try {
      while (true) {
        final chunk = await handle.read(4096);
        if (chunk.isEmpty) break;
        builder.add(chunk);
        if (builder.length > _maxJournalBytes) {
          throw const FormatException('Recovery receipt journal exceeds limit');
        }
      }
    } finally {
      await handle.close();
    }
    final bytes = builder.takeBytes();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['files'] is! List ||
        (decoded['files'] as List).length > 256) {
      throw const FormatException('Recovery receipt journal is invalid');
    }
    final names = <String>{};
    for (final name in decoded['files'] as List) {
      if (name is! String ||
          !_ownedReceiptName.hasMatch(name) ||
          !names.add(name)) {
        throw const FormatException('Recovery receipt journal is invalid');
      }
    }
    return names;
  }

  static Future<void> _writeReceiptJournal(
    Directory directory,
    Set<String> names,
  ) async {
    if (names.length > 256 ||
        names.any((name) => !_ownedReceiptName.hasMatch(name))) {
      throw const FormatException('Recovery receipt journal exceeds limit');
    }
    final journal = File(path.join(directory.path, _recoveryReceiptJournal));
    final temporary = File('${journal.path}.tmp');
    final tempType = await FileSystemEntity.type(
      temporary.path,
      followLinks: false,
    );
    if (tempType != FileSystemEntityType.notFound &&
        tempType != FileSystemEntityType.file) {
      throw const FormatException('Recovery receipt journal temp is unsafe');
    }
    if (tempType == FileSystemEntityType.file) {
      await temporary.delete();
    }
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'files': names.toList()..sort()}),
      flush: true,
    );
    await temporary.rename(journal.path);
  }

  static Future<void> _requireSafeJournalTemp(Directory directory) async {
    final temporary = File(
      path.join(directory.path, '$_recoveryReceiptJournal.tmp'),
    );
    final type = await FileSystemEntity.type(
      temporary.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('Recovery receipt journal temp is unsafe');
    }
  }

  /// Removes only unreferenced files in the dedicated recovery-owned
  /// namespace. Caller must hold the native recovery lease and operation gate.
  /// Unknown schemas, unsafe paths, and query failures preserve every file.
  static Future<int> reconcileOrphanedReceipts({
    required AppDatabaseRecoveryLease lease,
    required Directory attachmentsDirectory,
    void Function()? checkStillCurrent,
  }) async {
    final db = lease.database;
    final schema = _tables(db);
    final attachmentColumns = schema['transaction_attachments'];
    if (attachmentColumns == null ||
        !attachmentColumns.contains('local_path')) {
      throw const FormatException(
        'Receipt references cannot be verified for recovery cleanup',
      );
    }
    if (!await attachmentsDirectory.exists()) return 0;
    final root = await attachmentsDirectory.resolveSymbolicLinks();
    if (path.dirname(root) == root) {
      throw const FormatException('Private attachment directory is invalid');
    }
    final directory = Directory(path.join(root, _recoveryReceiptDirectory));
    if (!await directory.exists()) return 0;
    final resolvedDirectory = await directory.resolveSymbolicLinks();
    if (path.dirname(resolvedDirectory) != root ||
        resolvedDirectory != path.join(root, _recoveryReceiptDirectory)) {
      throw const FormatException('Recovery receipt directory is unsafe');
    }
    final names = await _readReceiptJournal(directory);
    if (names.isEmpty) return 0;
    await _requireSafeJournalTemp(directory);

    if (schema.length > _maxTables ||
        schema.values.fold<int>(0, (count, columns) => count + columns.length) >
            _maxColumns) {
      throw const FormatException(
        'Receipt reference scan schema exceeds limit',
      );
    }
    final safeFiles = <String, File>{};
    final referenced = <String>{};
    for (final name in names) {
      final entity = File(path.join(resolvedDirectory, name));
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Recovery receipt candidate is unsafe');
      }
      final realPath = await entity.resolveSymbolicLinks();
      if (realPath != path.join(resolvedDirectory, name)) {
        throw const FormatException(
          'Recovery receipt candidate path is unsafe',
        );
      }
      safeFiles[name] = entity;
    }

    final scanStarted = Stopwatch()..start();
    var scannedCells = 0;
    var scannedBytes = 0;
    for (final table in schema.entries) {
      for (final column in table.value) {
        for (var offset = 0; ; offset += 64) {
          checkStillCurrent?.call();
          final lengths = db.select(
            'SELECT CASE typeof(${_quote(column)}) '
            'WHEN \'text\' THEN length(${_quote(column)})*4 '
            'WHEN \'blob\' THEN length(${_quote(column)}) ELSE 8 END AS byte_length '
            'FROM ${_quote(table.key)} LIMIT 64 OFFSET ?',
            [offset],
          );
          if (scanStarted.elapsed > _maxScanDuration) {
            throw const FormatException(
              'Receipt reference scan exceeds work limit',
            );
          }
          for (final row in lengths) {
            scannedCells++;
            if (scannedCells > _maxScannedCells ||
                scanStarted.elapsed > _maxScanDuration) {
              throw const FormatException(
                'Receipt reference scan exceeds work limit',
              );
            }
            scannedBytes += (row['byte_length'] as int?) ?? 0;
            if (scannedBytes > _maxScannedBytes) {
              throw const FormatException(
                'Receipt reference scan exceeds byte limit',
              );
            }
          }
          final rows = db.select(
            'SELECT ${_quote(column)} FROM ${_quote(table.key)} LIMIT 64 OFFSET ?',
            [offset],
          );
          if (scanStarted.elapsed > _maxScanDuration) {
            throw const FormatException(
              'Receipt reference scan exceeds work limit',
            );
          }
          for (final row in rows) {
            final value = row[column];
            // Opaque binary cells may encode a path in a format we cannot
            // prove here. Retain every candidate rather than infer no reference.
            if (value is Uint8List && value.isNotEmpty) {
              referenced.addAll(names);
              continue;
            }
            final searchable = value is String ? value.toLowerCase() : null;
            if (searchable == null) continue;
            for (final name in names) {
              if (searchable.contains(name.toLowerCase())) {
                referenced.add(name);
              }
            }
          }
          if (rows.length < 64) break;
        }
      }
    }
    scanStarted.stop();
    checkStillCurrent?.call();

    // All schema, reference and path checks finish before the first deletion.
    var removed = 0;
    final remaining = <String>{...referenced};
    for (final entry in safeFiles.entries) {
      if (referenced.contains(entry.key)) continue;
      checkStillCurrent?.call();
      final currentType = await FileSystemEntity.type(
        entry.value.path,
        followLinks: false,
      );
      if (currentType != FileSystemEntityType.file ||
          await entry.value.resolveSymbolicLinks() != entry.value.path) {
        throw const FormatException('Recovery receipt changed during cleanup');
      }
      await entry.value.delete();
      removed++;
    }
    await _writeReceiptJournal(directory, remaining);
    return removed;
  }

  static Future<Uint8List> capture({
    required AppDatabaseRecoveryLease lease,
    required String accountId,
    required String namespace,
    required bool includeReceipts,
  }) async {
    _requireAccountNamespace(accountId, namespace);
    final db = lease.database;
    final tables = _tables(db),
        captured = <String, Object?>{},
        receipts = <Map<String, Object?>>[];
    // Independently enumerate the schema inventory that this producer is
    // responsible for. The serialized map is checked against it before its
    // coverage digest is built, so a future capture-path omission cannot be
    // hidden by describing only the rows that happened to be emitted.
    final inventory = <String, List<String>>{
      for (final entry in tables.entries)
        if (entry.value.contains('namespace') &&
            !_excluded.contains(entry.key) &&
            entry.key != 'transaction_attachments')
          entry.key: entry.value,
    };
    if (includeReceipts &&
        tables.containsKey('transaction_attachments') &&
        tables.containsKey('financial_entities')) {
      inventory['transaction_attachments'] = tables['transaction_attachments']!;
    }
    if (inventory.length > _maxTables ||
        inventory.values.fold<int>(
              0,
              (count, columns) => count + columns.length,
            ) >
            _maxColumns) {
      throw const FormatException('Local recovery schema exceeds limit');
    }
    var estimate = 0, rowCount = 0;
    db.execute('SAVEPOINT account_recovery_capture');
    try {
      final sourceRowCounts = <String, int>{};
      for (final entry in inventory.entries) {
        final count = entry.key == 'transaction_attachments'
            ? db.select(
                "SELECT COUNT(*) AS n FROM transaction_attachments a WHERE EXISTS(SELECT 1 FROM financial_entities f WHERE f.namespace=? AND f.entity='transactions' AND f.id=a.transaction_id)",
                [namespace],
              ).single['n']
            : db.select(
                'SELECT COUNT(*) AS n FROM ${_quote(entry.key)} WHERE ${_quote('namespace')}=?',
                [namespace],
              ).single['n'];
        sourceRowCounts[entry.key] = count as int;
      }
      for (final entry in tables.entries) {
        if (_excluded.contains(entry.key) ||
            entry.key == 'transaction_attachments') {
          continue;
        }
        if (!entry.value.contains('namespace')) {
          if ((db
                      .select('SELECT COUNT(*) AS n FROM ${_quote(entry.key)}')
                      .single['n']
                  as int) >
              0) {
            throw const FormatException(
              'Unscoped local data requires an ownership policy before recovery',
            );
          }
          continue;
        }
        final rows = <Map<String, Object?>>[];
        for (var offset = 0; ; offset += 100) {
          final batch = db.select(
            'SELECT * FROM ${_quote(entry.key)} WHERE namespace=? LIMIT 100 OFFSET ?',
            [namespace, offset],
          );
          for (final row in batch) {
            final value = {
              for (final column in entry.value)
                column: _encodeValue(row[column]),
            };
            estimate += utf8.encode(jsonEncode(value)).length;
            if (++rowCount > 50000 ||
                estimate > accountRecoveryMaxBytes - 4096) {
              throw const FormatException(
                'Local recovery snapshot exceeds limit',
              );
            }
            rows.add(value);
          }
          if (batch.length < 100) break;
        }
        captured[entry.key] = rows;
      }
      if (includeReceipts && tables.containsKey('transaction_attachments')) {
        if (!tables.containsKey('financial_entities')) {
          if ((db
                      .select(
                        'SELECT COUNT(*) AS n FROM transaction_attachments',
                      )
                      .single['n']
                  as int) !=
              0) {
            throw const FormatException('Receipt ownership cannot be verified');
          }
        } else {
          final metadata = <Map<String, Object?>>[];
          for (final row in db.select(
            "SELECT a.* FROM transaction_attachments a WHERE EXISTS(SELECT 1 FROM financial_entities f WHERE f.namespace=? AND f.entity='transactions' AND f.id=a.transaction_id) ORDER BY a.id",
            [namespace],
          )) {
            if (db.select(
              "SELECT 1 FROM financial_entities WHERE entity='transactions' AND id=? AND namespace<>? LIMIT 1",
              [row['transaction_id'], namespace],
            ).isNotEmpty) {
              throw const FormatException(
                'Receipt ownership is ambiguous across accounts',
              );
            }
            final source = File(row['local_path'] as String);
            if (!source.existsSync() ||
                source.lengthSync() > accountRecoveryMaxBytes) {
              throw const FormatException(
                'Recovery receipt is unavailable or too large',
              );
            }
            // No await occurs inside the SQLite read transaction: callbacks
            // using this connection cannot accidentally join our snapshot.
            final handle = source.openSync();
            late Uint8List bytes;
            try {
              bytes = handle.readSync(accountRecoveryMaxBytes + 1);
            } finally {
              handle.closeSync();
            }
            if (bytes.length > accountRecoveryMaxBytes) {
              throw const FormatException('Recovery receipt exceeds limit');
            }
            final value = {
              for (final column in tables['transaction_attachments']!)
                column: _encodeValue(row[column]),
            };
            metadata.add(value);
            final attachment = <String, Object?>{
              'id': row['id'],
              'bytes_base64': base64Encode(bytes),
              'sha256': sha256.convert(bytes).toString(),
            };
            estimate += utf8.encode(jsonEncode(attachment)).length;
            if (estimate > accountRecoveryMaxBytes - 4096) {
              throw const FormatException('Recovery receipts exceed limit');
            }
            receipts.add(attachment);
          }
          captured['transaction_attachments'] = metadata;
        }
      }
      if (captured.length != inventory.length ||
          !captured.keys.toSet().containsAll(inventory.keys)) {
        throw const FormatException(
          'Local recovery coverage inventory mismatch',
        );
      }
      for (final entry in inventory.entries) {
        final rows = captured[entry.key] as List;
        if (rows.length != sourceRowCounts[entry.key]) {
          throw const FormatException(
            'Local recovery coverage row count mismatch',
          );
        }
        for (final row in rows) {
          if (row is! Map ||
              row.length != entry.value.length ||
              !entry.value.toSet().containsAll(row.keys.cast<String>())) {
            throw const FormatException(
              'Local recovery coverage columns mismatch',
            );
          }
        }
      }
      final coverage = _coverageManifest(
        accountId: accountId,
        namespace: namespace,
        includeReceipts: includeReceipts,
        inventory: inventory,
        capturedTables: captured,
        receipts: receipts,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'pandapay-account-local-v1',
            'account_id': accountId,
            'namespace': namespace,
            'include_receipts': includeReceipts,
            'include_unsynced': true,
            'tables': captured,
            'receipts': receipts,
            'declared_exclusions': _excluded.toList(),
            'coverage': coverage,
          }),
        ),
      );
      if (bytes.length > accountRecoveryMaxBytes - 45) {
        throw const FormatException('Local recovery snapshot exceeds limit');
      }
      db.execute('RELEASE SAVEPOINT account_recovery_capture');
      return bytes;
    } catch (_) {
      db.execute('ROLLBACK TO SAVEPOINT account_recovery_capture');
      db.execute('RELEASE SAVEPOINT account_recovery_capture');
      rethrow;
    }
  }

  /// Fresh-target only: never replaces financial rows already on this phone.
  /// Existing account UUIDs and durable mutation IDs are replayed exactly.
  static Future<void> restoreFresh({
    required AppDatabaseRecoveryLease lease,
    required Uint8List payload,
    required String accountId,
    required String namespace,
    required Directory attachmentsDirectory,
  }) async {
    _requireAccountNamespace(accountId, namespace);
    final db = lease.database;
    if (payload.length > accountRecoveryMaxBytes) {
      throw const FormatException('Local recovery snapshot exceeds limit');
    }
    final data = jsonDecode(utf8.decode(payload));
    if (data is! Map ||
        data['format'] != 'pandapay-account-local-v1' ||
        data['account_id'] != accountId ||
        data['namespace'] != namespace ||
        data['include_receipts'] is! bool ||
        data['include_unsynced'] != true ||
        data['tables'] is! Map ||
        data['receipts'] is! List) {
      throw const FormatException('Invalid account recovery snapshot');
    }
    final schema = _tables(db),
        tables = data['tables'] as Map,
        installed = <File>[];
    _validateCoverage(
      data: data,
      schema: schema,
      accountId: accountId,
      namespace: namespace,
    );
    for (final entry in schema.entries) {
      if (entry.value.contains('namespace') &&
          (db.select(
                    'SELECT COUNT(*) AS n FROM ${_quote(entry.key)} WHERE namespace=?',
                    [namespace],
                  ).single['n']
                  as int) >
              0) {
        throw StateError('Account recovery requires a fresh local namespace');
      }
    }
    final transactionIds = <Object?>{};
    if (tables['financial_entities'] is List) {
      for (final row in tables['financial_entities'] as List) {
        if (row is Map &&
            row['namespace'] == namespace &&
            row['entity'] == 'transactions') {
          transactionIds.add(row['id']);
        }
      }
    }
    final expectedReceipts = <String>{};
    final attachmentRows = tables['transaction_attachments'];
    if (attachmentRows != null && attachmentRows is! List) {
      throw const FormatException('Invalid recovery attachment metadata');
    }
    for (final row in (attachmentRows as List? ?? const [])) {
      if (row is! Map ||
          row['id'] is! String ||
          !expectedReceipts.add(row['id'] as String) ||
          !transactionIds.contains(row['transaction_id'])) {
        throw const FormatException(
          'Recovery receipt has no owned transaction',
        );
      }
      if (schema.containsKey('financial_entities') &&
          db.select(
            "SELECT 1 FROM financial_entities WHERE entity='transactions' AND id=? AND namespace<>? LIMIT 1",
            [row['transaction_id'], namespace],
          ).isNotEmpty) {
        throw const FormatException('Recovery receipt ownership is ambiguous');
      }
    }
    if (data['include_receipts'] != true &&
        (expectedReceipts.isNotEmpty ||
            (data['receipts'] as List).isNotEmpty)) {
      throw const FormatException('Recovery receipt scope mismatch');
    }
    final receiptBytes = <String, Uint8List>{};
    for (final receipt in data['receipts'] as List) {
      if (receipt is! Map ||
          receipt['id'] is! String ||
          !expectedReceipts.contains(receipt['id']) ||
          receiptBytes.containsKey(receipt['id']) ||
          receipt['bytes_base64'] is! String ||
          receipt['sha256'] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(receipt['sha256'] as String)) {
        throw const FormatException('Invalid recovery receipt');
      }
      late Uint8List bytes;
      try {
        bytes = base64Decode(receipt['bytes_base64'] as String);
      } on FormatException {
        throw const FormatException('Invalid recovery receipt bytes');
      }
      if (sha256.convert(bytes).toString() != receipt['sha256']) {
        throw const FormatException('Recovery receipt checksum mismatch');
      }
      receiptBytes[receipt['id'] as String] = bytes;
    }
    if (receiptBytes.length != expectedReceipts.length) {
      throw const FormatException('Recovery receipt bytes are missing');
    }

    // No malformed archive reaches the filesystem or SQLite write path.
    await attachmentsDirectory.create(recursive: true);
    final root = await attachmentsDirectory.resolveSymbolicLinks();
    if (path.dirname(root) == root) {
      throw const FormatException('Private attachment directory is invalid');
    }
    final ownedDirectory = Directory(
      path.join(root, _recoveryReceiptDirectory),
    );
    await ownedDirectory.create(recursive: true);
    final ownedRoot = await ownedDirectory.resolveSymbolicLinks();
    if (path.dirname(ownedRoot) != root ||
        ownedRoot != path.join(root, _recoveryReceiptDirectory)) {
      throw const FormatException('Recovery receipt directory is unsafe');
    }
    final intentNames = await _readReceiptJournal(ownedDirectory);
    final receiptPaths = <String, String>{};
    var transactionStarted = false;
    try {
      for (final receipt in data['receipts'] as List) {
        final receiptId = (receipt as Map)['id'] as String;
        final bytes = receiptBytes[receiptId]!;
        final random = Random.secure();
        final token = List.generate(
          16,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        final destination = File(path.join(ownedRoot, 'receipt-$token.bin'));
        if (await destination.exists()) {
          throw StateError('Recovery attachment destination exists');
        }
        intentNames.add(path.basename(destination.path));
        await _writeReceiptJournal(ownedDirectory, intentNames);
        installed.add(destination);
        lease.removeNewFileOnRollback(destination);
        await destination.writeAsBytes(bytes, flush: true);
        receiptPaths[receiptId] = destination.path;
      }
      // Stage files first. Recheck freshness while holding the write lock,
      // then make every SQLite write synchronously with no await boundary.
      db.execute('SAVEPOINT account_recovery_restore');
      transactionStarted = true;
      db.execute('PRAGMA defer_foreign_keys=ON');
      for (final entry in _tables(db).entries) {
        if (entry.value.contains('namespace') &&
            (db.select(
                      'SELECT COUNT(*) AS n FROM ${_quote(entry.key)} WHERE namespace=?',
                      [namespace],
                    ).single['n']
                    as int) >
                0) {
          throw StateError('Account recovery requires a fresh local namespace');
        }
      }
      for (final row in (attachmentRows ?? const [])) {
        if (schema.containsKey('financial_entities') &&
            db.select(
              "SELECT 1 FROM financial_entities WHERE entity='transactions' AND id=? AND namespace<>? LIMIT 1",
              [row['transaction_id'], namespace],
            ).isNotEmpty) {
          throw const FormatException(
            'Recovery receipt ownership is ambiguous',
          );
        }
      }
      for (final entry in tables.entries) {
        final name = entry.key as String;
        if (!schema.containsKey(name) ||
            _excluded.contains(name) ||
            (!schema[name]!.contains('namespace') &&
                name != 'transaction_attachments') ||
            entry.value is! List) {
          throw const FormatException('Unsupported recovery table');
        }
        for (final row in entry.value as List) {
          if (row is! Map ||
              row.isEmpty ||
              row.keys.any(
                (key) => key is! String || !schema[name]!.contains(key),
              )) {
            throw const FormatException('Unsupported recovery columns');
          }
          final values = <String, Object?>{
            for (final value in row.entries)
              value.key as String: _decodeValue(value.value),
          };
          if (schema[name]!.contains('namespace') &&
              values['namespace'] != namespace) {
            throw const FormatException('Recovery namespace mismatch');
          }
          if (name == 'transaction_attachments') {
            final restoredPath = receiptPaths[values['id']];
            if (restoredPath == null) {
              throw const FormatException('Recovery receipt bytes are missing');
            }
            values['local_path'] = restoredPath;
          }
          if (values.containsKey('in_flight')) values['in_flight'] = 0;
          final columns = values.keys.toList();
          db.execute(
            'INSERT INTO ${_quote(name)}(${columns.map(_quote).join(',')}) VALUES(${List.filled(columns.length, '?').join(',')})',
            values.values.toList(),
          );
        }
      }
      db.execute('RELEASE SAVEPOINT account_recovery_restore');
      transactionStarted = false;
    } catch (_) {
      if (transactionStarted) {
        db.execute('ROLLBACK TO SAVEPOINT account_recovery_restore');
        db.execute('RELEASE SAVEPOINT account_recovery_restore');
      }
      for (final file in installed) {
        try {
          await file.delete();
        } on FileSystemException {
          /* Only new private copies are cleanup targets. */
        }
      }
      rethrow;
    }
  }
}
