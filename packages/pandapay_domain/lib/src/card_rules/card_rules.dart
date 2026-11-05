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

/// [unknown] exists for catalogue DRAFTS only.
///
/// The CardPipeline import resolves a card's network from extracted text.
/// Roughly a quarter of real extractions either report none ("N/A") or name
/// several at once ("Visa,Mastercard,RuPay" — a genuine multi-network
/// product, not a bad reading). Both land here rather than being guessed at
/// or, as before, causing the whole card and its reward rules to be thrown
/// away over a field the ranking engine never reads.
///
/// A published card can never carry this: migration 0042's
/// `card_published_needs_known_network` CHECK refuses it, and the device
/// catalogue only ever contains published cards. So devices will not see
/// [unknown] in practice — it is handled here because the model is shared
/// with the admin console, which does show drafts.
enum CardNetwork { rupay, visa, mastercard, amex, diners, unknown }

enum TxnRail { upiQr, swipe, online, contactless, atm, emi, unknown }

enum CapPeriod {
  statementCycle,
  calendarMonth,
  quarter,
  halfYear,
  annual,
  lifetime,
}

/// Mirrors `cap_measure` (database.sql §0001). What [CapRule.capValue] and
/// the engine's `capRemaining` headroom actually count — critical, because
/// blending a spend cap and a reward-value cap the same way is wrong: ₹1,000
/// of *spend* headroom at 5% is worth ₹50 of reward before hitting the post-
/// cap rate, but ₹1,000 of *reward-value* headroom is worth ₹1,000 of
/// cashback regardless of the rate that earned it.
enum CapMeasure { rewardValue, spendAmount, txnCount }

/// The newest catalogue rule semantics this package's engine implements
/// (plan C1 `min_engine_version`). Rules and caps that ask for a newer
/// engine are skipped at parse time rather than misread.
const int kRewardEngineVersion = 2;

/// v2 `reward_rules.rule_role` (plan C1 / C3.3).
///
/// Null on [RewardRule.role] means the catalogue row predates v2 (no
/// `rule_role` key on the wire); the v2 engine reads that as [earn].
enum RuleRole {
  /// The card's everything-else rate, written out as a rule.
  base,

  /// An earning rule (accelerated, reduced, or merchant/app specific).
  earn,

  /// Earns nothing; matching spend is excluded.
  exclusion,

  /// A rule the catalogue cannot express faithfully. Shown, never ranked.
  info,
}

/// v2 `cap_rules.cap_kind` (plan C1 / C3.6). Every amount is in the cap's
/// native unit: points for the `*Points` kinds, ₹ for the `*Cashback` kinds
/// and [eligibleSpend], a count for [txnCount].
enum CapKind {
  bonusPoints,
  totalPoints,
  bonusCashback,
  totalCashback,
  eligibleSpend,
  txnCount;

  bool get isBonus => this == bonusPoints || this == bonusCashback;
  bool get isTotal => this == totalPoints || this == totalCashback;
  bool get isPoints => this == bonusPoints || this == totalPoints;
  bool get isCashback => this == bonusCashback || this == totalCashback;
}

/// v2 `cap_rules.scope`: [targets] limits only the rules listed in
/// [CapRule.targets]; [card] limits all earning on the card.
enum CapScope { targets, card }

/// What spend past an eligible-spend or transaction-count cap earns.
enum PostCapBehavior { baseRate, zero, customRate }

/// `milestone_rules.anchor` values, also used by `cap_rules.anchor`.
enum PeriodAnchor { cardAnniversary, calendarYear, fiscalYear, statementCycle }

/// v2 `card_products.accrual_rounding`: how a transaction's spend is turned
/// into points. Null on a v2 card means [floor].
///
/// [floor], [round] (half-up) and [none] (fractional) apply to the number
/// of blocks (C3.5). [pointsHalfUp] and [pointsFloor] (plan C8/D7) round
/// the whole-transaction product `eligible × rate / block` instead — some
/// issuers pay ₹7,500 × 1.5 pts/₹100 as 113 points, not 75 blocks × 1.5.
enum AccrualRounding { floor, round, none, pointsHalfUp, pointsFloor }

