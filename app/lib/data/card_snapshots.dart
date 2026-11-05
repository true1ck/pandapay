import 'package:pandapay_domain/pandapay_domain.dart';

import 'user_cards_repository.dart';

/// Card Rewards Phase 1 (WP9) — the one place an owned card becomes a
/// [CardSnapshot] for the recommendation engine.
///
/// **Never mix measures.** A v1-shaped card keeps today's meaning: the
/// server's `consumed` is in the cap's v1 measure, and the engine is told
/// the headroom through [CardSnapshot.capRemaining].
///
/// A v2-shaped card (`CardProduct.isV2Shaped`) is different. Its caps are in
/// native units (points, ₹, a count), so the snapshot carries
/// [CardSnapshot.capConsumed] taken from `consumed_native`, and
/// `capRemaining` stays empty: the engine's fallback
/// (`capValue − capRemaining`) would otherwise subtract a v1 ₹ figure from a
/// native points cap. The v1 `consumed` is never turned into native units.
///
/// *No row for a cap* means nothing consumed this period. *A row without a
/// native figure* (written before the server's recompute), *a row from a
/// period that has ended*, and *a row recorded for a different cap kind* are
/// all **unknown, not empty**: the snapshot feeds `consumed = cap amount`, so
/// the engine promises no capped bonus.

/// Larger than any real cap: used when an unknown cap has no amount to feed
/// (a legacy cap the engine converts itself). The engine reads a remaining
/// of `max(0, amount − consumed)`, so this leaves nothing.
const double kCapExhaustedSentinel = 1e12;

enum CapUsageStatus {
  /// No row this period: nothing consumed.
  none,

  /// A native figure the app may rely on.
  known,

  /// Present but not trustworthy (see library comment).
  unknown,
}

/// What an owned card has used of one cap this period, in native units.
class CapUsage {
  final CapUsageStatus status;

  /// Native units: 0 for [CapUsageStatus.none], null for
  /// [CapUsageStatus.unknown].
  final double? consumed;
  final CapStateRow? row;

  const CapUsage._(this.status, this.consumed, this.row);
  const CapUsage.none() : this._(CapUsageStatus.none, 0, null);
  const CapUsage.unknown([CapStateRow? row])
    : this._(CapUsageStatus.unknown, null, row);
  const CapUsage.known(double consumed, CapStateRow row)
    : this._(CapUsageStatus.known, consumed, row);

  bool get isUnknown => status == CapUsageStatus.unknown;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// The native-unit usage of [cap] on [owned], as of [now]. For a v2-shaped
/// card only; a v1 card's usage is [UserCard.capConsumed] in its own
/// measure.
CapUsage resolveCapUsage(UserCard? owned, CapRule cap, {required DateTime now}) {
  if (owned == null) return const CapUsage.none();
  final row = owned.capStates[cap.id];
  if (row == null) {
    // A v1 figure with no row cannot be turned into native units.
    return owned.capConsumed.containsKey(cap.id)
        ? const CapUsage.unknown()
        : const CapUsage.none();
  }
  final native = row.consumedNative;
  if (native == null) return CapUsage.unknown(row);
  final end = row.periodEnd;
  if (end != null && _day(now).isAfter(end)) {
    // The period this figure belongs to has ended (a cached wallet read
    // after a rollover): this period's usage is not known yet.
    return CapUsage.unknown(row);
  }
  final recordedKind = row.capKind;
  if (recordedKind != null &&
      cap.capKind != null &&
      recordedKind != cap.capKind) {
    // The catalogue's cap changed kind since the row was recorded.
    return CapUsage.unknown(row);
  }
  return CapUsage.known(native < 0 ? 0 : native, row);
}

/// The native amount to feed as `consumed` for an unknown cap so the engine
/// has no headroom to promise: the cap's own amount.
double _exhaustedConsumed(CapRule cap, CapUsage usage) {
  final amounts = <double>[
    ?cap.capAmount,
    if (cap.capKind != null) ?usage.row?.capAmount,
  ];
  if (amounts.isEmpty) return kCapExhaustedSentinel;
  return amounts.reduce((a, b) => a > b ? a : b);
}

/// [product] as the engine should see it for [owned] (null when the user
/// does not hold it: every cap is then fresh).
CardSnapshot buildCardSnapshot(
  CardProduct product, {
  UserCard? owned,
  required DateTime now,
  String? forcedOverrideCardId,
}) {
  final milestoneProgress = owned?.milestoneQualifiedSpend ?? const {};
  if (!product.isV2Shaped) {
    final capRemaining = owned == null
        ? const <String, Money>{}
        : {
            for (final cap in uniqueCapRules(product.capRules))
              if (owned.capConsumed.containsKey(cap.id))
                cap.id: cap.capValue - owned.capConsumed[cap.id]!,
          };
    return CardSnapshot(
      product: product,
      capRemaining: capRemaining,
      milestoneProgress: milestoneProgress,
      forcedOverrideCardId: forcedOverrideCardId,
    );
  }

  final consumed = <String, double>{};
  // Every cap by id; v2-shaped cards are not de-duplicated (D15a).
  for (final cap in product.capRules) {
    final usage = resolveCapUsage(owned, cap, now: now);
    switch (usage.status) {
      case CapUsageStatus.none:
        break;
      case CapUsageStatus.known:
        consumed[cap.id] = usage.consumed!;
      case CapUsageStatus.unknown:
        consumed[cap.id] = _exhaustedConsumed(cap, usage);
    }
  }
  return CardSnapshot(
    product: product,
    // Deliberately empty: capRemaining is the v1 measure.
    capRemaining: const {},
    capConsumed: consumed,
    milestoneProgress: milestoneProgress,
    forcedOverrideCardId: forcedOverrideCardId,
  );
}
