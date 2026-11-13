import 'package:sqlite3/sqlite3.dart';

import 'app_database.dart';

/// One list describing every durable queue on the phone (WP-C2, Q-11).
///
/// Five hand-maintained lists used to drift apart (the sign-out report, the
/// sign-out flush, `pendingRecoveryStatusProvider`, the backup `_queues` and
/// the restore wipe list). They are meant to read this registry instead, so a
/// queue added here is counted, flushed, backed up and wiped everywhere.
/// This file only provides the list and the counting/flush API; rewiring the
/// readers is separate work (WP-C3).
///
/// To add a queue, append a [QueueSpec] to [QueueRegistry.defaultQueues]. The
/// counting SQL is read-only and tolerant: a table or column that does not
/// exist yet (a queue whose owner creates it lazily, or a module that has not
/// run on this install) counts as 0, it never throws.

/// Whether a spec is delivered to the server later, or is data that only
/// lives on this phone (it still matters to sign-out: it would be lost).
enum QueueKind { outbox, localData }

/// How many entries of one queue (for one account) are in each state.
class QueueCounts {
  const QueueCounts({this.pending = 0, this.parked = 0, this.blocked = 0});

  /// Waiting to be sent, or in a backoff: will go without anyone acting.
  final int pending;

  /// The server refused it for good (or it ran out of automatic attempts).
  /// Kept with its error; needs the person to retry or discard.
  final int parked;

  /// Cannot go until something else happens (sign in again, an earlier
  /// command to be delivered).
  final int blocked;

  int get total => pending + parked + blocked;
  bool get isEmpty => total == 0;

  QueueCounts operator +(QueueCounts other) => QueueCounts(
    pending: pending + other.pending,
    parked: parked + other.parked,
    blocked: blocked + other.blocked,
  );

  static const zero = QueueCounts();

  @override
  String toString() =>
      'QueueCounts(pending: $pending, parked: $parked, blocked: $blocked)';

  @override
  bool operator ==(Object other) =>
      other is QueueCounts &&
      other.pending == pending &&
      other.parked == parked &&
      other.blocked == blocked;

  @override
  int get hashCode => Object.hash(pending, parked, blocked);
}

/// Sends what is queued; returns how many entries were delivered.
typedef QueueFlush = Future<int> Function();

/// Describes one queue.
///
/// [pendingWhere], [parkedWhere] and [blockedWhere] are SQL boolean
/// expressions over one row of [table]. A row is counted when it satisfies
/// [pendingWhere] (default: every row of the account); of those, a row that
/// satisfies [parkedWhere] is parked, else one that satisfies [blockedWhere]
/// is blocked, else it is pending. [parkedColumns] / [blockedColumns] name the
/// columns those expressions use: while one of them does not exist yet the
/// expression is ignored (rows count as pending) instead of failing.
class QueueSpec {
  const QueueSpec({
    required this.name,
    required this.table,
    this.namespaceColumn = 'namespace',
    this.kind = QueueKind.outbox,
    this.pendingWhere = '1 = 1',
    this.parkedWhere,
    this.parkedColumns = const {},
    this.blockedWhere,
    this.blockedColumns = const {},
    this.extraTables = const [],
    this.customCountSql,
    this.customCountTables = const [],
    this.note,
  });

  /// Stable id, used as the key of counts and flush results.
  final String name;
  final String table;
  final String namespaceColumn;
  final QueueKind kind;
  final String pendingWhere;
  final String? parkedWhere;
  final Set<String> parkedColumns;
  final String? blockedWhere;
  final Set<String> blockedColumns;

  /// Further tables that belong to the same queue (for backup/wipe lists).
  final List<String> extraTables;

  /// For a queue that is not simply the rows of one table (statement import:
  /// a batch is pending while its ciphertext is stored and its session open).
  /// One `SELECT` with a single `?` (the account) returning the integer
  /// columns `total` and `parked`, and optionally `blocked`. When set, the
  /// `*Where` expressions are ignored; every table of [tables] must exist.
  final String? customCountSql;

  /// Tables [customCountSql] reads; all must exist or the queue counts 0.
  final List<String> customCountTables;
  final String? note;

  /// Every table this queue uses.
  List<String> get tables => [table, ...extraTables];
}

/// Result of [QueueRegistry.flushAll].
class QueueFlushReport {
  QueueFlushReport(this.delivered, this.failures);

  /// Entries delivered per queue name (only queues that have a flusher).
  final Map<String, int> delivered;

  /// Queues whose flusher threw. A failing queue never stops the others.
  final Map<String, Object> failures;

  int get totalDelivered => delivered.values.fold(0, (a, b) => a + b);
}

