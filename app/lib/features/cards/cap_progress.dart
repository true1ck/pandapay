import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../data/card_snapshots.dart';
import '../../data/user_cards_repository.dart';

/// Card Rewards Phase 1 (WP9, B1) — what a cap bar shows for one cap of a
/// v2-shaped card, in the cap's NATIVE unit.
///
/// Built on [resolveCapUsage], the same reading the recommendation engine
/// gets (data/card_snapshots.dart), so the bar and the ranking can never
/// disagree about a cap: no row is "nothing consumed", a missing native
/// figure / an ended period / a changed cap kind is **unknown** (shown as
/// "Updating", never as a comforting number), and the v1 `consumed` is never
/// read here.

/// How the amounts of a cap are written.
enum CapUnit {
  /// `bonus_points`, `total_points`: "1,240 / 1,500 pts".
  points,

  /// `bonus_cashback`, `total_cashback`: "₹240 / ₹500".
  cashback,

  /// `eligible_spend`: "₹12,400 / ₹20,000 spent".
  spend,

  /// `txn_count`: "2 / 3 uses".
  uses;

  static CapUnit of(CapKind kind) => switch (kind) {
    CapKind.bonusPoints || CapKind.totalPoints => CapUnit.points,
    CapKind.bonusCashback || CapKind.totalCashback => CapUnit.cashback,
    CapKind.eligibleSpend => CapUnit.spend,
    CapKind.txnCount => CapUnit.uses,
  };
}

/// "1,240" (Indian grouping), "1,240.5" when the figure is fractional. Never
/// rounds a figure away.
String formatNative(double value) =>
    Money.fromRupees(value).format(showSymbol: false, hidePaise: true);

/// A whole-number percentage for [ratio], rounded DOWN so a bar or alert
/// never reads 100% before the cap is actually reached. The small epsilon
/// keeps exact figures exact (0.58 × 100 is 57.999…).
int percentFloor(double ratio) => (ratio * 100 + 1e-9).floor();

String _rupees(double value) =>
    Money.fromRupees(value).format(hidePaise: true);

