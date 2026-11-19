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

  /// Set only when another wallet card would clearly have earned more on this
  /// spend (see [SpendComparer]).
  final SpendComparison? missed;

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

  /// Two or more different card products in the wallet: the only case where
  /// "another card would have earned more" has an answer.
  final bool canCompare;
  final Money missed;
  final int missedCount;

  /// Spends in scope that had at least one other card to be compared with (it
  /// was in hand on the day and fits the payment). Fewer than [rows] when some
  /// spends were from before the other cards, or cannot move (EMI, UPI on a
  /// card that cannot take UPI). "Nothing missed" only means something about
  /// these.
  final int comparedCount;

  /// The comparison could not be run (it failed), so Missed says nothing about
  /// these spends rather than claiming the best card was used.
  final bool comparisonFailed;

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
    required this.comparedCount,
    required this.comparisonFailed,
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
/// Cost: one pass over the range's transactions. Whether another card would
/// have paid more on a spend is NOT worked out here: pricing every spend on
/// every wallet card is O(spends x cards) and runs off the UI isolate
/// (`rewards_comparison.dart`). The answers arrive as [checks], by transaction
/// id, so changing a card or category filter only re-slices them.
///
/// [checks] holds an entry only for spends that had another card to compare
/// with. [comparisonFailed] says the comparison could not be run at all.
RewardsReport buildRewardsReport({
  required List<TransactionEntry> transactions,
  required RewardsRange range,
  required List<(UserCard, CardProduct)> walletCards,
  Set<String> cardIds = const {},
  Set<String> categories = const {},
  Map<String, SpendCheck> checks = const {},
  bool comparisonFailed = false,
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
  // Two cards of the same product (two Amazon Pay cards) are one choice, not
  // two: they earn the same, so with only those there is nothing to compare.
  final canCompare = {for (final (_, product) in walletCards) product.id}.length >= 2;

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

  var earned = const Money.zero();
  var spend = const Money.zero();
  var earnedCount = 0;
  var noRewardCount = 0;
  var notInWallet = 0;
  var notWorkedOut = 0;
  var missed = const Money.zero();
  var missedCount = 0;
  var comparedCount = 0;

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

    final cardId = entry.userCardId;
    final check = canCompare ? checks[entry.id] : null;
    if (check != null && check.compared) comparedCount++;
    final comparison = check?.better;
    if (comparison != null) {
      missed += comparison.missedValue;
      missedCount++;
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
    comparedCount: comparedCount,
    comparisonFailed: comparisonFailed,
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

// Some catalogue names carry a line break ("Swiggy\n HDFC Bank Credit Card").
final RegExp _runsOfWhitespace = RegExp(r'\s+');

/// A card name on one line.
String rewardCardName(String name) =>
    name.replaceAll(_runsOfWhitespace, ' ').trim();

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
        : rewardCardName(product.name);
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
