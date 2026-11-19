import 'package:flutter/foundation.dart' show compute;
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:pandapay_domain/sms_v2_category.dart' show TaxonomyRegistry;

import '../../../data/reward_counting.dart';
import '../../../data/user_cards_repository.dart';

/// "Would another card in the wallet have paid more on this spend?" for a list
/// of spends, shared by the Rewards page (Missed tab, Summary, Cards) and the
/// Insights hub so the two always show the same figure for the same period.
///
/// The answer for each spend comes from [SpendComparer] (the reward engine
/// itself, not a category-level rate). It is worked out in an isolate for a
/// real history (see [runRewardsComparison]): pricing every spend on every
/// wallet card is O(spends x cards), which the performance rulebook (R1) keeps
/// off the UI isolate.

/// A wallet card with no recorded use and no issue date: nothing says when the
/// person had it, so it is never offered for a past spend (a card added to the
/// wallet today did not exist for last month's purchases).
final DateTime _neverUsed = DateTime.utc(9999);

/// The category id card reward rules are written against (the system
/// category), or null. A category the person made themselves stands for the
/// system category it sits under.
String? rewardRuleCategoryId(TransactionEntry entry) {
  final id = entry.categoryId;
  if (id == null) return null;
  if (!id.startsWith('custom:')) return id;
  final parent = entry.parentCategoryId;
  return parent == null || parent.startsWith('custom:') ? null : parent;
}

final Map<String, String> _slugByDisplayName = {
  for (final category in TaxonomyRegistry.v1.categories)
    category.displayName.toLowerCase(): category.slug,
};

/// The category slug ('dining', 'rent') of [entry], from the category list
/// when it is loaded, else from the built-in category names.
String? rewardCategorySlug(
  TransactionEntry entry,
  Map<String, String> slugByCategoryId,
) {
  final id = rewardRuleCategoryId(entry);
  if (id != null) {
    final slug = slugByCategoryId[id];
    if (slug != null) return slug;
  }
  final name = entry.categoryName?.trim().toLowerCase();
  return name == null ? null : _slugByDisplayName[name];
}

/// One spend to check: the wallet product it was paid with and what the
/// comparison reads about it.
class RewardsSpendInput {
  final String entryId;
  final CardProduct used;
  final SpendProbe probe;

  const RewardsSpendInput({
    required this.entryId,
    required this.used,
    required this.probe,
  });
}

/// Everything the comparison needs, plain data so it can cross to an isolate.
class RewardsComparisonRequest {
  final List<WalletCardOption> wallet;
  final MerchantDirectory? directory;
  final List<RewardsSpendInput> spends;

  const RewardsComparisonRequest({
    required this.wallet,
    required this.directory,
    required this.spends,
  });

  /// Nothing to ask: no spend, or fewer than two cards to choose between.
  bool get isEmpty =>
      spends.isEmpty ||
      wallet.map((option) => option.product.id).toSet().length < 2;
}

/// Builds the request for [transactions]: the credit-card spends paid with a
/// wallet card in a way that earns rewards, against the whole wallet.
///
/// [firstUseByCardId] says when each wallet card first appears in the person's
/// history (the ledger keeps all of it); a card's issue date, when the person
/// entered one, wins over that.
RewardsComparisonRequest buildRewardsComparisonRequest({
  required Iterable<TransactionEntry> transactions,
  required List<(UserCard, CardProduct)> walletCards,
  Map<String, DateTime> firstUseByCardId = const {},
  Map<String, String> categorySlugById = const {},
  MerchantDirectory? directory,
}) {
  final productByCardId = {
    for (final (card, product) in walletCards) card.id: product,
  };
  final wallet = [
    for (final (card, product) in walletCards)
      WalletCardOption(
        product,
        usableFrom: card.openedOn ?? firstUseByCardId[card.id] ?? _neverUsed,
      ),
  ];
  final byId = <String, TransactionEntry>{};
  for (final entry in transactions) {
    if (!isCardRewardSpend(entry)) continue;
    // A gift card, reward points, EMI or pay-later payment earns nothing on any
    // card, so there is no better card for it.
    if (noRewardPaymentMethodNotes.containsKey(entry.paymentMethod)) continue;
    if (!productByCardId.containsKey(entry.userCardId)) continue;
    byId[entry.id] = entry;
  }
  return RewardsComparisonRequest(
    wallet: wallet,
    directory: directory,
    spends: [
      for (final entry in byId.values)
        RewardsSpendInput(
          entryId: entry.id,
          used: productByCardId[entry.userCardId]!,
          probe: SpendProbe(
            amount: entry.amount,
            occurredAt: entry.occurredAt,
            categoryId: rewardRuleCategoryId(entry),
            categorySlug: rewardCategorySlug(entry, categorySlugById),
            merchantName: entry.merchantName,
            merchantVpa: entry.merchantVpa,
            rail: entry.rail,
          ),
        ),
    ],
  );
}

/// The answer for every spend that had another card to compare with. A spend
/// missing from the result was not compared at all (no other card was in hand,
/// or the payment cannot be moved), which is different from "the best card was
/// used". Pure and synchronous: this is what runs in the isolate.
Map<String, SpendCheck> computeSpendChecks(RewardsComparisonRequest request) {
  if (request.isEmpty) return const {};
  final comparer = SpendComparer(
    wallet: request.wallet,
    directory: request.directory,
  );
  final checks = <String, SpendCheck>{};
  for (final spend in request.spends) {
    final check = comparer.check(spend.used, spend.probe);
    if (check.compared) checks[spend.entryId] = check;
  }
  return checks;
}

/// Runs a request. Tests and callers that want it inline can swap this out
/// (`rewardsComparisonRunnerProvider`).
typedef RewardsComparisonRunner =
    Future<Map<String, SpendCheck>> Function(RewardsComparisonRequest request);

/// Spends x cards priced on the UI isolate without a hop (roughly 10 ms). A
/// month of use is under this; a year of history is not.
const int rewardsInlineComparisonWork = 800;

Future<Map<String, SpendCheck>> runRewardsComparison(
  RewardsComparisonRequest request,
) {
  if (request.isEmpty) return Future.value(const {});
  if (request.spends.length * request.wallet.length <=
      rewardsInlineComparisonWork) {
    return Future.value(computeSpendChecks(request));
  }
  return compute(computeSpendChecks, request);
}
