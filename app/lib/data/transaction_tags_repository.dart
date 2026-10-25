import 'portable_backup/account_recovery_operation_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'api_exception.dart';
import 'local/app_database.dart';
import 'user_cards_repository.dart';

export 'user_cards_repository.dart' show TransactionTag;

/// Account-scoped tag intent. Financial writes never pass through this store.
/// Each link has its own durable operation, so changes on different devices
/// cannot overwrite an entire transaction's tag set.
class TransactionTagsRepository extends ChangeNotifier {
  final AppDatabase database;
  final String namespace;
  final String apiBaseUrl;
  final String accessToken;
  final http.Client client;
  final VoidCallback? onChanged;
  bool isSyncing = false;
  Future<void>? _syncFuture;
  bool _syncAgain = false;
  bool _disposed = false;
  String? lastError;
  Map<String, List<TransactionTag>>? _assignmentCache;
  Map<String, String>? _aliasCache;
  Set<String>? _knownCache;
  bool? _snapshotCache;

  void _invalidateCache() {
    _assignmentCache = null;
    _aliasCache = null;
    _knownCache = null;
    _snapshotCache = null;
  }

  TransactionTagsRepository({
    required this.database,
    required this.namespace,
    required this.apiBaseUrl,
    required this.accessToken,
    required this.client,
    this.onChanged,
  });

  List<TransactionTag> get allTags => database.db
      .select(
        'SELECT * FROM transaction_tags WHERE namespace=? ORDER BY normalized_name',
        [namespace],
      )
      .map((r) => TransactionTag.fromJson(Map<String, dynamic>.from(r)))
      .toList();
  List<TransactionTag> get tags => allTags.where((t) => !t.isArchived).toList();
  int get pendingCount =>
      database.db.select(
            'SELECT count(*) n FROM transaction_tag_outbox WHERE namespace=?',
            [namespace],
          ).single['n']
          as int;
  bool get hasSnapshot => _snapshotCache ??= database.db.select(
    'SELECT 1 FROM transaction_tag_sync_state WHERE namespace=?',
    [namespace],
  ).isNotEmpty;

  String _canonical(String id) {
    final aliases = _aliasCache ??= {
      for (final row in database.db.select(
        'SELECT local_id,transaction_id FROM transaction_tag_aliases WHERE namespace=?',
        [namespace],
      ))
        row['local_id'] as String: row['transaction_id'] as String,
    };
    final visited = <String>{};
    while (visited.add(id)) {
      final next = aliases[id];
      if (next == null) break;
      id = next;
    }
    return id;
  }

  List<TransactionTag> tagsForTransaction(
    String transactionId, {
    List<TransactionTag> fallback = const [],
  }) {
    final id = _canonical(transactionId);
    final known =
        hasSnapshot ||
        (_knownCache ??= {
          for (final row in database.db.select(
            'SELECT transaction_id FROM transaction_tag_known_transactions WHERE namespace=?',
            [namespace],
          ))
            row['transaction_id'] as String,
        }).contains(id);
    if (!known) return fallback;
    if (_assignmentCache == null) {
      final result = <String, List<TransactionTag>>{};
      for (final row in database.db.select(
        '''SELECT t.*,l.transaction_id FROM transaction_tags t
      JOIN transaction_tag_links l ON l.namespace=t.namespace AND l.tag_id=t.id
      WHERE l.namespace=? AND l.deleted_at IS NULL ORDER BY t.normalized_name''',
        [namespace],
      )) {
        result
            .putIfAbsent(row['transaction_id'] as String, () => [])
            .add(TransactionTag.fromJson(Map<String, dynamic>.from(row)));
      }
      _assignmentCache = result.map(
        (id, tags) => MapEntry(id, List.unmodifiable(tags)),
      );
    }
    return _assignmentCache![id] ?? const [];
  }

  int usageCount(String id) =>
      database.db.select(
            'SELECT count(DISTINCT transaction_id) n FROM transaction_tag_links WHERE namespace=? AND tag_id=? AND deleted_at IS NULL',
            [namespace, id],
          ).single['n']
          as int;

