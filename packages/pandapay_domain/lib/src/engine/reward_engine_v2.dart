import '../card_rules/card_rules.dart';
import '../card_rules/merchant_directory.dart';
import '../money/money.dart';
import 'engine.dart';

/// Reward engine v2 — plan C3. Pure, no IO, identical in semantics to
/// api/src/reward_math_v2.js; db/fixtures/reward_v2_scenarios/ is the
/// shared contract both suites run.
///
/// Reached through [computeRewardV2] / [RecommendationEngine.evaluateRewardV2] (one card, one
/// transaction, native units) and, for v2-shaped cards, through
/// [RecommendationEngine.rank].

/// What a reward accrues as.
enum RewardCurrency { points, cashback }

RewardCurrency rewardCurrencyOf(RewardUnit unit) => switch (unit) {
  RewardUnit.cashbackPercent ||
  RewardUnit.discountPercent => RewardCurrency.cashback,
  _ => RewardCurrency.points,
};

/// One cap that applied to a transaction, in its native unit (points, ₹,
/// or a count — see [kind]).
class RewardCapUsage {
  final CapRule cap;

  /// The kind the engine used: [CapRule.capKind], or the C3.6 conversion of
  /// a legacy row.
  final CapKind kind;

  /// True when [kind]/[amount] were converted from a legacy row.
  final bool legacy;
  final double amount;
  final double consumedBefore;
  final double remainingBefore;

  /// What this transaction consumes (rounded to 2 dp; 0 when none).
  final double delta;

  /// Whether this cap reduced what the transaction earned.
  final bool limiting;

  const RewardCapUsage({
    required this.cap,
    required this.kind,
    required this.legacy,
    required this.amount,
    required this.consumedBefore,
    required this.remainingBefore,
    required this.delta,
    required this.limiting,
  });

  String get capId => cap.id;
}

/// The C3.6.8 result for one card and one transaction.
class RewardEvaluation {
  final bool excluded;

  /// The chosen rule, the matching exclusion rule, or null (implicit base
  /// rule, or a card-level category exclusion).
  final String? ruleId;
  final RewardRule? rule;

  /// The currency of the chosen rule (or of the card's base rate). Null
  /// when the card has no applicable rule and no base rate.
  final RewardCurrency? currency;

  /// Points earned. Null when the card neither earns nor quotes points.
  final double? points;

  /// ₹ cashback earned. Null when the card neither earns nor quotes cashback.
  final double? cashbackInr;

  /// ₹ value of everything earned, rounded half-up to 2 dp.
  final double valueInr;

  /// Cap id → native-unit consumption. Zero deltas are omitted.
  final Map<String, double> capDeltas;

  /// Every cap that applied, in catalogue order.
  final List<RewardCapUsage> caps;

  /// Machine-readable reasons, aligned with the JS engine: the rule's
  /// display note, then codes such as `above_max_txn`, `spend_cap_reached`,
  /// `txn_count_cap_reached`, `bonus_cap_reached`, `total_cap_reached` and
  /// `cap_skipped:<cap_id>:<reason>` (D12d). An exclusion carries its
  /// display note, `excluded_by_rule` or `excluded_category`.
  final List<String> reasons;

  /// The same story in plain language, for the "Why this card?" UI.
  final List<String> reasonLines;

  /// Machine-readable notes on what the engine had to assume, e.g.
  /// `merchant_resolved_by_alias`.
  final List<String> assumptions;

  /// How the merchant was identified, if it was.
  final MerchantMatch? merchant;

  /// The chosen rule's nominal earn rate as a fraction of spend.
  final double ratePerRupee;

  /// Spend split: what earned the rule's rate, what ran past a cap, and
  /// what was above the rule's per-transaction maximum.
  final Money ruleSpend;
  final Money overflowSpend;
  final Money overMaxSpend;

  /// 2 for the plan C3 path. 1 when [RecommendationEngine.evaluateRewardV2]
  /// handed a v1-shaped card (C3.2/D10) to the original engine: then only
  /// [valueInr], [ruleId] and [excluded] are meaningful, [capDeltas] is
  /// empty, and [points]/[cashbackInr] are derived from the value.
  final int engineVersion;

  const RewardEvaluation({
    required this.excluded,
    this.ruleId,
    this.rule,
    this.currency,
    this.points,
    this.cashbackInr,
    required this.valueInr,
    this.capDeltas = const {},
    this.caps = const [],
    this.reasons = const [],
    this.reasonLines = const [],
    this.assumptions = const [],
    this.merchant,
    this.ratePerRupee = 0,
    this.ruleSpend = const Money.zero(),
    this.overflowSpend = const Money.zero(),
    this.overMaxSpend = const Money.zero(),
    this.engineVersion = 2,
  });

  Money get value => Money.fromRupees(valueInr);

  /// Where the transaction stands against its caps, for the breakdown UI.
  CapStatus get capStatus {
    if (caps.isEmpty) return CapStatus.none;
    final limiting = caps.where((c) => c.limiting).toList();
    if (limiting.isEmpty) return CapStatus.withinCap;
    final exhausted = limiting.any(
      (c) => c.kind == CapKind.txnCount
          ? c.remainingBefore < 1
          : c.remainingBefore <= 0,
    );
    return exhausted ? CapStatus.reached : CapStatus.partiallyConsumed;
  }
}

