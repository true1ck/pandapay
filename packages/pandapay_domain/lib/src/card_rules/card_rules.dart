import '../money/money.dart';

/// Mirrors `database.sql` §0003 `reward_unit` enum. All rates are normalized
/// to an effective ₹-per-₹-spent multiplier by [RewardUnit.perRupee] using
/// the card's point valuation — this is what makes cashback, points/₹100,
/// points/₹150, and miles comparable on Home (ui-spec B1).
enum RewardUnit {
  cashbackPercent,
  pointsPer100,
  pointsPer150,
  pointsPer200,
  milesPer100,
  flatPoints,
  discountPercent;

  /// Converts a nominal [rate] in this unit to an effective fraction of
  /// spend (e.g. 0.05 == 5%), given the card's ₹-per-point valuation.
  /// `flatPoints` cannot be normalized this way — it's a fixed bonus, not a
  /// per-rupee rate, and callers must special-case it.
  double effectiveRatePerRupee(double rate, {double pointValueInr = 0}) {
    switch (this) {
      case RewardUnit.cashbackPercent:
      case RewardUnit.discountPercent:
        return rate / 100;
      case RewardUnit.pointsPer100:
        return (rate * pointValueInr) / 100;
      case RewardUnit.pointsPer150:
        return (rate * pointValueInr) / 150;
      case RewardUnit.pointsPer200:
        return (rate * pointValueInr) / 200;
      case RewardUnit.milesPer100:
        return (rate * pointValueInr) / 100;
      case RewardUnit.flatPoints:
        return 0; // handled separately by callers as a fixed bonus
    }
  }
}

enum CardNetwork { rupay, visa, mastercard, amex, diners }

enum TxnRail { upiQr, swipe, online, contactless, atm, emi, unknown }

enum CapPeriod { statementCycle, calendarMonth, quarter, halfYear, annual, lifetime }

/// Mirrors `cap_measure` (database.sql §0001). What [CapRule.capValue] and
/// the engine's `capRemaining` headroom actually count — critical, because
/// blending a spend cap and a reward-value cap the same way is wrong: ₹1,000
/// of *spend* headroom at 5% is worth ₹50 of reward before hitting the post-
/// cap rate, but ₹1,000 of *reward-value* headroom is worth ₹1,000 of
/// cashback regardless of the rate that earned it.
enum CapMeasure { rewardValue, spendAmount, txnCount }

/// A single reward rule (`reward_rules` table). `categoryId == null` means
/// "all other spends" — the base rate.
class RewardRule {
  final String id;
  final String? categoryId;
  final String? merchantPattern;
  final TxnRail? rail;
  final RewardUnit unit;
  final double rate;
  final Money? minTxn;
  final Money? maxTxn;
  final int priority; // lower wins

  const RewardRule({
    required this.id,
    this.categoryId,
    this.merchantPattern,
    this.rail,
    required this.unit,
    required this.rate,
    this.minTxn,
    this.maxTxn,
    this.priority = 100,
  });
}

/// `cap_rules` — UA-2.2.3 cap blending depends on this exactly.
class CapRule {
  final String id;
  final String? rewardRuleId;
  final String? categoryId;
  final String label;
  final Money capValue; // in the unit [measure] names — spend, reward value, or (as a count) txn_count
  final CapMeasure measure;
  final RewardUnit? postCapUnit;
  final double postCapRate;
  final CapPeriod period;

  const CapRule({
    required this.id,
    this.rewardRuleId,
    this.categoryId,
    required this.label,
    required this.capValue,
    required this.measure,
    this.postCapUnit,
    this.postCapRate = 0,
    required this.period,
  });
}

/// `milestone_rules` — UA-2.2.4.
class MilestoneRule {
  final String id;
  final String label;
  final Money thresholdSpend;
  final Money rewardValue;
  final bool isRepeatable;

  const MilestoneRule({
    required this.id,
    required this.label,
    required this.thresholdSpend,
    required this.rewardValue,
    this.isRepeatable = false,
  });
}

/// `forex_rules` — UA-2.2.5 travel mode.
class ForexRule {
  final double markupPercent;
  final bool gstOnMarkup;

  const ForexRule({required this.markupPercent, this.gstOnMarkup = true});

  /// Effective markup fraction including GST (18% GST on markup is the
  /// common Indian case; product-plan doesn't pin the GST rate so callers
  /// may override).
  double effectiveMarkupFraction({double gstRate = 0.18}) {
    final markup = markupPercent / 100;
    return gstOnMarkup ? markup * (1 + gstRate) : markup;
  }
}

