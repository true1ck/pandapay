import '../sms_v2/ledger/providers.dart';
import '../../data/spend_reports_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../data/reward_counting.dart';
import '../../data/user_cards_repository.dart';
import 'rewards/rewards_filter.dart' show RewardsRange;
import 'rewards/rewards_providers.dart';

/// The period chips across the top of design 04 Insights.
///
/// The visible selector mirrors Spending so the same question has the same
/// answer whichever entry point the user takes: this week, this month, this
/// quarter, this year, or a custom inclusive date range.
enum InsightsPeriod {
  week('This week'),
  thisMonth('This month'),
  thisQuarter('This quarter'),
  thisYear('This year'),
  custom('Custom dates'),

  // Kept for compatibility with older deep links and cached callers. They
  // are intentionally not part of [selectorValues], which is the product
  // surface shown to users going forward.
  lastMonth('Last month'),
  last3Months('3 months');

  final String label;
  const InsightsPeriod(this.label);

  static const selectorValues = <InsightsPeriod>[
    week,
    thisMonth,
    thisQuarter,
    thisYear,
    custom,
  ];

  /// Inclusive start / exclusive end for this period, relative to [now].
  ///
  /// [customRange] is inclusive at the UI boundary. The returned end is the
  /// following local midnight so a transaction occurring at any time on the
  /// selected final date is retained by the shared transaction loader.
  (DateTime, DateTime) range(DateTime now, {InsightsDateRange? customRange}) {
    if (this == InsightsPeriod.custom && customRange != null) {
      return (
        _dateOnly(customRange.from),
        _dateOnly(customRange.to).add(const Duration(days: 1)),
      );
    }

    final startOfToday = _dateOnly(now);
    final startOfThisMonth = DateTime(now.year, now.month);
    return switch (this) {
      InsightsPeriod.week => (
        startOfToday.subtract(Duration(days: startOfToday.weekday - 1)),
        startOfToday
            .subtract(Duration(days: startOfToday.weekday - 1))
            .add(const Duration(days: 7)),
      ),
      InsightsPeriod.thisMonth => (
        startOfThisMonth,
        DateTime(now.year, now.month + 1),
      ),
      InsightsPeriod.thisQuarter => (
        DateTime(now.year, ((now.month - 1) ~/ 3) * 3 + 1),
        DateTime(now.year, ((now.month - 1) ~/ 3) * 3 + 4),
      ),
      InsightsPeriod.thisYear => (DateTime(now.year), DateTime(now.year + 1)),
      InsightsPeriod.lastMonth => (
        DateTime(now.year, now.month - 1),
        startOfThisMonth,
      ),
      InsightsPeriod.last3Months => (
        DateTime(now.year, now.month - 2),
        DateTime(now.year, now.month + 1),
      ),
      // A custom query without dates is only possible for a programmatic
      // caller; fall back to this month rather than issuing an invalid range.
      InsightsPeriod.custom => (
        startOfThisMonth,
        DateTime(now.year, now.month + 1),
      ),
    };
  }
}

/// Inclusive, date-only bounds selected by the Insights date picker.
class InsightsDateRange {
  final DateTime from;
  final DateTime to;

  InsightsDateRange({required DateTime from, required DateTime to})
    : from = _dateOnly(from),
      to = _dateOnly(to) {
    if (this.to.isBefore(this.from)) {
      throw ArgumentError.value(to, 'to', 'must be on or after from');
    }
  }

