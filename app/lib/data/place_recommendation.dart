import 'package:pandapay_domain/pandapay_domain.dart';

import 'card_overrides_repository.dart';
import 'override_resolver.dart';
import 'user_cards_repository.dart';

/// Shared helper for place-aware ranking.
///
/// This keeps the recommendation logic used by nearby-merchant screens and
/// background geofence notifications consistent: same wallet scope, same
/// override resolution, same ranking engine.
Recommendation? bestCardForPlace({
  required RecommendationEngine engine,
  required List<CardProduct> catalogue,
  required List<UserCard> wallet,
  required List<CardOverride> overrides,
  String? categoryId,
  String? merchantName,
  String? vpa,
}) {
  final cards = wallet.isEmpty
      ? catalogue
      : catalogue.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();
  final overrideProductId = resolveActiveOverrideCardProductId(
    overrides: overrides,
    wallet: wallet,
    categoryId: categoryId,
    merchantName: merchantName,
    vpa: vpa,
  );
  final snapshots = buildCardSnapshots(cards: cards, wallet: wallet, forcedOverrideCardId: overrideProductId);
  return BestCardForWidget(engine: engine).pickBestCard(cards: snapshots, categoryId: categoryId);
}

List<CardSnapshot> buildCardSnapshots({
  required List<CardProduct> cards,
  required List<UserCard> wallet,
  String? forcedOverrideCardId,
}) {
  return cards.map((c) {
    final owned = wallet.firstWhereOrNull((w) => w.cardProductId == c.id);
    final capRemaining = owned == null
        ? const <String, Money>{}
        : {
            for (final cap in c.capRules)
              if (owned.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - owned.capConsumed[cap.id]!,
          };
    return CardSnapshot(
      product: c,
      capRemaining: capRemaining,
      milestoneProgress: owned?.milestoneQualifiedSpend ?? const {},
      forcedOverrideCardId: forcedOverrideCardId,
    );
  }).toList();
}

/// Returns the best recommendation for a merchant/category context using the
/// user's current wallet, or null if every owned card is excluded.
Recommendation? bestCardForCategory({
  required RecommendationEngine engine,
  required List<CardProduct> catalogue,
  required List<UserCard> wallet,
  required List<CardOverride> overrides,
  required String? categoryId,
}) {
  return bestCardForPlace(
    engine: engine,
    catalogue: catalogue,
    wallet: wallet,
    overrides: overrides,
    categoryId: categoryId,
  );
}

extension _FirstWhereOrNull<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
