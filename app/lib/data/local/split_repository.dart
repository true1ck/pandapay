import '../portable_backup/account_recovery_operation_gate.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../api_exception.dart';
import '../user_cards_repository.dart';
import 'app_database.dart';

class LocalSplitDocument {
  final TransactionSplitDocument document;
  final bool pending;
  final String? error;
  final bool blocked;
  final int version;
  final DateTime fetchedAt;
  const LocalSplitDocument(
    this.document,
    this.pending,
    this.error,
    this.blocked,
    this.version,
    this.fetchedAt,
  );
}

/// One durable row is both the displayed document and its coalescing outbox.
/// Persisting pending state and content in one SQLite statement is atomic.
/// The server remains authoritative for ownership, totals and conflicts.
class SplitRepository extends ChangeNotifier {
  final AppDatabase database;
  final String namespace;
  final UserCardsRepository? Function() remote;
  final bool Function() canSync;
  final DateTime Function() now;
  final bool autoSync;
  final _reads = <String, Future<void>>{};
  Timer? _timer;
  bool _running = false, _disposed = false;

  SplitRepository(
    this.database, {
    required this.namespace,
    required this.remote,
    required this.canSync,
    required this.now,
    this.autoSync = true,
  }) {
    database.db.execute('''CREATE TABLE IF NOT EXISTS split_documents (
      namespace TEXT NOT NULL, transaction_id TEXT NOT NULL,
      document_json TEXT NOT NULL, pending INTEGER NOT NULL DEFAULT 0,
      version INTEGER NOT NULL DEFAULT 0, fetched_at INTEGER NOT NULL,
      error TEXT, blocked INTEGER NOT NULL DEFAULT 0,
      attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(namespace, transaction_id)
    )''');
    database.db.execute(
      'CREATE INDEX IF NOT EXISTS split_documents_pending '
      'ON split_documents(namespace,pending,blocked,next_attempt)',
    );
  }