/// `fuel_surcharge_rules` — UA-2.2.7.
class FuelSurchargeRule {
  final double surchargePercent;
  final double waiverPercent;
  final Money? minTxn;
  final Money? maxTxn;

  const FuelSurchargeRule({
    required this.surchargePercent,
    required this.waiverPercent,
    this.minTxn,
    this.maxTxn,
  });
}

/// `fee_waiver_rules` — the catalogue's DEFINITION of a waiver (threshold,
/// period, fee amount). Distinct from [FeeWaiverProgress] in
/// user_cards_repository.dart, which is a specific user's PROGRESS against
/// one of these — C2's Fees tab and C4/C6 zip the two together by
/// [feeWaiverRuleId].
class FeeWaiverRule {
  final String id;
  final Money thresholdSpend;
  final CapPeriod period;
  final Money waivesFee;
  final List<String> excludedCategoryIds;
  final String? notes;

  const FeeWaiverRule({
    required this.id,
    required this.thresholdSpend,
    required this.period,
    required this.waivesFee,
    this.excludedCategoryIds = const [],
    this.notes,
  });
}

/// Mirrors `benefit_kind` (database.sql) — C5's cross-card grouping key.
enum BenefitKind {
  loungeDomestic,
  loungeInternational,
  golf,
  concierge,
  insuranceTravel,
  insurancePurchase,
  extendedWarranty,
  diningProgram,
  movie,
  fuelSurcharge,
  roadsideAssistance,
  other,
}

/// `card_benefits` — static catalogue data, no per-user state (unlike
/// caps/milestones/fee-waivers, which all have a *_states counterpart).
/// Feeds C2's Benefits tab and C5's cross-card cheat sheet.
class CardBenefit {
  final String id;
  final BenefitKind kind;
  final String label;
  final String? description;
  final int? quotaCount;
  final CapPeriod? quotaPeriod;
  final String? networkProgram; // e.g. 'Priority Pass', 'DreamFolks'
  final Money? valueEstimate;

  const CardBenefit({
    required this.id,
    required this.kind,
    required this.label,
    this.description,
    this.quotaCount,
    this.quotaPeriod,
    this.networkProgram,
    this.valueEstimate,
  });
}

/// A minimal `card_products` projection — everything the engine needs to
/// rank, nothing it needs to fetch. Assembled by a repository layer;
/// per UA-2.1.2 the engine never queries.
///
/// Task C-0: [feeWaiverRules], [benefits], [annualFeeInr], [joiningFeeInr],
/// [verifiedAt], [issuerName], [artAssetUrl] and [artPrimaryColor] were
/// already present in every `GET /catalogue` response
/// (`v_card_catalogue_export`) but silently dropped by the old
/// [CardProductJson.fromJson] — the engine never needed them, but C2's
/// Fees/Benefits tabs and C5's cheat sheet do. None of this is used by
/// `domain/engine/` ranking logic; it's catalogue display data riding on
/// the same fetch.
class CardProduct {
  final String id;
  final String name;
  final CardNetwork network;
  final bool isUpiLinkable;
  final double pointValueInr;
  final List<RewardRule> rewardRules;
  final List<CapRule> capRules;
  final List<MilestoneRule> milestoneRules;
  final ForexRule? forexRule;
  final FuelSurchargeRule? fuelRule;
  final List<FeeWaiverRule> feeWaiverRules;
  final List<CardBenefit> benefits;
  final Money? annualFeeInr;
  final Money? joiningFeeInr;
  final DateTime? verifiedAt;
  final String? issuerName;
  final String? artAssetUrl;
  final String? artPrimaryColor;

  /// The card's everything-else earn rate — what it pays on spend that no
  /// category rule covers. Every real card has one, and leaving it off the
  /// model made the engine report "No applicable reward rule" (i.e. ₹0) for
  /// any category the catalogue hadn't enumerated, which is wrong: a 1%
  /// cashback card still earns 1% at a pharmacy.
  ///
  /// Null only when the catalogue genuinely doesn't state a base rate, in
  /// which case the engine still excludes rather than inventing one.
  final RewardUnit? baseRewardUnit;
  final double? baseRewardRate;

  const CardProduct({
    required this.id,
    required this.name,
    required this.network,
    this.isUpiLinkable = false,
    this.pointValueInr = 0,
    this.baseRewardUnit,
    this.baseRewardRate,
    this.rewardRules = const [],
    this.capRules = const [],
    this.milestoneRules = const [],
    this.forexRule,
    this.fuelRule,
    this.feeWaiverRules = const [],
    this.benefits = const [],
    this.annualFeeInr,
    this.joiningFeeInr,
    this.verifiedAt,
    this.issuerName,
    this.artAssetUrl,
    this.artPrimaryColor,
  });
}
