import '../api_exception.dart';
import '../user_cards_repository.dart';
import 'app_database.dart';
import '../connectivity/server_backoff.dart';
import 'queue_retry_policy.dart';

/// Returns true when retrying cannot change the outcome because the candidate
/// is already resolved or no longer exists on the server.
bool isDuplicateResolutionAlreadyHandled(Object error) {
  if (error is! ApiException) return false;
  final code = error.errorCode?.toLowerCase() ?? '';
  final message = error.userMessage.toLowerCase();
  if (error.statusCode == 409) {
    return code.startsWith('already resolved') ||
        message.contains('already resolved');
  }
  if (error.statusCode == 404) {
    return code.contains('duplicate_candidate') ||
        code.contains('duplicate candidate') ||
        message.contains('duplicate_candidate') ||
        message.contains('duplicate candidate');
  }
  return false;
}

/// A durable user decision for one duplicate candidate.
///
/// This is an intent queue, not a local copy of the server's financial
/// tables. The server remains the authority for the atomic transaction,
/// observation, cap, milestone and points changes.
class DuplicateResolutionOutboxEntry {
  const DuplicateResolutionOutboxEntry({
    required this.id,
    required this.candidateId,
    required this.resolution,
    required this.keepTransactionId,
    required this.createdAt,
    required this.attempts,
    this.lastError,
  });

  final int id;
  final String candidateId;
  final String resolution;
  final String? keepTransactionId;
  final DateTime createdAt;
  final int attempts;
  final String? lastError;
}

/// Offline/retry queue for duplicate-review decisions.
///
/// Enqueueing is synchronous and happens before any network request. A
/// successful server response, including an idempotent "already resolved"
/// response, removes the intent. Other failures stay durable for the next
/// connectivity/lifecycle flush, up to five counted attempts; then they wait
/// for an explicit retry from Sync & backup. A failure to reach the server
/// (no connection, timeout, rejected session) is not counted and ends the
/// pass, so a flaky connection cannot burn the five attempts; a permanent 4xx
/// blocks at once. There is no time backoff here, so nothing to reset when the
/// connection returns: the next flush simply retries.
class DuplicateResolutionOutboxRepository {
  /// Automatic flushes are deliberately bounded. A later scheduler pass can
  /// continue from the oldest durable intent, keeping duplicate resolution
  /// work from starving input/raster frames during reconnect or resume.
  static const defaultFlushBatchSize = 20;

  /// Counted failures after which an entry waits for an explicit retry.
  static const maxAttempts = 5;

  DuplicateResolutionOutboxRepository(
    this._appDb, {
    this.namespace = 'legacy',
  }) {
    _appDb.db.execute('''
      CREATE TABLE IF NOT EXISTS duplicate_resolution_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        namespace TEXT NOT NULL DEFAULT 'legacy',
        candidate_id TEXT NOT NULL,
        resolution TEXT NOT NULL,
        keep_transaction_id TEXT,
        created_at INTEGER NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        UNIQUE(namespace, candidate_id)
      )
    ''');
    _appDb.db.execute(
      'CREATE INDEX IF NOT EXISTS idx_duplicate_resolution_outbox_pending '
      'ON duplicate_resolution_outbox(namespace, created_at)',
    );
  }

  final AppDatabase _appDb;
  final String namespace;

