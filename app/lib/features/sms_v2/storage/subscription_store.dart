import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../ledger/adapters.dart' show SubscriptionHistoryEntry, SubscriptionHistoryKind;
import '../ledger/subscription_state.dart';

/// The one place the phone keeps subscription data: a row per service
/// (`v2_subscriptions`) and the dated story of each (`v2_subscription_history`).
///
/// Rows are derived from the SMS ledger by `SubscriptionProjection` whenever the
/// ledger changes, never edited by a screen. Every reader (Payments >
/// Subscriptions, the SMS ledger list, the Insights tile, renewal reminders,
/// the detail history) reads these few rows instead of walking the history.
class SubscriptionStore {
  const SubscriptionStore(this.db, {required this.namespace});

  final Database db;
  final String namespace;

  /// Bump when the way rows are derived changes, so every phone re-derives them
  /// once after the update.
  static const int projectionVersion = 1;

  static const _versionKey = 'subscriptions_projection_version';
  static const _dirtyKey = 'subscriptions_dirty';
  static const _seqKey = 'subscriptions_seq';

  String? _flag(String key) =>
      db.select('SELECT value FROM v2_sync_state WHERE namespace=? AND key=?', [
            namespace,
            key,
          ]).firstOrNull?['value']
          as String?;

  void _setFlag(String key, String value) => db.execute(
    'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
    'ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
    [namespace, key, value],
  );

  /// True once rows were derived by this version of the code.
  bool get isBuilt => _flag(_versionKey) == '$projectionVersion';

  /// True when the ledger changed in a way that may alter a subscription and
  /// the rows have not been re-derived yet.
  bool get isDirty => _flag(_dirtyKey) == '1';

  /// A counter that goes up every time something that may alter a subscription
  /// changed. A rebuild reads it BEFORE it reads the ledger and writes its rows
  /// only if it is still the same afterwards ([replaceAll]), so a rebuild that
  /// raced a cancellation, a correction or a pull can never overwrite newer
  /// facts with older rows or clear the dirty flag over them.
  int get seq => int.tryParse(_flag(_seqKey) ?? '') ?? 0;

  /// Something that may alter a subscription changed; re-derive before reading.
  /// Cheap and safe to call from any write path, inside or outside a transaction.
  void markDirty() {
    db.execute(
      'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
      'ON CONFLICT(namespace,key) DO UPDATE SET '
      'value = CAST(CAST(value AS INTEGER) + 1 AS TEXT)',
      [namespace, _seqKey, '1'],
    );
    _setFlag(_dirtyKey, '1');
  }

  /// True when the rows can be read as they are.
  bool get isCurrent => isBuilt && !isDirty;