String _number(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

int _unitBlock(RewardUnit unit) => switch (unit) {
  RewardUnit.pointsPer150 => 150,
  RewardUnit.pointsPer200 => 200,
  _ => 100,
};

/// "1 pt/₹100", "5 pts/₹150", "1.5% cashback"; null when the unit has no
/// per-rupee wording (flat points are written per transaction).
String? rewardRateText(RewardUnit unit, double rate, {int? blockInr}) {
  final n = _number(rate);
  switch (unit) {
    case RewardUnit.cashbackPercent:
      return '$n% cashback';
    case RewardUnit.discountPercent:
      return '$n% discount';
    case RewardUnit.pointsPer100:
    case RewardUnit.pointsPer150:
    case RewardUnit.pointsPer200:
      return '$n ${rate == 1 ? 'pt' : 'pts'}/₹${blockInr ?? _unitBlock(unit)}';
    case RewardUnit.milesPer100:
      return '$n ${rate == 1 ? 'mile' : 'miles'}/₹${blockInr ?? 100}';
    case RewardUnit.flatPoints:
      return '$n ${rate == 1 ? 'pt' : 'pts'} per transaction';
  }
}

String _periodWord(CapPeriod period) => switch (period) {
  CapPeriod.statementCycle => 'each statement cycle',
  CapPeriod.calendarMonth => 'monthly',
  CapPeriod.quarter => 'each quarter',
  CapPeriod.halfYear => 'each half-year',
  CapPeriod.annual => 'yearly',
  CapPeriod.lifetime => 'never (lifetime cap)',
};

class CapProgress {
  final CapRule cap;

  /// The kind the bar speaks in: the catalogue's, else the server row's,
  /// else the C3.6 conversion of a legacy row.
  final CapKind kind;

  /// The cap in native units; always above zero.
  final double amount;
  final CapUsage usage;

  /// What spend past the cap earns ("1 pt/₹100", "nothing"), or null when
  /// that cannot be stated without guessing.
  final String? thenText;

  const CapProgress._({
    required this.cap,
    required this.kind,
    required this.amount,
    required this.usage,
    required this.thenText,
  });

  CapUnit get unit => CapUnit.of(kind);

  /// Present but not trustworthy: shown as "Updating", fed to the engine as
  /// fully consumed.
  bool get isUnknown => usage.isUnknown;

  /// Native consumption; null when [isUnknown].
  double? get consumed => usage.consumed;

  /// 0..1; null when [isUnknown].
  double? get ratio {
    final used = consumed;
    if (used == null) return null;
    return (used / amount).clamp(0.0, 1.0);
  }

  /// Unraised alert level: 0.8 warns, 1.0 is reached.
  bool get isReached => (ratio ?? 0) >= 1.0;

  bool get approximateWindow => usage.row?.approximateWindow ?? false;

  /// The day the period rolls over: the server's `period_end` plus one day.
  /// Null with no row, and for an unknown row (its period is not this one).
  DateTime? get resetsOn {
    if (isUnknown) return null;
    final end = usage.row?.periodEnd;
    if (end == null) return null;
    return DateTime(end.year, end.month, end.day + 1);
  }

  String get consumedText => formatNative(consumed ?? 0);

  String get amountText => formatNative(amount);

  /// "1,240 / 1,500 pts", "₹240 / ₹500", "₹12,400 / ₹20,000 spent",
  /// "2 / 3 uses".
  String get consumptionText {
    final used = consumed ?? 0;
    switch (unit) {
      case CapUnit.points:
        return '${formatNative(used)} / ${formatNative(amount)} pts';
      case CapUnit.cashback:
        return '${_rupees(used)} / ${_rupees(amount)}';
      case CapUnit.spend:
        return '${_rupees(used)} / ${_rupees(amount)} spent';
      case CapUnit.uses:
        return '${formatNative(used)} / ${formatNative(amount)} uses';
    }
  }

  /// "resets 1 Dec", "resets approx. 1 Dec", or the period word when no row
  /// exists yet ("resets monthly").
  String get resetText {
    final date = resetsOn;
    if (date == null) return 'resets ${_periodWord(cap.period)}';
    final day = DateFormat('d MMM').format(date);
    return approximateWindow ? 'resets approx. $day' : 'resets $day';
  }

  /// The one-line summary: "1,240 / 1,500 pts · resets 1 Dec · then 1 pt/₹100",
  /// or just "Updating…" for an unknown cap.
  String get summary {
    if (isUnknown) return 'Updating…';
    return [
      consumptionText,
      resetText,
      if (thenText != null) 'then $thenText',
    ].join(' · ');
  }

  /// What a reached cap means for the next spend, in the same words as
  /// [thenText]: "extra spend here earns nothing" (total caps), "extra spend
  /// here earns only 1 pt/₹100" (a stated base or post-cap rate), or, when
  /// the rate cannot be stated, a clause that names no rate.
  String get reachedConsequence {
    final then = thenText;
    if (then == 'nothing') return 'extra spend here earns nothing';
    if (then != null) return 'extra spend here earns only $then';
    return switch (kind) {
      CapKind.bonusPoints ||
      CapKind.bonusCashback => 'extra spend here won\'t earn the bonus rate',
      _ => 'extra spend here won\'t earn the capped rate',
    };
  }

  /// For tests and diagnostics only: never rendered.
  @override
  String toString() => 'CapProgress(${cap.id}, $kind, $summary)';
}

/// The bars for [product] (a v2-shaped card) as [owned] stands: one per cap,
/// in catalogue order, each as [capProgressFor] reads it. A cap that cannot
/// be stated natively is left out; callers show it the v1 way.
List<CapProgress> capProgressesFor({
  required CardProduct product,
  UserCard? owned,
  required DateTime now,
}) => [
  for (final cap in product.capRules)
    ?capProgressFor(product: product, cap: cap, owned: owned, now: now),
];

/// The cap the My Cards tile shows: the fullest. An unknown cap counts as
/// full, so a tile never shows a comforting bar while a cap's usage is not
/// known. The first of equals wins (catalogue order). Null for an empty list.
CapProgress? fullestCapProgress(Iterable<CapProgress> all) {
  CapProgress? best;
  double bestRatio = -1;
  for (final p in all) {
    final r = p.ratio ?? 2.0;
    if (r > bestRatio) {
      best = p;
      bestRatio = r;
    }
  }
  return best;
}

/// One cap's progress, or null when its kind or amount cannot be determined
/// without guessing (a legacy `reward_value` cap on a card with no point
/// value, say).
CapProgress? capProgressFor({
  required CardProduct product,
  required CapRule cap,
  UserCard? owned,
  required DateTime now,
}) {
  final usage = resolveCapUsage(owned, cap, now: now);
  final row = owned?.capStates[cap.id];

  CapKind? kind;
  double? amount;
  if (cap.capKind != null) {
    kind = cap.capKind;
    amount = cap.capAmount ?? row?.capAmount;
  } else if (row?.capKind != null) {
    kind = row!.capKind;
    amount = row.capAmount;
  } else {
    final legacy = _legacyKindAndAmount(product, cap);
    kind = legacy?.$1;
    amount = legacy?.$2;
  }
  if (kind == null || amount == null || amount <= 0) return null;

  return CapProgress._(
    cap: cap,
    kind: kind,
    amount: amount,
    usage: usage,
    thenText: _thenText(product, cap, kind),
  );
}

/// C3.6's conversion of a legacy (`cap_kind` null) row, as the engine and
/// the server make it.
(CapKind, double)? _legacyKindAndAmount(CardProduct product, CapRule cap) {
  switch (cap.measure) {
    case CapMeasure.spendAmount:
      return (CapKind.eligibleSpend, cap.capValue.rupees);
    case CapMeasure.txnCount:
      return (CapKind.txnCount, cap.capValue.rupees);
    case CapMeasure.rewardValue:
      final ruleId = cap.rewardRuleId ?? cap.targets.firstOrNull;
      final rule = ruleId == null
          ? null
          : product.rewardRules.where((r) => r.id == ruleId).firstOrNull;
      final unit = rule?.unit ?? product.baseRewardUnit;
      if (unit == null) return null;
      if (unit == RewardUnit.cashbackPercent ||
          unit == RewardUnit.discountPercent) {
        return (CapKind.totalCashback, cap.capValue.rupees);
      }
      if (product.pointValueInr <= 0) return null;
      return (CapKind.totalPoints, cap.capValue.rupees / product.pointValueInr);
  }
}

/// What spend past [cap] earns, mirroring the engine (C3.6): a bonus cap
/// leaves the base rate, a total cap leaves nothing, and an eligible-spend or
/// count cap follows its post-cap behaviour (explicit, else derived from
/// `post_cap_rate` as the engine does). Null whenever it would be a guess.
String? _thenText(CardProduct product, CapRule cap, CapKind kind) {
  switch (kind) {
    case CapKind.totalPoints:
    case CapKind.totalCashback:
      return 'nothing';
    case CapKind.bonusPoints:
    case CapKind.bonusCashback:
      return _baseRateText(product);
    case CapKind.eligibleSpend:
    case CapKind.txnCount:
      final behavior =
          cap.postCapBehavior ??
          switch (cap.postCapRate) {
            null => PostCapBehavior.baseRate,
            0 => PostCapBehavior.zero,
            _ => PostCapBehavior.customRate,
          };
      switch (behavior) {
        case PostCapBehavior.baseRate:
          return _baseRateText(product);
        case PostCapBehavior.zero:
          return 'nothing';
        case PostCapBehavior.customRate:
          final rate = cap.postCapRate;
          if (rate == null) return null;
          final targetId = cap.targets.firstOrNull ?? cap.rewardRuleId;
          final rule = targetId == null
              ? null
              : product.rewardRules.where((r) => r.id == targetId).firstOrNull;
          final unit = cap.postCapUnit ?? rule?.unit;
          if (unit == null) return null;
          return rewardRateText(
            unit,
            rate,
            blockInr: cap.postCapUnit == null ? rule?.blockInr : null,
          );
      }
  }
}

/// The card's everything-else rate, as the engine's implicit base. Null
/// (omit the clause) when the card has an explicit base-role rule that
/// differs from it (a different block, unit or rate), or no base rate.
String? _baseRateText(CardProduct product) {
  final unit = product.baseRewardUnit;
  final rate = product.baseRewardRate;
  if (unit == null || rate == null) return null;
  for (final rule in product.rewardRules) {
    if (rule.role == RuleRole.base &&
        (rule.unit != unit || rule.rate != rate || rule.blockInr != null)) {
      return null;
    }
  }
  if (rate == 0) return 'nothing';
  if (unit == RewardUnit.flatPoints) return null;
  return rewardRateText(unit, rate);
}
