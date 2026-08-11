import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../../data/user_cards_repository.dart';

/// The period chips across the top of design 04 Insights.
///
/// Three, not a free date range: the deck shows a short chip row, and every
/// figure on the screen is a "what did this stretch of time do for me"
/// summary rather than an audit tool. E11 Spending Overview already owns
/// arbitrary month selection for anyone who needs it.
enum InsightsPeriod {
  thisMonth('This month'),
  lastMonth('Last month'),
  last3Months('3 months');

  final String label;
  const InsightsPeriod(this.label);

  /// Inclusive start / exclusive end for this period, relative to [now].
  (DateTime, DateTime) range(DateTime now) {
    final startOfThisMonth = DateTime(now.year, now.month);
    return switch (this) {
      InsightsPeriod.thisMonth => (startOfThisMonth, DateTime(now.year, now.month + 1)),
      InsightsPeriod.lastMonth => (DateTime(now.year, now.month - 1), startOfThisMonth),
      InsightsPeriod.last3Months => (DateTime(now.year, now.month - 2), DateTime(now.year, now.month + 1)),
    };
  }
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
  const MissedEarning({required this.entry, required this.betterCard, required this.missed});
}

/// Everything design 04 Insights puts on screen, computed once.
///
/// Two different sources feed this, deliberately:
///
/// - **Earned** figures are the stored per-transaction `expected_value_inr`
///   (see [TransactionEntry.rewardValue]) — the same rows `GET /home-summary`
///   sums for design 01's header, so Insights and Home never disagree about
///   what a month earned.
/// - **Missed** figures are derived by [compareToOwnedCards], which is a
///   deliberately scoped base-rate comparison and cannot see the cap or
///   milestone state as it stood on the day (that history isn't retained —
///   see historical_comparison.dart). So "left on the table" is an estimate
///   where "earned" is a record. They are shown side by side on the deck's
///   own layout, and [missedIsEstimate] exists so the screen can mark the
///   difference rather than implying both are equally certain.
class InsightsOverview {
  final Money earned;
  final Money spend;
  final Money missed;
  final int missedCount;
  final int transactionCount;
  final List<CategoryEarning> byCategory;

  /// Earnings split by the card that produced them, highest first — design
  /// 32's "Best card" tile. Labelled with the card's display name (nickname
  /// if the user set one), so it reads the way they think of the card.
  final List<CategoryEarning> byCard;
  final List<MissedEarning> topMissed;

  /// True whenever [missed] came out of the base-rate comparator, which is
  /// always — kept as a named flag rather than a comment so the screen
  /// can't quietly start presenting it as exact.
  bool get missedIsEstimate => true;

  const InsightsOverview({
    required this.earned,
    required this.spend,
    required this.missed,
    required this.missedCount,
    required this.transactionCount,
    required this.byCategory,
    required this.byCard,
    required this.topMissed,
  });

  static const empty = InsightsOverview(
    earned: Money.zero(),
    spend: Money.zero(),
    missed: Money.zero(),
    missedCount: 0,
    transactionCount: 0,
    byCategory: [],
    byCard: [],
    topMissed: [],
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
  CategoryEarning? get bestCategory => byCategory.isEmpty ? null : byCategory.first;

  /// The card that earned the most — design 32's "Best card" tile.
  CategoryEarning? get bestCard => byCard.isEmpty ? null : byCard.first;
}

/// Backs the Insights tab. Signed out, or with no transactions in the
/// period, this resolves to [InsightsOverview.empty] rather than an error —
/// "you haven't spent anything this month" is a real answer, and the screen
/// renders its own empty state from the zero counts.
final insightsOverviewProvider = FutureProvider.family<InsightsOverview, InsightsPeriod>((ref, period) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return InsightsOverview.empty;

  final now = ref.watch(clockProvider).now();
  final (from, to) = period.range(now);

  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  final productsByUserCardId = {for (final (uc, p) in pairs) uc.id: p};
  final allProducts = [for (final (_, p) in pairs) p];

  final transactions = await repo.fetchTransactions(from: from, to: to);
  final active = transactions.where((t) => t.status == 'active').toList();
  if (active.isEmpty) return InsightsOverview.empty;

  var earned = const Money.zero();
  var spend = const Money.zero();
  var missed = const Money.zero();
  var missedCount = 0;
  final byCategory = <String, Money>{};
  final byCard = <String, Money>{};
  final missedRows = <MissedEarning>[];

  for (final txn in active) {
    spend += txn.amount;

    // Null reward means "not known", not "earned nothing" — such a row is
    // left out of the earned total and its category bar entirely rather
    // than dragging both down towards zero.
    final reward = txn.rewardValue;
    if (reward != null) {
      earned += reward;
      final categoryLabel = txn.categoryName ?? 'Uncategorised';
      byCategory[categoryLabel] = (byCategory[categoryLabel] ?? const Money.zero()) + reward;
      final cardLabel = txn.cardDisplayName;
      if (cardLabel != null) {
        byCard[cardLabel] = (byCard[cardLabel] ?? const Money.zero()) + reward;
      }
    }

    // Needs at least two owned cards to mean anything — with one card there
    // was nothing else to have chosen. Same guard D6 Missed Opportunities
    // applies.
    if (allProducts.length < 2) continue;
    final usedProduct = productsByUserCardId[txn.userCardId];
    if (usedProduct == null) continue; // card since archived — nothing to compare against

    final comparison = compareToOwnedCards(
      usedCard: usedProduct,
      ownedCards: allProducts,
      amount: txn.amount,
      categoryId: txn.categoryId,
    );
    if (!comparison.hadBetterOption) continue;
    missed += comparison.missedValue;
    missedCount++;
    missedRows.add(
      MissedEarning(entry: txn, betterCard: comparison.betterCard!, missed: comparison.missedValue),
    );
  }

  List<CategoryEarning> ranked(Map<String, Money> totals) =>
      [for (final entry in totals.entries) CategoryEarning(label: entry.key, earned: entry.value)]
        ..sort((a, b) => b.earned.paise.compareTo(a.earned.paise));

  final categories = ranked(byCategory);
  final cards = ranked(byCard);

  missedRows.sort((a, b) => b.missed.paise.compareTo(a.missed.paise));

  return InsightsOverview(
    earned: earned,
    spend: spend,
    missed: missed,
    missedCount: missedCount,
    transactionCount: active.length,
    byCategory: categories,
    byCard: cards,
    topMissed: missedRows.take(3).toList(),
  );
});

/// Which period chip is selected. A plain [StateProvider] like Home's own
/// category selection — session state, not persisted.
final insightsPeriodProvider = StateProvider<InsightsPeriod>((ref) => InsightsPeriod.thisMonth);
