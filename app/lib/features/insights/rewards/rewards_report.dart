import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../data/reward_counting.dart';
import '../../../data/user_cards_repository.dart';
import 'rewards_filter.dart';

/// Everything the Rewards page shows, worked out once from one list of
/// transactions and one [RewardsFilter] scope. Pure Dart (no Flutter, no
/// providers) so every figure can be unit tested.
///
/// Rows in scope are credit-card purchases ([isCardRewardSpend]) inside the
/// date range, narrowed by the card and category filters. The reward counted
/// for a row is [countedRewardValue], the same rule Activity and the Insights
/// overview use.

/// What a spend in scope contributed.
enum RewardRowStatus {
  /// A counted reward above zero.
  earned,

  /// Priced at zero (an excluded category, under a minimum, refunded), or paid
  /// in a way that earns nothing (EMI, gift card, reward points, pay later).
  noReward,

  /// No figure the app can count yet: the card is not in the wallet, or the
  /// reward has not been worked out.
  notCounted,
}

enum RewardNotCountedReason { notInWallet, notWorkedOut }

/// The category key the page groups and filters by: the top-level category
/// name, "Other" when there is none. Top level on purpose: "Food" is a useful
/// filter; "Food · Swiggy Instamart" is a list of one.
String rewardCategoryKey(TransactionEntry entry) {
  final name = entry.categoryName?.trim();
  return name == null || name.isEmpty ? 'Other' : name;
}

class RewardRow {
  final TransactionEntry entry;
  final RewardRowStatus status;
  final RewardNotCountedReason? notCountedReason;

  /// The counted reward; zero unless [status] is [RewardRowStatus.earned].
  final Money reward;

  /// Set only when another wallet card would have earned more at base rate.
  final HistoricalCardComparison? missed;

  const RewardRow({
    required this.entry,
    required this.status,
    required this.reward,
    this.notCountedReason,
    this.missed,
  });

  Money get missedValue => missed?.missedValue ?? const Money.zero();
}

/// One slice of a breakdown (a category).
class RewardSlice {
  final String key;
  final Money earned;
  final Money spend;
  final int spends;

  const RewardSlice({
    required this.key,
    required this.earned,
    required this.spend,
    required this.spends,
  });
}

/// One wallet card's figures for the scope.
class RewardCardSummary {
  final String userCardId;
  final String label;
  final UserCard? card;
  final CardProduct? product;
  final Money earned;
  final Money spend;
  final Money missed;
  final int spends;

  const RewardCardSummary({
    required this.userCardId,
    required this.label,
    required this.card,
    required this.product,
    required this.earned,
    required this.spend,
    required this.missed,
    required this.spends,
  });

  /// Null when nothing was spent: 0% on no spend is not a fact.
  double? get ratePct =>
      spend.paise <= 0 ? null : earned.paise / spend.paise * 100;
}

/// One bar of the month-by-month (or year-by-year) chart.
class RewardBucket {
  final DateTime start;
  final bool isYear;
  final Money earned;

  const RewardBucket({
    required this.start,
    required this.isYear,
    required this.earned,
  });
}

/// One choice in the filter sheet, with how many spends in the date range it
/// covers (before the card and category filters).
class RewardFilterOption {
  final String key;
  final String label;
  final int spends;

  const RewardFilterOption({
    required this.key,
    required this.label,
    required this.spends,
  });
}

class RewardsReport {
  final RewardsRange range;

  /// Spends in scope, newest first.
  final List<RewardRow> rows;
  final Money earned;
  final Money spend;
  final int earnedCount;
  final int noRewardCount;
  final int notInWalletCount;
  final int notWorkedOutCount;

  /// Two or more wallet cards: the only case where "another card would have
  /// earned more" has an answer.
  final bool canCompare;
  final Money missed;
  final int missedCount;

  /// How much more the cards actually used earned than the best single wallet
  /// card would have on the same spends, both at base rate. Null when there is
  /// nothing to compare or the mix did not beat one card.
  final Money? beatBestSingleCard;
  final String? bestSingleCardName;

  /// Categories that earned something, highest first.
  final List<RewardSlice> byCategory;

  /// Wallet cards in scope, highest earned first; cards with no spend last.
  final List<RewardCardSummary> cards;

  /// Earned per month (or per year for long ranges). Empty when the range is
  /// inside one month.
  final List<RewardBucket> buckets;

  /// Choices for the filter sheet, from the whole date range.
  final List<RewardFilterOption> cardOptions;
  final List<RewardFilterOption> categoryOptions;

