import 'package:pandapay_domain/pandapay_domain.dart' show Money, TxnInstrument;

import '../../../data/user_cards_repository.dart';
import '../storage/shared_store.dart';
import 'shared_local_reads.dart';

/// One accepted expense in a split where somebody else paid the whole bill and
/// the person owes a share: the cost that never leaves their own account until
/// they settle up.
class SplitShareExpense {
  const SplitShareExpense({
    required this.id,
    required this.title,
    required this.occurredOn,
    required this.shareMinor,
  });
  final String id;
  final String title;

  /// `yyyy-MM-dd`, the day the expense happened.
  final String occurredOn;
  final int shareMinor;
}

/// A friend or group, with the friend-paid expenses in it and what the person
/// still owes there.
class SplitShareContext {
  const SplitShareContext({
    required this.id,
    required this.name,
    required this.expenses,
    this.owingMinor,
  });
  final String id;
  final String name;
  final List<SplitShareExpense> expenses;

  /// What the person owes in this context right now; null when not known.
  final int? owingMinor;
}

/// Source of the rows: the person's share of splits somebody else paid.
const kSplitShareSource = 'split';

bool isSplitShareEntry(TransactionEntry entry) =>
    entry.source == kSplitShareSource;

/// The Activity rows for [contexts], oldest settled first.
///
/// A share counts in spending while it is owed. Once the person pays it back
/// (their bank payment to the friend counts as spending on its own), the share
/// stops counting, so the same money is never spent twice. What is still owed
/// per context decides how much is settled: the oldest shares are treated as
/// paid first, and one part-paid share counts only for what remains.
List<TransactionEntry> splitShareEntries(Iterable<SplitShareContext> contexts) {
  final out = <TransactionEntry>[];
  for (final context in contexts) {
    final expenses = [...context.expenses]
      ..sort((a, b) {
        final byDay = a.occurredOn.compareTo(b.occurredOn);
        return byDay != 0 ? byDay : a.id.compareTo(b.id);
      });
    final total = expenses.fold<int>(0, (sum, e) => sum + e.shareMinor);
    final owing = context.owingMinor;
    var settled = owing == null ? 0 : (total - owing).clamp(0, total);
    for (final e in expenses) {
      final day = DateTime.tryParse(e.occurredOn);
      if (day == null || e.shareMinor <= 0) continue;
      var counted = e.shareMinor;
      var left = false;
      var label = 'Split · ${context.name}';
      if (settled >= e.shareMinor) {
        settled -= e.shareMinor;
        left = true;
        label = '$label · settled';
      } else if (settled > 0) {
        counted = e.shareMinor - settled;
        label =
            '$label · ${Money.fromPaise(counted).format()} of '
            '${Money.fromPaise(e.shareMinor).format()} still owed';
        settled = 0;
      }
      out.add(
        TransactionEntry(
          id: 'split:${e.id}',
          amount: Money.fromPaise(left ? e.shareMinor : counted),
          occurredAt: DateTime(day.year, day.month, day.day, 12),
          merchantName: e.title,
          instrument: TxnInstrument.other,
          source: kSplitShareSource,
          status: 'active',
          note: label,
          excludeFromSpend: left,
          excludeReason: left ? 'other' : null,
        ),
      );
    }
  }
  return out;
}

int? _minor(Object? v) => v is String ? int.tryParse(v) : null;

/// Reads every context's friend-paid shares from the phone's own copy of
/// Splits, bounded like the screens: at most 100 contexts, and the first page
/// (100) of expenses in each.
///
/// Keeps what it read per context, keyed by that context's own revision and
/// sequence, so a re-read costs one query for the context list plus the
/// members and expenses of the contexts that actually changed.
class SplitShareReader {
  SplitShareReader(this.store, this.accountId);
  final SharedExpensesStore store;
  final String accountId;
  late final SharedLocalReads _reads = SharedLocalReads(store, accountId);
  final Map<String, (String, SplitShareContext?)> _cache = {};

  List<SplitShareContext> read() {
    final page = store.readContexts(limit: 100);
    final seen = <String>{};
    final out = <SplitShareContext>[];
    for (final row in page.items) {
      final payload = row.payload;
      if (payload is! Map || payload['state'] == 'archived') continue;
      seen.add(row.id);
      final signature =
          '${row.revision}|${payload['committedSequence']}|'
          '${payload['owingMinor']}|${payload['name']}';
      var hit = _cache[row.id];
      if (hit == null || hit.$1 != signature) {
        hit = (signature, _context(row.id, payload));
        _cache[row.id] = hit;
      }
      final context = hit.$2;
      if (context != null) out.add(context);
    }
    _cache.removeWhere((id, _) => !seen.contains(id));
    return out;
  }

  SplitShareContext? _context(String id, Map<Object?, Object?> payload) {
    final own = _reads.ownMemberId(id);
    if (own == null) return null;
    final items = _reads.read('context:$id:expenses:first')?['items'];
    if (items is! List) return null;
    final expenses = <SplitShareExpense>[];
    for (final item in items) {
      if (item is! Map || item['totalMinor'] == null || item['void'] == true) {
        continue;
      }
      final paid = _minor(item['yourPaidMinor']);
      final share = _minor(item['yourShareMinor']);
      final expenseId = item['expenseId'], on = item['occurredOn'];
      if (paid != 0 || share == null || share <= 0) continue;
      if (expenseId is! String || on is! String) continue;
      expenses.add(
        SplitShareExpense(
          id: expenseId,
          title: '${item['title'] ?? 'Shared expense'}',
          occurredOn: on,
          shareMinor: share,
        ),
      );
    }
    if (expenses.isEmpty) return null;
    var name = '${payload['name'] ?? 'Split'}';
    if (payload['kind'] == 'direct') {
      final other = _reads
          .memberRows(id)
          .where((m) => m['memberId'] != own && m['state'] == 'active')
          .map((m) => m['displayName'])
          .whereType<String>()
          .firstOrNull;
      if (other != null && other.trim().isNotEmpty) name = other.trim();
    }
    return SplitShareContext(
      id: id,
      name: name,
      expenses: expenses,
      owingMinor: _minor(payload['owingMinor']),
    );
  }
}

/// One-shot read, for tests and callers that do not keep a reader.
List<SplitShareContext> readSplitShareContexts(
  SharedExpensesStore store,
  String accountId,
) => SplitShareReader(store, accountId).read();
