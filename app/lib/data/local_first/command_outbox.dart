import 'dart:convert';

import '../api_exception.dart';
import '../local/app_database.dart';
import '../local/queue_retry_policy.dart';

/// One queued command, as seen by a screen that overlays it.
class PendingCommand {
  const PendingCommand({
    required this.kind,
    required this.target,
    required this.payload,
  });
  final String kind;
  final String target;
  final Map<String, Object?> payload;
}

/// Runs one queued command against the server. Throw to report failure.
typedef CommandHandler = Future<void> Function(Map<String, Object?> payload);

/// The general "do this on the server later" queue.
///
/// [SyncQueue] carries plain field edits that `/sync/push` can apply. A few
/// actions have their own server routes because they do more than set a field
/// (ignoring a transaction reverses its rewards and caps, for example). Those
/// cannot go through `/sync/push`, but the button should not wait on them
/// either. A screen applies the change to the phone's own data first, then
/// records a command here; [flush] replays it when the network allows.
///
/// Rules a command must meet to belong here:
/// * Repeating it is harmless (the handler sets a state, it does not add to
///   one). A command that adds to a balance needs a client request id first.
/// * The screen has already shown the result locally.
///
/// Behaviour:
/// * Commands for the same target run in the order they were made. If one
///   fails for a retryable reason, later commands for that target wait.
/// * Opposite commands cancel each other while still queued: ignore then
///   restore of one transaction sends nothing.
/// * A retryable server failure (5xx, 408, 429) backs off 30 s, 1 min, 2 min
///   ... up to 30 min and tries again.
/// * A failure to reach the server at all (no connection, timeout, a rejected
///   session) is not the command's fault: it does not count as an attempt and
///   sets no backoff, and it ends the pass. [resetBackoff] makes everything
///   due again when the connection returns.
/// * A permanent refusal (other 4xx) is parked, kept with its error, and no
///   longer retried automatically. So is a 500 for a target that is not a
///   server id (`v2:...`, `projection:...`): the server cannot succeed for it,
///   and retrying every 30 minutes would keep the pending badge up for ever.
class CommandOutbox {
  CommandOutbox(this._appDb, {required this.namespace, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    _appDb.db.execute('''
      CREATE TABLE IF NOT EXISTS command_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        namespace TEXT NOT NULL,
        kind TEXT NOT NULL,
        target TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at INTEGER NOT NULL DEFAULT 0,
        parked INTEGER NOT NULL DEFAULT 0
      )''');
    _appDb.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_command_outbox_ns '
      'ON command_outbox(namespace, parked, id)',
    );
  }

  final AppDatabase _appDb;
  final String namespace;
  final DateTime Function() _now;

  static const _maxBackoffSeconds = 1800;