// ---------------------------------------------------------------------------
// Exact arithmetic helpers.
// ---------------------------------------------------------------------------

/// A non-negative decimal as numerator / 10^k, read from the shortest
/// round-trip text of the double — i.e. the decimal the catalogue wrote
/// (`1.5`, `0.25`, `3.3`). Lets block/points maths be done in integers so
/// ₹7,500 × 1.5 / 100 is exactly 112.5, never 112.4999….
class _Decimal {
  final BigInt numerator;
  final BigInt denominator;
  const _Decimal(this.numerator, this.denominator);

  factory _Decimal.of(double value) {
    if (value.isNaN || value.isInfinite) {
      return _Decimal(BigInt.zero, BigInt.one);
    }
    var text = value.abs().toString();
    var exponent = 0;
    final e = text.indexOf(RegExp('[eE]'));
    if (e >= 0) {
      exponent = int.parse(text.substring(e + 1));
      text = text.substring(0, e);
    }
    final dot = text.indexOf('.');
    var digits = text;
    var scale = 0;
    if (dot >= 0) {
      digits = text.substring(0, dot) + text.substring(dot + 1);
      scale = text.length - dot - 1;
    }
    scale -= exponent;
    var n = BigInt.parse(digits);
    var d = BigInt.one;
    if (scale >= 0) {
      d = BigInt.from(10).pow(scale);
    } else {
      n *= BigInt.from(10).pow(-scale);
    }
    if (value < 0) n = -n;
    return _Decimal(n, d);
  }
}

double _ratio(BigInt n, BigInt d) => n / d;

/// floor(n / d) for non-negative n, positive d.
BigInt _floorDiv(BigInt n, BigInt d) => n ~/ d;

/// round_half_up(n / d) for non-negative n, positive d.
BigInt _halfUpDiv(BigInt n, BigInt d) =>
    (n * BigInt.two + d) ~/ (d * BigInt.two);

/// Half-up to 2 dp for figures that are already near-exact doubles (cap
/// arithmetic, points × ₹/point). The epsilon absorbs binary noise like
/// 1.005 → 1.00499999.
double _round2(double x) {
  if (x < 0) return -_round2(-x);
  return (x * 100 + 0.5 + 1e-6).floorToDouble() / 100;
}

int? _unitBlock(RewardUnit unit) => switch (unit) {
  RewardUnit.pointsPer100 => 100,
  RewardUnit.pointsPer150 => 150,
  RewardUnit.pointsPer200 => 200,
  RewardUnit.milesPer100 => 100,
  _ => null,
};

/// C3.5 accrual of [rate] in [unit] on [spendPaise], in the unit's currency:
/// points under [rounding] (accrual_rounding, points only), or ₹ cashback
/// under [cashbackRounding] (D11: paise, or whole rupees floored/half-up).
double _accrue(
  RewardUnit unit,
  double rate,
  int spendPaise,
  AccrualRounding rounding,
  CashbackRounding cashbackRounding, {
  int? blockInr,
}) {
  if (spendPaise <= 0 || rate <= 0) return 0;
  final r = _Decimal.of(rate);
  final paise = BigInt.from(spendPaise);
  switch (unit) {
    case RewardUnit.cashbackPercent:
    case RewardUnit.discountPercent:
      // Exact cashback in paise is paise × rate / 100 = n / d.
      final n = paise * r.numerator;
      final d = BigInt.from(100) * r.denominator;
      final rupeeDen = d * BigInt.from(100);
      return switch (cashbackRounding) {
        CashbackRounding.paise => _halfUpDiv(n, d).toInt() / 100,
        CashbackRounding.rupeeFloor => _floorDiv(n, rupeeDen).toDouble(),
        CashbackRounding.rupeeHalfUp => _halfUpDiv(n, rupeeDen).toDouble(),
      };
    case RewardUnit.flatPoints:
      return rate;
    case RewardUnit.pointsPer100:
    case RewardUnit.pointsPer150:
    case RewardUnit.pointsPer200:
    case RewardUnit.milesPer100:
      final block = (blockInr != null && blockInr > 0)
          ? blockInr
          : _unitBlock(unit)!;
      final blockPaise = BigInt.from(block * 100);
      switch (rounding) {
        case AccrualRounding.floor:
          final blocks = _floorDiv(paise, blockPaise);
          return _ratio(blocks * r.numerator, r.denominator);
        case AccrualRounding.round:
          final blocks = _halfUpDiv(paise, blockPaise);
          return _ratio(blocks * r.numerator, r.denominator);
        case AccrualRounding.none:
          return _ratio(paise * r.numerator, blockPaise * r.denominator);
        case AccrualRounding.pointsFloor:
          return _floorDiv(
            paise * r.numerator,
            blockPaise * r.denominator,
          ).toDouble();
        case AccrualRounding.pointsHalfUp:
          return _halfUpDiv(
            paise * r.numerator,
            blockPaise * r.denominator,
          ).toDouble();
      }
  }
}

