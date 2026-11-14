import 'dart:convert';


import '../server_clock.dart';
import '../sync_api.dart';
import 'app_database.dart';
import 'queue_retry_policy.dart';
import '../local_first/provisional_cards.dart';

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

  /// Source of field clocks when a call does not pass `at`. Defaults to the
  /// process-wide [ServerClock], which is exactly `DateTime.now()` until an
  /// API response has revealed a clock skew.
  final ServerClock _clock;

  SyncQueue(
    this._appDb, {
    this.namespace = 'legacy',
    this.onChanged,
    ServerClock? serverClock,
  }) : _clock = serverClock ?? ServerClock.instance {
    final columns = _appDb.db.select('PRAGMA table_info(sync_pending_changes)');
    if (!columns.any((c) => c['name'] == 'namespace')) {
      _appDb.db.execute(
        "ALTER TABLE sync_pending_changes ADD COLUMN namespace TEXT NOT NULL DEFAULT 'legacy'",
      );
    }
    // H1: retry backoff for counted failures (additive, guarded).
    if (!columns.any((c) => c['name'] == 'next_attempt_at')) {
      _appDb.db.execute(
        'ALTER TABLE sync_pending_changes ADD COLUMN next_attempt_at INTEGER',
      );
    }
    _appDb.db.execute('''CREATE TABLE IF NOT EXISTS account_sync_state (
      namespace TEXT PRIMARY KEY, device_id TEXT, last_server_seq INTEGER NOT NULL DEFAULT 0,
      last_synced_at INTEGER)''');
    // H1: the last field clock issued, so a restart never stamps older.
    final stateColumns = _appDb.db.select('PRAGMA table_info(account_sync_state)');
    if (!stateColumns.any((c) => c['name'] == 'last_clock_ms')) {
      _appDb.db.execute(
        'ALTER TABLE account_sync_state ADD COLUMN last_clock_ms INTEGER',
      );
    }
    // A change claimed by a push that never finished (the process died) goes
    // back in line. One the server already applied (in_flight = 2) must not:
    // it is only waiting for its fresh server copy to be stored.
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET in_flight=0 WHERE namespace=? AND in_flight=1',
      [namespace],
    );
  }

  /// `in_flight` value of a change the server has applied but whose server
  /// copy has not been stored locally yet. It is never pushed again, yet keeps
  /// overlaying the stored row (so the edit does not flicker back to the old
  /// value) until [purgeApplied] runs after the server copy is saved.
  static const _applied = 2;

  /// The field clock for a new edit: the (server-adjusted) clock, but never
  /// older than the last one issued for this account, even across a restart
  /// (H1-4). An explicit [at] is used as given.
  int _stampMs(DateTime? at) {
    if (at != null) return at.millisecondsSinceEpoch;
    var ms = _clock.now().millisecondsSinceEpoch;
    final rows = _appDb.db.select(
      'SELECT last_clock_ms FROM account_sync_state WHERE namespace = ?',
      [namespace],
    );
    final last = rows.isEmpty ? null : rows.first['last_clock_ms'] as int?;
    if (last != null && ms < last) ms = last;
    _appDb.db.execute(
      'INSERT INTO account_sync_state(namespace,last_clock_ms) VALUES (?,?) '
      'ON CONFLICT(namespace) DO UPDATE SET last_clock_ms=excluded.last_clock_ms',
      [namespace, ms],
    );
    return ms;
  }

  /// Records a local edit.
  ///
  /// [fields] is field name -> new value, already in the shape the server
  /// expects (the API's allowlist is the authority on which names are valid;
  /// anything else is silently dropped server-side rather than rejected, so
  /// a typo here shows up as "my edit didn't sync", not as an error).
  /// Returns 0 when [fields] is empty and no change was queued.
  int enqueueUpdate({
    required String entity,
    required String entityId,
    required Map<String, Object?> fields,
    DateTime? at,
  }) {
    if (fields.isEmpty) return 0;
    final clockMs = _stampMs(at);

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
      return _appDb.db.select('SELECT last_insert_rowid() AS id').single['id']
          as int;
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
      'UPDATE sync_pending_changes SET payload_json = ?, field_clocks_json = ?, attempts = 0, next_attempt_at = NULL, last_error = NULL WHERE client_seq = ?',
      [jsonEncode(payload), jsonEncode(clocks), row['client_seq']],
    );
    onChanged?.call();
    return row['client_seq'] as int;
  }

  /// Records a locally-created row. Inserts are intentionally not coalesced:
  /// each category has its own stable id and must remain independently
  /// replayable when the device comes back online.
  void enqueueInsert({
    required String entity,
    required String entityId,
    required Map<String, Object?> fields,
    DateTime? at,
  }) {
    if (fields.isEmpty) return;
    final clockMs = _stampMs(at);
    _appDb.db.execute(
      'INSERT INTO sync_pending_changes '
      '(namespace, entity, entity_id, op, payload_json, field_clocks_json, created_at) '
      "VALUES (?, ?, ?, 'insert', ?, ?, ?)",
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
        _stampMs(at),
      ],
    );
    onChanged?.call();
  }

  List<SyncChange> pending({int limit = 200}) {
    final rows = _appDb.db.select(
      'SELECT * FROM sync_pending_changes WHERE namespace = ? AND attempts < 5 AND in_flight=0 '
      'AND (next_attempt_at IS NULL OR next_attempt_at <= ?) ORDER BY client_seq LIMIT ?',
      [namespace, _clock.now().millisecondsSinceEpoch, limit],
    );
    // H3-1: an edit for a card that is only on the phone waits for its add.
    final held = provisionalCardIds(_appDb.db, namespace);
    return rows.where((r) => !(r['entity'] == 'user_cards' && held.contains(r['entity_id']))).map((r) {
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

  /// Changes still waiting for the server (applied ones are not waiting).
  int get pendingCount =>
      _appDb.db.select(
            'SELECT COUNT(*) AS c FROM sync_pending_changes WHERE namespace = ? AND in_flight != $_applied',
            [namespace],
          ).first['c']
          as int;

  /// The server applied this change. It leaves the push queue for good (never
  /// re-sent, not counted as pending) but stays as an overlay until
  /// [purgeApplied], so a failed refetch cannot make the edit look undone.
  void markApplied(int clientSeq) {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET in_flight=$_applied WHERE namespace=? AND client_seq=?',
      [namespace, clientSeq],
    );
    onChanged?.call();
  }

  /// Entities that have applied changes awaiting [purgeApplied].
  Set<String> appliedEntities() => {
    for (final row in _appDb.db.select(
      'SELECT DISTINCT entity FROM sync_pending_changes WHERE namespace=? AND in_flight=$_applied',
      [namespace],
    ))
      row['entity'] as String,
  };

  /// Drops applied changes of [entities] once their server copy is stored.
  void purgeApplied(Iterable<String> entities) {
    for (final entity in entities) {
      _appDb.db.execute(
        'DELETE FROM sync_pending_changes WHERE namespace=? AND entity=? AND in_flight=$_applied',
        [namespace, entity],
      );
    }
    onChanged?.call();
  }

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
      // Only what is still claimed: a change the server applied stays applied.
      _appDb.db.execute(
        'UPDATE sync_pending_changes SET in_flight=0 WHERE namespace=? AND client_seq=? AND in_flight=1',
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
    final rows = _appDb.db.select(
      'SELECT attempts FROM sync_pending_changes WHERE client_seq = ? AND namespace = ?',
      [clientSeq, namespace],
    );
    final attempts = (rows.isEmpty ? 0 : rows.first['attempts'] as int) + 1;
    final due = _clock.now().add(queueBackoffJittered(attempts)).millisecondsSinceEpoch;
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET attempts = ?, next_attempt_at = ?, last_error = ? WHERE client_seq = ? AND namespace = ?',
      [attempts, due, error, clientSeq, namespace],
    );
    onChanged?.call();
  }

  /// Holds one change back for [delay] without counting an attempt (the
  /// safety valve for a head row that keeps crashing the server, H1-2).
  void defer(int clientSeq, Duration delay, String error) {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET next_attempt_at = ?, last_error = ? WHERE client_seq = ? AND namespace = ?',
      [_clock.now().add(delay).millisecondsSinceEpoch, error, clientSeq, namespace],
    );
    onChanged?.call();
  }

  /// Makes changes waiting out a backoff due again (connectivity came back).
  void resetBackoff() {
    _appDb.db.execute(
      'UPDATE sync_pending_changes SET next_attempt_at = NULL WHERE namespace = ? AND next_attempt_at IS NOT NULL',
      [namespace],
    );
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
