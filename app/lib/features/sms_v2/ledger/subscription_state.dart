// What the phone keeps about each subscription, and how a stored row becomes
// the `RecurringSeries` every screen shows.
//
// A subscription is derived from the whole SMS ledger (mandates, charges,
// failures, announcements), which is O(history). So it is derived once, when
// the ledger changes, and saved as plain rows (`SubscriptionStore`). A screen
// then reads a few rows and calls [seriesFromSubscriptionStates], which does only
// small arithmetic. Everything that depends on "today" (is it past? is the
// next charge late?) is decided here at read time from the saved dates, never
// frozen into the row, so a plan that simply stopped charging turns past
// without any new message arriving.
import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../../../data/spend_reports_repository.dart';

/// Where a subscription row came from.
enum SubscriptionStateKind {
  /// A mandate / setup / cancel message, and the charges that joined it.
  mandate,

  /// No mandate message: found by the same amount repeating on a rhythm.
  pattern,

  /// No mandate message and no debit: only announcements that one is coming.
  notice,
}

class SubscriptionState {
  const SubscriptionState({
    required this.kind,
    required this.key,
    required this.name,
    this.cadence = 0,
    this.chargeCount = 0,
    this.firstChargeAt,
    this.lastChargeAt,
    this.lastAmountMinor,
    this.currency = 'INR',
    this.ceilingMinor,
    this.latestPhase,
    this.latestPhaseAt,
    this.firstMandateAt,
    this.mandateReference,
    this.lastFailureAt,
    this.dueAts = const [],
    this.sourceKey,
    this.annualFactor,
    this.reviewReason,
    this.unnamed = false,
  });

  final SubscriptionStateKind kind;

  /// The merged service key; the series id is `v2:<key>` (`v2:pattern:<key>`,
  /// `v2:notice:<key>` for the other two kinds).
  final String key;
  final String name;

  /// Days between charges: the mandate's stated frequency, else the median gap.
  final int cadence;
  final int chargeCount;
  final DateTime? firstChargeAt;
  final DateTime? lastChargeAt;

  /// The last charge (or last announced debit) in minor units of [currency].
  final int? lastAmountMinor;
  final String currency;

  /// The most the mandate allows per debit.
  final int? ceilingMinor;

  /// The newest mandate message: `created`, `modified`, `paused`, `resumed`,
  /// `revoked` or `expired`, and when it was sent.
  final String? latestPhase;
  final DateTime? latestPhaseAt;
  final DateTime? firstMandateAt;
  final String? mandateReference;
  final DateTime? lastFailureAt;

  /// Dates a debit was announced for (newest last, at most [maxDueAts]).
  final List<DateTime> dueAts;
  final String? sourceKey;

  /// Charges a year, for a rhythm found by repetition (12 monthly, 52 weekly).
  final int? annualFactor;
  final String? reviewReason;

  /// A mandate whose service name was never read, with no charge.
  final bool unnamed;

  static const int maxDueAts = 6;

