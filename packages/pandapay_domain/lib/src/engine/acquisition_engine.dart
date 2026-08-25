import '../card_rules/card_rules.dart';
import '../money/money.dart';
import 'engine.dart';

/// A user's real spend, aggregated by category over a trailing window (the
/// app supplies 12 months). `null` is the same "all other spends" bucket
/// [RewardRule.categoryId] already uses everywhere else in this package —
/// deliberately reused rather than inventing a second "uncategorized"
/// concept.
class SpendProfile {
  final Map<String?, Money> annualSpendByCategory;

  const SpendProfile({required this.annualSpendByCategory});

  Money get totalAnnualSpend =>
      annualSpendByCategory.values.fold(const Money.zero(), (sum, v) => sum + v);
}

/// One candidate card NOT already in the user's wallet, ranked by how much
/// better off their WHOLE portfolio would be, annually, if they acquired it
/// — not the card's own standalone earn rate.
///
/// [uplift] can be negative (a card is included even when it's a bad idea —
/// see [CardAcquisitionRecommender.rank]'s doc-comment for why this engine
/// never silently drops a candidate, same principle [RecommendationEngine]
/// already applies to excluded cards).
class AcquisitionCandidate {
  final CardProduct card;

  /// This card's own attributed share of the portfolio's annual reward
  /// value — the categories where, once owned, it would actually be the
  /// card tapped (not its nominal best-case rate applied to everything).
  final Money projectedAnnualValue;

  /// This card's annual fee, net of any fee-waiver its attributed spend
  /// would trigger.
  final Money annualFeeNet;

  /// (portfolio value WITH this card, net of its fee) − (portfolio value
  /// without it). The number this whole engine exists to produce.
  final Money uplift;

  /// Categories where this card would actually win, and what it would earn
  /// there — the "why" breakdown, same transparency principle
  /// [Recommendation.reasonLines] applies at transaction time.
  final Map<String?, Money> valueByCategory;

  const AcquisitionCandidate({
    required this.card,
    required this.projectedAnnualValue,
    required this.annualFeeNet,
    required this.uplift,
    required this.valueByCategory,
  });

  bool get isWorthwhile => uplift > const Money.zero();
}

const Map<CapPeriod, int> _annualOccurrences = {
  CapPeriod.statementCycle: 12,
  CapPeriod.calendarMonth: 12,
  CapPeriod.quarter: 4,
  CapPeriod.halfYear: 2,
  CapPeriod.annual: 1,
  CapPeriod.lifetime: 1,
};

class _PortfolioEvaluation {
  final Money totalValue;
  final Map<String, Money> attributedValueByCardId;
  final Map<String, Money> attributedTotalSpendByCardId;
  // cardId -> {categoryId -> spend it won}, needed per-card for fee-waiver
  // exclusion checks (a waiver's excludedCategoryIds must not count toward
  // its own threshold).
  final Map<String, Map<String?, Money>> attributedSpendByCardAndCategory;
  // cardId -> {categoryId -> REWARD value earned there}, for the "why"
  // breakdown — distinct from attributedSpendByCardAndCategory, which is
  // the ₹ spent, not the ₹ earned.
  final Map<String, Map<String?, Money>> attributedValueByCardAndCategory;

  const _PortfolioEvaluation({
    required this.totalValue,
    required this.attributedValueByCardId,
    required this.attributedTotalSpendByCardId,
    required this.attributedSpendByCardAndCategory,
    required this.attributedValueByCardAndCategory,
  });
}

/// packages/pandapay_domain/src/engine/ — pure Dart, zero IO, same
/// discipline as [RecommendationEngine]. Answers a different question than
/// that engine does: not "which of MY cards should I use for THIS
/// transaction", but "which card I DON'T own would be worth acquiring,
/// given my actual spend pattern". New scope beyond product-plan.md's
/// documented v1 (§22.2, listed there only as a future bet) — see this
/// project's implementation plan for the acquisition-recommender design.
class CardAcquisitionRecommender {
  final RecommendationEngine _engine;

  // Deliberately public `engine`, private `_engine`: an initializing formal
  // would force the public parameter itself to be named `_engine`, which
  // callers outside this library couldn't pass at all.
  const CardAcquisitionRecommender({RecommendationEngine engine = const RecommendationEngine()})
      // ignore: prefer_initializing_formals
      : _engine = engine;

