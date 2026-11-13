import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/sms_v2.dart' show Totals;

import '../../data/user_cards_repository.dart';

enum ActivityRowKind { selection, summary, dayHeader, transaction, spacer }

/// How the Activity list is ordered. Date orders keep the day headers; the
/// others are one flat list, because a day heading over rows of different days
/// would say the wrong thing, so each row shows its own date instead.
enum ActivitySort {
  newest('Newest first'),
  oldest('Oldest first'),
  highestAmount('Highest amount'),
  lowestAmount('Lowest amount'),
  merchantAz('Merchant A to Z');

  const ActivitySort(this.label);
  final String label;

  bool get groupsByDay => this == newest || this == oldest;
}

/// The name a row is sorted by: the merchant, or nothing for a row that has
/// none (those go last).
String? _sortName(TransactionEntry entry) {
  final name = entry.merchantName?.trim();
  return name == null || name.isEmpty ? null : name.toLowerCase();
}

/// Newest first, then by id, so equal rows keep one stable order.
int _newestFirst(TransactionEntry a, TransactionEntry b) {
  final byDate = b.occurredAt.compareTo(a.occurredAt);
  return byDate != 0 ? byDate : a.id.compareTo(b.id);
}

int Function(TransactionEntry, TransactionEntry) _comparatorFor(
  ActivitySort sort,
) => switch (sort) {
  ActivitySort.highestAmount => (a, b) {
    final byAmount = b.amount.paise.compareTo(a.amount.paise);
    return byAmount != 0 ? byAmount : _newestFirst(a, b);
  },
  ActivitySort.lowestAmount => (a, b) {
    final byAmount = a.amount.paise.compareTo(b.amount.paise);
    return byAmount != 0 ? byAmount : _newestFirst(a, b);
  },
  ActivitySort.merchantAz => (a, b) {
    final nameA = _sortName(a), nameB = _sortName(b);
    if (nameA == null && nameB == null) return _newestFirst(a, b);
    if (nameA == null) return 1;
    if (nameB == null) return -1;
    final byName = nameA.compareTo(nameB);
    return byName != 0 ? byName : _newestFirst(a, b);
  },
  _ => _newestFirst,
};

/// Lightweight metadata; transaction widgets remain lazy in ListView.builder.
class ActivityListRow {
  final ActivityRowKind kind;
  final DateTime? day;
  final TransactionEntry? entry;
  final Money? totalIncoming;
  final Money? totalOutgoing;
  final int? activeCount;

  const ActivityListRow._({
    required this.kind,
    this.day,
    this.entry,
    this.totalIncoming,
    this.totalOutgoing,
    this.activeCount,
  });

  const ActivityListRow.selection() : this._(kind: ActivityRowKind.selection);

  const ActivityListRow.summary({
    required Money totalIncoming,
    required Money totalOutgoing,
    required int activeCount,
  }) : this._(
         kind: ActivityRowKind.summary,
         totalIncoming: totalIncoming,
         totalOutgoing: totalOutgoing,
         activeCount: activeCount,
       );

  const ActivityListRow.dayHeader(DateTime day)
    : this._(kind: ActivityRowKind.dayHeader, day: day);

  const ActivityListRow.transaction(TransactionEntry entry)
    : this._(kind: ActivityRowKind.transaction, entry: entry);

  const ActivityListRow.spacer() : this._(kind: ActivityRowKind.spacer);
}

/// One immutable projection of an immutable transaction-list snapshot.
/// Calendar labels and tag names stay outside the cache so midnight, locale
/// changes and tag edits do not leave stale display text behind.
class ActivityProjection {
  final List<ActivityListRow> rows;
  final Map<String, int> _visibleCounts;
  final Money totalIncoming;
  final Money totalOutgoing;
  final int activeCount;

  const ActivityProjection._(
    this._visibleCounts, {
    required this.rows,
    required this.totalIncoming,
    required this.totalOutgoing,
    required this.activeCount,
  });