  String get seriesId => switch (kind) {
    SubscriptionStateKind.mandate => 'v2:$key',
    SubscriptionStateKind.pattern => 'v2:pattern:$key',
    SubscriptionStateKind.notice => 'v2:notice:$key',
  };

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'key': key,
    'name': name,
    'cadence': cadence,
    'chargeCount': chargeCount,
    if (firstChargeAt != null) 'firstChargeAt': firstChargeAt!.toUtc().toIso8601String(),
    if (lastChargeAt != null) 'lastChargeAt': lastChargeAt!.toUtc().toIso8601String(),
    if (lastAmountMinor != null) 'lastAmountMinor': lastAmountMinor,
    'currency': currency,
    if (ceilingMinor != null) 'ceilingMinor': ceilingMinor,
    if (latestPhase != null) 'latestPhase': latestPhase,
    if (latestPhaseAt != null) 'latestPhaseAt': latestPhaseAt!.toUtc().toIso8601String(),
    if (firstMandateAt != null) 'firstMandateAt': firstMandateAt!.toUtc().toIso8601String(),
    if (mandateReference != null) 'mandateReference': mandateReference,
    if (lastFailureAt != null) 'lastFailureAt': lastFailureAt!.toUtc().toIso8601String(),
    'dueAts': [for (final d in dueAts) d.toUtc().toIso8601String()],
    if (sourceKey != null) 'sourceKey': sourceKey,
    if (annualFactor != null) 'annualFactor': annualFactor,
    if (reviewReason != null) 'reviewReason': reviewReason,
    if (unnamed) 'unnamed': true,
  };

  static DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;

  factory SubscriptionState.fromJson(Map<String, Object?> j) => SubscriptionState(
    kind: SubscriptionStateKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => SubscriptionStateKind.mandate,
    ),
    key: j['key'] as String,
    name: j['name'] as String,
    cadence: (j['cadence'] as num?)?.toInt() ?? 0,
    chargeCount: (j['chargeCount'] as num?)?.toInt() ?? 0,
    firstChargeAt: _date(j['firstChargeAt']),
    lastChargeAt: _date(j['lastChargeAt']),
    lastAmountMinor: (j['lastAmountMinor'] as num?)?.toInt(),
    currency: j['currency'] as String? ?? 'INR',
    ceilingMinor: (j['ceilingMinor'] as num?)?.toInt(),
    latestPhase: j['latestPhase'] as String?,
    latestPhaseAt: _date(j['latestPhaseAt']),
    firstMandateAt: _date(j['firstMandateAt']),
    mandateReference: j['mandateReference'] as String?,
    lastFailureAt: _date(j['lastFailureAt']),
    dueAts: [
      for (final d in (j['dueAts'] as List? ?? const []))
        if (_date(d) case final parsed?) parsed,
    ],
    sourceKey: j['sourceKey'] as String?,
    annualFactor: (j['annualFactor'] as num?)?.toInt(),
    reviewReason: j['reviewReason'] as String?,
    unnamed: j['unnamed'] == true,
  );
}

/// Days after a missed charge date before a subscription is called past. Half a
/// cycle, kept between 4 and 30 days: a monthly plan whose charge is a week late
/// is still running, one that has missed a whole cycle and a half is not.
int lapseGraceDays(int cadence) => (cadence * 0.5).round().clamp(4, 30);

/// With no stated or measured schedule, a charge this old (longer than a
/// quarterly plan plus slack) no longer shows the service is still billing.
const unscheduledStaleDays = 100;

/// A mandate that has never charged and is older than this is not "awaiting its
/// first charge" any more: nothing was ever taken under it.
const neverChargedStaleDays = 100;

/// A debit posted this soon after a revoke or pause notice is that notice
/// settling, not proof the service carried on.
const settleGrace = Duration(days: 3);

/// Announcements this old (and nothing since) are history, not a live mandate.
const staleNoticeDays = 75;

/// A failed payment is current for a while; after that the plain question is
/// whether the service still bills.
int failureWindowDays(int cadence) => cadence * 2 > 60 ? cadence * 2 : 60;

/// The next charge after [date]: the same calendar day next month (or year) for
/// monthly and yearly plans, else [days] later. SMS date-only values are parsed
/// at midnight in India and stored in UTC, so the calendar math is done on the
/// Indian wall clock.
DateTime nextChargeAfter(DateTime date, int days) {
  final months = days >= 350 ? 12 : (days >= 26 && days <= 32 ? 1 : 0);
  if (months == 0) return date.add(Duration(days: days));
  const offset = Duration(hours: 5, minutes: 30);
  final wall = date.toUtc().add(offset);
  final month = wall.month + months;
  final max = DateTime.utc(wall.year, month + 1, 0).day;
  return DateTime.utc(
    wall.year,
    month,
    wall.day > max ? max : wall.day,
    wall.hour,
    wall.minute,
    wall.second,
    wall.millisecond,
    wall.microsecond,
  ).subtract(offset);
}