  String _name(String name) => name.trim().replaceAll(RegExp(r'\s+'), ' ');
  void _atomic(void Function() action) {
    database.db.execute('BEGIN IMMEDIATE');
    try {
      action();
      database.db.execute('COMMIT');
    } catch (_) {
      database.db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _validate(String name, String? color, {String? except}) {
    if (name.isEmpty || name.length > 60)
      throw ArgumentError('Use a tag name with 1–60 characters.');
    if (color != null && !RegExp(r'^#[\da-fA-F]{6}$').hasMatch(color))
      throw ArgumentError('Invalid tag color.');
    if (tags.any(
      (t) =>
          t.id != except && _name(t.name).toLowerCase() == name.toLowerCase(),
    )) {
      throw ArgumentError('A tag with that name already exists.');
    }
  }

  Future<TransactionTag> create(String name, [String? color]) async {
    final value = _name(name);
    _validate(value, color);
    final tag = TransactionTag(
      id: const Uuid().v4(),
      name: value,
      color: color,
      updatedAt: DateTime.now().toUtc(),
    );
    _atomic(() {
      _upsert(tag);
      _queueTag(tag);
    });
    _changed();
    return tag;
  }

  Future<void> rename(String id, String name, {String? color}) async {
    final old = allTags.firstWhere((t) => t.id == id);
    final value = _name(name);
    _validate(value, color, except: id);
    final tag = TransactionTag(
      id: id,
      name: value,
      color: color,
      archivedAt: old.archivedAt,
      updatedAt: DateTime.now().toUtc(),
    );
    _atomic(() {
      _upsert(tag);
      _queueTag(tag);
    });
    _changed();
  }

  Future<void> archive(String id, [bool archived = true]) async {
    final old = allTags.firstWhere((t) => t.id == id);
    if (!archived) _validate(old.name, old.color, except: id);
    final at = DateTime.now().toUtc();
    final tag = TransactionTag(
      id: id,
      name: old.name,
      color: old.color,
      archivedAt: archived ? at : null,
      updatedAt: at,
    );
    _atomic(() {
      _upsert(tag);
      _queueTag(tag);
    });
    _changed();
  }

  Future<void> assign(List<String> transactionIds, List<String> tagIds) async =>
      _set(transactionIds, tagIds, false);
  Future<void> unassign(
    List<String> transactionIds,
    List<String> tagIds,
  ) async => _set(transactionIds, tagIds, true);
  Future<void> replace(
    String transactionId,
    Set<String> selected, {
    List<TransactionTag> fallback = const [],
  }) async {
    final current = tagsForTransaction(
      transactionId,
      fallback: fallback,
    ).map((t) => t.id).toSet();
    await assign([transactionId], selected.difference(current).toList());
    await unassign([transactionId], current.difference(selected).toList());
  }

  void _set(List<String> transactions, List<String> tagIds, bool deleted) {
    final owned = allTags.map((t) => t.id).toSet();
    if (tagIds.any((id) => !owned.contains(id)))
      throw ArgumentError('Tag is unavailable.');
    final at = DateTime.now().toUtc().toIso8601String();
    database.db.execute('BEGIN IMMEDIATE');
    try {
      for (final raw in transactions.toSet()) {
        final id = _canonical(raw);
        for (final tag in tagIds.toSet()) {
          _link(id, tag, at, deleted);
          // Collapse repeated edits of this link to the latest intent.
          final pending = database.db.select(
            'SELECT seq,payload_json FROM transaction_tag_outbox WHERE namespace=?',
            [namespace],
          );
          for (final row in pending) {
            final op = jsonDecode(row['payload_json'] as String) as Map;
            if (op['transactionId'] == id &&
                op['tagId'] == tag &&
                ['assign', 'unassign'].contains(op['operation'])) {
              database.db.execute(
                'DELETE FROM transaction_tag_outbox WHERE seq=?',
                [row['seq']],
              );
            }
          }
          _queue({
            'operation': deleted ? 'unassign' : 'assign',
            'transactionId': id,
            'tagId': tag,
            'updatedAt': at,
          });
        }
      }
      database.db.execute('COMMIT');
    } catch (_) {
      database.db.execute('ROLLBACK');
      rethrow;
    }
    _changed();
  }

  Future<void> merge(String source, String target) async {
    if (source == target || !tags.any((t) => t.id == target))
      throw ArgumentError('Choose another active tag.');
    final at = DateTime.now().toUtc().toIso8601String();
    _atomic(() {
      _applyMerge(source, target, at);
      _queue({
        'operation': 'merge_tags',
        'tagId': source,
        'targetTagId': target,
        'updatedAt': at,
      });
    });
    _changed();
  }

  void _applyMerge(String source, String target, String at) {
    final ids = database.db
        .select(
          'SELECT transaction_id FROM transaction_tag_links WHERE namespace=? AND tag_id=? AND deleted_at IS NULL',
          [namespace, source],
        )
        .map((r) => r['transaction_id'] as String)
        .toList();
    for (final id in ids) {
      // A pending merge is local intent over a server snapshot. Download time
      // is not a competing user edit and must not defeat that intent.
      database.db.execute(
        'DELETE FROM transaction_tag_links WHERE namespace=? AND transaction_id=? AND tag_id IN (?,?)',
        [namespace, id, source, target],
      );
      _link(id, target, at, false);
      _link(id, source, at, true);
    }
    database.db.execute(
      'UPDATE transaction_tags SET archived_at=?,updated_at=? WHERE namespace=? AND id=?',
      [at, at, namespace, source],
    );
  }

  void remapTransaction(String local, String canonical) {
    if (local == canonical) return;
    database.db.execute(
      'INSERT OR REPLACE INTO transaction_tag_aliases(namespace,local_id,transaction_id) VALUES(?,?,?)',
      [namespace, local, canonical],
    );
    final rows = database.db.select(
      'SELECT * FROM transaction_tag_links WHERE namespace=? AND transaction_id=?',
      [namespace, local],
    );
    for (final row in rows) {
      _link(
        canonical,
        row['tag_id'] as String,
        row['updated_at'] as String,
        row['deleted_at'] != null,
      );
    }
    database.db.execute(
      'DELETE FROM transaction_tag_links WHERE namespace=? AND transaction_id=?',
      [namespace, local],
    );
    _changed();
  }

  void _upsert(TransactionTag tag) => database.db.execute(
    '''INSERT INTO transaction_tags
    (namespace,id,name,normalized_name,color,archived_at,updated_at) VALUES(?,?,?,?,?,?,?)
    ON CONFLICT(namespace,id) DO UPDATE SET name=excluded.name,normalized_name=excluded.normalized_name,
      color=excluded.color,archived_at=excluded.archived_at,updated_at=excluded.updated_at''',
    [
      namespace,
      tag.id,
      tag.name,
      _name(tag.name).toLowerCase(),
      tag.color,
      tag.archivedAt?.toUtc().toIso8601String(),
      tag.updatedAt?.toUtc().toIso8601String() ??
          DateTime.now().toUtc().toIso8601String(),
    ],
  );
  void _link(String id, String tag, String at, bool deleted) {
    database.db.execute(
      'INSERT OR IGNORE INTO transaction_tag_known_transactions VALUES(?,?)',
      [namespace, id],
    );
    database.db.execute(
      '''INSERT INTO transaction_tag_links(namespace,transaction_id,tag_id,updated_at,deleted_at) VALUES(?,?,?,?,?)
      ON CONFLICT(namespace,transaction_id,tag_id) DO UPDATE SET updated_at=excluded.updated_at,deleted_at=excluded.deleted_at
      WHERE transaction_tag_links.updated_at<=excluded.updated_at''',
      [namespace, id, tag, at, deleted ? at : null],
    );
  }

  void _queueTag(TransactionTag tag) {
    final pending = database.db.select(
      'SELECT seq,payload_json FROM transaction_tag_outbox WHERE namespace=?',
      [namespace],
    );
    for (final row in pending) {
      final op = jsonDecode(row['payload_json'] as String) as Map;
      if (op['operation'] == 'upsert_tag' && (op['tag'] as Map)['id'] == tag.id)
        database.db.execute('DELETE FROM transaction_tag_outbox WHERE seq=?', [
          row['seq'],
        ]);
    }
    // Tag creation goes before link assignments even when rename coalesces it.
    _queue({
      'operation': 'upsert_tag',
      'tag': tag.toJson(),
      'updatedAt': tag.updatedAt!.toUtc().toIso8601String(),
    });
  }

  void _queue(Map<String, dynamic> change) {
    final payload = {'mutationId': const Uuid().v4(), ...change};
    database.db.execute(
      'INSERT INTO transaction_tag_outbox(namespace,mutation_id,payload_json) VALUES(?,?,?)',
      [namespace, payload['mutationId'], jsonEncode(payload)],
    );
  }

  void _changed({bool requestSync = true}) {
    _invalidateCache();
    if (_disposed) return;
    notifyListeners();
    onChanged?.call();
    if (requestSync) {
      if (isSyncing) _syncAgain = true;
      unawaited(sync().catchError((Object _) {}));
    }
  }

  Future<void> sync() =>
      _syncFuture ??= AccountRecoveryOperationGate.process.run(_runSync)
          .whenComplete(() => _syncFuture = null);
  Future<void> _runSync() async {
    do {
      _syncAgain = false;
      await _syncOnce();
    } while (_syncAgain && !_disposed);
  }

  Future<void> _syncOnce() async {
    if (isSyncing || _disposed) return;
    isSyncing = true;
    lastError = null;
    try {
      final headers = {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      };
      // Definitions first; independent links retain their own mutation clock.
      final pending =
          database.db.select(
            'SELECT * FROM transaction_tag_outbox WHERE namespace=? ORDER BY seq',
            [namespace],
          ).toList()..sort((a, b) {
            final x = jsonDecode(a['payload_json'] as String) as Map;
            final y = jsonDecode(b['payload_json'] as String) as Map;
            final p = (x['operation'] == 'upsert_tag' ? 0 : 1).compareTo(
              y['operation'] == 'upsert_tag' ? 0 : 1,
            );
            return p != 0 ? p : (a['seq'] as int).compareTo(b['seq'] as int);
          });
      for (final row in pending) {
        if (_disposed) return;
        try {
          final response = await client
              .post(
                Uri.parse('$apiBaseUrl/transaction-tags/changes'),
                headers: headers,
                body: row['payload_json'] as String,
              )
              .timeout(const Duration(seconds: 15));
          if (response.statusCode != 200)
            throw ApiException(
              'Tag sync: ${response.statusCode} ${response.body}',
              userMessage:
                  'Tag changes are saved on this device. Retry sync in Manage tags.',
            );
          database.db.execute(
            'DELETE FROM transaction_tag_outbox WHERE namespace=? AND mutation_id=?',
            [namespace, row['mutation_id']],
          );
        } catch (error) {
          if (_disposed) return;
          lastError = error.toString();
          database.db.execute(
            'UPDATE transaction_tag_outbox SET attempts=attempts+1,last_error=? WHERE namespace=? AND mutation_id=?',
            [lastError, namespace, row['mutation_id']],
          );
          // A pending offline transaction must not block independent tag edits.
        }
      }
      if (_disposed) return;
      final response = await client
          .get(Uri.parse('$apiBaseUrl/transaction-tags'), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200)
        throw ApiException('Tag download: ${response.statusCode}');
      if (_disposed) return;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      database.db.execute('BEGIN IMMEDIATE');
      try {
        database.db.execute(
          'DELETE FROM transaction_tag_links WHERE namespace=?',
          [namespace],
        );
        database.db.execute('DELETE FROM transaction_tags WHERE namespace=?', [
          namespace,
        ]);
        for (final row in (body['tags'] as List? ?? [])) {
          _upsert(
            TransactionTag.fromJson(Map<String, dynamic>.from(row as Map)),
          );
        }
        final at = DateTime.now().toUtc().toIso8601String();
        for (final row in (body['assignments'] as List? ?? [])) {
          _link(
            row['transactionId'] as String,
            row['tagId'] as String,
            at,
            false,
          );
        }
        for (final row in (body['aliases'] as List? ?? [])) {
          database.db.execute(
            'INSERT OR REPLACE INTO transaction_tag_aliases VALUES(?,?,?)',
            [namespace, row['localId'], row['transactionId']],
          );
        }
        // Replay unacknowledged intent over the downloaded snapshot, including
        _invalidateCache();
        // explicit removals so a stale response cannot resurrect a tag.
        final remaining = database.db.select(
          'SELECT payload_json FROM transaction_tag_outbox WHERE namespace=? ORDER BY seq',
          [namespace],
        );
        for (final row in remaining) {
          final op =
              jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
          if (op['operation'] == 'upsert_tag')
            _upsert(
              TransactionTag.fromJson(
                Map<String, dynamic>.from(op['tag'] as Map),
              ),
            );
          if (['assign', 'unassign'].contains(op['operation'])) {
            final id = _canonical(op['transactionId'] as String);
            // Pending intent is authoritative locally, regardless of server clock.
            database.db.execute(
              'DELETE FROM transaction_tag_links WHERE namespace=? AND transaction_id=? AND tag_id=?',
              [namespace, id, op['tagId']],
            );
            _link(
              id,
              op['tagId'] as String,
              op['updatedAt'] as String,
              op['operation'] == 'unassign',
            );
          }
          if (op['operation'] == 'merge_tags') {
            _applyMerge(
              op['tagId'] as String,
              op['targetTagId'] as String,
              op['updatedAt'] as String,
            );
          }
        }
        database.db.execute(
          'INSERT OR REPLACE INTO transaction_tag_sync_state VALUES(?,?)',
          [namespace, at],
        );
        database.db.execute('COMMIT');
      } catch (_) {
        database.db.execute('ROLLBACK');
        rethrow;
      }
      _changed(requestSync: false);
    } catch (error) {
      lastError = error.toString();
    } finally {
      isSyncing = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