  factory ActivityProjection.build(
    List<TransactionEntry> entries, {
    Totals? ledgerTotals,
    ActivitySort sort = ActivitySort.newest,
  }) {
    final byDay = <DateTime, List<TransactionEntry>>{};
    final counts = <String, int>{};
    var incomingPaise = 0;
    var outgoingPaise = 0;
    var activeCount = 0;
    for (final entry in entries) {
      counts.update(entry.id, (count) => count + 1, ifAbsent: () => 1);
      final date = entry.occurredAt;
      final day = DateTime(date.year, date.month, date.day);
      byDay.putIfAbsent(day, () => []).add(entry);
      if (ledgerTotals != null ||
          entry.status != 'active' ||
          entry.entryKind == TxnEntryKind.refund ||
          entry.entryKind == TxnEntryKind.unknown)
        continue;
      activeCount++;
      if (entry.amount.paise <= 0) continue;
      // Money in is income plus money back from investments; Money out is
      // spending plus money put into investments. Transfers, card bills and
      // refunds (netted inside spend) are in neither. The ledger path and this
      // fallback must agree, so both use the same two definitions.
      if (entry.entryKind == TxnEntryKind.income ||
          entry.entryKind == TxnEntryKind.investmentReturn) {
        incomingPaise += entry.amount.paise;
      } else if (entry.entryKind == TxnEntryKind.spend ||
          entry.entryKind == TxnEntryKind.investment) {
        outgoingPaise += entry.amount.paise;
      }
    }
    final incoming = Money.fromPaise(
      ledgerTotals?.moneyInMinor ?? incomingPaise,
    );
    final outgoing = Money.fromPaise(
      ledgerTotals?.moneyOutMinor ?? outgoingPaise,
    );
    activeCount = ledgerTotals?.transactionCount ?? activeCount;
    final summary = ActivityListRow.summary(
      totalIncoming: incoming,
      totalOutgoing: outgoing,
      activeCount: activeCount,
    );
    final List<ActivityListRow> rows;
    if (sort.groupsByDay) {
      // Oldest first is exactly newest first turned around, within each day too.
      final oldest = sort == ActivitySort.oldest;
      final days = byDay.keys.toList()
        ..sort((a, b) => oldest ? a.compareTo(b) : b.compareTo(a));
      rows = [
        summary,
        for (final day in days) ...[
          ActivityListRow.dayHeader(day),
          for (final entry in oldest ? byDay[day]!.reversed : byDay[day]!)
            ActivityListRow.transaction(entry),
          const ActivityListRow.spacer(),
        ],
      ];
    } else {
      final ordered = [...entries]..sort(_comparatorFor(sort));
      rows = [
        summary,
        for (final entry in ordered) ActivityListRow.transaction(entry),
        const ActivityListRow.spacer(),
      ];
    }
    return ActivityProjection._(
      Map.unmodifiable(counts),
      rows: List.unmodifiable(rows),
      totalIncoming: incoming,
      totalOutgoing: outgoing,
      activeCount: activeCount,
    );
  }

  int visibleSelectedCount(Set<String> selectedIds) =>
      selectedIds.fold(0, (total, id) => total + (_visibleCounts[id] ?? 0));
}

/// A screen-owned, single-entry cache. [scope] carries the account, session
/// and filter; a new immutable list snapshot carries transaction revisions.
/// Selection and expansion state deliberately do not invalidate aggregates.
class ActivityProjectionCache {
  List<TransactionEntry>? _entries;
  Object? _scope;
  Totals? _ledgerTotals;
  ActivityProjection? _projection;

  ActivityProjection resolve(
    List<TransactionEntry> entries, {
    required Object scope,
    Totals? ledgerTotals,
    ActivitySort sort = ActivitySort.newest,
  }) {
    if (identical(_entries, entries) &&
        _scope == scope &&
        identical(_ledgerTotals, ledgerTotals))
      return _projection!;
    final projection = ActivityProjection.build(
      entries,
      ledgerTotals: ledgerTotals,
      sort: sort,
    );
    _ledgerTotals = ledgerTotals;
    _entries = entries;
    _scope = scope;
    _projection = projection;
    return projection;
  }
}
