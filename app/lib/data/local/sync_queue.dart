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
  SyncQueue(this._appDb);

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
      "WHERE entity = ? AND entity_id = ? AND op = 'update' ORDER BY client_seq LIMIT 1",
      [entity, entityId],
    );

    if (existing.isEmpty) {
      _appDb.db.execute(
        'INSERT INTO sync_pending_changes '
        '(entity, entity_id, op, payload_json, field_clocks_json, created_at) '
        "VALUES (?, ?, 'update', ?, ?, ?)",
        [
          entity,
          entityId,
          jsonEncode(fields),
          jsonEncode({for (final k in fields.keys) k: clockMs}),
          clockMs,
        ],
      );
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
      'UPDATE sync_pending_changes SET payload_json = ?, field_clocks_json = ? WHERE client_seq = ?',
      [jsonEncode(payload), jsonEncode(clocks), row['client_seq']],
    );
  }

  /// Records a local delete.
  ///
  /// Any queued updates for the same row are dropped first: pushing an edit
  /// and then a delete of the same row wastes a round trip on a value that is
  /// about to stop existing, and on `user_cards` the delete is really an
  /// archive, so the ordering would be observable.
  void enqueueDelete({required String entity, required String entityId, DateTime? at}) {
    _appDb.db.execute(
      'DELETE FROM sync_pending_changes WHERE entity = ? AND entity_id = ?',
      [entity, entityId],
    );
    _appDb.db.execute(
      'INSERT INTO sync_pending_changes '
      '(entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES (?, ?, 'delete', '{}', '{}', ?)",
      [entity, entityId, (at ?? DateTime.now()).millisecondsSinceEpoch],
    );
  }

  List<SyncChange> pending({int limit = 200}) {
    final rows = _appDb.db.select(
      'SELECT * FROM sync_pending_changes ORDER BY client_seq LIMIT ?',
      [limit],
    );
    return rows.map((r) {
      return SyncChange(
        entity: r['entity'] as String,
        entityId: r['entity_id'] as String,
        op: r['op'] as String,
        payload: Map<String, Object?>.from(jsonDecode(r['payload_json'] as String) as Map),
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
      _appDb.db.select('SELECT COUNT(*) AS c FROM sync_pending_changes').first['c'] as int;

  void remove(int clientSeq) {
    _appDb.db.execute('DELETE FROM sync_pending_changes WHERE client_seq = ?', [clientSeq]);
  }

  /// Marks a change as having failed for a retryable reason.
  ///
  /// After [maxAttempts] the change is dropped rather than retried forever.
  /// That is a deliberate, uncomfortable choice: it discards a user edit. The
  /// alternative is worse — a change the server will never accept sits at the
  /// head of the queue and blocks every later edit from syncing, so one bad
  /// row silently freezes the account's sync indefinitely. The error is
  /// retained on the row until it is dropped so it can be surfaced.
  static const maxAttempts = 5;

  void recordFailure(int clientSeq, String error) {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET attempts = attempts + 1, last_error = ? WHERE client_seq = ?',
      [error, clientSeq],
    );
    _appDb.db.execute(
      'DELETE FROM sync_pending_changes WHERE client_seq = ? AND attempts >= ?',
      [clientSeq, maxAttempts],
    );
  }

  // ---- Device identity and cursor -------------------------------------------

  String? get deviceId {
    final rows = _appDb.db.select('SELECT device_id FROM sync_state WHERE id = 1');
    return rows.isEmpty ? null : rows.first['device_id'] as String?;
  }

  set deviceId(String? value) {
    _appDb.db.execute(
      'INSERT INTO sync_state (id, device_id) VALUES (1, ?) '
      'ON CONFLICT(id) DO UPDATE SET device_id = excluded.device_id',
      [value],
    );
  }

  int get lastServerSeq {
    final rows = _appDb.db.select('SELECT last_server_seq FROM sync_state WHERE id = 1');
    return rows.isEmpty ? 0 : (rows.first['last_server_seq'] as int?) ?? 0;
  }

  set lastServerSeq(int value) {
    _appDb.db.execute(
      'INSERT INTO sync_state (id, last_server_seq, last_synced_at) VALUES (1, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET last_server_seq = excluded.last_server_seq, '
      'last_synced_at = excluded.last_synced_at',
      [value, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// Called on sign-out. The queue and cursor belong to one account; carrying
  /// them into the next sign-in on the same device would push one user's edits
  /// under another user's token.
  void clear() {
    _appDb.db.execute('DELETE FROM sync_pending_changes');
    _appDb.db.execute('DELETE FROM sync_state');
  }
}
