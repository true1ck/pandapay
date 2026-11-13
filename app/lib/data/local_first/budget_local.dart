/// WP-C7: a budget's "spent so far" computed on the phone. Mirrors the API's
/// rules (api/src/spend_reports.js `budgetSpend` / `budgetPeriodBounds` /
/// `periodElapsedFraction`), so a budget created offline shows a figure that
/// matches what the server later returns. The same cases are in
/// test/fixtures/budget_spent_cases.json for the API repo to replay.
///
/// Plain data in, plain data out: no clock reads, no I/O, no Flutter types.
class BudgetTxn {
  const BudgetTxn({
    required this.amountPaise,
    required this.occurredAt,
    this.status = 'active',
    this.entryKind = 'spend',
    this.excludeFromSpend = false,
    this.categoryId,
    this.userCategoryId,
    this.parentUserCategoryId,
    this.userCardId,
    this.tagIds = const [],
  });

  factory BudgetTxn.fromJson(Map<String, dynamic> j) => BudgetTxn(
    amountPaise: (j['amountPaise'] as num).toInt(),
    occurredAt: DateTime.parse(j['occurredAt'] as String),
    status: j['status'] as String? ?? 'active',
    entryKind: j['entryKind'] as String? ?? 'spend',
    excludeFromSpend: j['excludeFromSpend'] as bool? ?? false,
    categoryId: j['categoryId'] as String?,
    userCategoryId: j['userCategoryId'] as String?,
    parentUserCategoryId: j['parentUserCategoryId'] as String?,
    userCardId: j['userCardId'] as String?,
    tagIds: ((j['tagIds'] as List?) ?? const []).cast<String>(),
  );

  final int amountPaise;
  final DateTime occurredAt;
  final String status;
  final String entryKind;
  final bool excludeFromSpend;
  final String? categoryId, userCategoryId, parentUserCategoryId, userCardId;
  final List<String> tagIds;
}

class BudgetDef {
  const BudgetDef({
    required this.scope,
    required this.period,
    this.scopeRefId,
    this.startsOn,
  });

  factory BudgetDef.fromJson(Map<String, dynamic> j) => BudgetDef(
    scope: j['scope'] as String,
    scopeRefId: j['scopeRefId'] as String?,
    period: j['period'] as String,
    startsOn: j['startsOn'] == null
        ? null
        : DateTime.parse(j['startsOn'] as String),
  );

  /// overall | category | card | tag
  final String scope;
  final String? scopeRefId;

  /// weekly | monthly | quarterly | yearly
  final String period;

  /// Anchor of a weekly budget (its week starts on this weekday).
  final DateTime? startsOn;
}

class BudgetSpend {
  const BudgetSpend({
    required this.spentPaise,
    required this.txnCount,
    required this.start,
    required this.end,
    required this.elapsedFraction,
  });
  final int spentPaise, txnCount;
  final DateTime start, end;
  final double elapsedFraction;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// Inclusive start, exclusive end of the budget's current period.
({DateTime start, DateTime end}) budgetPeriodBounds(
  BudgetDef budget,
  DateTime now,
) {
  final today = _day(now);
  switch (budget.period) {
    case 'weekly':
      final anchor = _day(budget.startsOn ?? today);
      // Calendar-day difference (DST safe), whole weeks since the anchor.
      final daysSince = DateTime.utc(today.year, today.month, today.day)
          .difference(DateTime.utc(anchor.year, anchor.month, anchor.day))
          .inDays;
      final whole = (daysSince / 7).floor();
      final start = DateTime(anchor.year, anchor.month, anchor.day + whole * 7);
      return (
        start: start,
        end: DateTime(start.year, start.month, start.day + 7),
      );
    case 'quarterly':
      final q = (today.month - 1) ~/ 3;
      return (
        start: DateTime(today.year, q * 3 + 1, 1),
        end: DateTime(today.year, q * 3 + 4, 1),
      );
    case 'yearly':
      return (
        start: DateTime(today.year, 1, 1),
        end: DateTime(today.year + 1, 1, 1),
      );
    default:
      return (
        start: DateTime(today.year, today.month, 1),
        end: DateTime(today.year, today.month + 1, 1),
      );
  }
}

BudgetSpend computeBudgetSpend(
  BudgetDef budget,
  Iterable<BudgetTxn> txns,
  DateTime now,
) {
  final b = budgetPeriodBounds(budget, now);
  var spent = 0;
  var count = 0;
  final ref = budget.scopeRefId;
  for (final t in txns) {
    if (t.status != 'active' ||
        t.entryKind != 'spend' ||
        t.excludeFromSpend ||
        t.amountPaise <= 0 ||
        t.occurredAt.isBefore(b.start) ||
        !t.occurredAt.isBefore(b.end)) {
      continue;
    }
    final inScope = switch (budget.scope) {
      'category' =>
        t.categoryId == ref ||
            t.userCategoryId == ref ||
            t.parentUserCategoryId == ref,
      'card' => t.userCardId == ref,
      'tag' => t.tagIds.contains(ref),
      _ => true,
    };
    if (!inScope) continue;
    spent += t.amountPaise;
    count++;
  }
  final total = b.end.difference(b.start).inMilliseconds;
  final done = now.difference(b.start).inMilliseconds;
  final elapsed = total <= 0
      ? 1.0
      : done <= 0
      ? 0.0
      : done >= total
      ? 1.0
      : done / total;
  return BudgetSpend(
    spentPaise: spent,
    txnCount: count,
    start: b.start,
    end: b.end,
    elapsedFraction: elapsed,
  );
}