/// One honest state per subscription, read only from what the messages say:
/// `cancelled` (revoked, nothing charged since), `expired`, `paused` (same),
/// `failed_payment` (a recent failed debit with no later charge), `lapsed` (no
/// charge for well over its cycle, or never charged), else `active`.
///
/// A revoke or pause is superseded by a later charge, because the SMS that
/// would have said "resumed" can be missing while the money plainly moved.
String subscriptionLifecycleOf(
  SubscriptionState s,
  DateTime now, {
  DateTime? next,
  DateTime? announced,
}) {
  final lastCharge = s.lastChargeAt;
  bool chargedAfter(DateTime t) =>
      lastCharge != null && lastCharge.isAfter(t.add(settleGrace));
  final phaseAt = s.latestPhaseAt;
  if (s.latestPhase != null && phaseAt != null && !chargedAfter(phaseAt)) {
    if (s.latestPhase == 'revoked') return 'cancelled';
    if (s.latestPhase == 'expired') return 'expired';
    if (s.latestPhase == 'paused') return 'paused';
  }
  final failure = s.lastFailureAt;
  final failed =
      failure != null &&
      (lastCharge == null || failure.isAfter(lastCharge)) &&
      (phaseAt == null || !phaseAt.isAfter(failure)) &&
      now.difference(failure).inDays <= failureWindowDays(s.cadence);
  if (failed) return 'failed_payment';
  // The service itself announced an upcoming debit: it is live.
  if (announced != null) return 'active';
  if (lastCharge != null) {
    if (s.cadence > 0 && next != null) {
      return now.isAfter(next.add(Duration(days: lapseGraceDays(s.cadence))))
          ? 'lapsed'
          : 'active';
    }
    return now.difference(lastCharge).inDays > unscheduledStaleDays
        ? 'lapsed'
        : 'active';
  }
  // Never charged: awaiting the first debit only while the setup is recent.
  return phaseAt != null && now.difference(phaseAt).inDays > neverChargedStaleDays
      ? 'lapsed'
      : 'active';
}

/// The series for one stored row as of [now], or null when it should not be
/// listed at all (an unnamed AutoPay that is already stale or ended).
RecurringSeries? seriesFromSubscriptionState(SubscriptionState s, DateTime now) =>
    switch (s.kind) {
      SubscriptionStateKind.mandate => _mandateSeries(s, now),
      SubscriptionStateKind.pattern => _patternSeries(s, now),
      SubscriptionStateKind.notice => _noticeSeries(s, now),
    };

/// Every stored row as a series, sorted by name, as of [now].
List<RecurringSeries> seriesFromSubscriptionStates(
  Iterable<SubscriptionState> states,
  DateTime now,
) {
  final result = <RecurringSeries>[
    for (final s in states)
      if (seriesFromSubscriptionState(s, now) case final series?) series,
  ]..sort((a, b) => a.displayName.compareTo(b.displayName));
  return result;
}

RecurringSeries? _mandateSeries(SubscriptionState s, DateTime now) {
  final last = s.lastChargeAt;
  final next = last == null || s.cadence == 0
      ? null
      : nextChargeAfter(last, s.cadence);
  // A renewal the service announced ("will renew on 12 Nov") is a better guess
  // for the next charge than last charge plus cadence. It adds no charge and
  // no amount: an announcement is not money moved.
  final announced = ([
    for (final d in s.dueAts)
      if (d.isAfter(now) && (last == null || d.isAfter(last))) d,
  ]..sort()).firstOrNull;
  final lifecycle = subscriptionLifecycleOf(
    s,
    now,
    next: next,
    announced: announced,
  );
  final cancelled = lifecycle == 'cancelled' || lifecycle == 'expired';
  // Only a subscription that is still billing carries a renewal date. A
  // paused, cancelled or lapsed one must never be reminded about or listed
  // as upcoming.
  final billing = lifecycle == 'active' || lifecycle == 'failed_payment';
  // A mandate whose service name was never read, with no charge to show for
  // it, cannot be listed as a subscription. While it is recent a person is
  // asked what it is; once it is stale or ended there is nothing to ask.
  final unnamed = s.unnamed;
  if (unnamed && lifecycle != 'active') return null;
  final amount = s.lastAmountMinor;
  final cadence = s.cadence;
  final yearly = cadence == 0
      ? 0
      : cadence >= 26 && cadence <= 32
      ? 12
      : cadence >= 350
      ? 1
      : 365 / cadence;
  final hasMandate = s.latestPhase != null;
  return RecurringSeries(
    id: s.seriesId,
    displayName: s.name,
    typicalAmount: Money.fromPaise(amount ?? 0),
    amountKnown: amount != null,
    cadenceDays: cadence,
    occurrenceCount: s.chargeCount,
    annualCost: Money.fromPaise(amount == null ? 0 : (amount * yearly).round()),
    autopayLimit: s.ceilingMinor == null ? null : Money.fromPaise(s.ceilingMinor!),
    lastSeenOn: last,
    nextExpectedOn: billing ? (announced ?? next) : null,
    startDate: s.firstMandateAt ?? s.firstChargeAt,
    endDate: cancelled ? s.latestPhaseAt : null,
    lifecycleStatus: lifecycle,
    autopayStatus: cancelled ? 'cancelled' : s.latestPhase ?? 'unknown',
    isMandate: hasMandate,
    mandateReference: s.mandateReference,
    sourceKey: s.sourceKey,
    detectionSource: 'sms_v2',
    cadenceConfirmed: cadence > 0,
    setupConfirmed: hasMandate,
    // Say the state outright. Left null, the model derives "at risk" from a
    // renewal date a few days in the past, which is only a late charge.
    engineStatus: billing ? (cadence > 0 ? 'confirmed' : null) : lifecycle,
    reviewCandidate: unnamed,
    reviewReason: unnamed
        ? 'An AutoPay was set up but the message did not say for which service.'
        : null,
  );
}

