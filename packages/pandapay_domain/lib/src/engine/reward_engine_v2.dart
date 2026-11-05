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
  RewardUnit.cashbackPercent || RewardUnit.discountPercent =>
    RewardCurrency.cashback,
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
  final List<String> reasons;

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
    this.assumptions = const [],
    this.merchant,
    this.ratePerRupee = 0,
    this.ruleSpend = const Money.zero(),
    this.overflowSpend = const Money.zero(),
    this.overMaxSpend = const Money.zero(),
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
    if (value.isNaN || value.isInfinite) return _Decimal(BigInt.zero, BigInt.one);
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

/// C3.5 accrual of [rate] in [unit] on [spendPaise], in the unit's currency
/// (points, or ₹ cashback kept to paise).
double _accrue(
  RewardUnit unit,
  double rate,
  int spendPaise,
  AccrualRounding rounding, {
  int? blockInr,
}) {
  if (spendPaise <= 0 || rate == 0) return 0;
  final r = _Decimal.of(rate);
  final paise = BigInt.from(spendPaise);
  switch (unit) {
    case RewardUnit.cashbackPercent:
    case RewardUnit.discountPercent:
      // cashback = spend × rate / 100, kept to paise (half-up).
      final cashbackPaise = _halfUpDiv(
        paise * r.numerator,
        BigInt.from(100) * r.denominator,
      );
      return cashbackPaise.toInt() / 100;
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
/// and the breakdown's headline rate. A flat bonus is spread over [amount].
double _ratePerRupee(
  RewardUnit unit,
  double rate,
  double pointValueInr,
  Money amount, {
  int? blockInr,
}) {
  switch (unit) {
    case RewardUnit.cashbackPercent:
    case RewardUnit.discountPercent:
      return rate / 100;
    case RewardUnit.flatPoints:
      return amount.paise <= 0 ? 0 : rate * pointValueInr / amount.rupees;
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
  if (rule.platformSlugs.isNotEmpty) {
    final platform = context.platform;
    if (platform == null || !rule.platformSlugs.contains(platform)) {
      return false;
    }
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

/// C3 for one card and one transaction. [capConsumedBefore] is each cap's
/// consumption so far this period, in the cap's native unit (C3.6).
RewardEvaluation computeRewardV2(
  CardProduct card,
  RecommendationContext context, {
  Map<String, double> capConsumedBefore = const {},
  MerchantDirectory? directory,
}) {
  final assumptions = <String>[];
  final pointValue = card.pointValueInr;

  // Merchant (C3.1/C5): a caller-supplied slug wins; otherwise resolve.
  MerchantMatch? merchant;
  final givenSlug = context.merchantSlug?.trim();
  if (givenSlug != null && givenSlug.isNotEmpty) {
    merchant = MerchantMatch(
      slug: givenSlug,
      source: MerchantMatchSource.context,
      lineage: directory?.lineage(givenSlug) ?? [givenSlug],
    );
  } else if (directory != null) {
    merchant = directory.resolve(
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
  }
  final lineage = merchant?.lineage.toSet() ?? const <String>{};

  final baseUnit = card.baseRewardUnit;
  final baseRate = card.baseRewardRate;
  final hasBase = baseUnit != null && baseRate != null;
  final baseCurrency = hasBase ? rewardCurrencyOf(baseUnit) : null;

  // C3.3 over every rule, keeping catalogue order for stable tie-breaks.
  final applicable = <(int, RewardRule)>[
    for (final (i, rule) in card.rewardRules.indexed)
      if (rewardRuleAppliesV2(rule, context, merchantLineage: lineage))
        (i, rule),
  ];

  // C3.4.1 exclusions: an exclusion rule (lowest priority first), else the
  // card's own excluded categories. No caps are touched.
  final exclusions =
      applicable.where((e) => e.$2.effectiveRole == RuleRole.exclusion).toList()
        ..sort((a, b) {
          final byPriority = a.$2.priority.compareTo(b.$2.priority);
          return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
        });
  final exclusionRule = exclusions.isEmpty ? null : exclusions.first.$2;
  if (exclusionRule != null || card.excludesCategory(context.categoryId)) {
    final currency =
        baseCurrency ??
        (exclusionRule == null ? null : rewardCurrencyOf(exclusionRule.unit));
    final note = exclusionRule?.displayNote;
    return RewardEvaluation(
      excluded: true,
      ruleId: exclusionRule?.id,
      rule: exclusionRule,
      currency: currency,
      points: currency == RewardCurrency.points ? 0 : null,
      cashbackInr: currency == RewardCurrency.cashback ? 0 : null,
      valueInr: 0,
      reasons: [
        (note != null && note.trim().isNotEmpty) ? note : _excludedReason,
      ],
      assumptions: assumptions,
      merchant: merchant,
    );
  }

  // C3.4.2 lowest priority; tie → highest ₹-per-₹ rate; tie → catalogue order.
  double rateOf(RewardRule r) => _ratePerRupee(
    r.unit,
    r.rate,
    pointValue,
    context.amount,
    blockInr: r.blockInr,
  );
  final earning =
      applicable
          .where(
            (e) =>
                e.$2.effectiveRole == RuleRole.base ||
                e.$2.effectiveRole == RuleRole.earn,
          )
          .toList()
        ..sort((a, b) {
          final byPriority = a.$2.priority.compareTo(b.$2.priority);
          if (byPriority != 0) return byPriority;
          final byRate = rateOf(b.$2).compareTo(rateOf(a.$2));
          if (byRate != 0) return byRate;
          return a.$1.compareTo(b.$1);
        });
  final RewardRule? rule = earning.isEmpty ? null : earning.first.$2;

  // C3.4.3 implicit base rule (id null) when nothing applies.
  final RewardUnit? ruleUnit = rule?.unit ?? baseUnit;
  final double? ruleRate = rule?.rate ?? baseRate;
  if (ruleUnit == null || ruleRate == null) {
    return RewardEvaluation(
      excluded: false,
      valueInr: 0,
      reasons: const ['No applicable reward rule.'],
      assumptions: assumptions,
      merchant: merchant,
    );
  }
  final ruleCurrency = rewardCurrencyOf(ruleUnit);
  final isBaseRole = rule == null || rule.effectiveRole == RuleRole.base;
  final rounding = card.accrualRounding ?? AccrualRounding.floor;
  final ratePerRupee = rule == null
      ? _ratePerRupee(ruleUnit, ruleRate, pointValue, context.amount)
      : rateOf(rule);

  double baseAccrual(int paise) =>
      hasBase ? _accrue(baseUnit, baseRate, paise, rounding) : 0;

  // C3.5 eligible spend: up to max_txn_inr; the excess earns the base rate.
  final amountPaise = context.amount.paise;
  final maxTxn = rule?.maxTxn;
  final eligiblePaise = maxTxn != null && amountPaise > maxTxn.paise
      ? (maxTxn.paise < 0 ? 0 : maxTxn.paise)
      : amountPaise;
  final overMaxPaise = amountPaise - eligiblePaise;

  // C3.6 caps, resolved to native units.
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
          } else if (pointValue > 0) {
            kind = CapKind.totalPoints;
            amount = cap.capValue.rupees / pointValue;
          }
      }
    }
    if (kind == null || amount == null) {
      assumptions.add('cap_unenforced:${cap.id}');
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

  // Step 1: eligible-spend caps.
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

  // Step 2: transaction-count caps.
  final countCaps = applied.where((c) => c.kind == CapKind.txnCount).toList();
  final forcing = countCaps.where((c) => c.remaining < 1).firstOrNull;
  if (forcing != null) {
    rulePaise = 0;
    overflowCap = forcing;
    forcing.limiting = true;
  }
  final overflowPaise = eligiblePaise - rulePaise;

  // Step 3: accrue on the rule's spend, and on the overflow.
  final base = _Ledger();
  final bonus = _Ledger();
  final overflow = _Ledger();
  final extra = _Ledger();
  final ruleAccrual = _accrue(
    ruleUnit,
    ruleRate,
    rulePaise,
    rounding,
    blockInr: rule?.blockInr,
  );
  if (isBaseRole) {
    base.add(ruleCurrency, ruleAccrual);
  } else if (baseCurrency == ruleCurrency) {
    final baseOnRuleSpend = baseAccrual(rulePaise);
    // Not literal C3.5: base_accrual is capped at the rule's own accrual, so
    // a reduced-rate rule (e.g. 0.5 pt on utilities on a 1 pt card) earns
    // its own rate, never the higher base rate. Identical to C3.5 whenever
    // the rule earns at least the base rate.
    base.add(
      ruleCurrency,
      baseOnRuleSpend < ruleAccrual ? baseOnRuleSpend : ruleAccrual,
    );
    final b = ruleAccrual - baseOnRuleSpend;
    bonus.add(ruleCurrency, b > 0 ? b : 0);
  } else {
    bonus.add(ruleCurrency, ruleAccrual);
  }
  if (overflowPaise > 0 && overflowCap != null) {
    switch (overflowCap.behavior) {
      case PostCapBehavior.baseRate:
        if (hasBase) overflow.add(baseCurrency!, baseAccrual(overflowPaise));
      case PostCapBehavior.zero:
        break;
      case PostCapBehavior.customRate:
        final unit = overflowCap.cap.postCapUnit ?? ruleUnit;
        final rate = overflowCap.cap.postCapRate ?? 0;
        overflow.add(
          rewardCurrencyOf(unit),
          _accrue(unit, rate, overflowPaise, rounding),
        );
    }
  }
  if (overMaxPaise > 0 && hasBase) {
    extra.add(baseCurrency!, baseAccrual(overMaxPaise));
  }

  // Steps 4–7, per currency.
  final finalEarned = _Ledger();
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
      for (final c in bonusCaps) {
        if (c.remaining <= allowedBonus) c.limiting = true;
      }
    }
    final earned = base[currency] + allowedBonus + overflow[currency];

    var allowedTotal = earned;
    for (final c in totalCaps) {
      if (c.remaining < allowedTotal) allowedTotal = c.remaining;
    }
    final cut = earned - allowedTotal;
    if (cut > 0) {
      for (final c in totalCaps) {
        if (c.remaining <= allowedTotal) c.limiting = true;
      }
    }
    for (final c in bonusCaps) {
      final d = allowedBonus - cut;
      c.delta = d > 0 ? d : 0;
    }
    for (final c in totalCaps) {
      c.delta = allowedTotal;
    }
    // The excess above max_txn_inr earns the base rate outside the caps
    // (C3.5 "v1 behaviour").
    finalEarned[currency] = allowedTotal + extra[currency];
  }
  for (final c in applied) {
    if (c.kind == CapKind.eligibleSpend) c.delta = rulePaise / 100;
    if (c.kind == CapKind.txnCount) c.delta = forcing == null ? 1 : 0;
  }

  final capDeltas = <String, double>{};
  for (final c in applied) {
    final d = _round2(c.delta);
    if (d != 0) capDeltas[c.cap.id] = d;
  }

  final cardCurrency = baseCurrency ?? ruleCurrency;
  bool quotes(RewardCurrency c) =>
      cardCurrency == c || ruleCurrency == c || finalEarned[c] != 0;
  final points = quotes(RewardCurrency.points)
      ? _round2(finalEarned.points)
      : null;
  final cashback = quotes(RewardCurrency.cashback)
      ? _round2(finalEarned.cashback)
      : null;
  final valueInr = _round2(
    finalEarned.points * pointValue + finalEarned.cashback,
  );

  final reasons = <String>[
    if (rule?.displayNote != null && rule!.displayNote!.trim().isNotEmpty)
      rule.displayNote!
    else if (rule == null)
      'Base rate ${_percent(ratePerRupee)} — no category bonus on this spend'
    else
      'Rate ${_percent(ratePerRupee)} on ${Money.fromPaise(eligiblePaise).format()}',
    for (final c in applied.where((c) => c.limiting))
      '${capRuleDisplayLabel(c.cap)}: '
          '${c.kind == CapKind.txnCount ? (c.remaining < 1 ? 'reached' : 'limited') : (c.remaining <= 0 ? 'reached' : 'limited this spend')}',
    if (overflowPaise > 0)
      '${Money.fromPaise(overflowPaise).format()} past the cap '
          '${overflowCap!.behavior == PostCapBehavior.zero ? 'earns nothing' : 'earns the post-cap rate'}',
    if (overMaxPaise > 0)
      '${Money.fromPaise(overMaxPaise).format()} above the rule\'s '
          '${maxTxn!.format()} per-transaction limit at the base rate',
    if (points != null && (cashback == null || points != 0))
      'Earns ${_formatPoints(points)} pts'
          '${pointValue > 0 ? ' (${Money.fromRupees(valueInr).format()})' : ''}',
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
    assumptions: assumptions,
    merchant: merchant,
    ratePerRupee: ratePerRupee,
    ruleSpend: Money.fromPaise(rulePaise),
    overflowSpend: Money.fromPaise(overflowPaise),
    overMaxSpend: Money.fromPaise(overMaxPaise),
  );
}