  /// Every service of this account, in no particular order. One row that cannot
  /// be read is skipped, so the rest still show (the next rebuild rewrites it).
  List<SubscriptionState> states() {
    final result = <SubscriptionState>[];
    for (final row in db.select(
      'SELECT payload FROM v2_subscriptions WHERE namespace=?',
      [namespace],
    )) {
      try {
        result.add(
          SubscriptionState.fromJson(
            (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
          ),
        );
      } catch (_) {
        continue;
      }
    }
    return result;
  }

  /// The story of one service, newest first.
  List<SubscriptionHistoryEntry> historyFor(String seriesId) => _entries(
    db.select(
      'SELECT kind, at, amount_minor, previous_minor, source_key '
      'FROM v2_subscription_history INDEXED BY idx_v2_subscription_history_at '
      'WHERE namespace=? AND series_id=? ORDER BY at DESC, seq DESC',
      [namespace, seriesId],
    ),
  );

  /// The story of every service, newest first, keyed by series id.
  Map<String, List<SubscriptionHistoryEntry>> allHistory() {
    final result = <String, List<SubscriptionHistoryEntry>>{};
    for (final row in db.select(
      'SELECT series_id, kind, at, amount_minor, previous_minor, source_key '
      'FROM v2_subscription_history WHERE namespace=? '
      'ORDER BY series_id, at DESC, seq DESC',
      [namespace],
    )) {
      result
          .putIfAbsent(row['series_id'] as String, () => [])
          .addAll(_entries([row]));
    }
    return result;
  }

  static List<SubscriptionHistoryEntry> _entries(Iterable<Row> rows) => [
    for (final row in rows)
      SubscriptionHistoryEntry(
        kind: SubscriptionHistoryKind.values.firstWhere(
          (k) => k.name == row['kind'],
          orElse: () => SubscriptionHistoryKind.charge,
        ),
        at: DateTime.parse(row['at'] as String),
        amountMinor: row['amount_minor'] as int?,
        previousAmountMinor: row['previous_minor'] as int?,
        sourceKey: row['source_key'] as String?,
      ),
  ];

  /// Replaces every row of this account with [states] and [history] in one
  /// transaction, then records that they are current. A reader never sees half
  /// of a rebuild.
  ///
  /// With [basedOnSeq] (the [seq] read before the ledger was read) the swap is
  /// a compare-and-set: when something called [markDirty] since, nothing is
  /// written, the flag stays dirty and false is returned, so the caller derives
  /// again from the newer ledger. Without it the swap is unconditional.
  /// Returns true when the rows were saved.
  bool replaceAll(
    Iterable<SubscriptionState> states,
    Map<String, List<SubscriptionHistoryEntry>> history, {
    DateTime? at,
    int? basedOnSeq,
  }) {
    final stamp = (at ?? DateTime.now()).toUtc().toIso8601String();
    // Outside a transaction the write lock is taken up front (BEGIN IMMEDIATE),
    // so no other connection (the capture worker) can commit between the check
    // and the swap, and the lock upgrade cannot fail halfway. Inside one, a
    // savepoint joins the caller's transaction.
    final ownTransaction = db.autocommit;
    db.execute(ownTransaction ? 'BEGIN IMMEDIATE' : 'SAVEPOINT v2_subscriptions_write');
    try {
      if (basedOnSeq != null && seq != basedOnSeq) {
        _finish(ownTransaction, commit: false);
        return false;
      }
      db.execute('DELETE FROM v2_subscriptions WHERE namespace=?', [namespace]);
      db.execute(
        'DELETE FROM v2_subscription_history WHERE namespace=?',
        [namespace],
      );
      final insertState = db.prepare(
        'INSERT INTO v2_subscriptions '
        '(namespace, series_id, kind, name, payload, updated_at) '
        'VALUES (?,?,?,?,?,?)',
      );
      final insertHistory = db.prepare(
        'INSERT INTO v2_subscription_history '
        '(namespace, series_id, seq, kind, at, amount_minor, previous_minor, source_key) '
        'VALUES (?,?,?,?,?,?,?,?)',
      );
      try {
        for (final s in states) {
          insertState.execute([
            namespace,
            s.seriesId,
            s.kind.name,
            s.name,
            jsonEncode(s.toJson()),
            stamp,
          ]);
        }
        for (final entry in history.entries) {
          // Stored oldest first so `seq` follows the order things happened.
          final oldestFirst = entry.value.reversed.toList();
          for (var i = 0; i < oldestFirst.length; i++) {
            final h = oldestFirst[i];
            insertHistory.execute([
              namespace,
              entry.key,
              i,
              h.kind.name,
              h.at.toUtc().toIso8601String(),
              h.amountMinor,
              h.previousAmountMinor,
              h.sourceKey,
            ]);
          }
        }
      } finally {
        insertState.dispose();
        insertHistory.dispose();
      }
      _setFlag(_versionKey, '$projectionVersion');
      _setFlag(_dirtyKey, '0');
      _finish(ownTransaction, commit: true);
      return true;
    } catch (_) {
      _finish(ownTransaction, commit: false);
      rethrow;
    }
  }

  void _finish(bool ownTransaction, {required bool commit}) {
    if (ownTransaction) {
      db.execute(commit ? 'COMMIT' : 'ROLLBACK');
    } else {
      if (!commit) db.execute('ROLLBACK TO v2_subscriptions_write');
      db.execute('RELEASE v2_subscriptions_write');
    }
  }
}