  /// Ranks every card in [candidates] that isn't already in [ownedCards] by
  /// annual portfolio uplift, highest first.
  ///
  /// Deliberately never drops a candidate for scoring poorly — a card whose
  /// fee outweighs anything it would ever win gets a real, explainable
  /// negative [AcquisitionCandidate.uplift] rather than being silently
  /// excluded from the list. [RecommendationEngine.rank] applies the exact
  /// same "always return everything, let the caller/UI decide what to
  /// show" rule to excluded cards, for the same reason: a number a user can
  /// see and question is more trustworthy than a card that quietly
  /// vanished.
  ///
  /// Rail is fixed to [TxnRail.swipe] for every synthetic evaluation below
  /// — [SpendProfile] carries a category total, not a rail mix, and swipe
  /// is the one rail with no eligibility exclusion, so it never
  /// unfairly penalises or favours a card based on a rail assumption this
  /// engine has no real data for.
  ///
  /// [now], when given, is passed into every synthetic evaluation so a
  /// candidate is not recommended on the strength of a promo rate whose
  /// catalogue validity window has already closed — the most embarrassing
  /// way for an acquisition recommendation to be wrong, since the user
  /// would apply for the card and never see the rate. Left null it
  /// preserves the previous behaviour of ignoring those windows; see
  /// [RecommendationContext.now].
  List<AcquisitionCandidate> rank({
    required List<CardProduct> candidates,
    required List<CardProduct> ownedCards,
    required SpendProfile spendProfile,
    DateTime? now,
  }) {
    final ownedIds = ownedCards.map((c) => c.id).toSet();
    final baseline = _evaluatePortfolio(ownedCards, spendProfile, now: now);

    final results = <AcquisitionCandidate>[];
    for (final candidate in candidates) {
      if (ownedIds.contains(candidate.id)) continue;

      final withCandidate = _evaluatePortfolio([...ownedCards, candidate], spendProfile, now: now);
      final candidateSpendByCategory =
          withCandidate.attributedSpendByCardAndCategory[candidate.id] ?? const {};
      final fee = _netAnnualFee(candidate, candidateSpendByCategory);
      final netTotal = withCandidate.totalValue - fee;
      final uplift = netTotal - baseline.totalValue;

      results.add(AcquisitionCandidate(
        card: candidate,
        projectedAnnualValue: withCandidate.attributedValueByCardId[candidate.id] ?? const Money.zero(),
        annualFeeNet: fee,
        uplift: uplift,
        valueByCategory: withCandidate.attributedValueByCardAndCategory[candidate.id] ?? const {},
      ));
    }

    results.sort((a, b) => b.uplift.paise.compareTo(a.uplift.paise));
    return results;
  }

  /// One pass over every category in [profile], per category running the
  /// SAME [RecommendationEngine] a real transaction would — treating a
  /// year's total category spend as one synthetic transaction, with cap
  /// headroom annualized by [CapRule.period] (an explicit, documented
  /// simplifying assumption: even spend distribution across the year, not
  /// a real month-by-month simulation). Reusing the transaction engine
  /// here, rather than re-deriving rate/cap logic, is what keeps this
  /// projection consistent with what Home already shows for the same
  /// card+category — see the project's implementation plan for why.
  _PortfolioEvaluation _evaluatePortfolio(List<CardProduct> cards, SpendProfile profile, {DateTime? now}) {
    if (cards.isEmpty) {
      return const _PortfolioEvaluation(
        totalValue: Money.zero(),
        attributedValueByCardId: {},
        attributedTotalSpendByCardId: {},
        attributedSpendByCardAndCategory: {},
        attributedValueByCardAndCategory: {},
      );
    }

    var total = const Money.zero();
    final attributedValue = <String, Money>{};
    final attributedTotalSpend = <String, Money>{};
    final attributedSpendByCategory = <String, Map<String?, Money>>{};
    final attributedValueByCategory = <String, Map<String?, Money>>{};

    for (final entry in profile.annualSpendByCategory.entries) {
      final categoryId = entry.key;
      final amount = entry.value;
      if (amount.isZero || amount.isNegative) continue;

      final ctx = RecommendationContext(amount: amount, categoryId: categoryId, rail: TxnRail.swipe, now: now);
      // Milestones are stripped from the per-category snapshot on purpose:
      // RecommendationEngine._evaluate() adds its OWN milestone bonus given
      // milestoneProgress=0 and a large enough synthetic "transaction",
      // which is correct for a single real transaction but wrong here —
      // called once per category, a card's milestone (which is threshold-ed
      // against its TOTAL spend, not any one category) would otherwise get
      // credited once per category that independently looks "material"
      // instead of once for the year. The real milestone bonus is computed
      // separately below, against each card's true cross-category
      // attributed total.
      final snapshots = cards
          .map((c) => CardSnapshot(
                product: _withoutMilestones(c),
                capRemaining: _annualizedCapRemaining(c, amount),
              ))
          .toList();
      final ranked = _engine.rank(ctx, snapshots);
      final winner = ranked.firstWhere((r) => !r.isExcluded, orElse: () => ranked.first);
      if (winner.isExcluded) continue;

      total += winner.expectedValue;
      final id = winner.card.id;
      attributedValue[id] = (attributedValue[id] ?? const Money.zero()) + winner.expectedValue;
      attributedTotalSpend[id] = (attributedTotalSpend[id] ?? const Money.zero()) + amount;
      final spendByCategory = attributedSpendByCategory.putIfAbsent(id, () => {});
      spendByCategory[categoryId] = (spendByCategory[categoryId] ?? const Money.zero()) + amount;
      final valueByCategoryForCard = attributedValueByCategory.putIfAbsent(id, () => {});
      valueByCategoryForCard[categoryId] =
          (valueByCategoryForCard[categoryId] ?? const Money.zero()) + winner.expectedValue;
    }

    // Milestone bonuses, attributed to whichever card actually earned the
    // spend that would clear them — not every owned/candidate card blindly.
    for (final card in cards) {
      final spend = attributedTotalSpend[card.id] ?? const Money.zero();
      if (spend.isZero) continue;
      for (final milestone in card.milestoneRules) {
        Money bonus;
        if (milestone.isRepeatable) {
          final times = (spend.paise / milestone.thresholdSpend.paise).floor();
          if (times < 1) continue;
          bonus = milestone.rewardValue * times;
        } else {
          if (spend < milestone.thresholdSpend) continue;
          bonus = milestone.rewardValue;
        }
        total += bonus;
        attributedValue[card.id] = (attributedValue[card.id] ?? const Money.zero()) + bonus;
      }
    }

    return _PortfolioEvaluation(
      totalValue: total,
      attributedValueByCardId: attributedValue,
      attributedTotalSpendByCardId: attributedTotalSpend,
      attributedSpendByCardAndCategory: attributedSpendByCategory,
      attributedValueByCardAndCategory: attributedValueByCategory,
    );
  }