  const RewardsReport({
    required this.range,
    required this.rows,
    required this.earned,
    required this.spend,
    required this.earnedCount,
    required this.noRewardCount,
    required this.notInWalletCount,
    required this.notWorkedOutCount,
    required this.canCompare,
    required this.missed,
    required this.missedCount,
    required this.beatBestSingleCard,
    required this.bestSingleCardName,
    required this.byCategory,
    required this.cards,
    required this.buckets,
    required this.cardOptions,
    required this.categoryOptions,
  });

  int get notCountedCount => notInWalletCount + notWorkedOutCount;

  /// Null when nothing was spent by card.
  double? get ratePct =>
      spend.paise <= 0 ? null : earned.paise / spend.paise * 100;

  /// The spends another card would have done better on, biggest gap first.
  List<RewardRow> get missedRows =>
      rows.where((row) => row.missed != null).toList()..sort((a, b) {
        final byValue = b.missedValue.paise.compareTo(a.missedValue.paise);
        if (byValue != 0) return byValue;
        return b.entry.occurredAt.compareTo(a.entry.occurredAt);
      });

  String? cardLabel(String userCardId) {
    for (final option in cardOptions) {
      if (option.key == userCardId) return option.label;
    }
    return null;
  }
}

/// Longest range still drawn month by month; longer ranges go year by year so
/// the chart stays readable on a phone.
const rewardsMaxMonthlyBuckets = 18;