  void enqueue({
    required String candidateId,
    required String resolution,
    String? keepTransactionId,
  }) {
    _appDb.db.execute(
      '''
      INSERT INTO duplicate_resolution_outbox
        (namespace, candidate_id, resolution, keep_transaction_id, created_at,
         attempts, last_error)
      VALUES (?, ?, ?, ?, ?, 0, NULL)
      ON CONFLICT(namespace, candidate_id) DO UPDATE SET
        resolution = excluded.resolution,
        keep_transaction_id = excluded.keep_transaction_id,
        created_at = excluded.created_at,
        attempts = 0,
        last_error = NULL
      ''',
      [
        namespace,
        candidateId,
        resolution,
        keepTransactionId,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  List<DuplicateResolutionOutboxEntry> pending({
    bool includeBlocked = true,
    int? limit,
  }) {
    final blockedClause = includeBlocked ? '' : ' AND attempts < $maxAttempts';
    final boundedLimit = limit?.clamp(1, 200);
    final limitClause = boundedLimit == null ? '' : ' LIMIT $boundedLimit';
    final rows = _appDb.db.select(
      'SELECT * FROM duplicate_resolution_outbox '
      'WHERE namespace=?$blockedClause ORDER BY created_at ASC, id ASC$limitClause',
      [namespace],
    );
    return rows.map((row) {
      return DuplicateResolutionOutboxEntry(
        id: row['id'] as int,
        candidateId: row['candidate_id'] as String,
        resolution: row['resolution'] as String,
        keepTransactionId: row['keep_transaction_id'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          row['created_at'] as int,
        ),
        attempts: row['attempts'] as int,
        lastError: row['last_error'] as String?,
      );
    }).toList();
  }

  int get pendingCount =>
      _appDb.db.select(
            'SELECT COUNT(*) AS count FROM duplicate_resolution_outbox WHERE namespace=?',
            [namespace],
          ).single['count']
          as int;

  void remove(int id) {
    _appDb.db.execute(
      'DELETE FROM duplicate_resolution_outbox WHERE namespace=? AND id=?',
      [namespace, id],
    );
  }

  void removeCandidate(String candidateId) {
    _appDb.db.execute(
      'DELETE FROM duplicate_resolution_outbox '
      'WHERE namespace=? AND candidate_id=?',
      [namespace, candidateId],
    );
  }

  /// Makes permanently-failing entries eligible for an explicit user retry.
  ///
  /// Automatic flushes still retain the attempt count so the sync screen can
  /// surface entries that need attention instead of retrying them silently
  /// forever.
  int resetBlocked() {
    final count =
        _appDb.db.select(
              'SELECT COUNT(*) AS count FROM duplicate_resolution_outbox '
              'WHERE namespace=? AND attempts>=$maxAttempts',
              [namespace],
            ).single['count']
            as int;
    _appDb.db.execute(
      'UPDATE duplicate_resolution_outbox '
      'SET attempts=0, last_error=NULL '
      'WHERE namespace=? AND attempts>=$maxAttempts',
      [namespace],
    );
    return count;
  }

  Future<int> flush(
    UserCardsRepository repository, {
    int maxEntries = defaultFlushBatchSize,
  }) async {
    var sent = 0;
    for (final entry in pending(includeBlocked: false, limit: maxEntries)) {
      if (ServerBackoff.process.isPaused) break; // the server asked us to wait
      try {
        await repository.resolveDuplicateCandidate(
          entry.candidateId,
          resolution: entry.resolution,
          keepTransactionId: entry.keepTransactionId,
        );
        remove(entry.id);
        sent++;
      } catch (error) {
        if (isDuplicateResolutionAlreadyHandled(error)) {
          remove(entry.id);
          sent++;
        } else {
          final failure = classifyQueueFailure(error);
          switch (failure) {
            case QueueFailure.network:
              _appDb.db.execute(
                'UPDATE duplicate_resolution_outbox SET last_error=? '
                'WHERE namespace=? AND id=?',
                [error.toString(), namespace, entry.id],
              );
            case QueueFailure.retryable:
              _appDb.db.execute(
                'UPDATE duplicate_resolution_outbox '
                'SET attempts=attempts+1, last_error=? '
                'WHERE namespace=? AND id=?',
                [error.toString(), namespace, entry.id],
              );
            case QueueFailure.permanent:
              _appDb.db.execute(
                'UPDATE duplicate_resolution_outbox '
                'SET attempts=MAX(attempts+1, $maxAttempts), last_error=? '
                'WHERE namespace=? AND id=?',
                [error.toString(), namespace, entry.id],
              );
          }
          // Could not reach the server: the rest would fail the same way.
          if (failure == QueueFailure.network) break;
        }
      }
      // Yield between entries so a reconnect/resume flush cannot monopolise
      // the Dart isolate while it drains a backlog.
      await Future<void>.delayed(Duration.zero); // perf-ok: bounded 20-row outbox batch
    }
    return sent;
  }
}
