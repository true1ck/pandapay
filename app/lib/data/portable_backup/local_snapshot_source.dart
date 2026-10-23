import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart' show Database, Row, SqliteException;

import 'canonical_ndjson.dart';
import 'portable_attachments.dart';
import 'portable_snapshot.dart';
import '../local/app_database.dart';

/// One locally persisted outbox queue that must be empty before the export.
class LocalPortableQueue {
  final String name;
  final List<Object?> args;
  final Future<void> Function()? drain;

  const LocalPortableQueue(this.name, this.args, {this.drain});
}

/// Implement [drain] against existing flush machinery (never hand-rolled) and
/// wire it by the parent integration; when it is null the queue is only
/// counted, and a nonzero count still blocks `complete: true`.
typedef LocalQueueDrain = Future<void> Function();

/// The concrete capture adapter around the account's SQLite database.
///
/// Reads rows inside one synchronous transaction so every section observes
/// the same committed state, then serialises to canonical NDJSON. The live WAL
/// file is never copied. Only rows assigned to the active account namespace
/// are exported; ownership of pre-namespace `legacy` rows cannot be proven.
///
/// ponytail: rows are materialised per section (single-account local data);
/// move to chunked streaming reads inside the transaction if an account
/// exceeds ~200k rows.
class LocalPortableSnapshotSource implements PortableLocalSnapshotSource {
  final AppDatabase appDb;
  final String namespace;
  final Map<String, LocalQueueDrain> drainHooks;

  static const List<String> declaredExclusions = <String>[
    'device tokens and biometric state',
    'device/push identifiers',
    'SMS provider cursor and inbox progress',
    'local sync cursors and cache refresh requests',
    'cached_responses blobs (server re-serves them)',
    'split_documents staging (server splits are canonical)',
    'SMS intake raw ingest log (parsed observations travel)',
    'attachment binary paths (files travel by content hash)',
  ];

  const LocalPortableSnapshotSource({
    required this.appDb,
    required this.namespace,
    this.drainHooks = const {},
  });

  List<String> get _namespaces => <String>[namespace];

  @override
  Future<PortableOutboxStatus> drainAndVerifyOutboxes({
    Future<bool> Function()? isCancelled,
  }) async {
    final counts = <String, int>{};
    for (final queue in _queues.entries) {
      if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
      final hooksEntry = drainHooks[queue.key];
      if (hooksEntry != null) await hooksEntry();
      counts[queue.key] = _count(queue.value);
    }
    return PortableOutboxStatus(counts);
  }

  Map<String, List<Object?>> get _queues {
    final args = _namespaces;
    List<Object?> namespaced(String table, {String column = 'namespace'}) => <Object?>[
          'SELECT COUNT(*) FROM $table WHERE $column = ?',
          args,
        ];
    return <String, List<Object?>>{
      'sync_pending_changes': namespaced('sync_pending_changes'),
      'transaction_outbox_entries': namespaced('transaction_outbox_entries'),
      'duplicate_resolution_outbox': namespaced('duplicate_resolution_outbox'),
      'transaction_tag_outbox': namespaced('transaction_tag_outbox'),
      'sms_facts_outbox': namespaced('sms_facts_outbox'),
      'sms_fact_override_outbox': namespaced('sms_fact_override_outbox'),
      'sms_rule_exposure_outbox': namespaced('sms_rule_exposure_outbox'),
      'sms_dismissal_outbox': namespaced('sms_dismissal_outbox'),
      'financial_pending': [
        'SELECT COUNT(*) FROM financial_entities WHERE namespace = ? AND pending = 1',
        <Object?>[namespace],
      ],
    };
  }

  int _count(List<Object?> definition) {
    final sql = definition[0] as String;
    final args = (definition.length > 1 ? definition[1] : const <Object?>[]) as List<Object?>;
    try {
      final rows = appDb.db.select(sql, args);
      final value = rows.single.values.first;
      if (value is int) return value;
      return int.parse('$value');
    } on SqliteException catch (error) {
      // Queue tables are created lazily by their owning repositories; a slot
      // that has never been written cannot hold pending work. Other SQLite
      // failures (corruption, readonly) still abort the export.
      if (error.message.contains('no such table')) return 0;
      rethrow;
    }
  }

