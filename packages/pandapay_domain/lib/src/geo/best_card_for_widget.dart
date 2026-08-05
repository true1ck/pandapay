import '../card_rules/card_rules.dart';
import '../engine/engine.dart';
import '../money/money.dart';

/// UA-8.2: "which single card should a home-screen widget show right now."
/// Deliberately NOT a new ranking algorithm — this just calls the existing
/// `RecommendationEngine.rank()` (packages/pandapay_domain/lib/src/engine/
/// engine.dart) with a widget-appropriate context and takes the top
/// non-excluded result. A widget has no amount entry field, so a nominal
/// amount is used purely to drive rate-based/cap-blended math the same way
/// the Home screen's ranking already does with its own entered amount —
/// the *relative* ordering of cards for a flat per-rupee rate doesn't
/// depend on the exact amount chosen, only capped/tiered rules do, and
/// those already degrade gracefully to "evaluate as if fresh" the same way
/// rankedRecommendationsProvider does for a card with no live cap state.
class BestCardForWidget {
  /// Nominal amount used only to exercise the engine's per-rupee math when
  /// no real transaction amount is known (a widget doesn't have an amount
  /// entry field). Matches enteredAmountProvider's own default in
  /// app/lib/app/providers.dart, so this is the same number Home would rank
  /// against before the user types anything.
  static final Money defaultNominalAmount = const Money.fromPaise(100000);

  final RecommendationEngine engine;

  const BestCardForWidget({this.engine = const RecommendationEngine()});

  /// Returns the single best non-excluded [Recommendation] for [cards], or
  /// null if every card is excluded (e.g. an empty wallet, or every owned
  /// card is a UPI-incompatible RuPay card on a UPI-only rail). [categoryId]
  /// is optional — pass the user's last-used spend category to bias toward
  /// "top card for what I usually buy," or leave null for a simple
  /// "top overall card" default (matches this chunk's two stated widget
  /// modes: last-used-category top pick, or overall-top-pick fallback).
  Recommendation? pickBestCard({
    required List<CardSnapshot> cards,
    String? categoryId,
    Money? amount,
  }) {
    if (cards.isEmpty) return null;
    final context = RecommendationContext(
      amount: amount ?? defaultNominalAmount,
      categoryId: categoryId,
      rail: TxnRail.swipe,
    );
    final ranked = engine.rank(context, cards);
    for (final rec in ranked) {
      if (!rec.isExcluded) return rec;
    }
    return null;
  }
}
