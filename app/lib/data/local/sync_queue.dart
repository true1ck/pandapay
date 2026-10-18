import 'dart:convert';

import '../sync_api.dart';
import 'app_database.dart';

/// Plan Phase 4 — the local half of the change queue.
///
/// Every user edit to a synced entity is recorded here first and pushed later,
/// which is what makes offline editing work on more than the one write path
/// (`transaction_outbox_entries`, B6 quick-add) that previously supported it.
///
/// The design decision that matters most is COALESCING. A user dragging a
/// credit-limit slider or retyping a note produces dozens of edits per second.
/// Queuing each one would mean pushing dozens of changes that all describe the
/// same final state, and — worse — the intermediate values would each get
/// their own conflict evaluation against the other device. So an edit to a
/// field that is already queued for the same row replaces the queued value
/// rather than appending. Only the latest value of each field is ever sent,
/// which is also the only value that is true.
class SyncQueue {
  final AppDatabase _appDb;
  final String namespace;
  final void Function()? onChanged;
  SyncQueue(this._appDb, {this.namespace = 'legacy', this.onChanged}) {
    final columns = _appDb.db.select('PRAGMA table_info(sync_pending_changes)');
    if (!columns.any((c) => c['name'] == 'namespace')) {
      _appDb.db.execute(
        "ALTER TABLE sync_pending_changes ADD COLUMN namespace TEXT NOT NULL DEFAULT 'legacy'",
      );
    }
    _appDb.db.execute('''CREATE TABLE IF NOT EXISTS account_sync_state (
      namespace TEXT PRIMARY KEY, device_id TEXT, last_server_seq INTEGER NOT NULL DEFAULT 0,
      last_synced_at INTEGER)''');
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET in_flight=0 WHERE namespace=?',
      [namespace],
    );
  }

  /// Records a local edit.
  ///
  /// [fields] is field name -> new value, already in the shape the server
  /// expects (the API's allowlist is the authority on which names are valid;
  /// anything else is silently dropped server-side rather than rejected, so
  /// a typo here shows up as "my edit didn't sync", not as an error).
  void enqueueUpdate({
    required String entity,
    required String entityId,
    required Map<String, Object?> fields,
    DateTime? at,
  }) {
    if (fields.isEmpty) return;
    final clockMs = (at ?? DateTime.now()).millisecondsSinceEpoch;

    final existing = _appDb.db.select(
      "SELECT client_seq, payload_json, field_clocks_json FROM sync_pending_changes "
      "WHERE namespace = ? AND entity = ? AND entity_id = ? AND op = 'update' AND in_flight=0 ORDER BY client_seq LIMIT 1",
      [namespace, entity, entityId],
    );

    if (existing.isEmpty) {
      _appDb.db.execute(
        'INSERT INTO sync_pending_changes '
        '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
        "VALUES (?, ?, ?, 'update', ?, ?, ?)",
        [
          namespace,
          entity,
          entityId,
          jsonEncode(fields),
          jsonEncode({for (final k in fields.keys) k: clockMs}),
          clockMs,
        ],
      );
      onChanged?.call();
      return;
    }

    // Merge into the queued change. Each field's clock is bumped to now, so a
    // value the user re-edited after another device wrote correctly wins the
    // later comparison — using the ORIGINAL queue time here would make a fresh
    // local edit lose to a stale remote one.
    final row = existing.first;
    final payload = Map<String, Object?>.from(
      jsonDecode(row['payload_json'] as String) as Map,
    )..addAll(fields);
    final clocks = Map<String, Object?>.from(
      jsonDecode(row['field_clocks_json'] as String) as Map,
    )..addAll({for (final k in fields.keys) k: clockMs});

    _appDb.db.execute(
      'UPDATE sync_pending_changes SET payload_json = ?, field_clocks_json = ?, attempts = 0, last_error = NULL WHERE client_seq = ?',
      [jsonEncode(payload), jsonEncode(clocks), row['client_seq']],
    );
    onChanged?.call();
  }

  /// Records a local delete.
  ///
  /// Any queued updates for the same row are dropped first: pushing an edit
  /// and then a delete of the same row wastes a round trip on a value that is
  /// about to stop existing, and on `user_cards` the delete is really an
  /// archive, so the ordering would be observable.
  void enqueueDelete({
    required String entity,
    required String entityId,
    DateTime? at,
  }) {
    _appDb.db.execute(
      'DELETE FROM sync_pending_changes WHERE namespace = ? AND entity = ? AND entity_id = ? AND in_flight=0',
      [namespace, entity, entityId],
    );
    _appDb.db.execute(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES (?, ?, ?, 'delete', '{}', '{}', ?)",
      [
        namespace,
        entity,
        entityId,
        (at ?? DateTime.now()).millisecondsSinceEpoch,
      ],
    );
    onChanged?.call();
  }

  List<SyncChange> pending({int limit = 200}) {
    final rows = _appDb.db.select(
      'SELECT * FROM sync_pending_changes WHERE namespace = ? AND attempts < 5 AND in_flight=0 ORDER BY client_seq LIMIT ?',
      [namespace, limit],
    );
    return rows.map((r) {
      return SyncChange(
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String,
        op: r['op'] as String,
        payload: Map<String, Object?>.from(
          jsonDecode(r['payload_json'] as String) as Map,
        ),
        fieldClocks: Map<String, int>.from(
          (jsonDecode(r['field_clocks_json'] as String) as Map).map(
            (k, v) => MapEntry(k as String, (v as num).toInt()),
          ),
        ),
        clientSeq: r['client_seq'] as int,
      );
    }).toList();
  }

  int get pendingCount =>
      _appDb.db.select(
            'SELECT COUNT(*) AS c FROM sync_pending_changes WHERE namespace = ?',
            [namespace],
          ).first['c']
          as int;

  void remove(int clientSeq) {
    _appDb.db.execute(
      'DELETE FROM sync_pending_changes WHERE client_seq = ? AND namespace = ?',
      [clientSeq, namespace],
    );
    onChanged?.call();
  }

  void claim(List<SyncChange> changes) {
    for (final change in changes) {
      _appDb.db.execute(
        'UPDATE sync_pending_changes SET in_flight=1 WHERE namespace=? AND client_seq=?',
        [namespace, change.clientSeq],
      );
    }
  }

  void release(List<SyncChange> changes) {
    for (final change in changes) {
      _appDb.db.execute(
        'UPDATE sync_pending_changes SET in_flight=0 WHERE namespace=? AND client_seq=?',
        [namespace, change.clientSeq],
      );
    }
  }

  /// Marks a change as having failed for a retryable reason.
  ///
  /// After [maxAttempts] the change stays saved but leaves the automatic
  /// retry set. Sync & backup exposes it for correction or explicit retry;
  /// later valid edits continue syncing.
  static const maxAttempts = 5;

  void recordFailure(int clientSeq, String error) {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET attempts = attempts + 1, last_error = ? WHERE client_seq = ? AND namespace = ?',
      [error, clientSeq, namespace],
    );
    onChanged?.call();
  }

  void reject(int clientSeq, String error) {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET attempts = ?, last_error = ? WHERE client_seq = ? AND namespace = ?',
      [maxAttempts, error, clientSeq, namespace],
    );
    onChanged?.call();
  }
  // ---- Device identity and cursor -------------------------------------------

  String? get deviceId {
    final rows = _appDb.db.select(
      'SELECT device_id FROM account_sync_state WHERE namespace = ?',
      [namespace],
    );
    return rows.isEmpty ? null : rows.first['device_id'] as String?;
  }

  set deviceId(String? value) {
    _appDb.db.execute(
      'INSERT INTO account_sync_state(namespace,device_id) VALUES (?,?) ON CONFLICT(namespace) DO UPDATE SET device_id=excluded.device_id',
      [namespace, value],
    );
  }

  int get lastServerSeq {
    final rows = _appDb.db.select(
      'SELECT last_server_seq FROM account_sync_state WHERE namespace=?',
      [namespace],
    );
    return rows.isEmpty ? 0 : rows.first['last_server_seq'] as int;
  }

  set lastServerSeq(int value) {
    _appDb.db.execute(
      'INSERT INTO account_sync_state(namespace,last_server_seq,last_synced_at) VALUES (?,?,?) ON CONFLICT(namespace) DO UPDATE SET last_server_seq=excluded.last_server_seq,last_synced_at=excluded.last_synced_at',
      [namespace, value, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void resetCursor() {
    _appDb.db.execute('DELETE FROM account_sync_state WHERE namespace=?', [
      namespace,
    ]);
  }

  void clear() {
    _appDb.db.execute('DELETE FROM sync_pending_changes WHERE namespace=?', [
      namespace,
    ]);
    _appDb.db.execute('DELETE FROM account_sync_state WHERE namespace=?', [
      namespace,
    ]);
    onChanged?.call();
  }
}