/// Works out the whole page for one scope.
///
/// Cost: one pass over the range's transactions, plus, with two or more wallet
/// cards, `cards` base-rate lookups per spend in scope. Rates come from a
/// [BaseRateTable], so each card's rule is picked once per category rather than
/// once per spend (picking a rule builds a key per catalogue rule, which is what
/// made a year of history slow).
RewardsReport buildRewardsReport({
  required List<TransactionEntry> transactions,
  required RewardsRange range,
  required List<(UserCard, CardProduct)> walletCards,
  Set<String> cardIds = const {},
  Set<String> categories = const {},
}) {
  // Same id twice (an offline copy and a fresh row) counts once.
  final byId = <String, TransactionEntry>{};
  for (final entry in transactions) {
    if (!isCardRewardSpend(entry)) continue;
    if (!range.contains(entry.occurredAt)) continue;
    byId[entry.id] = entry;
  }
  final inRange = byId.values.toList();

  final productsByCardId = {
    for (final (card, product) in walletCards) card.id: product,
  };
  final cardsById = {for (final (card, _) in walletCards) card.id: card};
  final allProducts = [for (final (_, product) in walletCards) product];
  final canCompare = allProducts.length >= 2;

  final labels = _cardLabels(walletCards, inRange);

  // Filter choices come from the whole range, so picking one card never hides
  // the others from the sheet.
  final cardSpends = <String, int>{};
  final categorySpends = <String, int>{};
  final categorySpendTotals = <String, int>{};
  for (final entry in inRange) {
    final cardId = entry.userCardId;
    if (cardId != null) cardSpends[cardId] = (cardSpends[cardId] ?? 0) + 1;
    final key = rewardCategoryKey(entry);
    categorySpends[key] = (categorySpends[key] ?? 0) + 1;
    categorySpendTotals[key] =
        (categorySpendTotals[key] ?? 0) + entry.amount.paise;
  }
  final cardOptions = <RewardFilterOption>[
    for (final (card, _) in walletCards)
      if (!card.isArchived || cardSpends.containsKey(card.id))
        RewardFilterOption(
          key: card.id,
          label: labels[card.id]!,
          spends: cardSpends[card.id] ?? 0,
        ),
    for (final id in cardSpends.keys)
      if (!cardsById.containsKey(id))
        RewardFilterOption(
          key: id,
          label: labels[id]!,
          spends: cardSpends[id]!,
        ),
  ]..sort((a, b) => b.spends.compareTo(a.spends));
  final categoryOptions =
      [
        for (final key in categorySpends.keys)
          RewardFilterOption(
            key: key,
            label: key,
            spends: categorySpends[key]!,
          ),
      ]..sort(
        (a, b) =>
            categorySpendTotals[b.key]!.compareTo(categorySpendTotals[a.key]!),
      );

  final scoped = inRange.where((entry) {
    if (cardIds.isNotEmpty && !cardIds.contains(entry.userCardId)) return false;
    if (categories.isNotEmpty &&
        !categories.contains(rewardCategoryKey(entry))) {
      return false;
    }
    return true;
  }).toList()..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

  final rates = BaseRateTable();
  var earned = const Money.zero();
  var spend = const Money.zero();
  var earnedCount = 0;
  var noRewardCount = 0;
  var notInWallet = 0;
  var notWorkedOut = 0;
  var missed = const Money.zero();
  var missedCount = 0;
  var usedBaseRate = const Money.zero();
  final singleCardTotals = List<Money>.filled(
    allProducts.length,
    const Money.zero(),
  );

  final categoryEarned = <String, Money>{};
  final categorySpend = <String, Money>{};
  final categoryCount = <String, int>{};
  final cardEarned = <String, Money>{};
  final cardSpend = <String, Money>{};
  final cardMissed = <String, Money>{};
  final cardCount = <String, int>{};
  final rows = <RewardRow>[];

  for (final entry in scoped) {
    spend += entry.amount;
    final (status, reason) = _statusOf(entry);
    final reward = status == RewardRowStatus.earned
        ? countedRewardValue(entry)!
        : const Money.zero();
    switch (status) {
      case RewardRowStatus.earned:
        earned += reward;
        earnedCount++;
      case RewardRowStatus.noReward:
        noRewardCount++;
      case RewardRowStatus.notCounted:
        if (reason == RewardNotCountedReason.notInWallet) {
          notInWallet++;
        } else {
          notWorkedOut++;
        }
    }

    HistoricalCardComparison? comparison;
    final cardId = entry.userCardId;
    final usedProduct = cardId == null ? null : productsByCardId[cardId];
    if (canCompare && usedProduct != null) {
      final result = compareToOwnedCards(
        usedCard: usedProduct,
        ownedCards: allProducts,
        amount: entry.amount,
        categoryId: entry.categoryId,
        rates: rates,
      );
      if (result.hadBetterOption && result.missedValue.paise > 0) {
        comparison = result;
        missed += result.missedValue;
        missedCount++;
      }
      usedBaseRate += result.actualValue;
      for (var i = 0; i < allProducts.length; i++) {
        singleCardTotals[i] += rates.valueFor(
          product: allProducts[i],
          amount: entry.amount,
          categoryId: entry.categoryId,
        );
      }
    }

    final key = rewardCategoryKey(entry);
    categorySpend[key] =
        (categorySpend[key] ?? const Money.zero()) + entry.amount;
    categoryCount[key] = (categoryCount[key] ?? 0) + 1;
    if (reward.paise > 0) {
      categoryEarned[key] =
          (categoryEarned[key] ?? const Money.zero()) + reward;
    }
    if (cardId != null) {
      cardSpend[cardId] =
          (cardSpend[cardId] ?? const Money.zero()) + entry.amount;
      cardCount[cardId] = (cardCount[cardId] ?? 0) + 1;
      cardEarned[cardId] = (cardEarned[cardId] ?? const Money.zero()) + reward;
      if (comparison != null) {
        cardMissed[cardId] =
            (cardMissed[cardId] ?? const Money.zero()) + comparison.missedValue;
      }
    }

    rows.add(
      RewardRow(
        entry: entry,
        status: status,
        notCountedReason: reason,
        reward: reward,
        missed: comparison,
      ),
    );
  }

  Money? beatBestSingleCard;
  String? bestSingleCardName;
  if (canCompare && usedBaseRate.paise > 0) {
    var bestIndex = 0;
    for (var i = 1; i < singleCardTotals.length; i++) {
      if (singleCardTotals[i] > singleCardTotals[bestIndex]) bestIndex = i;
    }
    final gap = usedBaseRate - singleCardTotals[bestIndex];
    if (gap.paise > 0) {
      beatBestSingleCard = gap;
      bestSingleCardName = allProducts[bestIndex].name;
    }
  }

  final byCategory = [
    for (final key in categoryEarned.keys)
      RewardSlice(
        key: key,
        earned: categoryEarned[key]!,
        spend: categorySpend[key]!,
        spends: categoryCount[key]!,
      ),
  ]..sort((a, b) => b.earned.paise.compareTo(a.earned.paise));

  final cardSummaries =
      <RewardCardSummary>[
        for (final (card, product) in walletCards)
          if ((cardIds.isEmpty || cardIds.contains(card.id)) &&
              (!card.isArchived || cardCount.containsKey(card.id)))
            RewardCardSummary(
              userCardId: card.id,
              label: labels[card.id]!,
              card: card,
              product: product,
              earned: cardEarned[card.id] ?? const Money.zero(),
              spend: cardSpend[card.id] ?? const Money.zero(),
              missed: cardMissed[card.id] ?? const Money.zero(),
              spends: cardCount[card.id] ?? 0,
            ),
        // A card that left the wallet (or whose product is missing from the
        // catalogue) still owns its spends in the range.
        for (final id in cardCount.keys)
          if (!productsByCardId.containsKey(id))
            RewardCardSummary(
              userCardId: id,
              label: labels[id]!,
              card: cardsById[id],
              product: null,
              earned: cardEarned[id] ?? const Money.zero(),
              spend: cardSpend[id]!,
              missed: const Money.zero(),
              spends: cardCount[id]!,
            ),
      ]..sort((a, b) {
        if ((a.spends == 0) != (b.spends == 0)) return a.spends == 0 ? 1 : -1;
        final byEarned = b.earned.paise.compareTo(a.earned.paise);
        if (byEarned != 0) return byEarned;
        return b.spend.paise.compareTo(a.spend.paise);
      });

  return RewardsReport(
    range: range,
    rows: rows,
    earned: earned,
    spend: spend,
    earnedCount: earnedCount,
    noRewardCount: noRewardCount,
    notInWalletCount: notInWallet,
    notWorkedOutCount: notWorkedOut,
    canCompare: canCompare,
    missed: missed,
    missedCount: missedCount,
    beatBestSingleCard: beatBestSingleCard,
    bestSingleCardName: bestSingleCardName,
    byCategory: byCategory,
    cards: cardSummaries,
    buckets: _buckets(range, rows),
    cardOptions: cardOptions,
    categoryOptions: categoryOptions,
  );
}

