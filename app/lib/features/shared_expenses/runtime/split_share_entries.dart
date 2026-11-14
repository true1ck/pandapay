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

/// An accepted expense the person paid part or all of and then split: their
/// bank payment counts in full, but their own cost is only their share.
class SplitPaidExpense {
  const SplitPaidExpense({
    required this.id,
    required this.title,
    required this.occurredOn,
    required this.paidMinor,
    required this.shareMinor,
  });
  final String id;
  final String title;
  final String occurredOn;
  final int paidMinor;
  final int shareMinor;
}

/// A friend or group, with the expenses in it that change what the person
/// spends, and what the person still owes there.
class SplitShareContext {
  const SplitShareContext({
    required this.id,
    required this.name,
    required this.expenses,
    this.owingMinor,
    this.paidExpenses = const [],
  });
  final String id;
  final String name;
  final List<SplitShareExpense> expenses;
  final List<SplitPaidExpense> paidExpenses;

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
        _shareRow(
          id: e.id,
          title: e.title,
          day: day,
          amount: left ? e.shareMinor : counted,
          label: label,
          left: left,
        ),
      );
    }
  }
  return out;
}

TransactionEntry _shareRow({
  required String id,
  required String title,
  required DateTime day,
  required int amount,
  required String label,
  bool left = false,
}) => TransactionEntry(
  id: 'split:$id',
  amount: Money.fromPaise(amount),
  occurredAt: DateTime(day.year, day.month, day.day, 12),
  merchantName: title,
  instrument: TxnInstrument.other,
  source: kSplitShareSource,
  status: 'active',
  note: label,
  excludeFromSpend: left,
  excludeReason: left ? 'other' : null,
);

/// A share that stands in for a payment of the person's own in their spending,
/// once one payment can be found for it (see [applySplitOverlay]).
class SplitLinkedShare {
  const SplitLinkedShare({
    required this.row,
    required this.paidMinor,
    required this.day,
  });

  /// The person's share, a counted spend row.
  final TransactionEntry row;

  /// What the person paid, which the payment it stands in for must equal.
  final int paidMinor;

  /// The day the expense happened.
  final DateTime day;
}

/// Everything Splits adds to the person's spending view.
class SplitOverlay {
  const SplitOverlay({this.rows = const [], this.linked = const []});

  /// Shares of splits somebody else paid.
  final List<TransactionEntry> rows;

  /// Shares of splits the person paid for from a payment of their own. Each
  /// applies only while that payment is found (see [applySplitOverlay]).
  final List<SplitLinkedShare> linked;

  bool get isEmpty => rows.isEmpty && linked.isEmpty;

  static const empty = SplitOverlay();
}

/// [splitShareEntries] plus the shares of splits the person paid.
SplitOverlay splitOverlay(Iterable<SplitShareContext> contexts) {
  final all = contexts.toList();
  final linked = <SplitLinkedShare>[];
  for (final context in all) {
    for (final e in context.paidExpenses) {
      final day = DateTime.tryParse(e.occurredOn);
      if (day == null || e.shareMinor <= 0 || e.shareMinor >= e.paidMinor) {
        continue;
      }
      linked.add(
        SplitLinkedShare(
          row: _shareRow(
            id: e.id,
            title: e.title,
            day: day,
            amount: e.shareMinor,
            label:
                'Split · ${context.name} · your share of '
                '${Money.fromPaise(e.paidMinor).format()}',
          ),
          paidMinor: e.paidMinor,
          day: DateTime(day.year, day.month, day.day),
        ),
      );
    }
  }
  return SplitOverlay(rows: splitShareEntries(all), linked: linked);
}

/// The person's payments and Splits' shares, ready to show and to total.
class SplitApplied {
  const SplitApplied(this.payments, this.shares);

  /// The payments passed in, with each one a split replaced left out of
  /// spending.
  final List<TransactionEntry> payments;

  /// The share rows to show beside them.
  final List<TransactionEntry> shares;
}

/// Reason a payment is left out because a split's share stands in for it.
const kSplitCoveredReason = 'split';