class QueueRegistry {
  QueueRegistry(this._database, {List<QueueSpec>? queues})
    : _queues = List.unmodifiable(queues ?? defaultQueues) {
    final seen = <String>{};
    for (final spec in _queues) {
      if (!seen.add(spec.name)) {
        throw ArgumentError('Duplicate queue name: ${spec.name}');
      }
    }
  }

  final AppDatabase _database;
  final List<QueueSpec> _queues;
  final Map<String, QueueFlush> _flushers = {};

  Database get _db => _database.db;

  /// Every existing queue, from the storage audit (appendix B of the offline
  /// plan). Table and column names were read from the code that owns them.
  static const List<QueueSpec> defaultQueues = [
    // Field edits for /sync/push. `attempts >= 5` is how SyncQueue parks a
    // change (SyncQueue.maxAttempts); it stays saved but leaves the automatic
    // retry set.
    QueueSpec(
      name: 'sync_pending_changes',
      table: 'sync_pending_changes',
      // in_flight = 2: the server applied it, only its fresh copy is awaited.
      pendingWhere: 'in_flight != 2',
      parkedWhere: 'attempts >= 5',
      parkedColumns: {'attempts'},
    ),
    // New transactions (quick add, voice, ...). A row in backoff is pending.
    QueueSpec(
      name: 'transaction_outbox_entries',
      table: 'transaction_outbox_entries',
      parkedWhere: 'parked = 1',
      parkedColumns: {'parked'},
    ),
    // Duplicate-review decisions; five counted failures block an entry.
    QueueSpec(
      name: 'duplicate_resolution_outbox',
      table: 'duplicate_resolution_outbox',
      parkedWhere: 'attempts >= 5',
      parkedColumns: {'attempts'},
    ),
    // Ignore/restore/budget/recurring/lounge/points commands.
    QueueSpec(
      name: 'command_outbox',
      table: 'command_outbox',
      parkedWhere: 'parked = 1',
      parkedColumns: {'parked'},
    ),
    // Tag changes. `parked` arrives with the queue hygiene migration.
    QueueSpec(
      name: 'transaction_tag_outbox',
      table: 'transaction_tag_outbox',
      parkedWhere: 'parked = 1',
      parkedColumns: {'parked'},
    ),
    // Foreign-payment decisions. `parked` arrives with the same migration.
    QueueSpec(
      name: 'foreign_payments_outbox',
      table: 'foreign_payments_outbox',
      parkedWhere: 'parked = 1',
      parkedColumns: {'parked'},
    ),
    // Split commands. awaitingAuth waits for a sign-in; rejected/conflict were
    // refused for good and have no screen yet; committed ones are history.
    QueueSpec(
      name: 'shared_commands',
      table: 'shared_commands',
      pendingWhere: "state != 'committed'",
      parkedWhere: "state IN ('rejected', 'conflict')",
      parkedColumns: {'state'},
      blockedWhere: "state = 'awaitingAuth'",
      blockedColumns: {'state'},
      extraTables: [
        'shared_command_dependencies',
        'shared_source_dependencies',
        'shared_operation_receipts',
        'shared_provisional',
        'shared_editor_drafts',
        'shared_editor_receipts',
      ],
    ),
    // Split documents waiting to be saved; `blocked` ones were refused.
    QueueSpec(
      name: 'split_documents',
      table: 'split_documents',
      pendingWhere: 'pending = 1',
      parkedWhere: 'blocked = 1',
      parkedColumns: {'blocked'},
    ),
    // Statement import continuation: one entry per stored (encrypted) batch of
    // an open session. A session that needs review is parked.
    QueueSpec(
      name: 'statement_import',
      table: 'statement_import_batches',
      extraTables: ['statement_import_sessions', 'statement_import_leases'],
      customCountTables: [
        'statement_import_batches',
        'statement_import_sessions',
      ],
      customCountSql:
          'SELECT COUNT(*) AS total, '
          "COALESCE(SUM(CASE WHEN s.state = 'needs_review' THEN 1 ELSE 0 END), 0) AS parked "
          'FROM statement_import_batches b '
          'JOIN statement_import_sessions s '
          'ON s.namespace = b.namespace AND s.session_id = b.session_id '
          "WHERE b.namespace = ? AND b.ciphertext IS NOT NULL AND s.state IN ('pending', 'needs_review')",
    ),
    // SMS v2 facts/corrections to upload. No parked state: failures back off.
    QueueSpec(
      name: 'v2_outbox',
      table: 'v2_outbox',
      note: 'attempts/next_attempt_at back off up to 30 minutes',
    ),
    // Raw SMS waiting to be parsed.
    QueueSpec(name: 'sms_intake', table: 'sms_intake'),
    // Parsed-message history kept only on the phone: not a send queue, but
    // lost on sign-out, so sign-out reports it.
    QueueSpec(
      name: 'sms_captured_messages',
      table: 'sms_captured_messages',
      kind: QueueKind.localData,
    ),
  ];

