import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show SpendCheck;

import '../../../app/providers.dart';
import '../../../data/reward_counting.dart';
import '../../../data/user_cards_repository.dart';
import '../../sms_v2/ledger/providers.dart';
import 'rewards_comparison.dart';
import 'rewards_filter.dart';
import 'rewards_report.dart';

/// The resolved scope a report is built for: real dates (a preset resolved
/// against the clock) plus the card and category choices.
@immutable
class RewardsScope {
  final RewardsRange range;
  final Set<String> cardIds;
  final Set<String> categories;

  const RewardsScope({
    required this.range,
    this.cardIds = const {},
    this.categories = const {},
  });

  factory RewardsScope.of(RewardsFilter filter, DateTime now) => RewardsScope(
    range: rewardsRangeFor(filter.query, now),
    cardIds: filter.cardIds,
    categories: filter.categories,
  );

  @override
  bool operator ==(Object other) =>
      other is RewardsScope &&
      other.range == range &&
      setEquals(other.cardIds, cardIds) &&
      setEquals(other.categories, categories);

  @override
  int get hashCode => Object.hash(
    range,
    Object.hashAllUnordered(cardIds),
    Object.hashAllUnordered(categories),
  );
}

/// The transactions of one date range, from the same source the Insights
/// overview reads (the SMS ledger model once it reports, otherwise the
/// offline-first transaction list), so the hub and this page agree.
///
/// Keyed by the range only: changing a card or category filter re-runs the
/// pure report over this list and never fetches again.
final rewardsTransactionsProvider = FutureProvider.autoDispose
    .family<List<TransactionEntry>, RewardsRange>((ref, range) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) return const [];
      final ledgerModel = ref.watch(smsV2ReportingEnabledProvider)
          ? await ref.watch(smsV2LedgerReadModelProvider.future)
          : null;
      if (ledgerModel != null) {
        return [
          for (final entry in ledgerModel.transactions)
            if (range.contains(entry.occurredAt)) entry,
        ];
      }
      return loadTransactionsWithOfflineCache(
        ref,
        repo: repo,
        cacheKey:
            'rewards_transactions:${range.from.toIso8601String()}:${range.toExclusive.toIso8601String()}',
        from: range.from,
        to: range.toInclusive,
        preferCached: true,
        onBackgroundRefresh: ref.invalidateSelf,
      );
    });

/// How a comparison is run: off the UI isolate for a real history, inline for
/// a handful of spends. Tests override it with a synchronous runner.
final rewardsComparisonRunnerProvider = Provider<RewardsComparisonRunner>(
  (ref) => runRewardsComparison,
);

/// Category id to slug, from the category list, so a spend's category can be
/// told apart ("rent", "fuel") when it is checked against other cards.
final rewardCategorySlugByIdProvider = Provider<Map<String, String>>((ref) {
  final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
  return {
    for (final category in categories)
      if (!category.isCustom) category.id: category.slug,
  };
});

/// For each spend of one date range that had another wallet card to compare
/// with, whether another card would have paid more (see
/// `rewards_comparison.dart`).
///
/// Keyed by the range only, like [rewardsTransactionsProvider]: the card and
/// category filters re-slice these answers and never run them again.
final rewardsChecksProvider = FutureProvider.autoDispose
    .family<Map<String, SpendCheck>, RewardsRange>((ref, range) async {
      final transactions = await ref.watch(
        rewardsTransactionsProvider(range).future,
      );
      final wallet =
          ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
      // The ledger holds the whole history, so a card's first use is its real
      // first use even when the range is one month. Without a ledger the range's
      // own spends are all there is.
      final ledgerFirstUse = ref
          .watch(smsV2LedgerReadModelProvider)
          .valueOrNull
          ?.firstCardUseByUserCardId;
      final request = buildRewardsComparisonRequest(
        transactions: transactions,
        walletCards: wallet,
        firstUseByCardId: ledgerFirstUse != null && ledgerFirstUse.isNotEmpty
            ? ledgerFirstUse
            : firstCardUseOf(transactions),
        categorySlugById: ref.watch(rewardCategorySlugByIdProvider),
        directory: ref.watch(merchantDirectoryProvider),
      );
      return ref.watch(rewardsComparisonRunnerProvider)(request);
    });

/// The whole page for one scope. Loading until the range's transactions, the
/// wallet and the card comparison are all known: building it without the wallet
/// would briefly say "add a second card" to someone who has five, and building
/// it before the comparison would say "no missed rewards" to someone who has
/// not been checked yet.
final rewardsReportProvider = Provider.autoDispose
    .family<AsyncValue<RewardsReport>, RewardsScope>((ref, scope) {
      final transactions = ref.watch(rewardsTransactionsProvider(scope.range));
      final checks = ref.watch(rewardsChecksProvider(scope.range));
      final wallet = ref.watch(ownedCardsWithProductProvider);
      if (wallet.isLoading && !wallet.hasValue && !wallet.hasError) {
        return const AsyncLoading();
      }
      final walletCards = wallet.valueOrNull ?? const [];
      // A recheck in progress is a pending answer, not an empty one.
      if (checks.isLoading && !transactions.hasError) {
        return const AsyncLoading();
      }
      return transactions.whenData(
        (list) => buildRewardsReport(
          transactions: list,
          range: scope.range,
          walletCards: walletCards,
          cardIds: scope.cardIds,
          categories: scope.categories,
          checks: checks.valueOrNull ?? const {},
          comparisonFailed: checks.hasError,
        ),
      );
    });
