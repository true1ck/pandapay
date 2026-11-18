import 'package:flutter/foundation.dart';

import '../../../app/router.dart' show AppRoute;
import '../../../data/spend_reports_repository.dart';
import '../insights_overview.dart';

/// The Rewards page's one scope: a date range plus optional cards and
/// categories. Every tab and every figure on the page reads the same value, so
/// the Summary total, the Transactions list, Missed and Cards always add up to
/// the same thing.
///
/// Session state of the page, not saved: like Spending, a fresh visit starts at
/// this month for all cards.
@immutable
class RewardsFilter {
  /// The same date model Spending uses, so the same date sheet serves both.
  final SpendReportQuery query;

  /// Wallet card ids (`UserCard.id`). Empty means every card.
  final Set<String> cardIds;

  /// Top-level category names (see [rewardCategoryKey]). Empty means every
  /// category.
  final Set<String> categories;

  const RewardsFilter({
    this.query = const SpendReportQuery.preset(SpendPeriod.month),
    this.cardIds = const {},
    this.categories = const {},
  });

  /// True when cards or categories narrow the page (the date is always set).
  bool get narrowed => cardIds.isNotEmpty || categories.isNotEmpty;

  RewardsFilter copyWith({
    SpendReportQuery? query,
    Set<String>? cardIds,
    Set<String>? categories,
  }) => RewardsFilter(
    query: query ?? this.query,
    cardIds: cardIds ?? this.cardIds,
    categories: categories ?? this.categories,
  );