  @override
  Future<Map<String, File>> capturePortableSections({
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    final db = appDb.db;
    final sectionRows = <String, List<Map<String, dynamic>>>{};
    db.execute('BEGIN');
    try {
      for (final entity in const ['transactions', 'cards', 'sms_observations']) {
        sectionRows[entity] = _entitySnapshot(db, entity);
      }
      sectionRows['user_categories'] = _namespacedRows(db, 'user_categories', const [
        'namespace',
        'id',
        'name',
        'slug',
        'parent_category_id',
        'parent_user_category_id',
        'match_terms_json',
        'created_at',
        'updated_at',
      ]);
      sectionRows['transaction_tags'] = _namespacedRows(db, 'transaction_tags', const [
        'namespace',
        'id',
        'name',
        'normalized_name',
        'color',
        'archived_at',
        'updated_at',
      ]);
      sectionRows['transaction_tag_links'] = _namespacedRows(db, 'transaction_tag_links', const [
        'namespace',
        'transaction_id',
        'tag_id',
        'updated_at',
        'deleted_at',
      ]);
      sectionRows['local_user_cards'] = _plainRows(db, 'local_user_cards', const [
        'id',
        'card_product_id',
        'nickname',
        'last4',
        'is_default',
        'is_archived',
        'sort_order',
        'created_at',
      ]);
      sectionRows['local_commitments'] = _namespacedRows(db, 'local_commitments', const [
        'namespace',
        'id',
        'payload',
      ]);
      sectionRows['local_needs_review'] = _namespacedRows(db, 'local_needs_review', const [
        'namespace',
        'id',
        'payload',
      ]);
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    try {
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }

    await stagingDirectory.create(recursive: true);
    final files = <String, File>{};
    for (final entry in sectionRows.entries) {
      if (entry.value.isEmpty) continue;
      if (await isCancelled?.call() == true) {
        await cleanup(files.values);
        throw const PortableBackupCancelled();
      }
      final file = File(
        '${stagingDirectory.path}${Platform.pathSeparator}section-${entry.key}.ndjson',
      );
      await writeCanonicalNdjson(Stream.fromIterable(entry.value), file, isCancelled: isCancelled);
      files[entry.key] = file;
    }
    return files;
  }

  @override
  Future<List<PortableAttachmentSource>> listPortableAttachments() async {
    List<Map<String, Object?>> rows;
    try {
      rows = appDb.db.select(
        'SELECT id, transaction_id, file_name, mime_type, local_path '
        'FROM transaction_attachments ORDER BY transaction_id, created_at, id',
      );
    } on SqliteException {
      return const [];
    }
    return <PortableAttachmentSource>[
      for (final row in rows)
        PortableAttachmentSource(
          id: row['id'] as String,
          transactionId: row['transaction_id'] as String,
          fileName: row['file_name'] as String,
          mimeType: row['mime_type'] as String?,
          localPath: row['local_path'] as String,
        ),
    ];
  }

  List<Map<String, dynamic>> _entitySnapshot(Database db, String entity) {
    final rows = db.select(
      'SELECT id, observed_at, pending, source_key, payload FROM financial_entities '
      'WHERE namespace = ? AND entity = ? ORDER BY namespace, id',
      <Object?>[..._namespaces, entity],
    );
    return <Map<String, dynamic>>[
      for (final row in rows)
        <String, dynamic>{
          'id': row['id'] as String,
          'observed_at': row['observed_at'] as int,
          'pending': row['pending'] as int,
          'source_key': row['source_key'] as String?,
          'payload': jsonDecode(row['payload'] as String) as Object?,
        },
    ];
  }

  List<Map<String, dynamic>> _namespacedRows(
    Database db,
    String table,
    List<String> columns,
  ) {
    final names = columns.join(', ');
    final ordering = columns.contains('id')
        ? 'namespace, id'
        : columns.contains('transaction_id') && columns.contains('tag_id')
            ? 'namespace, transaction_id, tag_id'
            : 'namespace';
    final rows = db.select(
      'SELECT $names FROM $table WHERE namespace = ? ORDER BY $ordering',
      _namespaces,
    );
    return <Map<String, dynamic>>[for (final row in rows) _rowMap(row)];
  }

  List<Map<String, dynamic>> _plainRows(Database db, String table, List<String> columns) {
    final names = columns.join(', ');
    final rows = db.select('SELECT $names FROM $table ORDER BY id');
    return <Map<String, dynamic>>[for (final row in rows) _rowMap(row)];
  }

  Map<String, dynamic> _rowMap(Row row) {
    final out = <String, dynamic>{};
    for (final column in row.keys) {
      final value = row[column];
      out[column] = value is String && _jsonColumns.contains(column)
          ? jsonDecode(value) as Object?
          : value;
    }
    return out;
  }
}

/// Columns that ship canonical JSON strings locally; portable records carry
/// the decoded value so section digests stay stable across sqlite string
/// quirks.
const Set<String> _jsonColumns = <String>{
  'payload',
  'match_terms_json',
};