/// Applies [overlay] to [base] (the person's own payments).
///
/// A split the person paid for counts only their share: their payment for it is
/// left out of spending and the share counts instead. Splitting a payment from
/// Activity is not switched on for friends yet, so a split carries no link to
/// the payment and it is found by what it must be: an active spend of exactly
/// what the person paid, on the expense's day or the day either side of it.
/// When no payment fits, or more than one does, nothing is guessed (the payment
/// counts in full and no share is added). A payment the person already left out
/// is never touched, and one payment is replaced by at most one split.
///
/// [memo] keeps the replaced copies, so a payment that did not change keeps the
/// same instance between calls (the ledger model compares rows by identity).
SplitApplied applySplitOverlay(
  List<TransactionEntry> base,
  SplitOverlay? overlay, {
  Map<String, (TransactionEntry, TransactionEntry)>? memo,
}) {
  if (overlay == null || overlay.isEmpty) return SplitApplied(base, const []);
  final shares = [...overlay.rows];
  var payments = base;
  if (overlay.linked.isNotEmpty) {
    final byAmount = <int, List<TransactionEntry>>{};
    for (final row in base) {
      if (row.status == 'active' &&
          row.entryKind == TxnEntryKind.spend &&
          !row.excludeFromSpend &&
          !isSplitShareEntry(row)) {
        (byAmount[row.amount.paise] ??= []).add(row);
      }
    }
    final replaced = <String>{};
    for (final link in overlay.linked) {
      final fits = [
        for (final row
            in byAmount[link.paidMinor] ?? const <TransactionEntry>[])
          if (_withinADay(row.occurredAt, link.day)) row,
      ];
      if (fits.length != 1 || !replaced.add(fits.single.id)) continue;
      shares.add(link.row);
    }
    if (replaced.isNotEmpty) {
      payments = [
        for (final row in base)
          if (replaced.contains(row.id)) _covered(row, memo) else row,
      ];
    }
  }
  return SplitApplied(payments, shares);
}

bool _withinADay(DateTime at, DateTime day) {
  final local = at.toLocal();
  final days = DateTime(
    local.year,
    local.month,
    local.day,
  ).difference(day).inDays.abs();
  return days <= 1;
}

TransactionEntry _covered(
  TransactionEntry row,
  Map<String, (TransactionEntry, TransactionEntry)>? memo,
) {
  final hit = memo?[row.id];
  if (hit != null && identical(hit.$1, row)) return hit.$2;
  final copy = row.copyWith(
    excludeFromSpend: true,
    excludeReason: kSplitCoveredReason,
  );
  memo?[row.id] = (row, copy);
  return copy;
}

int? _minor(Object? v) => v is String ? int.tryParse(v) : null;

/// Reads every context's expenses that change the person's spending from the
/// phone's own copy of Splits, bounded like the screens: at most 100 contexts,
/// and the first page (100) of expenses in each.
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
    final paidExpenses = <SplitPaidExpense>[];
    for (final item in items) {
      if (item is! Map || item['totalMinor'] == null || item['void'] == true) {
        continue;
      }
      final paid = _minor(item['yourPaidMinor']);
      final share = _minor(item['yourShareMinor']);
      final expenseId = item['expenseId'], on = item['occurredOn'];
      if (paid == null || share == null || share <= 0) continue;
      if (expenseId is! String || on is! String) continue;
      final title = '${item['title'] ?? 'Shared expense'}';
      if (paid == 0) {
        expenses.add(
          SplitShareExpense(
            id: expenseId,
            title: title,
            occurredOn: on,
            shareMinor: share,
          ),
        );
      } else if (share < paid) {
        paidExpenses.add(
          SplitPaidExpense(
            id: expenseId,
            title: title,
            occurredOn: on,
            paidMinor: paid,
            shareMinor: share,
          ),
        );
      }
    }
    if (expenses.isEmpty && paidExpenses.isEmpty) return null;
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
      paidExpenses: paidExpenses,
      owingMinor: _minor(payload['owingMinor']),
    );
  }
}

/// One-shot read, for tests and callers that do not keep a reader.
List<SplitShareContext> readSplitShareContexts(
  SharedExpensesStore store,
  String accountId,
) => SplitShareReader(store, accountId).read();
