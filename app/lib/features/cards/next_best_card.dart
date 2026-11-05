import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/card_snapshots.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart';

/// Card Rewards Phase 1 (WP9) — "Use {card} for {category} instead": the
/// next-best OWNED card for the category a capped card is limited in.
///
/// It is the recommender over the user's other cards (the capped card is
/// excluded), each with its own cap state, so a card whose bonus is already
/// used up or unknown is not named. It is silent (null) unless a card earns
/// **more than base**: strictly more than its own base rate (it has a real
/// bonus here) and strictly more than the capped card's base rate (what the
/// user earns anyway after the cap). Both bars only ever suppress a
/// suggestion, never add one.
class NextBestCard {
  final UserCard userCard;
  final CardProduct product;
  final Recommendation recommendation;
  final String categoryName;

  const NextBestCard({
    required this.userCard,
    required this.product,
    required this.recommendation,
    required this.categoryName,
  });

  String get cardName =>
      userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name;

  /// "Use HDFC Millennia for Dining instead".
  String get message => 'Use $cardName for $categoryName instead';
}

/// The one category [cap] limits, or null for a card-wide cap or one whose
/// targets span several categories (then no suggestion is made).
String? capCategoryId(CardProduct product, CapRule cap) {
  if (cap.scope == CapScope.card) return null;
  if (cap.categoryId != null) return cap.categoryId;
  final targetIds = <String>{
    ...cap.targets,
    if (cap.rewardRuleId != null) cap.rewardRuleId!,
  };
  if (targetIds.isEmpty) return null;
  final categoryIds = <String?>{};
  for (final id in targetIds) {
    final rule = product.rewardRules.where((r) => r.id == id).firstOrNull;
    if (rule == null) return null;
    categoryIds.add(rule.categoryId);
  }
  if (categoryIds.length != 1) return null;
  return categoryIds.single;
}

/// Nominal spend the comparison is made at; only the relative rates matter.
const Money kNextBestNominalSpend = Money.fromPaise(100000);

NextBestCard? nextBestOwnedCard({
  required List<(UserCard, CardProduct)> owned,
  required UserCard cappedCard,
  required CardProduct cappedProduct,
  required CapRule cap,
  required List<SpendCategory> categories,
  required DateTime now,
}) {
  final categoryId = capCategoryId(cappedProduct, cap);
  if (categoryId == null) return null;
  final category = categories.where((c) => c.id == categoryId).firstOrNull;
  if (category == null) return null;

  final others = [
    for (final pair in owned)
      if (pair.$1.id != cappedCard.id) pair,
  ];
  if (others.isEmpty) return null;

  final ranked = const RecommendationEngine().rank(
    RecommendationContext(
      amount: kNextBestNominalSpend,
      categoryId: categoryId,
      categorySlug: category.slug,
      rail: TxnRail.swipe,
      now: now,
    ),
    [
      for (final (userCard, product) in others)
        buildCardSnapshot(product, owned: userCard, now: now),
    ],
  );
  final best = ranked.where((r) => !r.isExcluded).firstOrNull;
  if (best == null) return null;

  final match = others.firstWhere((p) => p.$2.id == best.card.id);
  final floor = [
    kNextBestNominalSpend * match.$2.baseRatePerRupee,
    kNextBestNominalSpend * cappedProduct.baseRatePerRupee,
  ].reduce((a, b) => a > b ? a : b);
  if (best.expectedValue <= floor) return null;
  return NextBestCard(
    userCard: match.$1,
    product: match.$2,
    recommendation: best,
    categoryName: category.name,
  );
}