/// v2 `card_products.cashback_rounding` (plan C8/D11): how each cashback
/// accrual piece is rounded before caps. Null on the card means [paise].
/// `accrual_rounding` governs points only.
enum CashbackRounding { paise, rupeeFloor, rupeeHalfUp }

/// v2 `card_products.model_status`: how faithfully the catalogue models
/// this card's earning (plan §1 item 6).
enum ModelStatus { verified, partial, basic }

/// v2 `milestone_rules.reward_kind`.
enum MilestoneRewardKind {
  points,
  voucher,
  cashback,
  feeWaiver,
  benefit,
  other,
}

/// v2 `benefit_unlock_rules.kind`.
enum UnlockKind {
  loungeDomestic,
  loungeInternational,
  loungeRailway,
  feeWaiver,
  tier,
  welcome,
  membership,
  other,
}

/// v2 `benefit_unlock_rules.spend_window`.
enum UnlockSpendWindow {
  previousCalendarQuarter,
  currentCalendarQuarter,
  previousCalendarMonth,
  calendarMonth,
  cardYear,
  calendarYear,
  firstDaysAfterIssue,
  rollingDays,
}

/// A single reward rule (`reward_rules` table). `categoryId == null` means
/// "all other spends" — the base rate.
///
/// Every constraint field here is enforced by
/// [RecommendationEngine.ruleApplies]. That was not always true:
/// [merchantPattern], [rail], [minTxn] and [maxTxn] all existed on this
/// class (and as columns in Postgres) while the engine matched on
/// [categoryId] alone, so "10% at Amazon only" paid out at every online
/// merchant and "5%, min ₹500" paid out on a ₹50 purchase. If you add a
/// field here, add it to that predicate too.
class RewardRule {
  final String id;
  final String? categoryId;

  /// Merchant this rule is restricted to, matched case-insensitively as a
  /// substring of the transaction's merchant name ('amazon', 'swiggy').
  /// Null means unrestricted.
  final String? merchantPattern;

  /// Rail this rule is restricted to (a swipe-only accelerated rate that
  /// doesn't pay over UPI, and vice versa). Null means any rail.
  final TxnRail? rail;
  final RewardUnit unit;
  final double rate;

  /// Transaction floor — spends below this don't qualify for the rule at
  /// all, so the card falls through to its base rate.
  final Money? minTxn;

  /// Per-transaction ceiling on the *bonus* rate. Unlike [minTxn] this does
  /// NOT disqualify the rule: the portion up to [maxTxn] earns [rate] and
  /// the excess earns the card's base rate, which is how issuers actually
  /// word these ("5% on the first ₹5,000 per transaction").
  final Money? maxTxn;

  /// Categories this rule explicitly does not pay on. Distinct from
  /// [CardProduct.excludedCategoryIds], which excludes at the card level.
  final List<String> excludedCategoryIds;

  /// Validity window from the catalogue. A rule whose window has closed is
  /// not applied — without this, a promo rate that ended last quarter kept
  /// being recommended indefinitely.
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;

  final int priority; // lower wins

  // ---- v2 fields (plan C1). All optional; defaults mean "v1 row". ----

  /// Null when the wire row carried no `rule_role` (a v1 row).
  final RuleRole? role;

  /// Any-of merchant slugs (C5 directory). Matches the resolved merchant or
  /// any of its ancestors. Empty means unrestricted by merchant slug.
  final List<String> merchantSlugs;

  /// Any-of payment platform slugs. Empty means unrestricted.
  final List<String> platformSlugs;

  /// 4-digit MCC strings the spend must be in / must not be in.
  final List<String> mccInclude;
  final List<String> mccExclude;