  List<QueueSpec> get queues => _queues;

  /// Every table of every queue, for backup, restore and wipe lists.
  List<String> get allTables => [for (final spec in _queues) ...spec.tables];

  QueueSpec spec(String name) => _queues.firstWhere(
    (queue) => queue.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'Unknown queue'),
  );

  /// Counts one queue for [namespace]. 0 when its table does not exist.
  QueueCounts countsFor(String name, String namespace) =>
      _count(spec(name), namespace);

  /// Counts every queue for [namespace], in registry order.
  Map<String, QueueCounts> countAll(String namespace) => {
    for (final spec in _queues) spec.name: _count(spec, namespace),
  };

  /// Everything still to be delivered (send queues only).
  QueueCounts unsent(String namespace) => _sum(namespace, QueueKind.outbox);

  /// Data that exists only on this phone and would be lost.
  QueueCounts localOnly(String namespace) =>
      _sum(namespace, QueueKind.localData);

  /// True when anything is queued for delivery.
  bool hasUnsent(String namespace) => !unsent(namespace).isEmpty;

  QueueCounts _sum(String namespace, QueueKind kind) {
    var total = QueueCounts.zero;
    for (final spec in _queues) {
      if (spec.kind == kind) total += _count(spec, namespace);
    }
    return total;
  }

  bool _tableExists(String table) => _db.select(
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
    [table],
  ).isNotEmpty;

  QueueCounts _count(QueueSpec spec, String namespace) {
    final custom = spec.customCountSql;
    if (custom != null) {
      if (!spec.customCountTables.every(_tableExists)) return QueueCounts.zero;
      final row = _db.select(custom, [namespace]).single;
      final parked = row['parked'] as int;
      final blocked =
          (row.containsKey('blocked') ? row['blocked'] as int? : 0) ?? 0;
      return QueueCounts(
        pending: (row['total'] as int) - parked - blocked,
        parked: parked,
        blocked: blocked,
      );
    }
    if (!_tableExists(spec.table)) return QueueCounts.zero;
    final columns = _db
        .select('PRAGMA table_info("${spec.table}")')
        .map((row) => row['name'] as String)
        .toSet();
    if (!columns.contains(spec.namespaceColumn)) return QueueCounts.zero;
    final parked =
        spec.parkedWhere != null && columns.containsAll(spec.parkedColumns)
        ? spec.parkedWhere!
        : '0';
    final blocked =
        spec.blockedWhere != null && columns.containsAll(spec.blockedColumns)
        ? spec.blockedWhere!
        : '0';
    final ResultSet rows;
    try {
      rows = _db.select(
        'SELECT COUNT(*) AS total, '
        'COALESCE(SUM(CASE WHEN ($parked) THEN 1 ELSE 0 END), 0) AS parked, '
        'COALESCE(SUM(CASE WHEN NOT ($parked) AND ($blocked) THEN 1 ELSE 0 END), 0) AS blocked '
        'FROM "${spec.table}" '
        'WHERE "${spec.namespaceColumn}" = ? AND (${spec.pendingWhere})',
        [namespace],
      );
    } on SqliteException catch (error) {
      // A column the spec relies on is not there (an older or newer schema).
      // Anything else (a locked database, corruption) must surface.
      if (error.message.contains('no such column')) return QueueCounts.zero;
      rethrow;
    }
    final row = rows.single;
    final total = row['total'] as int;
    final parkedCount = row['parked'] as int;
    final blockedCount = row['blocked'] as int;
    return QueueCounts(
      pending: total - parkedCount - blockedCount,
      parked: parkedCount,
      blocked: blockedCount,
    );
  }

  /// Registers how to send queue [name]. Done by the code that owns the
  /// repositories (it needs the signed-in providers), not by the registry.
  void attachFlush(String name, QueueFlush flush) {
    spec(name); // validates the name
    _flushers[name] = flush;
  }

  bool hasFlush(String name) => _flushers.containsKey(name);

  /// Runs every attached flusher (or only [only]), one after another, in
  /// registry order. A failing queue is reported, never fatal to the rest.
  Future<QueueFlushReport> flushAll({Iterable<String>? only}) async {
    final wanted = only?.toSet();
    final delivered = <String, int>{};
    final failures = <String, Object>{};
    for (final spec in _queues) {
      if (wanted != null && !wanted.contains(spec.name)) continue;
      final flush = _flushers[spec.name];
      if (flush == null) continue;
      try {
        delivered[spec.name] = await flush();
      } catch (error) {
        failures[spec.name] = error;
      }
    }
    return QueueFlushReport(delivered, failures);
  }
}
