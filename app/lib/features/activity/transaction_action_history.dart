import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../app/providers.dart';

/// One thing the person did to a payment from "Choose an action", kept so it can
/// be seen later and taken back. Stored on this phone only, in the account's
/// key/value table (no schema change).
class TxnActionRecord {
  const TxnActionRecord({
    required this.id,
    required this.at,
    required this.action,
    required this.title,
    required this.amountPaise,
    required this.scope,
    required this.targets,
    required this.undo,
    this.undoneAt,
  });

  final String id;
  final DateTime at;

  /// A [TxnAction] name.
  final String action;
  final String title;
  final int amountPaise;

  /// Words for how far it reached ("Only this payment", "12 payments", ...).
  final String scope;

  /// The payments it changed (the first is the one the person was looking at).
  final List<String> targets;

  /// What it takes to reverse it; read by the flow, opaque here.
  final Map<String, Object?> undo;
  final DateTime? undoneAt;

  bool get isUndone => undoneAt != null;

  Map<String, Object?> toJson() => {
    'id': id,
    'at': at.toUtc().toIso8601String(),
    'action': action,
    'title': title,
    'amount': amountPaise,
    'scope': scope,
    'targets': targets,
    'undo': undo,
    if (undoneAt != null) 'undone_at': undoneAt!.toUtc().toIso8601String(),
  };

  static TxnActionRecord? fromJson(Object? raw) {
    try {
      final m = (raw as Map).cast<String, Object?>();
      return TxnActionRecord(
        id: m['id'] as String,
        at: DateTime.parse(m['at'] as String).toLocal(),
        action: m['action'] as String,
        title: (m['title'] as String?) ?? '',
        amountPaise: (m['amount'] as num?)?.toInt() ?? 0,
        scope: (m['scope'] as String?) ?? '',
        targets: [for (final t in (m['targets'] as List? ?? const [])) '$t'],
        undo: ((m['undo'] as Map?) ?? const {}).cast<String, Object?>(),
        undoneAt: m['undone_at'] == null
            ? null
            : DateTime.parse(m['undone_at'] as String).toLocal(),
      );
    } catch (_) {
      return null;
    }
  }

  TxnActionRecord markUndone(DateTime now) => TxnActionRecord(
    id: id,
    at: at,
    action: action,
    title: title,
    amountPaise: amountPaise,
    scope: scope,
    targets: targets,
    undo: undo,
    undoneAt: now,
  );
}

class TransactionActionHistory {
  const TransactionActionHistory(this.db, {required this.namespace});
  final Database db;
  final String namespace;

  static const _prefix = 'txn-action:';

  void save(TxnActionRecord r) => db.execute(
    'INSERT INTO v2_sync_state(namespace,key,value) VALUES(?,?,?) '
    'ON CONFLICT(namespace,key) DO UPDATE SET value=excluded.value',
    [namespace, '$_prefix${r.id}', jsonEncode(r.toJson())],
  );

  /// Newest first. [transactionId] keeps only the actions that touched it.
  List<TxnActionRecord> list({String? transactionId}) {
    final rows = db.select(
      'SELECT value FROM v2_sync_state WHERE namespace=? AND key LIKE ? '
      'ORDER BY key DESC LIMIT 500',
      [namespace, '$_prefix%'],
    );
    final out = <TxnActionRecord>[];
    for (final row in rows) {
      final r = TxnActionRecord.fromJson(jsonDecode(row['value'] as String));
      if (r == null) continue;
      if (transactionId != null && !r.targets.contains(transactionId)) continue;
      out.add(r);
    }
    return out;
  }

  /// Time-ordered, so the key sort is the history order.
  static String newId() {
    final t = DateTime.now().toUtc().microsecondsSinceEpoch;
    return t.toString().padLeft(18, '0');
  }
}

Future<TransactionActionHistory> _open(Ref ref) async {
  final cache = await ref.read(responseCacheProvider.future);
  return TransactionActionHistory(
    cache.financialStore.database.db,
    namespace: ref.read(cacheNamespaceProvider),
  );
}

/// Every recorded action (or those on one payment), newest first.
final transactionActionHistoryProvider = FutureProvider.autoDispose
    .family<List<TxnActionRecord>, String?>((ref, transactionId) async {
      final h = await _open(ref);
      return h.list(transactionId: transactionId);
    });
