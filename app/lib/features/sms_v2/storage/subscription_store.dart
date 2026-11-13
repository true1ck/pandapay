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

  /// Something that may alter a subscription changed; re-derive before reading.
  void markDirty() => _setFlag(_dirtyKey, '1');

  /// True when the rows can be read as they are.
  bool get isCurrent => isBuilt && !isDirty;

  /// Every service of this account, in no particular order.
  List<SubscriptionState> states() => [
    for (final row in db.select(
      'SELECT payload FROM v2_subscriptions WHERE namespace=?',
      [namespace],
    ))
      SubscriptionState.fromJson(
        (jsonDecode(row['payload'] as String) as Map).cast<String, Object?>(),
      ),
  ];

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
  /// savepoint, then records that they are current. A reader never sees half
  /// of a rebuild.
  void replaceAll(
    Iterable<SubscriptionState> states,
    Map<String, List<SubscriptionHistoryEntry>> history, {
    DateTime? at,
  }) {
    final stamp = (at ?? DateTime.now()).toUtc().toIso8601String();
    db.execute('SAVEPOINT v2_subscriptions_write');
    try {
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
      db.execute('RELEASE v2_subscriptions_write');
    } catch (_) {
      db.execute('ROLLBACK TO v2_subscriptions_write');
      db.execute('RELEASE v2_subscriptions_write');
      rethrow;
    }
  }
}
