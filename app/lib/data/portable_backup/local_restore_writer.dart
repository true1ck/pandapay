import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' show Database, SqliteException;

import 'portable_backup.dart';
import '../local/app_database.dart';

/// Fresh-target gate for the raw-sqlite3 database: the namespace must hold
/// no portable rows and no attachment metadata before a restore may wipe it.
class LocalPortableRestoreTargetInspector implements PortableRestoreTargetInspector {
  final AppDatabase appDb;
  final String namespace;

  const LocalPortableRestoreTargetInspector({required this.appDb, required this.namespace});

  static const _portableRowCounts = <String>[
    'SELECT COUNT(*) FROM financial_entities WHERE namespace IN (?, ?)',
    'SELECT COUNT(*) FROM user_categories WHERE namespace IN (?, ?)',
    'SELECT COUNT(*) FROM transaction_tags WHERE namespace IN (?, ?)',
    'SELECT COUNT(*) FROM transaction_tag_links WHERE namespace IN (?, ?)',
    'SELECT COUNT(*) FROM local_commitments WHERE namespace IN (?, ?)',
    'SELECT COUNT(*) FROM local_needs_review WHERE namespace IN (?, ?)',
  ];

  int _rowCount(String sql, List<Object?> args) {
    try {
      final value = appDb.db.select(sql, args).single.values.first;
      return value is int ? value : int.tryParse('$value') ?? 0;
    } on SqliteException {
      // ponytail: table never created in this build = zero rows.
      return 0;
    }
  }

  int _attachmentCount() => _rowCount('SELECT COUNT(*) FROM transaction_attachments', const []);

  @override
  Future<PortableFreshNamespaceState> inspectFreshNamespace() async {
    final args = <Object?>[namespace, 'legacy'];
    var portableRows = 0;
    for (final sql in _portableRowCounts) {
      portableRows += _rowCount(sql, args);
    }
    final attachments = _attachmentCount();
    return PortableFreshNamespaceState(hasPortableRows: portableRows > 0, hasAttachments: attachments > 0);
  }
}

/// Concrete restore writer over the account's raw-sqlite3 `AppDatabase`.
///
/// Everything happens inside one SQLite write transaction started by
/// [beginFreshNamespace]; inserts replay exactly what
/// [LocalPortableSnapshotSource] exported, so source -> restore -> source
/// recapture must be byte-identical.
///
/// ponytail: attachment files land in [attachmentsDirectory] named by
/// metadata id and `local_path` is stored as that relative name; move to
/// configurable sub-paths only if the attachment picker actually shows them.
class LocalPortableRestoreWriter implements PortableLocalRestoreWriter {
  final AppDatabase appDb;
  final String namespace;
  final Directory attachmentsDirectory;

  const LocalPortableRestoreWriter({
    required this.appDb,
    required this.namespace,
    required this.attachmentsDirectory,
  });

  Database get _db => appDb.db;
  List<String> get _wipeNamespaces => <String>[namespace, 'legacy'];

  static const _namespacedTables = <String>[
    'user_categories',
    'transaction_tags',
    'transaction_tag_links',
    'local_commitments',
    'local_needs_review',
  ];