  /// Plan C8/D16a exceptions: the rule does not apply when the resolved
  /// merchant (or an ancestor) / the context platform is KNOWN and listed
  /// here. An unknown merchant or platform never proves an exception.
  final List<String> exceptMerchantSlugs;
  final List<String> exceptPlatformSlugs;

  /// Overrides the unit's block size: [rate] points per [blockInr] rupees.
  final int? blockInr;

  /// 2 means hidden from the v1 feed (plan C1).
  final int minEngineVersion;

  /// Plan C8/D18a: null = no maximum. 1 marks a v1-only row (e.g. a broad
  /// v1 projection of a precise v2 rule): the v2 engine ignores it
  /// entirely. Non-null marks the card v2-shaped.
  final int? maxEngineVersion;

  /// CardPipeline rule id. Not part of identity.
  final String? sourceLocalId;

  /// Plain-language rule text for the UI; also the exclusion reason.
  final String? displayNote;

  const RewardRule({
    required this.id,
    this.categoryId,
    this.merchantPattern,
    this.rail,
    required this.unit,
    required this.rate,
    this.minTxn,
    this.maxTxn,
    this.excludedCategoryIds = const [],
    this.effectiveFrom,
    this.effectiveTo,
    this.priority = 100,
    this.role,
    this.merchantSlugs = const [],
    this.platformSlugs = const [],
    this.mccInclude = const [],
    this.mccExclude = const [],
    this.exceptMerchantSlugs = const [],
    this.exceptPlatformSlugs = const [],
    this.blockInr,
    this.minEngineVersion = 1,
    this.maxEngineVersion,
    this.sourceLocalId,
    this.displayNote,
  });

  /// D18a: whether the v2 engine must ignore this row — exactly
  /// `max_engine_version = 1`, as in the JS engine.
  bool get isV1Only => maxEngineVersion == 1;

  /// The role the v2 engine uses: a v1 row on a v2 card is an earning rule.
  RuleRole get effectiveRole => role ?? RuleRole.earn;

  /// Plan C8/D10/D16c: whether this rule makes its card v2-shaped — a role
  /// other than the DB default `earn`, any non-empty slug/MCC/exception
  /// list, an exclusion with a `max_txn_inr` threshold, a `block_inr`, or
  /// `min_engine_version` 2. `rule_role = 'earn'` alone does not.
  bool get marksV2 =>
      (role != null && role != RuleRole.earn) ||
      merchantSlugs.isNotEmpty ||
      platformSlugs.isNotEmpty ||
      mccInclude.isNotEmpty ||
      mccExclude.isNotEmpty ||
      exceptMerchantSlugs.isNotEmpty ||
      exceptPlatformSlugs.isNotEmpty ||
      (role == RuleRole.exclusion && maxTxn != null) ||
      blockInr != null ||
      minEngineVersion >= 2 ||
      maxEngineVersion != null;

  /// Whether any v2-only field differs from its v1 default.
  bool get hasV2Fields =>
      role != null ||
      merchantSlugs.isNotEmpty ||
      platformSlugs.isNotEmpty ||
      mccInclude.isNotEmpty ||
      mccExclude.isNotEmpty ||
      exceptMerchantSlugs.isNotEmpty ||
      exceptPlatformSlugs.isNotEmpty ||
      blockInr != null ||
      minEngineVersion != 1 ||
      maxEngineVersion != null ||
      sourceLocalId != null ||
      displayNote != null;
}

/// `cap_rules` — UA-2.2.3 cap blending depends on this exactly.
class CapRule {
  final String id;
  final String? rewardRuleId;
  final String? categoryId;
  final String label;
  final Money
  capValue; // in the unit [measure] names — spend, reward value, or (as a count) txn_count
  final CapMeasure measure;

