// One reading of "what is a subscription" for every screen that lists them.
//
// The Subscriptions screen and the SMS ledger's subscription list used to filter
// and merge on their own, so the same account could show different rows. Both
// now call [buildSubscriptionView], so they cannot drift apart.

import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../../app/providers.dart' show namedServiceAutoPayName, recurringServiceKey;
import '../../data/commitments_repository.dart'
    show isNonSubscriptionRecurringPayment, isSubscriptionAutoPay;
import '../../data/spend_reports_repository.dart';

// Compiled once: these run for every series on every build of a subscription
// screen (and once per reminder check), so building them per call is waste.
final _brokerWords = RegExp(
  r'\b(?:zerodha|groww|upstox|angel\s*one|dhan|paytm\s*money|indmoney|5paisa|motilal\s*oswal|icici\s*direct|hdfc\s*securities|hdfc\s*sky|kotak\s*securities|sharekhan|iifl|geojit|axis\s*direct|demat|trading|broker|portfolio|mutual\s*fund|sip|equity|investment|transfer)\b',
  caseSensitive: false,
);
final _fuelWords = RegExp(
  r'\b(petroleum|petrol|fuel|gas\s*station|oil\s*co|hpcl|bpcl|iocl)\b',
  caseSensitive: false,
);
final _billOrLenderWords = RegExp(
  r'\b(?:tad|mad|total\s+amount\s+due|minimum\s+amount\s+due|finserv|fincorp|nbfc|capital\s*float|payu\s+finance)\b'
  // A lender is a business name ending in a company word; a service that
  // merely has "finance" or "loan" in its name is not one.
  r'|\b(?:finance|lending|loans?)\b(?=\s+(?:pvt|private|ltd|limited|india|corp|company|services?)\b)',
  caseSensitive: false,
);
final _shopWords = RegExp(
  r'\b(?:store|general\s*store|kirana|supermarket|mart|provision|traders|retail|retai|bazaar|tea\s*stall|chai|cafe|coffee|bakery|restaurant|dhaba|hotel|food|canteen|sweets|pharmacy|chemist|medical|hospital|clinic|vending)\b',
  caseSensitive: false,
);
final _hasLetters = RegExp(r'[A-Za-z]{2,}');
final _nonAlphanumeric = RegExp(r'[^a-z0-9]+');
final _genericPlanName = RegExp(
  r'^(daily|weekly|fortnightly|monthly|quarterly|half yearly|yearly|annual)\s*'
  r'(payment|charge|debit|subscription|mandate|autopay|plan)?$',
);

bool isExcludedNonSubscription(String name, {bool mandateBacked = false}) {
  final lower = name.toLowerCase();
  // If it's a recognized subscription service, do not exclude
  if (isSubscriptionAutoPay(name)) {
    return false;
  }
  if (isNonSubscriptionRecurringPayment(name)) return true;
  // 1. Demat / Broker / Trading / Investment / SIP / Mutual funds are money movements, NEVER subscriptions
  if (_brokerWords.hasMatch(lower)) {
    return true;
  }
  // 2. Fuel fill-ups and petrol pumps are variable spends, not subscriptions
  if (_fuelWords.hasMatch(lower)) {
    return true;
  }
  // 3. Raw UPI VPAs containing '@' are peer/merchant transfer handles, not
  // subscriptions, unless a mandate message itself named that handle as the
  // payee (a cancel notice that only says who the mandate was with).
  if (name.contains('@') && !mandateBacked) {
    return true;
  }
  // 3b. A card-bill AutoPay ("SI-TAD": total amount due, "MAD": minimum due)
  // and a lender's EMI debit are bills and loans, never services.
  if (_billOrLenderWords.hasMatch(lower)) {
    return true;
  }
  // 4. Retail stores, supermarkets, grocery, provisions, tea stall, cafes, bakeries, restaurants, medical, vending
  if (_shopWords.hasMatch(lower)) {
    return true;
  }
  return false;
}

