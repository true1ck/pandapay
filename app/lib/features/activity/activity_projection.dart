import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/user_cards_repository.dart';

enum ActivityRowKind { selection, summary, dayHeader, transaction, spacer }

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

  factory ActivityProjection.build(List<TransactionEntry> entries) {
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
      if (entry.status != 'active') continue;
      activeCount++;
      if (entry.amount.paise <= 0) continue;
      if (entry.entryKind == TxnEntryKind.income) {
        incomingPaise += entry.amount.paise;
      } else if (entry.entryKind == TxnEntryKind.spend ||
          entry.entryKind == TxnEntryKind.investment) {
        outgoingPaise += entry.amount.paise;
      }
    }
    final incoming = Money.fromPaise(incomingPaise);
    final outgoing = Money.fromPaise(outgoingPaise);
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    final rows = <ActivityListRow>[
      ActivityListRow.summary(
        totalIncoming: incoming,
        totalOutgoing: outgoing,
        activeCount: activeCount,
      ),
      for (final day in days) ...[
        ActivityListRow.dayHeader(day),
        for (final entry in byDay[day]!) ActivityListRow.transaction(entry),
        const ActivityListRow.spacer(),
      ],
    ];
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
  ActivityProjection? _projection;

  ActivityProjection resolve(
    List<TransactionEntry> entries, {
    required Object scope,
  }) {
    if (identical(_entries, entries) && _scope == scope) return _projection!;
    final projection = ActivityProjection.build(entries);
    _entries = entries;
    _scope = scope;
    _projection = projection;
    return projection;
  }
}