  /// See the call site's comment: a shallow copy of [card] with
  /// `milestoneRules` cleared, so [RecommendationEngine] can't apply its
  /// own per-transaction milestone bonus to a synthetic per-category call.
  CardProduct _withoutMilestones(CardProduct card) => CardProduct(
        id: card.id,
        name: card.name,
        network: card.network,
        isUpiLinkable: card.isUpiLinkable,
        pointValueInr: card.pointValueInr,
        baseRewardUnit: card.baseRewardUnit,
        baseRewardRate: card.baseRewardRate,
        rewardRules: card.rewardRules,
        capRules: card.capRules,
        milestoneRules: const [],
        forexRule: card.forexRule,
        fuelRule: card.fuelRule,
        feeWaiverRules: card.feeWaiverRules,
        benefits: card.benefits,
        annualFeeInr: card.annualFeeInr,
        joiningFeeInr: card.joiningFeeInr,
        verifiedAt: card.verifiedAt,
        issuerName: card.issuerName,
        artAssetUrl: card.artAssetUrl,
        artPrimaryColor: card.artPrimaryColor,
        hasApplyUrl: card.hasApplyUrl,
      );

  /// [CapRule.capValue] is one period's headroom; the projection needs a
  /// full year's, so it's scaled by how many times that period recurs
  /// annually. txn_count caps are left as-is — a whole year modeled as one
  /// synthetic transaction makes "annualizing a transaction count" not a
  /// meaningful operation, and real usage (many small transactions, each
  /// independently under the count limit) rarely hits this cap materially
  /// over a year regardless.
  Map<String, Money> _annualizedCapRemaining(CardProduct card, Money categorySpend) {
    final result = <String, Money>{};
    for (final cap in card.capRules) {
      if (cap.measure == CapMeasure.txnCount) {
        result[cap.id] = cap.capValue;
        continue;
      }
      final occurrences = _annualOccurrences[cap.period] ?? 1;
      result[cap.id] = cap.capValue * occurrences;
    }
    return result;
  }

  /// [attributedSpendByCategory] excludes categories a given waiver rule
  /// names in [FeeWaiverRule.excludedCategoryIds] — the same "rent/fuel/
  /// wallet commonly excluded" rule the catalogue schema documents, so
  /// this never credits a fee waiver from spend that wouldn't actually
  /// count toward it in real life.
  Money _netAnnualFee(CardProduct card, Map<String?, Money> attributedSpendByCategory) {
    var fee = card.annualFeeInr ?? const Money.zero();
    if (fee.isZero || fee.isNegative) return const Money.zero();

    for (final waiver in card.feeWaiverRules) {
      final countedSpend = attributedSpendByCategory.entries
          .where((e) => e.key == null || !waiver.excludedCategoryIds.contains(e.key))
          .fold(const Money.zero(), (sum, e) => sum + e.value);
      if (countedSpend >= waiver.thresholdSpend) {
        fee -= waiver.waivesFee;
      }
    }
    return fee.isNegative ? const Money.zero() : fee;
  }
}
