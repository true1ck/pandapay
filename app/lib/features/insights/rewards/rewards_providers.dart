import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../data/user_cards_repository.dart';
import '../../sms_v2/ledger/providers.dart';
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

/// The whole page for one scope. Loading until both the range's transactions
/// and the wallet are known: building it without the wallet would briefly say
/// "add a second card" to someone who has five.
final rewardsReportProvider = Provider.autoDispose
    .family<AsyncValue<RewardsReport>, RewardsScope>((ref, scope) {
      final transactions = ref.watch(rewardsTransactionsProvider(scope.range));
      final wallet = ref.watch(ownedCardsWithProductProvider);
      if (wallet.isLoading && !wallet.hasValue && !wallet.hasError) {
        return const AsyncLoading();
      }
      final walletCards = wallet.valueOrNull ?? const [];
      return transactions.whenData(
        (list) => buildRewardsReport(
          transactions: list,
          range: scope.range,
          walletCards: walletCards,
          cardIds: scope.cardIds,
          categories: scope.categories,
        ),
      );
    });