  /// Queues [kind] for [target]. A queued command of the same kind and target
  /// is replaced, since only the latest intent matters. Any queued command in
  /// [cancels] for the same target is removed, and when one was, nothing is
  /// queued: the server is already in the state the person ended up in.
  /// Returns true when a command was queued.
  bool enqueue({
    required String kind,
    required String target,
    Map<String, Object?> payload = const {},
    List<String> cancels = const [],
  }) {
    for (final opposite in cancels) {
      _appDb.db.execute(
        'DELETE FROM command_outbox WHERE namespace=? AND kind=? AND target=?',
        [namespace, opposite, target],
      );
      if (_appDb.db.updatedRows > 0) return false;
    }
    _appDb.db.execute(
      'DELETE FROM command_outbox WHERE namespace=? AND kind=? AND target=?',
      [namespace, kind, target],
    );
    _appDb.db.execute(
      'INSERT INTO command_outbox (namespace, kind, target, payload_json, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        namespace,
        kind,
        target,
        jsonEncode(payload),
        _now().millisecondsSinceEpoch,
      ],
    );
    return true;
  }

  /// Commands still waiting to be sent (not parked).
  int get pendingCount =>
      _appDb.db
              .select(
                'SELECT COUNT(*) AS c FROM command_outbox WHERE namespace=? AND parked=0',
                [namespace],
              )
              .first['c']
          as int;

  /// Queued, unparked commands of the given [kinds], oldest first. Screens
  /// use this to show a pending change on top of the last data they loaded.
  List<PendingCommand> pendingOf(Set<String> kinds) => [
    for (final r in _appDb.db.select(
      'SELECT kind, target, payload_json FROM command_outbox '
      'WHERE namespace=? AND parked=0 ORDER BY id',
      [namespace],
    ))
      if (kinds.contains(r['kind']))
        PendingCommand(
          kind: r['kind'] as String,
          target: r['target'] as String,
          payload: Map<String, Object?>.from(
            jsonDecode(r['payload_json'] as String) as Map,
          ),
        ),
  ];

  /// Commands the server refused for good. They stay for the person to see.
  List<({int id, String kind, String target, String? error})> parked() => [
    for (final r in _appDb.db.select(
      'SELECT id, kind, target, last_error FROM command_outbox WHERE namespace=? AND parked=1 ORDER BY id',
      [namespace],
    ))
      (
        id: r['id'] as int,
        kind: r['kind'] as String,
        target: r['target'] as String,
        error: r['last_error'] as String?,
      ),
  ];

  /// Makes every unparked command due again. Called when the connection
  /// returns: a backoff was about a server problem that may have passed, and
  /// time spent offline should not be waited out a second time.
  void resetBackoff() => _appDb.db.execute(
    'UPDATE command_outbox SET next_attempt_at=0 '
    'WHERE namespace=? AND parked=0 AND next_attempt_at>0',
    [namespace],
  );

  /// Puts a parked command back in the queue (explicit retry).
  void retryParked(int id) {
    _appDb.db.execute(
      'UPDATE command_outbox SET parked=0, attempts=0, next_attempt_at=0, last_error=NULL '
      'WHERE namespace=? AND id=?',
      [namespace, id],
    );
  }

  /// Sends due commands, oldest first, at most [limit] in this pass. Returns
  /// how many were delivered. Never throws: a failure is recorded on the row.
  ///
  /// [onlyKinds] limits the pass to those kinds (WP-C6 sends queued card adds
  /// before the transactions that may name those cards); the rest stay queued.
  Future<int> flush(
    Map<String, CommandHandler> handlers, {
    int limit = 20,
    Set<String>? onlyKinds,
  }) async {
    final now = _now().millisecondsSinceEpoch;
    final due = _appDb.db.select(
      'SELECT id, kind, target, payload_json, attempts FROM command_outbox '
      'WHERE namespace=? AND parked=0 AND next_attempt_at<=? ORDER BY id LIMIT ?',
      [namespace, now, limit],
    );
    var delivered = 0;
    // A target whose command failed this pass keeps its later commands back.
    final blocked = <String>{};
    for (final row in due) {
      final id = row['id'] as int;
      final target = row['target'] as String;
      if (blocked.contains(target)) continue;
      if (onlyKinds != null && !onlyKinds.contains(row['kind'])) continue;
      final handler = handlers[row['kind'] as String];
      if (handler == null) {
        _park(id, 'No handler for ${row['kind']}');
        continue;
      }
      // Read the payload again: an earlier command of this same pass (a card
      // add) may have remapped ids inside it, or cancelled this row (WP-Q1).
      final fresh = _appDb.db.select(
        'SELECT payload_json FROM command_outbox WHERE id=? AND parked=0',
        [id],
      );
      if (fresh.isEmpty) continue;
      try {
        await handler(
          Map<String, Object?>.from(
            jsonDecode(fresh.first['payload_json'] as String) as Map,
          ),
        );
        _appDb.db.execute('DELETE FROM command_outbox WHERE id=?', [id]);
        delivered++;
      } catch (error) {
        switch (classifyQueueFailure(error)) {
          case QueueFailure.network:
            // Could not reach the server: not the command's fault. Keep it
            // due and stop; the other commands would fail the same way.
            _appDb.db.execute(
              'UPDATE command_outbox SET last_error=? WHERE id=?',
              ['$error', id],
            );
            return delivered;
          case QueueFailure.permanent:
            _park(id, '$error');
          case QueueFailure.retryable:
            if (_isInternalError(error) && !isServerId(target)) {
              _park(id, '$error');
            } else {
              _backoff(id, row['attempts'] as int, '$error');
              blocked.add(target);
            }
        }
      }
    }
    return delivered;
  }

  /// Only a plain 500: that is how the server reports a malformed id (a
  /// database cast error). 502/503/504 are outages and stay retryable.
  bool _isInternalError(Object error) =>
      error is ApiException && error.statusCode == 500;

  /// False for ids the phone made up for its own derived rows (SMS-derived
  /// subscriptions `v2:<key>`, server projections `projection:<key>`, queued
  /// transactions `local-outbox:<id>`). The server has no such row, so a 500
  /// for one of them is a permanent condition, not an outage.
  static bool isServerId(String target) =>
      !(target.startsWith('v2:') ||
          target.startsWith('projection:') ||
          target.startsWith('local-outbox:') ||
          target.startsWith('local:'));

  void _park(int id, String error) => _appDb.db.execute(
    'UPDATE command_outbox SET parked=1, last_error=? WHERE id=?',
    [error, id],
  );

  void _backoff(int id, int attempts, String error) {
    final seconds = (30 * (1 << attempts.clamp(0, 6))).clamp(
      30,
      _maxBackoffSeconds,
    );
    _appDb.db.execute(
      'UPDATE command_outbox SET attempts=attempts+1, last_error=?, next_attempt_at=? WHERE id=?',
      [error, _now().millisecondsSinceEpoch + seconds * 1000, id],
    );
  }

  /// Removes everything queued for this account (sign-out / account wipe).
  void clear() => _appDb.db.execute(
    'DELETE FROM command_outbox WHERE namespace=?',
    [namespace],
  );
}