/// The rule's nominal earn rate as a fraction of spend — the C3.4 tie-break
/// and the breakdown's headline rate. A flat bonus has no per-rupee rate
/// and reads as 0, as in the JS engine (and [RewardUnit]).
double _ratePerRupee(
  RewardUnit unit,
  double rate,
  double pointValueInr, {
  int? blockInr,
}) {
  switch (unit) {
    case RewardUnit.cashbackPercent:
    case RewardUnit.discountPercent:
      return rate / 100;
    case RewardUnit.flatPoints:
      return 0;
    case RewardUnit.pointsPer100:
    case RewardUnit.pointsPer150:
    case RewardUnit.pointsPer200:
    case RewardUnit.milesPer100:
      final block = (blockInr != null && blockInr > 0)
          ? blockInr
          : _unitBlock(unit)!;
      return rate * pointValueInr / block;
  }
}

// ---------------------------------------------------------------------------
// C3.3 applicability.
// ---------------------------------------------------------------------------

String? _cleanMcc(String? mcc) {
  final t = mcc?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

String _normalizePattern(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// C3.3: every restriction on [rule] holds for [context]. [merchantLineage]
/// is the resolved merchant slug plus its ancestors (empty when unknown).
bool rewardRuleAppliesV2(
  RewardRule rule,
  RecommendationContext context, {
  Set<String> merchantLineage = const {},
}) {
  // 1. Effective dates, as v1: only checked when the caller gave a date;
  // effective_to is inclusive of that whole day.
  final now = context.now;
  if (now != null) {
    final from = rule.effectiveFrom;
    if (from != null && now.isBefore(from)) return false;
    final to = rule.effectiveTo;
    if (to != null && !now.isBefore(DateTime(to.year, to.month, to.day + 1))) {
      return false;
    }
  }

  // 2. Info rules never apply. (Earning vs exclusion is the caller's split.)
  if (rule.effectiveRole == RuleRole.info) return false;

  // 3. Category.
  if (rule.categoryId != null && rule.categoryId != context.categoryId) {
    return false;
  }

  // 4. Per-rule excluded categories.
  if (context.categoryId != null &&
      rule.excludedCategoryIds.contains(context.categoryId)) {
    return false;
  }

  // 5. Merchant slugs: the resolved merchant or any ancestor. Unknown ⇒ no.
  if (rule.merchantSlugs.isNotEmpty) {
    if (!rule.merchantSlugs.any(merchantLineage.contains)) return false;
  } else {
    // Not in C3.3: a v2 row that kept only a v1 merchant_pattern (no slugs)
    // is still restricted by it, v1-style, rather than paying everywhere
    // (H2 "never widen"). The loader always pairs a pattern with a slug.
    final pattern = rule.merchantPattern;
    if (pattern != null && pattern.trim().isNotEmpty) {
      final merchant = context.merchantName;
      if (merchant == null) return false;
      if (!_normalizePattern(merchant).contains(_normalizePattern(pattern))) {
        return false;
      }
    }
  }

  // 6. Platform: callers supply it; the engine never infers it. Unknown ⇒ no.
  final platform = context.platform;
  if (rule.platformSlugs.isNotEmpty) {
    if (platform == null || !rule.platformSlugs.contains(platform)) {
      return false;
    }
  }

  // D16a exceptions: only a KNOWN merchant (or ancestor) / platform that is
  // listed takes the rule off; an unknown one never proves an exception.
  if (rule.exceptMerchantSlugs.any(merchantLineage.contains)) return false;
  if (platform != null && rule.exceptPlatformSlugs.contains(platform)) {
    return false;
  }

  // 7. MCC include. An unknown MCC is stood in for by a matching category
  // (step 3 already passed) when the rule has one; otherwise no.
  final mcc = _cleanMcc(context.mcc);
  if (rule.mccInclude.isNotEmpty) {
    if (mcc == null) {
      if (rule.categoryId == null) return false;
    } else if (!rule.mccInclude.any((m) => m.trim() == mcc)) {
      return false;
    }
  }

  // 8. MCC exclude.
  if (mcc != null && rule.mccExclude.any((m) => m.trim() == mcc)) return false;

  // 9. Rail: on a v2 card an unknown rail does not satisfy a rail rule.
  if (rule.rail != null &&
      (context.rail == TxnRail.unknown || context.rail != rule.rail)) {
    return false;
  }

  // 10. Transaction floor.
  final minTxn = rule.minTxn;
  if (minTxn != null && context.amount < minTxn) return false;

  // D16b: on an exclusion, max_txn_inr is a threshold — the exclusion
  // applies only below it ("no rewards on spends under ₹100").
  final maxTxn = rule.maxTxn;
  if (rule.effectiveRole == RuleRole.exclusion &&
      maxTxn != null &&
      !(context.amount < maxTxn)) {
    return false;
  }

  return true;
}

// ---------------------------------------------------------------------------
// C3.4–C3.6 evaluation.
// ---------------------------------------------------------------------------

class _Ledger {
  double points = 0;
  double cashback = 0;

  double operator [](RewardCurrency c) =>
      c == RewardCurrency.points ? points : cashback;
  void operator []=(RewardCurrency c, double v) {
    if (c == RewardCurrency.points) {
      points = v;
    } else {
      cashback = v;
    }
  }

  void add(RewardCurrency c, double v) => this[c] = this[c] + v;
}

class _AppliedCap {
  final CapRule cap;
  final CapKind kind;
  final bool legacy;
  final double amount;
  final double consumed;
  final double remaining;
  final PostCapBehavior behavior;
  double delta = 0;
  bool limiting = false;

  _AppliedCap({
    required this.cap,
    required this.kind,
    required this.legacy,
    required this.amount,
    required this.consumed,
    required this.behavior,
  }) : remaining = amount - consumed > 0 ? amount - consumed : 0;
}

/// What spend past [cap] earns. An explicit `post_cap_behavior` wins;
/// otherwise the v1 post-cap fields decide (null rate → base rate, explicit
/// 0 → nothing, any other rate → that rate), which is C3.6's `base_rate`
/// default except where the catalogue explicitly said "nothing after".
PostCapBehavior _behaviorOf(CapRule cap) {
  final explicit = cap.postCapBehavior;
  if (explicit != null) return explicit;
  final rate = cap.postCapRate;
  if (rate == null) return PostCapBehavior.baseRate;
  return rate == 0 ? PostCapBehavior.zero : PostCapBehavior.customRate;
}

/// C3.6 "which caps apply", in catalogue order: targeted caps naming the
/// rule, legacy fallbacks when a cap has no targets, every card-scope cap,
/// plus every ancestor via parent_cap_id (deduplicated, cycle-safe).
List<CapRule> _applicableCaps(
  CardProduct card,
  RewardRule? rule,
  RecommendationContext context,
) {
  final byId = <String, CapRule>{};
  for (final cap in card.capRules) {
    byId.putIfAbsent(cap.id, () => cap);
  }
  final selected = <String>{};
  for (final cap in byId.values) {
    final bool applies;
    if (cap.scope == CapScope.card) {
      applies = true;
    } else if (cap.targets.isNotEmpty) {
      applies = rule != null && cap.targets.contains(rule.id);
    } else {
      // Legacy fallback. A null category is never a wildcard: a cap with
      // neither key belongs to no rule and no category.
      applies =
          (cap.rewardRuleId != null &&
              rule != null &&
              cap.rewardRuleId == rule.id) ||
          (cap.rewardRuleId == null &&
              cap.categoryId != null &&
              cap.categoryId == context.categoryId);
    }
    if (applies) selected.add(cap.id);
  }
  for (final id in selected.toList()) {
    final seen = <String>{id};
    var parent = byId[id]?.parentCapId;
    while (parent != null && seen.add(parent) && byId.containsKey(parent)) {
      selected.add(parent);
      parent = byId[parent]!.parentCapId;
    }
  }
  return [
    for (final cap in byId.values)
      if (selected.contains(cap.id)) cap,
  ];
}

const _excludedReason = "This card doesn't earn rewards on this kind of spend.";

String _percent(double fraction) => '${(fraction * 100).toStringAsFixed(1)}%';

String _formatPoints(double points) {
  final rounded = _round2(points);
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toStringAsFixed(2);
}

/// Card-level accrual settings plus the transaction amount: everything the
/// accrual helpers need, computed once per evaluation.
class _Modes {
  final double pointValue;
  final AccrualRounding rounding;
  final CashbackRounding cashbackRounding;
  final RewardUnit? baseUnit;
  final double? baseRate;
  final int amountPaise;

  _Modes(CardProduct card, Money amount)
    : pointValue = card.pointValueInr,
      rounding = card.accrualRounding ?? AccrualRounding.floor,
      cashbackRounding = card.cashbackRounding ?? CashbackRounding.paise,
      baseUnit = card.baseRewardUnit,
      baseRate = card.baseRewardRate,
      amountPaise = amount.paise;

  bool get hasBase => baseUnit != null && baseRate != null;

  /// The card's currency: that of its base unit (null when it has none).
  RewardCurrency? get baseCurrency =>
      hasBase ? rewardCurrencyOf(baseUnit!) : null;

  double accrue(RewardUnit unit, double rate, int paise, {int? blockInr}) =>
      _accrue(
        unit,
        rate,
        paise,
        rounding,
        cashbackRounding,
        blockInr: blockInr,
      );

  /// The card's base rate on [paise], with the unit's own block (D9.4).
  double baseAccrual(int paise) =>
      hasBase ? accrue(baseUnit!, baseRate!, paise) : 0;

  double inRupees(RewardUnit unit, double accrual) =>
      rewardCurrencyOf(unit) == RewardCurrency.points
      ? accrual * pointValue
      : accrual;

  /// C3.5: the spend an earning rule's rate applies to, up to its
  /// max_txn_inr. (On an exclusion rule max_txn_inr is a threshold — D16b.)
  int eligibleFor(RewardRule? rule) {
    final max = rule?.maxTxn?.paise;
    if (max == null || amountPaise <= max) return amountPaise;
    return max < 0 ? 0 : max;
  }

  /// D12c/D15c tie-break value, in integer paise: the rule's own accrual on
  /// its eligible spend plus the base accrual above max_txn_inr, valued at
  /// the card's ₹/point, with no caps applied.
  int preCapValuePaise(RewardRule rule) {
    final eligible = eligibleFor(rule);
    final own = accrue(rule.unit, rule.rate, eligible, blockInr: rule.blockInr);
    final over = amountPaise - eligible;
    final value =
        inRupees(rule.unit, own) +
        (over > 0 && hasBase ? inRupees(baseUnit!, baseAccrual(over)) : 0);
    return (_round2(value) * 100).round();
  }
}

/// The C3.4 outcome.
class _Selection {
  final bool excluded;
  final RewardRule? exclusionRule;
  final RewardRule? rule;
  const _Selection({required this.excluded, this.exclusionRule, this.rule});
}

/// C3.4: exclusions first (an applicable exclusion rule, else the card's
/// excluded categories); otherwise the applicable base/earn rule with the
/// lowest priority, ties to the higher pre-cap value (D12c/D15c), then to
/// the rule id that sorts first. A null [_Selection.rule] means the
/// implicit base rule.
_Selection _selectRule(
  _Modes modes,
  CardProduct card,
  RecommendationContext context,
  Set<String> lineage,
) {
  final applicable = [
    for (final rule in card.rewardRules)
      if (rewardRuleAppliesV2(rule, context, merchantLineage: lineage)) rule,
  ];
  final tieValue = <RewardRule, int>{};
  int valueOf(RewardRule r) =>
      tieValue.putIfAbsent(r, () => modes.preCapValuePaise(r));
  int byPriority(RewardRule a, RewardRule b) {
    final p = a.priority.compareTo(b.priority);
    if (p != 0) return p;
    final v = valueOf(b).compareTo(valueOf(a));
    if (v != 0) return v;
    return a.id.compareTo(b.id);
  }

  final exclusions =
      applicable.where((r) => r.effectiveRole == RuleRole.exclusion).toList()
        ..sort(byPriority);
  if (exclusions.isNotEmpty) {
    return _Selection(excluded: true, exclusionRule: exclusions.first);
  }
  if (card.excludesCategory(context.categoryId)) {
    return const _Selection(excluded: true);
  }
  final earning =
      applicable
          .where(
            (r) =>
                r.effectiveRole == RuleRole.base ||
                r.effectiveRole == RuleRole.earn,
          )
          .toList()
        ..sort(byPriority);
  return _Selection(excluded: false, rule: earning.firstOrNull);
}

/// C3.6 caps in native units, in catalogue order, plus the reasons for any
/// that can't be enforced as written (D9.9/D12d — never guessed).
(List<_AppliedCap>, List<String>) _resolveCaps(
  _Modes modes,
  CardProduct card,
  RewardRule? rule,
  RewardCurrency ruleCurrency,
  RecommendationContext context,
  Map<String, double> capConsumedBefore,
) {
  // Caps the parser dropped for an unsupported v2 value are reported too.
  final skipped = <String>[
    for (final e in card.skippedCaps.entries) 'cap_skipped:${e.key}:${e.value}',
  ];
  final applied = <_AppliedCap>[];
  for (final cap in _applicableCaps(card, rule, context)) {
    CapKind? kind = cap.capKind;
    double? amount = cap.capAmount;
    var legacy = false;
    if (kind == null) {
      legacy = true;
      switch (cap.measure) {
        case CapMeasure.spendAmount:
          kind = CapKind.eligibleSpend;
          amount = cap.capValue.rupees;
        case CapMeasure.txnCount:
          kind = CapKind.txnCount;
          amount = cap.capValue.rupees;
        case CapMeasure.rewardValue:
          if (ruleCurrency == RewardCurrency.cashback) {
            kind = CapKind.totalCashback;
            amount = cap.capValue.rupees;
          } else if (modes.pointValue > 0) {
            kind = CapKind.totalPoints;
            amount = cap.capValue.rupees / modes.pointValue;
          }
      }
    }
    if (kind == null || amount == null) {
      skipped.add(
        'cap_skipped:${cap.id}:'
        '${legacy ? 'point_value_zero' : 'cap_amount_null'}',
      );
      continue;
    }
    applied.add(
      _AppliedCap(
        cap: cap,
        kind: kind,
        legacy: legacy,
        amount: amount,
        consumed: capConsumedBefore[cap.id] ?? 0,
        behavior: _behaviorOf(cap),
      ),
    );
  }
  return (applied, skipped);
}

/// The outcome of C3.6 steps 1–7.
class _Accrual {
  final int rulePaise;
  final int overflowPaise;
  final _AppliedCap? overflowCap;
  final _AppliedCap? forcing;
  final _Ledger earned;

  /// Currencies something was accrued in (D12f): the rule's, when it had
  /// spend, and every overflow / above-max piece's, even if it rounded to 0.
  final Set<RewardCurrency> accrued;
  final bool bonusCapReached;
  final bool totalCapReached;

  const _Accrual({
    required this.rulePaise,
    required this.overflowPaise,
    required this.overflowCap,
    required this.forcing,
    required this.earned,
    required this.accrued,
    required this.bonusCapReached,
    required this.totalCapReached,
  });
}

/// C3.6 steps 1–7: spend caps, count caps, accrual (C3.5, each piece
/// rounded on its own), bonus caps, total caps, and the consumption delta
/// set on each [_AppliedCap].
_Accrual _accrueAndCap(
  _Modes modes,
  RewardRule? rule,
  RewardUnit ruleUnit,
  double ruleRate,
  int eligiblePaise,
  int overMaxPaise,
  List<_AppliedCap> applied,
) {
  final ruleCurrency = rewardCurrencyOf(ruleUnit);
  final baseCurrency = modes.baseCurrency;
  final isBaseRole = rule == null || rule.effectiveRole == RuleRole.base;

  // Step 1: eligible-spend caps; the tightest binds, the first on a tie.
  var rulePaise = eligiblePaise;
  _AppliedCap? overflowCap;
  for (final c in applied.where((c) => c.kind == CapKind.eligibleSpend)) {
    final remainingPaise = (c.remaining * 100).round();
    if (remainingPaise < rulePaise) {
      rulePaise = remainingPaise;
      overflowCap = c;
    }
  }
  overflowCap?.limiting = true;

  // Step 2: an exhausted count cap pushes all eligible spend to overflow.
  final countCaps = applied.where((c) => c.kind == CapKind.txnCount).toList();
  final forcing = countCaps.where((c) => c.remaining < 1).firstOrNull;
  if (forcing != null) {
    rulePaise = 0;
    overflowCap = forcing;
    forcing.limiting = true;
  }
  final overflowPaise = eligiblePaise - rulePaise;

  // Step 3: accrue the rule's spend (base part vs bonus), then the overflow
  // and above-max pieces, each rounded on its own (D9.5).
  final base = _Ledger();
  final bonus = _Ledger();
  final pieces = _Ledger();
  final accrued = <RewardCurrency>{};
  if (rulePaise > 0) accrued.add(ruleCurrency);
  void addPiece(RewardCurrency currency, double amount) {
    pieces.add(currency, amount);
    accrued.add(currency);
  }

  final ruleAccrual = modes.accrue(
    ruleUnit,
    ruleRate,
    rulePaise,
    blockInr: rule?.blockInr,
  );
  if (isBaseRole) {
    // D9.1: a base-role rule earns at its own rate, with no bonus.
    base.add(ruleCurrency, ruleAccrual);
  } else if (baseCurrency == ruleCurrency) {
    // D12a: base_part = min(rule, base), so a rule paying less than the
    // base still earns its own rate.
    final baseOnRuleSpend = modes.baseAccrual(rulePaise);
    final basePart = baseOnRuleSpend < ruleAccrual
        ? baseOnRuleSpend
        : ruleAccrual;
    base.add(ruleCurrency, basePart);
    bonus.add(ruleCurrency, ruleAccrual - basePart);
  } else {
    bonus.add(ruleCurrency, ruleAccrual);
  }
  if (overflowPaise > 0 && overflowCap != null) {
    switch (overflowCap.behavior) {
      case PostCapBehavior.baseRate:
        if (modes.hasBase) {
          addPiece(baseCurrency!, modes.baseAccrual(overflowPaise));
        }
      case PostCapBehavior.zero:
        break;
      case PostCapBehavior.customRate:
        // D12b: post_cap_unit when set, else the rule's unit and block.
        final postUnit = overflowCap.cap.postCapUnit;
        final unit = postUnit ?? ruleUnit;
        addPiece(
          rewardCurrencyOf(unit),
          modes.accrue(
            unit,
            overflowCap.cap.postCapRate ?? 0,
            overflowPaise,
            blockInr: postUnit == null ? rule?.blockInr : null,
          ),
        );
    }
  }
  if (overMaxPaise > 0 && modes.hasBase) {
    addPiece(baseCurrency!, modes.baseAccrual(overMaxPaise));
  }

  // Steps 4–7, per currency: a cap limits only accrual in its own currency.
  var bonusCapReached = false;
  var totalCapReached = false;
  final earned = _Ledger();
  for (final currency in RewardCurrency.values) {
    final isPoints = currency == RewardCurrency.points;
    final bonusKind = isPoints ? CapKind.bonusPoints : CapKind.bonusCashback;
    final totalKind = isPoints ? CapKind.totalPoints : CapKind.totalCashback;
    final bonusCaps = applied.where((c) => c.kind == bonusKind).toList();
    final totalCaps = applied.where((c) => c.kind == totalKind).toList();

    var allowedBonus = bonus[currency];
    for (final c in bonusCaps) {
      if (c.remaining < allowedBonus) allowedBonus = c.remaining;
    }
    if (allowedBonus < bonus[currency]) {
      bonusCapReached = true;
      for (final c in bonusCaps) {
        if (c.remaining <= allowedBonus) c.limiting = true;
      }
    }
    final beforeTotal = base[currency] + allowedBonus + pieces[currency];

    var allowedTotal = beforeTotal;
    for (final c in totalCaps) {
      if (c.remaining < allowedTotal) allowedTotal = c.remaining;
    }
    final cut = beforeTotal - allowedTotal;
    if (cut > 0) {
      totalCapReached = true;
      for (final c in totalCaps) {
        if (c.remaining <= allowedTotal) c.limiting = true;
      }
    }
    // The cut comes off the bonus first.
    for (final c in bonusCaps) {
      final d = allowedBonus - cut;
      c.delta = d > 0 ? d : 0;
    }
    for (final c in totalCaps) {
      c.delta = allowedTotal;
    }
    earned[currency] = allowedTotal;
  }
  for (final c in applied) {
    if (c.kind == CapKind.eligibleSpend) c.delta = rulePaise / 100;
    if (c.kind == CapKind.txnCount) c.delta = forcing == null ? 1 : 0;
  }

  return _Accrual(
    rulePaise: rulePaise,
    overflowPaise: overflowPaise,
    overflowCap: overflowCap,
    forcing: forcing,
    earned: earned,
    accrued: accrued,
    bonusCapReached: bonusCapReached,
    totalCapReached: totalCapReached,
  );
}

/// The merchant for C3.3 step 5: a caller-supplied slug wins; otherwise the
/// directory resolves one (C5). Records how in [assumptions].
MerchantMatch? _resolveMerchant(
  RecommendationContext context,
  MerchantDirectory? directory,
  List<String> assumptions,
) {
  final givenSlug = context.merchantSlug?.trim();
  if (givenSlug != null && givenSlug.isNotEmpty) {
    return MerchantMatch(
      slug: givenSlug,
      source: MerchantMatchSource.context,
      lineage: directory?.lineage(givenSlug) ?? [givenSlug],
    );
  }
  if (directory == null) return null;
  final merchant = directory.resolve(
    merchantName: context.merchantName,
    vpa: context.vpa,
  );
  if (merchant != null) {
    assumptions.add(
      merchant.source == MerchantMatchSource.vpa
          ? 'merchant_resolved_by_vpa'
          : 'merchant_resolved_by_alias',
    );
  }
  return merchant;
}

/// C3 for one card and one transaction. [capConsumedBefore] is each cap's
/// consumption so far this period, in the cap's native unit (C3.6).
RewardEvaluation computeRewardV2(
  CardProduct card,
  RecommendationContext context, {
  Map<String, double> capConsumedBefore = const {},
  MerchantDirectory? directory,
}) {
  final modes = _Modes(card, context.amount);
  final baseCurrency = modes.baseCurrency;

  // D15d: rules the parser dropped are never silent.
  final assumptions = <String>[
    if (card.skippedExclusionRule) 'exclusion_unparsed',
  ];
  final ruleSkips = [
    for (final e in card.skippedRules.entries)
      'rule_skipped:${e.key}:${e.value}',
  ];

  // Rewards are never negative; a refund is state, not a negative purchase.
  if (modes.amountPaise <= 0) {
    return RewardEvaluation(
      excluded: false,
      currency: baseCurrency,
      points: baseCurrency == RewardCurrency.points ? 0 : null,
      cashbackInr: baseCurrency == RewardCurrency.cashback ? 0 : null,
      valueInr: 0,
      reasons: ['non_positive_amount', ...ruleSkips],
      reasonLines: const ['Nothing to earn on a zero or negative amount.'],
      assumptions: assumptions,
    );
  }

  final merchant = _resolveMerchant(context, directory, assumptions);
  final lineage = merchant?.lineage.toSet() ?? const <String>{};
  final selection = _selectRule(modes, card, context, lineage);

  if (selection.excluded) {
    final exclusionRule = selection.exclusionRule;
    final currency =
        baseCurrency ??
        (exclusionRule == null ? null : rewardCurrencyOf(exclusionRule.unit));
    final note = exclusionRule?.displayNote;
    final hasNote = note != null && note.trim().isNotEmpty;
    return RewardEvaluation(
      excluded: true,
      ruleId: exclusionRule?.id,
      rule: exclusionRule,
      currency: currency,
      points: currency == RewardCurrency.points ? 0 : null,
      cashbackInr: currency == RewardCurrency.cashback ? 0 : null,
      valueInr: 0,
      reasons: [
        hasNote
            ? note
            : (exclusionRule != null
                  ? 'excluded_by_rule'
                  : 'excluded_category'),
        ...ruleSkips,
      ],
      reasonLines: [hasNote ? note : _excludedReason],
      assumptions: assumptions,
      merchant: merchant,
    );
  }

  // C3.4.3 implicit base rule (id null) when no rule applies.
  final rule = selection.rule;
  final RewardUnit? ruleUnit = rule?.unit ?? modes.baseUnit;
  final double? ruleRate = rule?.rate ?? modes.baseRate;
  if (ruleUnit == null || ruleRate == null) {
    return RewardEvaluation(
      excluded: false,
      valueInr: 0,
      reasons: ['no_applicable_rule', ...ruleSkips],
      reasonLines: const ['No applicable reward rule.'],
      assumptions: assumptions,
      merchant: merchant,
    );
  }
  if (rule == null) assumptions.add('implicit_base_rule');
  final ruleCurrency = rewardCurrencyOf(ruleUnit);
  final ratePerRupee = _ratePerRupee(
    ruleUnit,
    ruleRate,
    modes.pointValue,
    blockInr: rule?.blockInr,
  );
  final eligiblePaise = modes.eligibleFor(rule);
  final overMaxPaise = modes.amountPaise - eligiblePaise;

  final (applied, capSkips) = _resolveCaps(
    modes,
    card,
    rule,
    ruleCurrency,
    context,
    capConsumedBefore,
  );
  final accrual = _accrueAndCap(
    modes,
    rule,
    ruleUnit,
    ruleRate,
    eligiblePaise,
    overMaxPaise,
    applied,
  );

  return _result(
    modes: modes,
    rule: rule,
    ruleCurrency: ruleCurrency,
    ratePerRupee: ratePerRupee,
    eligiblePaise: eligiblePaise,
    overMaxPaise: overMaxPaise,
    applied: applied,
    accrual: accrual,
    skipReasons: [...ruleSkips, ...capSkips],
    assumptions: assumptions,
    merchant: merchant,
  );
}

/// C3.6.8: the result, its reasons and its plain-language lines.
RewardEvaluation _result({
  required _Modes modes,
  required RewardRule? rule,
  required RewardCurrency ruleCurrency,
  required double ratePerRupee,
  required int eligiblePaise,
  required int overMaxPaise,
  required List<_AppliedCap> applied,
  required _Accrual accrual,
  required List<String> skipReasons,
  required List<String> assumptions,
  required MerchantMatch? merchant,
}) {
  final capDeltas = <String, double>{};
  for (final c in applied) {
    final d = _round2(c.delta);
    if (d != 0) capDeltas[c.cap.id] = d;
  }

  // D12f: a currency is reported when it is the card's base currency or
  // something was accrued in it.
  bool shows(RewardCurrency c) =>
      modes.baseCurrency == c || accrual.accrued.contains(c);
  final earned = accrual.earned;
  final points = shows(RewardCurrency.points) ? _round2(earned.points) : null;
  final cashback = shows(RewardCurrency.cashback)
      ? _round2(earned.cashback)
      : null;
  final valueInr = _round2(earned.points * modes.pointValue + earned.cashback);

  final rulePaise = accrual.rulePaise;
  final overflowPaise = accrual.overflowPaise;
  final forcing = accrual.forcing;
  final note = rule?.displayNote;
  final hasNote = note != null && note.trim().isNotEmpty;
  final reasons = <String>[
    if (hasNote) note,
    ...skipReasons,
    if (overMaxPaise > 0) 'above_max_txn',
    if (forcing == null && rulePaise < eligiblePaise) 'spend_cap_reached',
    if (forcing != null) 'txn_count_cap_reached',
    if (accrual.bonusCapReached) 'bonus_cap_reached',
    if (accrual.totalCapReached) 'total_cap_reached',
  ];
  final reasonLines = <String>[
    if (hasNote)
      note
    else if (rule == null)
      'Base rate ${_percent(ratePerRupee)} — no category bonus on this spend'
    else
      'Rate ${_percent(ratePerRupee)} on ${Money.fromPaise(eligiblePaise).format()}',
    for (final c in applied.where((c) => c.limiting))
      '${capRuleDisplayLabel(c.cap)}: '
          '${c.kind == CapKind.txnCount ? (c.remaining < 1 ? 'reached' : 'limited') : (c.remaining <= 0 ? 'reached' : 'limited this spend')}',
    if (overflowPaise > 0)
      '${Money.fromPaise(overflowPaise).format()} past the cap '
          '${accrual.overflowCap!.behavior == PostCapBehavior.zero ? 'earns nothing' : 'earns the post-cap rate'}',
    if (overMaxPaise > 0)
      '${Money.fromPaise(overMaxPaise).format()} above the rule\'s '
          '${rule!.maxTxn!.format()} per-transaction limit at the base rate',
    if (points != null && (cashback == null || points != 0))
      'Earns ${_formatPoints(points)} pts'
          '${modes.pointValue > 0 ? ' (${Money.fromRupees(valueInr).format()})' : ''}',
    if (cashback != null && (points == null || cashback != 0))
      'Earns ${Money.fromRupees(cashback).format()} cashback',
  ];

  return RewardEvaluation(
    excluded: false,
    ruleId: rule?.id,
    rule: rule,
    currency: ruleCurrency,
    points: points,
    cashbackInr: cashback,
    valueInr: valueInr,
    capDeltas: capDeltas,
    caps: [
      for (final c in applied)
        RewardCapUsage(
          cap: c.cap,
          kind: c.kind,
          legacy: c.legacy,
          amount: c.amount,
          consumedBefore: c.consumed,
          remainingBefore: c.remaining,
          delta: capDeltas[c.cap.id] ?? 0,
          limiting: c.limiting,
        ),
    ],
    reasons: reasons,
    reasonLines: reasonLines,
    assumptions: assumptions,
    merchant: merchant,
    ratePerRupee: ratePerRupee,
    ruleSpend: Money.fromPaise(rulePaise),
    overflowSpend: Money.fromPaise(overflowPaise),
    overMaxSpend: Money.fromPaise(overMaxPaise),
  );
}