  bool get _online => !_disposed && canSync() && remote() != null;
  int get pendingCount =>
      database.db.select(
            'SELECT COUNT(*) AS count FROM split_documents WHERE namespace=? AND pending=1',
            [namespace],
          ).single['count']
          as int;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  LocalSplitDocument? local(String id) {
    final rows = database.db.select(
      'SELECT * FROM split_documents WHERE namespace=? AND transaction_id=?',
      [namespace, id],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    return LocalSplitDocument(
      TransactionSplitDocument.fromJson(
        jsonDecode(r['document_json'] as String) as Map<String, dynamic>,
      ),
      r['pending'] == 1,
      r['error'] as String?,
      r['blocked'] == 1,
      r['version'] as int,
      DateTime.fromMillisecondsSinceEpoch(r['fetched_at'] as int),
    );
  }

  static String fingerprint(List<TransactionSplit> splits) {
    final rows =
        splits
            .map(
              (s) => jsonEncode([
                s.amount.paise,
                s.userCardId,
                s.categoryId,
                s.note?.isEmpty == true ? null : s.note,
              ]),
            )
            .toList()
          ..sort();
    return sha256.convert(utf8.encode(jsonEncode(rows))).toString();
  }

  TransactionSplitDocument _versioned(TransactionSplitDocument doc) =>
      TransactionSplitDocument(
        doc.splits,
        fingerprint: doc.fingerprint ?? fingerprint(doc.splits),
      );

  /// Migrate the former account-scoped cache once, preserving its actual age.
  void seed(String id, TransactionSplitDocument doc, DateTime fetchedAt) {
    database.db.execute(
      'INSERT OR IGNORE INTO split_documents '
      '(namespace,transaction_id,document_json,fetched_at) VALUES (?,?,?,?)',
      [
        namespace,
        id,
        jsonEncode(_versioned(doc).toJson()),
        fetchedAt.millisecondsSinceEpoch,
      ],
    );
  }

  Future<LocalSplitDocument> read(String id) async {
    final saved = local(id);
    if (saved != null) {
      if (!saved.pending &&
          now().difference(saved.fetchedAt) >= const Duration(minutes: 5) &&
          _online) {
        unawaited(refresh(id).catchError((Object _) {}));
      }
      return saved;
    }
    await refresh(id);
    return local(id)!;
  }

  Future<void> refresh(String id) async {
    final existing = _reads[id];
    if (existing != null) return existing;
    final request = _refresh(id);
    _reads[id] = request;
    try {
      await request;
    } finally {
      _reads.remove(id);
    }
  }

  Future<void> _refresh(String id) async {
    if (!_online) {
      throw StateError(
        'Connect once to load this expense’s current split before editing.',
      );
    }
    final before = local(id);
    if (before?.pending == true) return;
    final doc = _versioned(await remote()!.fetchSplitDocument(id));
    if (!_online) return;
    final current = local(id);
    if (current?.pending == true || current?.version != before?.version) return;
    database.db.execute(
      'INSERT INTO split_documents '
      '(namespace,transaction_id,document_json,fetched_at,version) VALUES (?,?,?,?,?) '
      'ON CONFLICT(namespace,transaction_id) DO UPDATE SET document_json=excluded.document_json, '
      'fetched_at=excluded.fetched_at,version=excluded.version',
      [
        namespace,
        id,
        jsonEncode(doc.toJson()),
        now().millisecondsSinceEpoch,
        (before?.version ?? 0) + 1,
      ],
    );
    _changed();
  }

  void save(String id, List<TransactionSplit> splits, Money total) {
    if (_disposed) {
      throw StateError(
        'Account changed. Reopen the transaction before editing.',
      );
    }
    final previous = local(id);
    if (previous == null) {
      throw StateError('Load the current split before editing.');
    }
    if (splits.length > 20 ||
        splits.any(
          (s) => s.amount.paise <= 0 || (s.note?.length ?? 0) > 2000,
        ) ||
        splits.fold<int>(0, (sum, s) => sum + s.amount.paise) > total.paise) {
      throw StateError('Check the share amounts and notes before saving.');
    }
    if (!previous.pending &&
        fingerprint(splits) == fingerprint(previous.document.splits)) {
      return;
    }
    final doc = TransactionSplitDocument(
      splits,
      fingerprint: previous.document.fingerprint,
    );
    database.db.execute(
      'UPDATE split_documents SET document_json=?,pending=1,version=version+1,'
      'error=NULL,blocked=0,attempts=0,next_attempt=0 WHERE namespace=? AND transaction_id=?',
      [jsonEncode(doc.toJson()), namespace, id],
    );
    _changed();
    _schedule(const Duration(milliseconds: 750));
  }

  void _schedule(Duration delay) {
    if (!autoSync || _disposed) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      unawaited(sync());
    });
  }

  /// Resume/reconnect drains only pending documents; clean records cost no GET.
  Future<void> sync({bool reconnect = false}) async {
    try {
      await AccountRecoveryOperationGate.process.run(() => _sync(reconnect: reconnect));
    } on AccountRecoveryBusy {
      // Pending documents remain durable until the next resume/reconnect.
    }
  }

  Future<void> _sync({bool reconnect = false}) async {
    if (_running || !_online) return;
    _timer?.cancel();
    _running = true;
    try {
      if (reconnect) {
        database.db.execute(
          'UPDATE split_documents SET next_attempt=0 '
          'WHERE namespace=? AND pending=1 AND blocked=0',
          [namespace],
        );
      }
      final rows = database.db.select(
        'SELECT transaction_id FROM split_documents '
        'WHERE namespace=? AND pending=1 AND blocked=0 AND next_attempt<=? LIMIT 50',
        [namespace, now().millisecondsSinceEpoch],
      );
      for (final row in rows) {
        if (!_online) break;
        final id = row['transaction_id'] as String;
        final sent = local(id)!;
        try {
          final accepted = _versioned(
            await remote()!.saveSplitDocument(id, sent.document),
          );
          if (!_online) break;
          final current = local(id)!;
          // An edit made in flight survives this acknowledgement. Its baseline
          // advances to the accepted document so the next PUT can safely follow.
          if (current.version == sent.version) {
            database.db.execute(
              'UPDATE split_documents SET document_json=?,pending=0,error=NULL,'
              'blocked=0,attempts=0,next_attempt=0,fetched_at=? WHERE namespace=? AND transaction_id=?',
              [
                jsonEncode(accepted.toJson()),
                now().millisecondsSinceEpoch,
                namespace,
                id,
              ],
            );
          } else if (current.document.fingerprint ==
              sent.document.fingerprint) {
            database.db.execute(
              'UPDATE split_documents SET document_json=? WHERE namespace=? AND transaction_id=?',
              [
                jsonEncode(
                  TransactionSplitDocument(
                    current.document.splits,
                    fingerprint: accepted.fingerprint,
                  ).toJson(),
                ),
                namespace,
                id,
              ],
            );
          }
          _changed();
        } catch (error) {
          if (_disposed) break;
          final status = error is ApiException ? error.statusCode : null;
          final blocked =
              status != null &&
              status >= 400 &&
              status < 500 &&
              status != 401 &&
              status != 408 &&
              status != 429;
          final attempts =
              database.db.select(
                    'SELECT attempts FROM split_documents '
                    'WHERE namespace=? AND transaction_id=?',
                    [namespace, id],
                  ).single['attempts']
                  as int;
          final seconds = math.min(300, 5 * (1 << math.min(attempts, 6)));
          database.db.execute(
            'UPDATE split_documents SET error=?,blocked=?,attempts=attempts+1,next_attempt=? '
            'WHERE namespace=? AND transaction_id=? AND version=?',
            [
              status == 409
                  ? 'This split changed on another device. Choose which version to keep.'
                  : status == 401
                  ? const AuthenticationUnavailableException().message
                  : userFacingErrorMessage(error),
              blocked ? 1 : 0,
              now().add(Duration(seconds: seconds)).millisecondsSinceEpoch,
              namespace,
              id,
              sent.version,
            ],
          );
          _changed();
          // One unavailable server is not a reason to try every queued bill.
          if (status == null ||
              status == 401 ||
              status == 408 ||
              status == 429 ||
              status >= 500) {
            database.db.execute(
              'UPDATE split_documents SET next_attempt=MAX(next_attempt, ?) '
              'WHERE namespace=? AND pending=1 AND blocked=0',
              [
                now().add(Duration(seconds: seconds)).millisecondsSinceEpoch,
                namespace,
              ],
            );
            break;
          }
        }
      }
    } finally {
      _running = false;
      if (!_disposed && _online) {
        final due =
            database.db.select(
                  'SELECT MIN(next_attempt) AS due FROM split_documents '
                  'WHERE namespace=? AND pending=1 AND blocked=0',
                  [namespace],
                ).single['due']
                as int?;
        if (due != null) {
          _schedule(
            Duration(
              milliseconds: math.max(750, due - now().millisecondsSinceEpoch),
            ),
          );
        }
      }
    }
  }

  /// Explicit user resolution only. A failed fetch preserves both versions.
  Future<TransactionSplitDocument> fetchServerVersion(String id) async {
    if (!_online) throw StateError('Reconnect to resolve this split.');
    return _versioned(await remote()!.fetchSplitDocument(id));
  }

  Future<void> resolve(
    String id, {
    required bool keepLocal,
    TransactionSplitDocument? reviewedServerVersion,
  }) async {
    if (!_online) throw StateError('Reconnect to resolve this split.');
    final before = local(id)!;
    final server = reviewedServerVersion ?? await fetchServerVersion(id);
    if (!_online || local(id)?.version != before.version) return;
    final chosen = keepLocal
        ? TransactionSplitDocument(
            before.document.splits,
            fingerprint: server.fingerprint,
          )
        : server;
    database.db.execute(
      'UPDATE split_documents SET document_json=?,pending=?,version=version+1,error=NULL,'
      'blocked=0,attempts=0,next_attempt=0,fetched_at=? WHERE namespace=? AND transaction_id=?',
      [
        jsonEncode(chosen.toJson()),
        keepLocal ? 1 : 0,
        now().millisecondsSinceEpoch,
        namespace,
        id,
      ],
    );
    _changed();
    if (keepLocal) _schedule(const Duration(milliseconds: 750));
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