  String get shortLabel => '${_shortDate(from)} – ${_shortDate(to)}';
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _shortDate(DateTime date) {
  const months = <String>[
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
  return '${months[date.month - 1]} ${date.day}';
}

/// One bar in design 04's "where it came from" breakdown, or one row of
/// design 32's. Used for both the category split and the per-card split —
/// they are the same shape and the same arithmetic, so they share a type
/// rather than growing a near-identical twin.
class CategoryEarning {
  final String label;
  final Money earned;
  const CategoryEarning({required this.label, required this.earned});
}

/// One row of design 04's "Missed opportunities" preview.
class MissedEarning {
  final TransactionEntry entry;
  final CardProduct betterCard;
  final Money missed;
  const MissedEarning({
    required this.entry,
    required this.betterCard,
    required this.missed,
  });
}

/// Everything design 04 Insights puts on screen, computed once.
///
/// - **Earned** figures are the stored per-transaction `expected_value_inr`
///   (see [TransactionEntry.rewardValue]) — the same rows `GET /home-summary`
///   sums for design 01's header, so Insights and Home never disagree about
///   what a month earned.
/// - **Missed** figures are not part of this snapshot: they come from
///   [insightsMissedProvider], which reads the Rewards page's own report for the
///   same dates, so the hub and the page always agree and the figures here never
///   wait on the card comparison.

class InsightsOverview {
  final Money earned;
  final Money spend;
  final int transactionCount;
  final List<CategoryEarning> byCategory;

  /// Earnings split by the card that produced them, highest first — design
  /// 32's "Best card" tile. Labelled with the card's display name (nickname
  /// if the user set one), so it reads the way they think of the card.
  final List<CategoryEarning> byCard;

  const InsightsOverview({
    required this.earned,
    required this.spend,
    required this.transactionCount,
    required this.byCategory,
    required this.byCard,
  });

  static const empty = InsightsOverview(
    earned: Money.zero(),
    spend: Money.zero(),
    transactionCount: 0,
    byCategory: [],
    byCard: [],
  );

  /// Design 04's *"₹1,842 on ₹58,000 of spend · 3.2% effective"*.
  ///
  /// Null rather than 0 when nothing was spent — a 0% effective rate on no
  /// spend is a division by zero dressed up as a fact.
  double? get effectiveRatePct {
    if (spend.paise == 0) return null;
    return (earned.paise / spend.paise) * 100;
  }

  /// The category that earned the most, or null when nothing has been
  /// categorised yet. [byCategory] is sorted, so this is just its head.
  CategoryEarning? get bestCategory =>
      byCategory.isEmpty ? null : byCategory.first;

  /// The card that earned the most — design 32's "Best card" tile.
  CategoryEarning? get bestCard => byCard.isEmpty ? null : byCard.first;
}

/// Backs the Insights tab. Signed out, or with no transactions in the
/// period, this resolves to [InsightsOverview.empty] rather than an error —
/// "you haven't spent anything this month" is a real answer, and the screen
/// renders its own empty state from the zero counts.
final FutureProviderFamily<InsightsOverview, InsightsPeriod>
insightsOverviewProvider = FutureProvider.family<InsightsOverview, InsightsPeriod>((
  ref,
  period,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return InsightsOverview.empty;

  final now = ref.watch(clockProvider).now();
  final customRange = ref.watch(insightsCustomRangeProvider);
  final (from, toExclusive) = period.range(now, customRange: customRange);
  // UserCardsRepository's transaction endpoint accepts an inclusive
  // calendar date, while the period model uses a half-open end. Convert
  // once at the boundary so online and cached reads agree.
  final toInclusive = toExclusive.subtract(const Duration(days: 1));

  final ledgerModel = ref.watch(smsV2ReportingEnabledProvider)
      ? await ref.watch(smsV2LedgerReadModelProvider.future)
      : null;
  final ledgerReport = ledgerModel?.spendReport(
    SpendReportQuery.custom(from: from, to: toInclusive),
    now,
  );
  final transactions =
      ledgerModel?.transactions
          .where(
            (t) =>
                !t.occurredAt.isBefore(from) &&
                t.occurredAt.isBefore(toExclusive),
          )
          .toList() ??
      await loadTransactionsWithOfflineCache(
        ref,
        repo: repo,
        cacheKey:
            'insights_transactions:${period.name}:${from.toIso8601String()}:${toExclusive.toIso8601String()}',
        from: from,
        to: toInclusive,
        preferCached: true,
        onBackgroundRefresh: () =>
            ref.invalidate(insightsOverviewProvider(period)),
      );
  // Insights is a spending/rewards view. Keep income, investments and
  // transfers out of both the spend total and the reward/card comparisons.
  // The API exposes entry_kind so this remains correct for SMS-imported rows
  // as well as manually logged rows.
  final active = transactions
      .where(
        (t) =>
            t.status == 'active' &&
            t.entryKind == TxnEntryKind.spend &&
            t.amount.paise > 0,
      )
      .toList();
  if (active.isEmpty && ledgerReport == null) return InsightsOverview.empty;

  var earned = const Money.zero();
  var spend = ledgerReport?.spend.total ?? const Money.zero();
  final byCategory = <String, Money>{};
  final byCard = <String, Money>{};

  for (final txn in active) {
    // Spend the person chose not to count stays out of the spend total, but its
    // rewards below were earned all the same.
    if (ledgerReport == null && txn.countsAsSpend) spend += txn.amount;

    // Null means the app counts no reward for this row (not a card spend,
    // not worked out yet, zero, or a payment method that earns nothing): it is
    // left out of the earned total and its category bar entirely rather than
    // dragging both down towards zero. Same rule as Activity and Rewards
    // (countedRewardValue), so the three never disagree about a period.
    final reward = countedRewardValue(txn);
    if (reward != null) {
      earned += reward;
      final categoryLabel = txn.categoryLabel;
      byCategory[categoryLabel] =
          (byCategory[categoryLabel] ?? const Money.zero()) + reward;
      final cardLabel = txn.cardDisplayName;
      if (cardLabel != null) {
        byCard[cardLabel] = (byCard[cardLabel] ?? const Money.zero()) + reward;
      }
    }
  }

  List<CategoryEarning> ranked(Map<String, Money> totals) => [
    for (final entry in totals.entries)
      CategoryEarning(label: entry.key, earned: entry.value),
  ]..sort((a, b) => b.earned.paise.compareTo(a.earned.paise));

  final categories = ranked(byCategory);
  final cards = ranked(byCard);

  return InsightsOverview(
    earned: earned,
    spend: spend,
    transactionCount: ledgerReport?.spend.txnCount ?? active.length,
    byCategory: categories,
    byCard: cards,
  );
});

/// The hub's "left on the table" figures for a period: how much more other
/// cards in the wallet would clearly have paid, how many spends it covers, and
/// the three biggest.
///
/// It is the Rewards page's own report for the same dates (the page is where
/// "See all" goes), so the two can never disagree, and it is a separate
/// provider so the rest of the hub never waits on the card comparison. While
/// the comparison is running the value is loading: the hub shows no figure
/// rather than "no missed rewards".
class InsightsMissed {
  final Money missed;
  final int missedCount;

  /// Spends that had another card to be compared with (see [RewardsReport]).
  final int comparedCount;

  /// Two different card products in the wallet.
  final bool canCompare;

  /// The comparison could not be run.
  final bool failed;
  final List<MissedEarning> top;

  const InsightsMissed({
    required this.missed,
    required this.missedCount,
    required this.comparedCount,
    required this.canCompare,
    required this.failed,
    required this.top,
  });

  /// Always an estimate: caps and milestones as they stood on the day are not
  /// kept (see historical_comparison.dart).
  bool get isEstimate => true;
}

final insightsMissedProvider = Provider.autoDispose
    .family<AsyncValue<InsightsMissed>, InsightsPeriod>((ref, period) {
      // Nothing to say until the overview has spend to talk about; this also
      // keeps a period with no spend from loading anything twice.
      final overview = ref.watch(insightsOverviewProvider(period)).valueOrNull;
      if (overview == null || overview.transactionCount == 0) {
        return const AsyncLoading();
      }
      final now = ref.watch(clockProvider).now();
      final customRange = ref.watch(insightsCustomRangeProvider);
      final (from, toExclusive) = period.range(now, customRange: customRange);
      final range = RewardsRange.days(
        from,
        toExclusive.subtract(const Duration(days: 1)),
      );
      // The Rewards page's own inputs for the same dates, read directly: a
      // tile does not need the page's whole report (R6 in the performance
      // rulebook), and the figures still agree because they are the same
      // answers summed the same way (guarded by a test).
      final transactions = ref.watch(rewardsTransactionsProvider(range));
      final checks = ref.watch(rewardsChecksProvider(range));
      final wallet = ref.watch(ownedCardsWithProductProvider);
      if (wallet.isLoading && !wallet.hasValue && !wallet.hasError) {
        return const AsyncLoading();
      }
      if (checks.isLoading && !transactions.hasError) {
        return const AsyncLoading();
      }
      final walletCards =
          wallet.valueOrNull ?? const <(UserCard, CardProduct)>[];
      final canCompare =
          {for (final (_, product) in walletCards) product.id}.length >= 2;
      return transactions.whenData((list) {
        if (checks.hasError) {
          return InsightsMissed(
            missed: const Money.zero(),
            missedCount: 0,
            comparedCount: 0,
            canCompare: canCompare,
            failed: true,
            top: const [],
          );
        }
        final byId = {for (final entry in list) entry.id: entry};
        var missed = const Money.zero();
        var compared = 0;
        final rows = <MissedEarning>[];
        if (canCompare) {
          for (final MapEntry(key: id, value: check)
              in (checks.valueOrNull ?? const {}).entries) {
            final entry = byId[id];
            if (entry == null || !check.compared) continue;
            compared++;
            final better = check.better;
            if (better == null) continue;
            missed += better.missedValue;
            rows.add(
              MissedEarning(
                entry: entry,
                betterCard: better.betterCard!,
                missed: better.missedValue,
              ),
            );
          }
        }
        rows.sort((a, b) {
          final byValue = b.missed.paise.compareTo(a.missed.paise);
          return byValue != 0
              ? byValue
              : b.entry.occurredAt.compareTo(a.entry.occurredAt);
        });
        return InsightsMissed(
          missed: missed,
          missedCount: rows.length,
          comparedCount: compared,
          canCompare: canCompare,
          failed: false,
          top: rows.take(3).toList(),
        );
      });
    });

/// Which period chip is selected. A plain [StateProvider] like Home's own
/// category selection — session state, not persisted.
final insightsPeriodProvider = StateProvider<InsightsPeriod>(
  (ref) => InsightsPeriod.thisMonth,
);

/// The currently selected custom range, kept separately because an enum is
/// the right key for preset periods but cannot carry two dates. The overview
/// provider watches this state, so changing either endpoint recomputes every
/// card, category, and missed-opportunity figure together.
final insightsCustomRangeProvider = StateProvider<InsightsDateRange?>(
  (ref) => null,
);