RecurringSeries _patternSeries(SubscriptionState s, DateTime now) {
  final last = s.lastChargeAt!;
  final next = nextChargeAfter(last, s.cadence);
  final lapsed = now.isAfter(next.add(Duration(days: lapseGraceDays(s.cadence))));
  final foreign = s.currency != 'INR';
  final amount = foreign ? 0 : (s.lastAmountMinor ?? 0);
  return RecurringSeries(
    id: s.seriesId,
    displayName: s.name,
    typicalAmount: Money.fromPaise(amount),
    amountKnown: !foreign,
    cadenceDays: s.cadence,
    occurrenceCount: s.chargeCount,
    reviewReason: s.reviewReason,
    annualCost: Money.fromPaise((amount * (s.annualFactor ?? 12)).round()),
    autopayLimit: null,
    lastSeenOn: last,
    nextExpectedOn: lapsed ? null : next,
    startDate: s.firstChargeAt,
    endDate: null,
    lifecycleStatus: lapsed ? 'lapsed' : 'active',
    autopayStatus: 'unknown',
    isMandate: false,
    mandateReference: null,
    sourceKey: s.sourceKey,
    detectionSource: 'sms_v2_pattern',
    cadenceConfirmed: true,
    setupConfirmed: false,
    // Found by rhythm alone: listed under "Possible subscriptions" for the
    // person to confirm, never counted in totals or reminded about.
    reviewCandidate: true,
    engineStatus: lapsed ? 'lapsed' : 'confirmed',
  );
}

RecurringSeries _noticeSeries(SubscriptionState s, DateTime now) {
  final lastDue = s.dueAts.isEmpty ? null : s.dueAts.last;
  final stale = lastDue == null || now.difference(lastDue).inDays > staleNoticeDays;
  final amount = s.lastAmountMinor;
  return RecurringSeries(
    id: s.seriesId,
    displayName: s.name,
    typicalAmount: Money.fromPaise(amount ?? 0),
    amountKnown: amount != null,
    cadenceDays: s.cadence,
    occurrenceCount: 0,
    annualCost: const Money.zero(),
    lastSeenOn: null,
    nextExpectedOn: stale || lastDue.isBefore(now) ? null : lastDue,
    startDate: s.firstMandateAt,
    lifecycleStatus: stale ? 'lapsed' : 'active',
    autopayStatus: 'unknown',
    isMandate: true,
    sourceKey: s.sourceKey,
    detectionSource: 'sms_v2_notice',
    cadenceConfirmed: s.cadence > 0,
    setupConfirmed: false,
    reviewCandidate: true,
    reviewReason: s.reviewReason,
    engineStatus: stale ? 'lapsed' : 'confirmed',
  );
}
