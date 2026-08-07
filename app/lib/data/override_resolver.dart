import 'card_overrides_repository.dart';
import 'user_cards_repository.dart';

/// B8 wiring: given every override the user owns and their current wallet,
/// resolve which CardProduct.id (NOT user_cards.id — the engine's
/// CardSnapshot.forcedOverrideCardId compares against CardProduct.id) should
/// be forced to the top of the ranking for the current transaction context.
///
/// Priority when more than one enabled override could apply: vpa (most
/// specific — a single merchant's payment address) > merchant_name (a named
/// place, possibly multiple VPAs) > category (broadest — "always this card
/// for Fuel"). Matches product-plan §4.6's framing of overrides as
/// increasingly specific rules. merchant_name comparison is
/// case-insensitive and exact (B3's editable merchant-name field is the
/// only place a name gets typed, so exact-after-normalizing is the right
/// bar — fuzzy matching here would make overrides fire unpredictably,
/// exactly the kind of silent-wrong-advice trust bug ui-spec calls out for
/// B8).
String? resolveActiveOverrideCardProductId({
  required List<CardOverride> overrides,
  required List<UserCard> wallet,
  String? categoryId,
  String? merchantName,
  String? vpa,
}) {
  String? productIdFor(String userCardId) {
    for (final card in wallet) {
      if (card.id == userCardId) return card.cardProductId;
    }
    return null; // override targets a card that's been archived/removed
  }

  final enabled = overrides.where((o) => o.isEnabled);

  if (vpa != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.vpa && o.vpa?.toLowerCase() == vpa.toLowerCase()) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  if (merchantName != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.merchantName &&
          o.merchantName?.toLowerCase() == merchantName.toLowerCase()) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  if (categoryId != null) {
    for (final o in enabled) {
      if (o.scope == OverrideScope.category && o.categoryId == categoryId) {
        final productId = productIdFor(o.userCardId);
        if (productId != null) return productId;
      }
    }
  }

  return null;
}