bool isDisplayableSubscription(RecurringSeries series) {
  final name = series.displayName.trim();
  if (name.length < 2 || !_hasLetters.hasMatch(name)) {
    return false;
  }
  if (isExcludedNonSubscription(
    name,
    mandateBacked: series.isMandate && series.setupConfirmed,
  )) {
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
      .replaceAll(_nonAlphanumeric, ' ')
      .trim();
  return !_genericPlanName.hasMatch(normalized);
}

/// Where a subscription stands, in the three words a person uses. Every screen
/// reads this one function, so a service is never "active" on one page and
/// "cancelled" on another.
enum SubscriptionPhase {
  /// Still billing (including one whose last payment failed — see
  /// [subscriptionHasPaymentIssue]).
  active,

  /// The mandate is paused: nothing is being charged and nothing is upcoming.
  paused,

  /// Cancelled, expired, or no charge for well over its cycle.
  past,
}

/// A series' status as the lists group it: the lifecycle when it says more than
/// "active", else the report's own status.
String subscriptionListStatus(RecurringSeries series) {
  final lifecycle = series.lifecycleStatus.trim().toLowerCase();
  if (lifecycle.isNotEmpty && lifecycle != 'active') return lifecycle;
  return series.status;
}

/// The phase of [series], from the lifecycle the ledger computed (cancelled,
/// paused, lapsed, failed_payment, active) and, for reports from older sources,
/// the legacy engine states.
SubscriptionPhase subscriptionPhase(RecurringSeries series) {
  switch (series.lifecycleStatus.trim().toLowerCase()) {
    case 'cancelled':
    case 'canceled':
    case 'ended':
    case 'expired':
    case 'lapsed':
    case 'revoked':
      return SubscriptionPhase.past;
    case 'paused':
      return SubscriptionPhase.paused;
  }
  // An older source never set a lifecycle; its engine says "at risk" when a
  // series has gone more than one and a half cycles without a charge.
  final engine = (series.engineStatus ?? '').trim().toLowerCase();
  if (engine == 'at_risk' || engine == 'ended') return SubscriptionPhase.past;
  if (engine == 'paused') return SubscriptionPhase.paused;
  return SubscriptionPhase.active;
}

/// A failed debit is a problem with a live subscription, not the end of it.
bool subscriptionHasPaymentIssue(RecurringSeries series) {
  final lifecycle = series.lifecycleStatus.trim().toLowerCase();
  final engine = (series.engineStatus ?? '').trim().toLowerCase();
  return lifecycle == 'failed_payment' ||
      lifecycle == 'payment_issue' ||
      engine == 'payment_issue';
}

int _phaseRank(RecurringSeries s) => switch (subscriptionPhase(s)) {
  SubscriptionPhase.active => 0,
  SubscriptionPhase.paused => 1,
  SubscriptionPhase.past => 2,
};

/// The subscriptions to list, and the recurring charges that are only possible
/// subscriptions (found by rhythm, not confirmed by a mandate).
class SubscriptionView {
  const SubscriptionView(this.subscriptions, this.candidates);

  final List<RecurringSeries> subscriptions;
  final List<RecurringSeries> candidates;

  List<RecurringSeries> inPhase(SubscriptionPhase phase) => [
    for (final s in subscriptions)
      if (subscriptionPhase(s) == phase) s,
  ];

  /// Still billing: what the totals, reminders and headlines may count.
  List<RecurringSeries> get active => inPhase(SubscriptionPhase.active);

  /// The active ones that are proven (a setup, a confirmed cycle, or a payment
  /// that failed): the only ones whose cost is a figure to show.
  List<RecurringSeries> get billing => [
    for (final s in active)
      if (s.setupConfirmed ||
          subscriptionListStatus(s) == 'confirmed' ||
          subscriptionListStatus(s) == 'active' ||
          subscriptionHasPaymentIssue(s))
        s,
  ];

  /// What the Subscriptions page, the Insights tile and the reminders call "the
  /// yearly cost": the sum over [billing]. One definition, so the screens agree.
  Money get billingAnnual => billing.fold<Money>(
    Money.zero(),
    (sum, s) => sum + s.annualCost,
  );
  List<RecurringSeries> get paused => inPhase(SubscriptionPhase.paused);
  List<RecurringSeries> get past => inPhase(SubscriptionPhase.past);
}

/// One service seen twice (two cards, a mandate and a pattern, a server row and
/// a local one) is one row. The row that is most alive leads — an active plan
/// must not be hidden behind an old cancelled mandate of the same service — and
/// the other fills only what the leader lacks.
RecurringSeries _mergeSameService(
  RecurringSeries existing,
  RecurringSeries incoming,
) {
  final incomingLeads = _phaseRank(incoming) < _phaseRank(existing) ||
      (_phaseRank(incoming) == _phaseRank(existing) &&
          incoming.occurrenceCount > existing.occurrenceCount);
  final lead = incomingLeads ? incoming : existing;
  final other = incomingLeads ? existing : incoming;
  final bestName =
      namedServiceAutoPayName(lead.displayName) ??
      namedServiceAutoPayName(other.displayName) ??
      lead.displayName;
  DateTime? later(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null || a.isAfter(b) ? a : b);
  return lead.copyWith(
    displayName: bestName,
    autopayLimit: lead.autopayLimit ?? other.autopayLimit,
    startDate: lead.startDate ?? other.startDate,
    endDate: lead.endDate ?? other.endDate,
    paymentMethod: lead.paymentMethod ?? other.paymentMethod,
    typicalAmount: (lead.amountKnown && lead.typicalAmount.paise > 0)
        ? lead.typicalAmount
        : other.typicalAmount,
    amountKnown: lead.amountKnown || other.amountKnown,
    annualCost: lead.annualCost.paise > 0 ? lead.annualCost : other.annualCost,
    occurrenceCount: lead.occurrenceCount > other.occurrenceCount
        ? lead.occurrenceCount
        : other.occurrenceCount,
    lastSeenOn: later(lead.lastSeenOn, other.lastSeenOn),
    cadenceDays: lead.cadenceDays > 0 ? lead.cadenceDays : other.cadenceDays,
    setupConfirmed: lead.setupConfirmed || other.setupConfirmed,
    cadenceConfirmed: lead.cadenceConfirmed || other.cadenceConfirmed,
  );
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
      uniqueSubscriptionsMap[k] = existing == null
          ? normalizedItem
          : _mergeSameService(existing, normalizedItem);
    }
    final subscriptions = uniqueSubscriptionsMap.values.toList(
      growable: false,
    );
    final rawCandidates = series
        .where((series) => series.reviewCandidate)
        .where((series) => series.displayName.trim().length >= 2)
        // A rhythm found by repetition needs a monthly-or-slower cycle; one the
        // pipeline can explain in words (an announced mandate, an unnamed
        // AutoPay) is asked about whatever its cycle.
        .where(
          (series) => series.reviewReason != null || series.cadenceDays >= 20,
        )
        // A rhythm that stopped is not worth asking the person to review.
        .where((series) => subscriptionPhase(series) == SubscriptionPhase.active)
        .where(
          (series) => !isExcludedNonSubscription(
            series.displayName,
            mandateBacked: series.isMandate,
          ),
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

/// The yearly cost on the Insights hub tile ("₹7,788/yr"), or null when no
/// service is billing. It is [SubscriptionView.billingAnnual] of the same
/// [buildSubscriptionView] the Subscriptions page uses, so the tile and the page
/// total can never differ.
String? subscriptionTileHeadline(RecurringReport? report) {
  if (report == null) return null;
  final total = buildSubscriptionView(report.series).billingAnnual;
  return total.paise <= 0 ? null : '${total.format(compact: true)}/yr';
}