/// Same order of checks as the transaction screen's reward line, so a row's
/// status here matches what that screen says about it.
(RewardRowStatus, RewardNotCountedReason?) _statusOf(TransactionEntry entry) {
  if (noRewardPaymentMethodNotes.containsKey(entry.paymentMethod)) {
    return (RewardRowStatus.noReward, null);
  }
  if (entry.userCardId == null) {
    return (RewardRowStatus.notCounted, RewardNotCountedReason.notInWallet);
  }
  final reward = entry.rewardValue;
  if (reward == null) {
    return (RewardRowStatus.notCounted, RewardNotCountedReason.notWorkedOut);
  }
  if (reward.paise <= 0) return (RewardRowStatus.noReward, null);
  return (RewardRowStatus.earned, null);
}

/// "HDFC Millennia", or "HDFC Millennia ••1234" when two cards share a name.
Map<String, String> _cardLabels(
  List<(UserCard, CardProduct)> walletCards,
  List<TransactionEntry> inRange,
) {
  final base = <String, String>{};
  final last4 = <String, String?>{};
  for (final (card, product) in walletCards) {
    final nickname = card.nickname?.trim();
    base[card.id] = nickname != null && nickname.isNotEmpty
        ? nickname
        : product.name;
    last4[card.id] = card.last4;
  }
  for (final entry in inRange) {
    final id = entry.userCardId;
    if (id == null || base.containsKey(id)) continue;
    final name = entry.cardDisplayName?.trim();
    base[id] = name != null && name.isNotEmpty ? name : 'Card';
    last4[id] = entry.cardLast4;
  }
  final counts = <String, int>{};
  for (final label in base.values) {
    counts[label] = (counts[label] ?? 0) + 1;
  }
  return {
    for (final id in base.keys)
      id: counts[base[id]]! > 1 && (last4[id]?.isNotEmpty ?? false)
          ? '${base[id]} ••${last4[id]}'
          : base[id]!,
  };
}

List<RewardBucket> _buckets(RewardsRange range, List<RewardRow> rows) {
  final months = range.monthStarts;
  if (months.length < 2) return const [];
  final byYear = months.length > rewardsMaxMonthlyBuckets;
  final starts = byYear
      ? [
          for (var y = months.first.year; y <= months.last.year; y++)
            DateTime(y),
        ]
      : months;
  final totals = {for (final start in starts) start: const Money.zero()};
  for (final row in rows) {
    if (row.reward.paise <= 0) continue;
    final at = row.entry.occurredAt.toLocal();
    final key = byYear ? DateTime(at.year) : DateTime(at.year, at.month);
    final current = totals[key];
    if (current != null) totals[key] = current + row.reward;
  }
  return [
    for (final start in starts)
      RewardBucket(start: start, isYear: byYear, earned: totals[start]!),
  ];
}