  @override
  Future<void> beginFreshNamespace() async {
    _db.execute('BEGIN IMMEDIATE');
    final args = _wipeNamespaces;
    try {
      for (final statement in <String>[
      'DELETE FROM financial_entities WHERE namespace IN (?, ?)',
      'DELETE FROM sync_pending_changes WHERE namespace IN (?, ?)',
      'DELETE FROM transaction_tags WHERE namespace IN (?, ?)',
      'DELETE FROM user_categories WHERE namespace IN (?, ?)',
      for (final table in <String>['transaction_tag_links', 'transaction_tag_outbox'])
        'DELETE FROM $table WHERE namespace IN (?, ?)',
      for (final table in <String>[
        'local_commitments',
        'local_needs_review',
        'duplicate_resolution_outbox',
        'transaction_outbox_entries',
        'sms_facts_outbox',
        'sms_fact_override_outbox',
        'sms_rule_exposure_outbox',
        'sms_dismissal_outbox',
      ])
        'DELETE FROM $table WHERE namespace IN (?, ?)',
      'DELETE FROM local_user_cards',
      'DELETE FROM transaction_attachments',
      ]) {
        try {
          _db.execute(statement, statement.contains('(?, ?)') ? args : const <Object?>[]);
        } on SqliteException catch (error) {
          if (!error.message.contains('no such table')) rethrow;
        }
      }
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  Future<void> insertPortableRows(
    String sectionName,
    Stream<Map<String, dynamic>> rows,
  ) async {
    switch (sectionName) {
      case 'transactions':
      case 'cards':
      case 'local_user_cards':
        break;
      default:
        if (!_namespacedTables.contains(sectionName)) {
          throw FormatException('unsupported portable section $sectionName');
        }
    }
    await for (final row in rows) {
      switch (sectionName) {
        case 'transactions':
        case 'cards':
          _insertFinancialEntity(sectionName, row);
        case 'local_user_cards':
          _insertVerbatim('local_user_cards', row, const [
            'id',
            'card_product_id',
            'nickname',
            'last4',
            'is_default',
            'is_archived',
            'sort_order',
            'created_at',
          ]);
        default:
          _insertNamespacedRaw(sectionName, row);
      }
    }
  }

  @override
  Future<void> insertHistoricalSmsRows(
    String sectionName,
    Stream<Map<String, dynamic>> rows,
  ) async {
    await for (final row in rows) {
      _insertFinancialEntity(sectionName, row);
    }
  }

  void _insertFinancialEntity(String entity, Map<String, dynamic> envelope) {
    _db.execute(
      'INSERT INTO financial_entities(namespace, entity, id, payload, observed_at, pending, '
      'source_key, occurred_at, amount_paise) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(namespace, entity, id) DO UPDATE SET payload=excluded.payload, '
      'observed_at=excluded.observed_at, pending=excluded.pending, source_key=excluded.source_key',
      <Object?>[
        namespace,
        entity,
        envelope['id'],
        jsonEncode(envelope['payload']),
        envelope['observed_at'],
        envelope['pending'] is int ? envelope['pending'] : 0,
        envelope['source_key'],
        null,
        null,
      ],
    );
  }

  void _insertNamespacedRaw(String table, Map<String, dynamic> row) {    final columns = row.keys.toList(growable: false);
    for (final c in columns) {
      if (c == 'namespace' || c == 'id') continue;
      if (!_knownColumns(table).contains(c)) {
        throw FormatException('unexpected column $c in section $table');
      }
    }
    final keys = _keyColumns(table);
    final data = _knownColumns(table).where(row.keys.contains).toList(growable: false);
    final names = <String>['namespace', ...keys, ...data];
    final placeholders = List.filled(names.length, '?').join(', ');
    final updated = data.map((n) => '$n=excluded.$n').join(', ');
    final sql = updated.isEmpty
        ? "INSERT INTO $table(${names.join(', ')}) VALUES ($placeholders)"
        : "INSERT INTO $table(${names.join(', ')}) VALUES ($placeholders) "
            "ON CONFLICT(${_conflictKey(table)}) DO UPDATE SET $updated";
    _db.execute(
      sql,
      <Object?>[
        for (final n in names)
          n == 'namespace' ? (row['namespace'] ?? namespace) : _bindValue(n, row[n]),
      ],
    );
  }

  List<String> _keyColumns(String table) => switch (table) {
        'transaction_tag_links' => const ['transaction_id', 'tag_id'],
        _ => const ['id'],
      };

  /// Export decodes stored JSON strings into portable values; bind time must
  /// re-encode exactly those columns.
  static const _jsonValues = <String>{'match_terms_json', 'payload'};

  static Object? _bindValue(String column, Object? value) =>
      value != null && value is! String && value is! num && value is! bool && value is! List<int> && _jsonValues.contains(column)
          ? jsonEncode(value)
          : value;

  String _conflictKey(String table) => switch (table) {
        'transaction_tag_links' => 'namespace, transaction_id, tag_id',
        _ => 'namespace, id',
      };

  List<String> _knownColumns(String table) => switch (table) {
        'user_categories' => const [
            'name',
            'slug',
            'parent_category_id',
            'parent_user_category_id',
            'match_terms_json',
            'created_at',
            'updated_at',
          ],
        'transaction_tags' => const [
            'name',
            'normalized_name',
            'color',
            'archived_at',
            'updated_at',
          ],
        'transaction_tag_links' => const [
            'transaction_id',
            'tag_id',
            'updated_at',
            'deleted_at',
          ],
        'local_commitments' || 'local_needs_review' => const ['payload'],
        _ => const [],
      };

  void _insertVerbatim(String table, Map<String, dynamic> row, List<String> columns) {
    for (final c in row.keys) {
      if (!columns.contains(c)) throw FormatException('unexpected column $c in section $table');
    }
    final names = columns.where(row.keys.contains).toList(growable: false);
    _db.execute(
      'INSERT INTO $table(${names.join(', ')}) '
      'VALUES (${List.filled(names.length, '?').join(', ')}) '
      'ON CONFLICT(id) DO UPDATE SET ${names.map((n) => '$n=excluded.$n').join(', ')}',
      <Object?>[for (final n in names) row[n]],
    );
  }

  @override
  Future<void> installAttachment({
    required PortableBackupAttachment metadata,
    required File stagedFile,
  }) async {
    await attachmentsDirectory.create(recursive: true);
    final target = File('${attachmentsDirectory.path}${Platform.pathSeparator}${metadata.id}');
    await stagedFile.copy(target.path);
    _db.execute(
      'INSERT INTO transaction_attachments(id, transaction_id, file_name, local_path, mime_type, '
      'created_at) VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET transaction_id=excluded.transaction_id, '
      'file_name=excluded.file_name, local_path=excluded.local_path, '
      'mime_type=excluded.mime_type, created_at=excluded.created_at',
      <Object?>[
        metadata.id,
        metadata.transactionId,
        metadata.fileName,
        metadata.id,
        metadata.mimeType,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  @override
  Future<void> rebuildDeclaredProjections() async {
    final rows = _db.select(
      "SELECT id, payload FROM financial_entities WHERE entity = 'transactions' AND namespace = ?",
      <Object?>[namespace],
    );
    for (final row in rows) {
      final payload = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      int? occurredAt;
      int? amountPaise;
      // Mirrors FinancialStore._upsert, which derives projections from
      // TransactionEntry.fromJson(body).amount.paise == round(amountInr*100).
      final amountInrDouble = _numLike(payload['amount_inr']);
      try {
        occurredAt = DateTime.parse(payload['occurred_at'] as String).millisecondsSinceEpoch;
        amountPaise = (amountInrDouble * 100).round();
      } catch (_) {
        // ponytail: malformed historical payload keeps null projections like
        // a fresh import would; upgrade to typed repair pass if a real
        // device reports one.
        occurredAt = null;
        amountPaise = null;
      }
      _db.execute(
        'UPDATE financial_entities SET occurred_at = ?, amount_paise = ? WHERE namespace = ? AND id = ?',
        <Object?>[occurredAt, amountPaise, namespace, row['id']],
      );
    }
  }

  /// Mirrors the private `_num` in user_cards_repository so restored
  /// `amount_paise` matches a live FinancialStore import exactly
  /// (null collapses to 0 rupees, strings like "249.00" parse fine).
  static double _numLike(Object? v) => v == null
      ? 0
      : (v is num ? v.toDouble() : double.parse(v as String));

  @override
  Future<void> commit() async => _db.execute('COMMIT');

  @override
  Future<void> rollback() async {
    try {
      _db.execute('ROLLBACK');
    } on SqliteException {
      // No active transaction (e.g. double rollback after commit).
    }
  }
}
