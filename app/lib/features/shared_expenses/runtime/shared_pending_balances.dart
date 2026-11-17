import 'package:pandapay_domain/shared_expenses.dart' show projectSharedExpense;

import '../storage/shared_store.dart';
import 'shared_local_reads.dart';

/// What the expenses still waiting on this phone will change in each pair
/// balance once the server has them, so a saved expense moves the balances on
/// the screen at once instead of when the server answers.
///
/// Works out the same who-owes-whom edges the server does (the one shared
/// `projectSharedExpense` rule), for the commands that have not been confirmed
/// yet. Nothing here is stored: the moment the server's own balances arrive the
/// command is no longer waiting and this contributes nothing, so a number is
/// never counted twice.
///
/// Assumes expenses post as soon as they are saved (the setting the server
/// runs with). A command the server refuses stops waiting, so its effect goes
/// away on its own.
class SharedPendingBalances {
  SharedPendingBalances._(this._deltas);

  /// An overlay that changes nothing.
  static final none = SharedPendingBalances._(const {});

  /// context id -> other member id -> change in what they owe you
  /// (positive = they owe you more, negative = you owe them more).
  final Map<String, Map<String, int>> _deltas;

  bool get isEmpty => _deltas.isEmpty;

  /// The change per other member in [contextId]; empty when none.
  Map<String, int> inContext(String contextId) =>
      _deltas[contextId] ?? const {};

  /// Every context that has a change.
  Iterable<String> get contexts => _deltas.keys;

  static SharedPendingBalances read(
    SharedExpensesStore store,
    String accountId,
  ) {
    final reads = SharedLocalReads(store, accountId);
    final commands = reads.pending();
    final deltas = <String, Map<String, int>>{};
    for (final op in commands) {
      if (op.command.kind != 'expense.propose') continue;
      final p = op.command.toJson()['payload'];
      if (p is! Map) continue;
      final contextId = p['contextId'], expenseId = p['expenseId'];
      if (contextId is! String || expenseId is! String) continue;
      final own = reads.ownMemberId(contextId);
      if (own == null) continue;
      final heads = _heads(store, contextId);
      final accepted = heads[expenseId];
      // Already in this phone's copy: the stored balances include it.
      if (accepted != null && accepted['revisionId'] == p['revisionId']) {
        continue;
      }
      final previous = p['expectedHeadRevisionId'];
      List<Map<String, String>> before = const [];
      if (previous != null) {
        // An edit or a removal: take back what the version it replaces did.
        if (accepted == null || accepted['revisionId'] != previous) continue;
        final edges = _edges(accepted['snapshot']);
        if (edges == null) continue;
        before = edges;
      }
      List<Map<String, String>> after = const [];
      if (p['void'] != true) {
        final edges = _edges(p['snapshot']);
        if (edges == null) continue;
        after = edges;
      }
      final into = deltas.putIfAbsent(contextId, () => {});
      void add(List<Map<String, String>> edges, int sign) {
        for (final edge in edges) {
          final amount = int.tryParse(edge['amountMinor'] ?? '') ?? 0;
          if (amount == 0) continue;
          if (edge['creditorId'] == own) {
            into.update(
              '${edge['debtorId']}',
              (v) => v + sign * amount,
              ifAbsent: () => sign * amount,
            );
          } else if (edge['debtorId'] == own) {
            into.update(
              '${edge['creditorId']}',
              (v) => v - sign * amount,
              ifAbsent: () => -sign * amount,
            );
          }
        }
      }

      add(after, 1);
      add(before, -1);
    }
    deltas.removeWhere((_, v) {
      v.removeWhere((_, amount) => amount == 0);
      return v.isEmpty;
    });
    return deltas.isEmpty ? none : SharedPendingBalances._(deltas);
  }

  /// The accepted version of each expense in the context, by expense id.
  static Map<String, Map<String, Object?>> _heads(
    SharedExpensesStore store,
    String contextId,
  ) {
    final out = <String, Map<String, Object?>>{};
    for (final row
        in store
            .readPage(entity: 'expenses', contextId: contextId, limit: 100)
            .items) {
      final p = row.payload;
      final id = p['expenseId'];
      final accepted = p['accepted'];
      if (p['recordType'] == 'head' && id is String && accepted is Map) {
        out[id] = Map<String, Object?>.from(accepted);
      }
    }
    return out;
  }

  /// The who-owes-whom lines of a saved version, or null when it cannot be
  /// worked out (then nothing is guessed).
  static List<Map<String, String>>? _edges(Object? snapshot) {
    if (snapshot is! Map) return null;
    try {
      final projected = projectSharedExpense(
        Map<String, Object?>.from(snapshot),
      );
      return [
        for (final edge in projected['obligations'] as List)
          Map<String, String>.from(edge as Map),
      ];
    } catch (_) {
      return null;
    }
  }
}
