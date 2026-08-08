import '../money/money.dart';

/// Task E-0c (implementation-plan-group-e-f-g.md §1) — a single, shared
/// "how urgent is this?" scorer so E1 (nearest-deadline-first across every
/// tracker kind), E2 (closest-to-cap), E5 (days-to-anniversary) and E6
/// (quota-reset) all sort by the same comparable shape instead of five
/// screens inventing their own ad hoc `.sort()`.
///
/// Lower [score] == more urgent == sorts first. Two orthogonal signals feed
/// it, blended into one comparable number:
///   - [ratioConsumed] (0..1): how close to "used up" something is (a cap's
///     spend ratio, a milestone's progress ratio). null when the item has
///     no such notion (e.g. E7 billing float has no "consumed" concept).
///   - [daysRemaining]: how many days until a hard deadline (milestone
///     period end, fee-waiver anniversary, lounge-quota reset). null when
///     there's no dated deadline.
///
/// At least one of the two must be non-null for a meaningful score — an
/// item with neither is treated as the least urgent (sorts last), not
/// excluded, so a caller can still show it in a stable position.
class UrgencyScore implements Comparable<UrgencyScore> {
  final double ratioConsumed;
  final int daysRemaining;

  /// Blend weights are deliberately simple and documented rather than
  /// tuned: ratio dominates (0-1 already comparable across item kinds),
  /// days-remaining is folded in as a small tiebreaker-scale term so two
  /// items at the same ratio but very different day counts still separate
  /// sensibly, without a raw day count (which can run into the hundreds)
  /// swamping the ratio signal.
  const UrgencyScore._({required this.ratioConsumed, required this.daysRemaining});

  factory UrgencyScore({double? ratioConsumed, int? daysRemaining}) {
    final r = ratioConsumed?.clamp(0.0, 1.0) ?? 0.0;
    final d = daysRemaining ?? 1 << 20; // "effectively never" when unknown
    return UrgencyScore._(ratioConsumed: r, daysRemaining: d);
  }

  /// Higher raw = more urgent internally; exposed as [compareTo] so callers
  /// just do `list.sort((a, b) => a.urgency.compareTo(b.urgency))` for a
  /// nearest-deadline/closest-to-cap-first ordering.
  double get _rawUrgency => ratioConsumed - (daysRemaining / 3650.0);

  @override
  int compareTo(UrgencyScore other) {
    // Sort DESCENDING by raw urgency (most urgent first) — compareTo
    // returns negative when `this` should sort before `other`, so flip
    // the natural ascending comparison.
    return other._rawUrgency.compareTo(_rawUrgency);
  }
}

/// Convenience: a days-until helper shared by every screen that needs
/// "days from today until [target]" (E4, E5, E6) so the same whole-day
/// rounding rule applies everywhere rather than each screen writing its
/// own `.difference(...).inDays`.
int daysUntil(DateTime target, DateTime today) {
  final t = DateTime(target.year, target.month, target.day);
  final n = DateTime(today.year, today.month, today.day);
  return t.difference(n).inDays;
}

/// Cap-consumption ratio, reused by E2's sort and E1's cap-urgency feed —
/// mirrors the clamping CapsScreen already does inline, factored out so E1
/// doesn't reimplement it.
double capRatio(Money consumed, Money capValue) {
  if (capValue.isZero) return 0;
  return (consumed.paise / capValue.paise).clamp(0.0, 1.0);
}