  /// What you earn once the cap is spent.
  ///
  /// Both are NULLABLE and null means "the catalogue doesn't say", which is
  /// the overwhelmingly common case — nothing in the import pipeline
  /// populates them. Null is NOT the same as an explicit zero, and the
  /// difference matters a lot: `postCapRate = 0` means the card genuinely
  /// pays nothing past the cap (rare, but real), while null means the card
  /// reverts to its ordinary base rate (the normal Indian-market
  /// behaviour — "5% on groceries up to ₹3,000/month, 1% thereafter", where
  /// the 1% is just the card's base rate and the catalogue never restates
  /// it). [RecommendationEngine] resolves null against
  /// [CardProduct.baseRewardRate]; treating it as 0 used to make a
  /// cap-exhausted card report ₹0 and sort below cards that were worse than
  /// its own base rate.
  final RewardUnit? postCapUnit;
  final double? postCapRate;

  final CapPeriod period;

  // ---- v2 fields (plan C1). All optional; defaults mean "v1 row". ----

  /// Null = legacy row; the v2 engine converts it from [measure] (C3.6).
  final CapKind? capKind;

  /// Native units: points, ₹ cashback, ₹ spend, or a count (see [CapKind]).
  final double? capAmount;

  final CapScope scope;

  /// Reward rule ids this cap limits (`cap_rule_targets`).
  final List<String> targets;

  /// A cap inside a cap: the parent also applies whenever this one does.
  final String? parentCapId;

  /// Used by [CapKind.eligibleSpend] / [CapKind.txnCount] caps.
  final PostCapBehavior? postCapBehavior;

  /// For card-year caps.
  final PeriodAnchor? anchor;

  final int minEngineVersion;

  /// CardPipeline cap id. Not part of identity.
  final String? sourceLocalId;

  const CapRule({
    required this.id,
    this.rewardRuleId,
    this.categoryId,
    required this.label,
    required this.capValue,
    required this.measure,
    this.postCapUnit,
    this.postCapRate,
    required this.period,
    this.capKind,
    this.capAmount,
    this.scope = CapScope.targets,
    this.targets = const [],
    this.parentCapId,
    this.postCapBehavior,
    this.anchor,
    this.minEngineVersion = 1,
    this.sourceLocalId,
  });

  /// Whether any v2-only field differs from its v1 default.
  bool get hasV2Fields =>
      capKind != null ||
      capAmount != null ||
      scope != CapScope.targets ||
      targets.isNotEmpty ||
      parentCapId != null ||
      postCapBehavior != null ||
      anchor != null ||
      minEngineVersion != 1 ||
      sourceLocalId != null;
}

/// `milestone_rules` — UA-2.2.4.
class MilestoneRule {
  final String id;
  final String label;
  final Money thresholdSpend;
  final Money rewardValue;
  final bool isRepeatable;

  /// The milestone's window and the date it counts from (plan C3.7). Both
  /// are on the v1 wire already; null when absent or not recognised.
  final CapPeriod? period;
  final PeriodAnchor? anchor;

  // ---- v2 fields (plan C1). ----
  final double? rewardPoints;
  final MilestoneRewardKind? rewardKind;
  final List<String> excludedCategoryIds;

  /// e.g. a welcome milestone "₹15,000 within 90 days".
  final int? windowDays;

  /// Not part of identity.
  final String? sourceLocalId;

  const MilestoneRule({
    required this.id,
    required this.label,
    required this.thresholdSpend,
    required this.rewardValue,
    this.isRepeatable = false,
    this.period,
    this.anchor,
    this.rewardPoints,
    this.rewardKind,
    this.excludedCategoryIds = const [],
    this.windowDays,
    this.sourceLocalId,
  });
}

/// v2 `benefit_unlock_rules`: a benefit (lounge visits, fee waiver, tier)
/// that unlocks after a spend threshold in a window. Phase 1 carries the
/// data only; progress is Phase 2.
class BenefitUnlockRule {
  final String id;
  final String? cardBenefitId;
  final UnlockKind kind;
  final String label;
  final Money spendThreshold;
  final UnlockSpendWindow spendWindow;
  final int? windowDays;
  final int? unlocksQuota;
  final CapPeriod? unlocksPeriod;
  final String? tierLabel;
  final List<String> excludedCategoryIds;
  final String? notes;
  final String? sourceLocalId;

