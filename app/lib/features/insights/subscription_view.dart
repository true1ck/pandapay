// One reading of "what is a subscription" for every screen that lists them.
//
// The Subscriptions screen and the SMS ledger's subscription list used to filter
// and merge on their own, so the same account could show different rows. Both
// now call [buildSubscriptionView], so they cannot drift apart.

import '../../app/providers.dart' show namedServiceAutoPayName, recurringServiceKey;
import '../../data/commitments_repository.dart'
    show isNonSubscriptionRecurringPayment, isSubscriptionAutoPay;
import '../../data/spend_reports_repository.dart';

bool isExcludedNonSubscription(String name) {
  final lower = name.toLowerCase();
  // If it's a recognized subscription service, do not exclude
  if (isSubscriptionAutoPay(name)) {
    return false;
  }
  if (isNonSubscriptionRecurringPayment(name)) return true;
  // 1. Demat / Broker / Trading / Investment / SIP / Mutual funds are money movements, NEVER subscriptions
  if (RegExp(
    r'\b(?:zerodha|groww|upstox|angel\s*one|dhan|paytm\s*money|indmoney|5paisa|motilal\s*oswal|icici\s*direct|hdfc\s*securities|hdfc\s*sky|kotak\s*securities|sharekhan|iifl|geojit|axis\s*direct|demat|trading|broker|portfolio|mutual\s*fund|sip|equity|investment|transfer)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return true;
  }
  // 2. Fuel fill-ups and petrol pumps are variable spends, not subscriptions
  if (RegExp(
    r'\b(petroleum|petrol|fuel|gas\s*station|oil\s*co|hpcl|bpcl|iocl)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return true;
  }
  // 3. Raw UPI VPAs containing '@' are peer/merchant transfer handles, not subscriptions
  if (name.contains('@')) {
    return true;
  }
  // 4. Retail stores, supermarkets, grocery, provisions, tea stall, cafes, bakeries, restaurants, medical, vending
  if (RegExp(
    r'\b(?:store|general\s*store|kirana|supermarket|mart|provision|traders|retail|retai|bazaar|tea\s*stall|chai|cafe|coffee|bakery|restaurant|dhaba|hotel|food|canteen|sweets|pharmacy|chemist|medical|hospital|clinic|vending)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return true;
  }
  return false;
}

bool isDisplayableSubscription(RecurringSeries series) {
  final name = series.displayName.trim();
  if (name.length < 2 || !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
    return false;
  }
  if (isExcludedNonSubscription(name)) {
    return false;
  }
  // A raw mandate is an authorization ceiling, not proof of a subscription
  // charge. The provider normalizes genuine local setup evidence before it
  // reaches this screen; keep the screen defensive for direct/API snapshots.
  if ((series.isMandate || series.detectionSource == 'mandate') &&
      !series.setupConfirmed) {
    return false;
  }
  // Daily repetitive spends (cadence < 6 days, like daily 10 Rs tea/groceries) must NEVER be subscriptions
  if (series.cadenceDays > 0 && series.cadenceDays < 6) {
    return false;
  }
  // A merchant mandate is an authorization record. It may carry a zero
  // setup amount and a maximum ceiling, neither of which proves a service
  // subscription or a future payment. Bills & Commitments owns that evidence
  // until the central projection links it to a service and supporting facts.
  if ((series.isMandate || series.detectionSource == 'mandate') &&
      !series.setupConfirmed &&
      namedServiceAutoPayName(name) == null) {
    return false;
  }
  // Merchant recurrence is useful for review, but it cannot establish that
  // the user has a subscription with that merchant unless it is a recognized service.
  if (series.reviewCandidate) return false;
  // Central explicit facts may describe a free or one-time service before a
  // charge exists. Keep that row so its lifecycle and unknown amount remain
  // visible; legacy observed rows still need a monetary or posted signal.
  if (series.typicalAmount.paise <= 0 &&
      series.occurrenceCount <= 0 &&
      !series.setupConfirmed &&
      series.detectionSource != 'central_projection' &&
      series.detectionSource != 'manual') {
    return false;
  }

  final normalized = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  return !RegExp(
    r'^(daily|weekly|fortnightly|monthly|quarterly|half yearly|yearly|annual)\s*'
    r'(payment|charge|debit|subscription|mandate|autopay|plan)?$',
  ).hasMatch(normalized);
}

/// The subscriptions to list, and the recurring charges that are only possible
/// subscriptions (found by rhythm, not confirmed by a mandate).
class SubscriptionView {
  const SubscriptionView(this.subscriptions, this.candidates);

  final List<RecurringSeries> subscriptions;
  final List<RecurringSeries> candidates;
}

SubscriptionView buildSubscriptionView(Iterable<RecurringSeries> series) {
    final rawSubscriptions = series
        .where(isDisplayableSubscription)
        .toList(growable: false);
    final uniqueSubscriptionsMap = <String, RecurringSeries>{};
    for (final item in rawSubscriptions) {
      final k = recurringServiceKey(item.displayName);
      final canonical =
          namedServiceAutoPayName(item.displayName) ?? item.displayName;
      final normalizedItem = item.copyWith(displayName: canonical);
      final existing = uniqueSubscriptionsMap[k];
      if (existing == null) {
        uniqueSubscriptionsMap[k] = normalizedItem;
      } else {
        final bestName =
            namedServiceAutoPayName(existing.displayName) ??
            namedServiceAutoPayName(normalizedItem.displayName) ??
            existing.displayName;
        uniqueSubscriptionsMap[k] = existing.copyWith(
          displayName: bestName,
          autopayLimit:
              existing.autopayLimit ?? normalizedItem.autopayLimit,
          startDate: existing.startDate ?? normalizedItem.startDate,
          endDate: existing.endDate ?? normalizedItem.endDate,
          paymentMethod:
              existing.paymentMethod ?? normalizedItem.paymentMethod,
          typicalAmount:
              (existing.amountKnown && existing.typicalAmount.paise > 0)
              ? existing.typicalAmount
              : normalizedItem.typicalAmount,
          amountKnown:
              existing.amountKnown || normalizedItem.amountKnown,
          occurrenceCount:
              existing.occurrenceCount > normalizedItem.occurrenceCount
              ? existing.occurrenceCount
              : normalizedItem.occurrenceCount,
          cadenceDays: existing.cadenceDays > 0
              ? existing.cadenceDays
              : normalizedItem.cadenceDays,
          setupConfirmed:
              existing.setupConfirmed || normalizedItem.setupConfirmed,
          cadenceConfirmed:
              existing.cadenceConfirmed ||
              normalizedItem.cadenceConfirmed,
        );
      }
    }
    final subscriptions = uniqueSubscriptionsMap.values.toList(
      growable: false,
    );
    final rawCandidates = series
        .where((series) => series.reviewCandidate)
        .where((series) => series.displayName.trim().length >= 2)
        .where((series) => series.cadenceDays >= 20)
        .where(
          (series) => !isExcludedNonSubscription(series.displayName),
        )
        .toList(growable: false);
    final uniqueCandidatesMap = <String, RecurringSeries>{};
    for (final item in rawCandidates) {
      final k = recurringServiceKey(item.displayName);
      final existing = uniqueCandidatesMap[k];
      if (existing == null ||
          item.occurrenceCount > existing.occurrenceCount) {
        uniqueCandidatesMap[k] = item;
      }
    }
    final reviewCandidates = uniqueCandidatesMap.values.toList(
      growable: false,
    );

  return SubscriptionView(subscriptions, reviewCandidates);
}