  /// Reads `period=week|month|quarter|year` or `from`/`to` (YYYY-MM-DD,
  /// inclusive) from a deep link. Anything else falls back to this month.
  static SpendReportQuery queryFromParams(Map<String, String> params) {
    final from = DateTime.tryParse(params['from'] ?? '');
    final to = DateTime.tryParse(params['to'] ?? '');
    if (from != null && to != null && !to.isBefore(from)) {
      return SpendReportQuery.custom(
        from: DateTime(from.year, from.month, from.day),
        to: DateTime(to.year, to.month, to.day),
      );
    }
    return switch (params['period']) {
      'week' => const SpendReportQuery.preset(SpendPeriod.week),
      'quarter' => const SpendReportQuery.preset(SpendPeriod.quarter),
      'year' => const SpendReportQuery.preset(SpendPeriod.year),
      _ => const SpendReportQuery.preset(SpendPeriod.month),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is RewardsFilter &&
      other.query == query &&
      setEquals(other.cardIds, cardIds) &&
      setEquals(other.categories, categories);

  @override
  int get hashCode => Object.hash(
    query,
    Object.hashAllUnordered(cardIds),
    Object.hashAllUnordered(categories),
  );
}

/// A half-open span of local calendar days: [from] is the first day's
/// midnight, [toExclusive] the midnight after the last day.
@immutable
class RewardsRange {
  final DateTime from;
  final DateTime toExclusive;

  const RewardsRange._(this.from, this.toExclusive);

  /// From [first] to [last], both inclusive, as calendar days.
  factory RewardsRange.days(DateTime first, DateTime last) {
    final start = DateTime(first.year, first.month, first.day);
    final end = DateTime(last.year, last.month, last.day + 1);
    if (!end.isAfter(start)) {
      throw ArgumentError.value(last, 'last', 'must be on or after first');
    }
    return RewardsRange._(start, end);
  }

  /// The last day in the range (inclusive), as a date.
  DateTime get toInclusive =>
      DateTime(toExclusive.year, toExclusive.month, toExclusive.day - 1);

  bool contains(DateTime at) {
    final local = at.toLocal();
    return !local.isBefore(from) && local.isBefore(toExclusive);
  }

  /// The first day of every calendar month the range touches, in order.
  List<DateTime> get monthStarts {
    final last = toInclusive;
    return [
      for (
        var month = DateTime(from.year, from.month);
        !month.isAfter(DateTime(last.year, last.month));
        month = DateTime(month.year, month.month + 1)
      )
        month,
    ];
  }

  /// True when the range starts on a 1st and ends on a month's last day.
  bool get isWholeMonths => from.day == 1 && toExclusive.day == 1;

  @override
  bool operator ==(Object other) =>
      other is RewardsRange &&
      other.from == from &&
      other.toExclusive == toExclusive;

  @override
  int get hashCode => Object.hash(from, toExclusive);

  @override
  String toString() => 'RewardsRange($from, $toExclusive)';
}

/// The calendar days [query] covers at [now]. Presets are whole calendar
/// periods, the same as Spending and the Insights hub (a month is the 1st to
/// the last day, even mid-month); a custom range is taken as given.
RewardsRange rewardsRangeFor(SpendReportQuery query, DateTime now) {
  if (query.isCustom && query.from != null && query.to != null) {
    final from = query.from!;
    final to = query.to!;
    return to.isBefore(from)
        ? RewardsRange.days(to, from)
        : RewardsRange.days(from, to);
  }
  final today = DateTime(now.year, now.month, now.day);
  switch (query.period) {
    case SpendPeriod.week:
      final monday = DateTime(
        today.year,
        today.month,
        today.day - (today.weekday - DateTime.monday),
      );
      return RewardsRange.days(
        monday,
        DateTime(monday.year, monday.month, monday.day + 6),
      );
    case SpendPeriod.quarter:
      final firstMonth = ((now.month - 1) ~/ 3) * 3 + 1;
      return RewardsRange.days(
        DateTime(now.year, firstMonth),
        DateTime(now.year, firstMonth + 3, 0),
      );
    case SpendPeriod.year:
      return RewardsRange.days(DateTime(now.year), DateTime(now.year, 12, 31));
    case SpendPeriod.month:
    case SpendPeriod.custom:
      return RewardsRange.days(
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1, 0),
      );
  }
}

const _monthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _monthLong = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// How the page names a range: "November 2026", "Sep – Nov 2026",
/// "Dec 2025 – Feb 2026" for whole months, otherwise days ("17 – 23 Nov 2026",
/// "12 Oct – 18 Nov 2026", "28 Dec 2025 – 3 Jan 2026").
String rewardsRangeLabel(RewardsRange range) {
  final from = range.from;
  final to = range.toInclusive;
  if (range.isWholeMonths) {
    if (from.year == to.year && from.month == to.month) {
      return '${_monthLong[from.month - 1]} ${from.year}';
    }
    if (from.year == to.year) {
      return '${_monthShort[from.month - 1]} – ${_monthShort[to.month - 1]} ${to.year}';
    }
    return '${_monthShort[from.month - 1]} ${from.year} – '
        '${_monthShort[to.month - 1]} ${to.year}';
  }
  if (from.year == to.year && from.month == to.month) {
    if (from.day == to.day) {
      return '${from.day} ${_monthShort[from.month - 1]} ${from.year}';
    }
    return '${from.day} – ${to.day} ${_monthShort[to.month - 1]} ${to.year}';
  }
  if (from.year == to.year) {
    return '${from.day} ${_monthShort[from.month - 1]} – '
        '${to.day} ${_monthShort[to.month - 1]} ${to.year}';
  }
  return '${from.day} ${_monthShort[from.month - 1]} ${from.year} – '
      '${to.day} ${_monthShort[to.month - 1]} ${to.year}';
}

/// A short month name ("Nov"), for chart labels.
String rewardsMonthShort(DateTime month) => _monthShort[month.month - 1];

String _dateParam(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The Rewards page location for a tab and the Insights hub's selected
/// period, so the page opens on the same dates the hub was showing (the hub's
/// Rewards donut and this page then show the same figure).
String rewardsLocation({
  String? tab,
  InsightsPeriod? period,
  InsightsDateRange? customRange,
  DateTime? now,
}) {
  final params = <String, String>{'tab': ?tab};
  switch (period) {
    case null:
    case InsightsPeriod.thisMonth:
      break;
    case InsightsPeriod.week:
      params['period'] = 'week';
    case InsightsPeriod.thisQuarter:
      params['period'] = 'quarter';
    case InsightsPeriod.thisYear:
      params['period'] = 'year';
    case InsightsPeriod.custom:
    case InsightsPeriod.lastMonth:
    case InsightsPeriod.last3Months:
      if (now != null) {
        final (from, toExclusive) = period.range(now, customRange: customRange);
        params['from'] = _dateParam(from);
        params['to'] = _dateParam(
          DateTime(toExclusive.year, toExclusive.month, toExclusive.day - 1),
        );
      }
  }
  return Uri(
    path: AppRoute.rewardsGroup,
    queryParameters: params.isEmpty ? null : params,
  ).toString();
}