  const BenefitUnlockRule({
    required this.id,
    this.cardBenefitId,
    required this.kind,
    required this.label,
    required this.spendThreshold,
    required this.spendWindow,
    this.windowDays,
    this.unlocksQuota,
    this.unlocksPeriod,
    this.tierLabel,
    this.excludedCategoryIds = const [],
    this.notes,
    this.sourceLocalId,
  });
}

/// `redemption_options`: how points turn into value.
class RedemptionOption {
  final String? id;
  final String programName;

  /// Free text on the wire ('statement_credit', 'airmiles_transfer', ...).
  final String method;
  final double valuePerPointInr;
  final int? minPoints;
  final String? notes;

  const RedemptionOption({
    this.id,
    required this.programName,
    required this.method,
    required this.valuePerPointInr,
    this.minPoints,
    this.notes,
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

  /// Catalogue instrument type (`credit`, `debit`, `prepaid`, ...). Kept on
  /// the shared projection so on-device SMS discovery cannot match a debit
  /// alert to a same-name credit product.
  final String? cardType;
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

  /// Categories this card earns nothing on, at any rate — rent, wallet
  /// loads, fuel, insurance premiums, government payments, EMI conversions
  /// and gift cards are all commonly excluded by Indian issuers, and are
  /// excluded from the base rate too, not just from accelerated rules.
  ///
  /// The engine returns these as a proper exclusion with a reason rather
  /// than quietly paying a rate the card doesn't actually honour. Without
  /// it the app promised rewards on spend that earns nothing, which is the
  /// single most trust-damaging thing a rewards optimizer can do.
  final List<String> excludedCategoryIds;

  /// Whether the catalogue holds an issuer application link for this card
  /// (plan Phase 2.3). A boolean, never the URL: the destination is produced
  /// only by `pandapay.record_partner_click()` at tap time, which is what
  /// guarantees the click is attributed rather than the app opening an
  /// untracked link it already had.
  ///
  /// Display-only, like the fee and art fields above it — the ranking engine
  /// does not read this and must never read it. A recommender that weighted
  /// toward the cards it can earn commission on would be worthless to the
  /// person relying on it. See migration 0030's header.
  final bool hasApplyUrl;

  // ---- v2 fields (plan C1/C2). All optional; defaults mean "v1 card". ----

  /// Default points block (100/125/150/200/500). Informational: the engine
  /// uses the rule's `block_inr` or the unit's own block (C3.5).
  final int? accrualBlockInr;

  /// Per-transaction rounding of points blocks. Non-null marks the card as
  /// v2-shaped (C3.2).
  final AccrualRounding? accrualRounding;

  /// Per-piece cashback rounding (D11). Non-null marks the card v2-shaped.
  final CashbackRounding? cashbackRounding;
  final int? pointsExpiryMonths;

  /// Null when the feed doesn't say (the v1 feed).
  final ModelStatus? modelStatus;
  final Map<String, dynamic> modelCoverage;
  final List<BenefitUnlockRule> unlockRules;
  final List<RedemptionOption> redemptionOptions;

  /// What the tolerant v2 parser skipped or defaulted, one line each, for
  /// logging. Never serialized.
  final List<String> parseWarnings;

  /// Cap id → why the parser dropped it (an unsupported v2 value). The v2
  /// engine reports each as `cap_skipped:<id>:<reason>` (plan C8/D12d), so
  /// a dropped cap is never silent. Never serialized.
  final Map<String, String> skippedCaps;

  /// Reward rule id → why the parser dropped it. The v2 engine reports each
  /// as `rule_skipped:<id>:<reason>` (plan C8/D15d). Never serialized.
  final Map<String, String> skippedRules;

  /// Whether a dropped rule was an exclusion (raw `rule_role = 'exclusion'`).
  /// The v2 engine then adds the assumption `exclusion_unparsed`, because
  /// the estimate may pay on spend the card actually excludes (D15d).
  final bool skippedExclusionRule;

  /// Set by the JSON parser when the wire card carried a v2 marker (C3.2)
  /// on a row that was then skipped, so the card still takes the v2 path.
  final bool wireV2Shaped;

  const CardProduct({
    required this.id,
    required this.name,
    required this.network,
    this.isUpiLinkable = false,
    this.pointValueInr = 0,
    this.baseRewardUnit,
    this.baseRewardRate,
    this.excludedCategoryIds = const [],
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
    this.cardType,
    this.artAssetUrl,
    this.artPrimaryColor,
    this.hasApplyUrl = false,
    this.accrualBlockInr,
    this.accrualRounding,
    this.cashbackRounding,
    this.pointsExpiryMonths,
    this.modelStatus,
    this.modelCoverage = const {},
    this.unlockRules = const [],
    this.redemptionOptions = const [],
    this.parseWarnings = const [],
    this.skippedCaps = const {},
    this.skippedRules = const {},
    this.skippedExclusionRule = false,
    this.wireV2Shaped = false,
  });

  /// C3.2 as amended by plan C8/D10/D11: v2-shaped iff the card has
  /// `accrual_rounding` or `cashback_rounding`, any cap has a `cap_kind`, or any rule carries a
  /// non-default v2 value ([RewardRule.marksV2]). It must not key on
  /// DB-defaulted columns: after the v2 migration every row has
  /// `rule_role = 'earn'` and empty arrays, and such a card must keep
  /// today's v1 answers. v1-shaped cards take the engine's original path.
  bool get isV2Shaped =>
      wireV2Shaped ||
      accrualRounding != null ||
      cashbackRounding != null ||
      rewardRules.any((r) => r.marksV2) ||
      capRules.any((c) => c.capKind != null);

  /// The card's everything-else earn rate as a fraction of spend, or 0 when
  /// the catalogue doesn't state one.
  ///
  /// `flatPoints` deliberately normalizes to 0 (see [RewardUnit]) — it's a
  /// fixed bonus, not a per-rupee rate — so a card whose base reward is a
  /// flat bonus reads as 0 here rather than advertising a rate it doesn't
  /// have. Used both by the engine's no-matching-rule fallback and by
  /// post-cap resolution, which must agree on what "the base rate" means.
  double get baseRatePerRupee {
    final unit = baseRewardUnit;
    final rate = baseRewardRate;
    if (unit == null || rate == null) return 0;
    return unit.effectiveRatePerRupee(rate, pointValueInr: pointValueInr);
  }

  /// Whether [categoryId] earns nothing on this card. Null category (an
  /// uncategorized import) is never treated as excluded — we don't know
  /// what it is, and guessing "excluded" would under-report real rewards.
  bool excludesCategory(String? categoryId) =>
      categoryId != null && excludedCategoryIds.contains(categoryId);
}

String _catalogueTextKey(String? value) => value?.trim().toLowerCase() ?? '';

String _catalogueListKey(Iterable<String> values) {
  final normalized = values.map(_catalogueTextKey).toList()..sort();
  return normalized.join(',');
}

String _catalogueMoneyKey(Money value) => value.paise.toString();

String _catalogueDateKey(DateTime? value) => value?.toIso8601String() ?? '';

/// Plan C8/D1: the v2 identity fields, appended to an identity key only
/// when at least one of them is set, so two v2 rows that differ only in a
/// v2 field (merchant slugs, platform, cap kind/amount, ...) never collapse
/// into one. `source_local_id` is deliberately not identity.
///
/// A row with every v2 field unset (an old cache blob, a hand-built rule)
/// keeps exactly its pre-v2 key. Rows from the v1 feed after the v2
/// migration carry `rule_role = 'earn'` (a DB default), so their keys DO
/// gain a v2 part — the same part for every such row, so which rows de-dup
/// together is unchanged. Keys are only compared in memory; the app never
/// persists them. (v2-shaped cards are not de-duplicated at all — D15a.)
String _v2IdentitySuffix(List<String> parts) =>
    parts.every((p) => p.isEmpty) ? '' : '|v2|${parts.join('|')}';

/// Stable semantic identity for a cap definition.
///
/// The database id is deliberately excluded: catalogue imports can recreate
/// the same rule with a new id, and showing that as a second cap is misleading.
/// [rewardRuleId] remains part of the key because two different reward rules
/// can intentionally have the same visible cap amount.
String capRuleIdentityKey(CapRule rule) =>
    [
      rule.rewardRuleId ?? '',
      rule.categoryId ?? '',
      _catalogueTextKey(rule.label),
      rule.measure.name,
      rule.period.name,
      _catalogueMoneyKey(rule.capValue),
      rule.postCapUnit?.name ?? '',
      rule.postCapRate?.toString() ?? '',
    ].join('|') +
    _v2IdentitySuffix([
      rule.capKind?.name ?? '',
      rule.capAmount?.toString() ?? '',
      rule.scope == CapScope.targets ? '' : rule.scope.name,
      // Targets are ids, compared verbatim (sorted, not case-folded).
      (rule.targets.toList()..sort()).join(','),
      rule.parentCapId ?? '',
      rule.postCapBehavior?.name ?? '',
      rule.anchor?.name ?? '',
      rule.minEngineVersion == 1 ? '' : rule.minEngineVersion.toString(),
    ]);

List<CapRule> uniqueCapRules(Iterable<CapRule> rules) {
  final seen = <String>{};
  return [
    for (final rule in rules)
      if (seen.add(capRuleIdentityKey(rule))) rule,
  ];
}

String rewardRuleIdentityKey(RewardRule rule) =>
    [
      rule.categoryId ?? '',
      _catalogueTextKey(rule.merchantPattern),
      rule.rail?.name ?? '',
      rule.unit.name,
      rule.rate.toString(),
      rule.minTxn == null ? '' : _catalogueMoneyKey(rule.minTxn!),
      rule.maxTxn == null ? '' : _catalogueMoneyKey(rule.maxTxn!),
      _catalogueListKey(rule.excludedCategoryIds),
      _catalogueDateKey(rule.effectiveFrom),
      _catalogueDateKey(rule.effectiveTo),
      rule.priority.toString(),
    ].join('|') +
    _v2IdentitySuffix([
      rule.role?.name ?? '',
      _catalogueListKey(rule.merchantSlugs),
      _catalogueListKey(rule.platformSlugs),
      _catalogueListKey(rule.mccInclude),
      _catalogueListKey(rule.mccExclude),
      rule.blockInr?.toString() ?? '',
      rule.minEngineVersion == 1 ? '' : rule.minEngineVersion.toString(),
      // D16: appended only when set, so pre-D16 v2 keys are unchanged.
      if (rule.exceptMerchantSlugs.isNotEmpty ||
          rule.exceptPlatformSlugs.isNotEmpty) ...[
        _catalogueListKey(rule.exceptMerchantSlugs),
        _catalogueListKey(rule.exceptPlatformSlugs),
      ],
      // D18a: likewise appended only when set.
      if (rule.maxEngineVersion != null) 'max${rule.maxEngineVersion}',
    ]);

List<RewardRule> uniqueRewardRules(Iterable<RewardRule> rules) {
  final seen = <String>{};
  return [
    for (final rule in rules)
      if (seen.add(rewardRuleIdentityKey(rule))) rule,
  ];
}

String milestoneRuleIdentityKey(MilestoneRule rule) =>
    [
      _catalogueTextKey(rule.label),
      _catalogueMoneyKey(rule.thresholdSpend),
      _catalogueMoneyKey(rule.rewardValue),
      rule.isRepeatable.toString(),
    ].join('|') +
    _v2IdentitySuffix([
      rule.rewardPoints?.toString() ?? '',
      rule.rewardKind?.name ?? '',
      rule.windowDays?.toString() ?? '',
      _catalogueListKey(rule.excludedCategoryIds),
    ]);

List<MilestoneRule> uniqueMilestoneRules(Iterable<MilestoneRule> rules) {
  final seen = <String>{};
  return [
    for (final rule in rules)
      if (seen.add(milestoneRuleIdentityKey(rule))) rule,
  ];
}

String cardBenefitIdentityKey(CardBenefit benefit) => [
  benefit.kind.name,
  _catalogueTextKey(benefit.label),
  _catalogueTextKey(benefit.description),
  benefit.quotaCount?.toString() ?? '',
  benefit.quotaPeriod?.name ?? '',
  _catalogueTextKey(benefit.networkProgram),
  benefit.valueEstimate == null
      ? ''
      : _catalogueMoneyKey(benefit.valueEstimate!),
].join('|');

List<CardBenefit> uniqueCardBenefits(Iterable<CardBenefit> benefits) {
  final seen = <String>{};
  return [
    for (final benefit in benefits)
      if (seen.add(cardBenefitIdentityKey(benefit))) benefit,
  ];
}

String feeWaiverRuleIdentityKey(FeeWaiverRule rule) => [
  _catalogueMoneyKey(rule.thresholdSpend),
  rule.period.name,
  _catalogueMoneyKey(rule.waivesFee),
  _catalogueListKey(rule.excludedCategoryIds),
  _catalogueTextKey(rule.notes),
].join('|');

List<FeeWaiverRule> uniqueFeeWaiverRules(Iterable<FeeWaiverRule> rules) {
  final seen = <String>{};
  return [
    for (final rule in rules)
      if (seen.add(feeWaiverRuleIdentityKey(rule))) rule,
  ];
}

/// Human-readable cap title used by every cap surface.
///
/// Raw catalogue labels are identifiers (`bonus_reward_points cap`), not
/// user-facing copy. Category-aware titles make separate caps recognizable
/// and avoid making every row look like a duplicate.
String capRuleDisplayLabel(CapRule rule, {String? categoryName}) {
  final category = categoryName?.trim();
  final hasCategory = category != null && category.isNotEmpty;
  final normalized = _catalogueTextKey(
    rule.label,
  ).replaceAll('_', ' ').replaceAll(RegExp(r'\s+cap$'), '').trim();

  // Catalogue labels may already be deliberately specific (for example,
  // "Dining cashback cap" or "5% bills cap"). Preserve that copy across
  // every surface instead of replacing it with a generic category-derived
  // label. Category context is only a fallback for generic/blank labels.
  final genericLabels = {
    '',
    'bonus reward points',
    'bonus points',
    'total reward points',
    'total rewards',
    'eligible spend amount',
    'eligible spend',
    'spend amount',
    'spend',
    'txn count',
    'transaction count',
  };
  if (!genericLabels.contains(normalized)) {
    final raw = rule.label.trim();
    if (raw.isNotEmpty) {
      return RegExp(r'cap\s*$', caseSensitive: false).hasMatch(raw)
          ? raw
          : '$raw cap';
    }
  }

  if (hasCategory) {
    final noun = switch (rule.measure) {
      CapMeasure.rewardValue => 'rewards',
      CapMeasure.spendAmount => 'spend',
      CapMeasure.txnCount => 'transactions',
    };
    return '$category $noun cap';
  }

  final title = switch (normalized) {
    'bonus reward points' || 'bonus points' => 'Bonus reward points cap',
    'total reward points' || 'total rewards' => 'Total rewards cap',
    'eligible spend amount' || 'eligible spend' => 'Eligible spend cap',
    'spend amount' || 'spend' => 'Spend cap',
    'txn count' || 'transaction count' => 'Transaction cap',
    _ => normalized.isEmpty ? 'Reward cap' : '$normalized cap',
  };
  return title[0].toUpperCase() + title.substring(1);
}
