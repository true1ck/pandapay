import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/providers.dart';
import '../insights/payments_due_screen.dart' show paymentsDueProvider;

/// UA-8.3 (B3) — the trigger side of the notification system: given the
/// data each per-screen provider already computes for its own UI, decide
/// whether any of the 7 trackable conditions is newly true and, if so, ask
/// NotificationGate to fire it. Deliberately reuses each screen's existing
/// provider rather than re-deriving the same numbers a second time —
/// FeeWaiversScreen/BillingFloatScreen/PointsExpiryScreen/PaymentsDueScreen/
/// MonthlySavingsScreen/NeedsReviewScreen all already compute exactly the
/// state these checks need.
///
/// No push/cron infrastructure exists for this app (see
/// GeofenceMonitorService's own doc-comment on the same constraint) — these
/// checks only ever run while the app process is alive, on foreground/
/// resume and after a transaction-affecting sync (see
/// notificationTriggerLifecycleProvider in providers.dart). That is a real,
/// honest limitation, not a "real-time push" promise — same posture as
/// geofencing's own "does not survive force-kill/reboot" note.
class NotificationTriggerRunner {
  final Ref ref;
  const NotificationTriggerRunner(this.ref);

  Future<void> runAll() async {
    // Independent try/catches: one failing check (e.g. a transient error
    // reading a provider that hasn't resolved yet) must never block the
    // other six.
    await _tryRun(_checkCaps);
    await _tryRun(_checkMilestones);
    await _tryRun(_checkFeeWaivers);
    await _tryRun(_checkBillsDue);
    await _tryRun(_checkPointsExpiry);
    await _tryRun(_checkMonthlyReport);
    await _tryRun(_checkNeedsReview);
  }

  Future<void> _tryRun(Future<void> Function() check) async {
    try {
      await check();
    } catch (_) {
      // Best-effort — see class doc-comment.
    }
  }

  String _displayName(String? nickname, String fallback) =>
      nickname?.isNotEmpty == true ? nickname! : fallback;

  /// Cap period start isn't exposed to the client (UserCard.capConsumed is
  /// just "consumed so far this period," with no period-start date) — this
  /// buckets by calendar period as an honest approximation, same "up to"
  /// posture BillingFloatScreen's own assumedGracePeriodDays takes with a
  /// number this schema doesn't capture precisely. Good enough to stop a
  /// cap warning from being silently deduped forever once a new period
  /// starts; pure and unit-testable on its own.
  static String capPeriodBucket(CapPeriod period, DateTime now) {
    switch (period) {
      case CapPeriod.statementCycle:
      case CapPeriod.calendarMonth:
        return '${now.year}-${now.month}';
      case CapPeriod.quarter:
        return '${now.year}-Q${((now.month - 1) ~/ 3) + 1}';
      case CapPeriod.halfYear:
        return '${now.year}-H${now.month <= 6 ? 1 : 2}';
      case CapPeriod.annual:
        return '${now.year}';
      case CapPeriod.lifetime:
        return 'lifetime';
    }
  }

  Future<void> _checkCaps() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    final now = DateTime.now();
    for (final (userCard, product) in owned) {
      for (final cap in product.capRules) {
        final consumed = userCard.capConsumed[cap.id] ?? const Money.zero();
        final ratio = capRatio(consumed, cap.capValue);
        if (ratio < 0.8) continue;
        final name = _displayName(userCard.nickname, product.name);
        final reached = ratio >= 1.0;
        final bucket = capPeriodBucket(cap.period, now);
        await gate.fire(
          category: 'caps',
          title: reached ? '$name cap reached' : '$name is close to its cap',
          body: reached
              ? 'You\'ve used up this period\'s "${cap.label}" cap — extra spend here won\'t earn the bonus rate.'
              : 'You\'ve used ${(ratio * 100).round()}% of $name\'s "${cap.label}" cap this period.',
          dedupeKey: 'cap:${userCard.id}:${cap.id}:$bucket:${reached ? 'reached' : 'warning'}',
        );
      }
    }
  }

  Future<void> _checkMilestones() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final (userCard, product) in owned) {
      for (final milestone in product.milestoneRules) {
        final progress = userCard.milestoneQualifiedSpend[milestone.id] ?? const Money.zero();
        final ratio = capRatio(progress, milestone.thresholdSpend);
        if (ratio < 0.8) continue;
        final name = _displayName(userCard.nickname, product.name);
        final completed = ratio >= 1.0;
        final periodEnd = userCard.milestonePeriodEnd[milestone.id];
        final bucket = periodEnd == null ? 'nodeadline' : periodEnd.toIso8601String().substring(0, 10);
        await gate.fire(
          category: 'milestones',
          title: completed
              ? '"${milestone.label}" milestone completed on $name'
              : '"${milestone.label}" is close on $name',
          body: completed
              ? 'You\'ve unlocked ${milestone.rewardValue.format()}.'
              : '${(ratio * 100).round()}% of the way to ${milestone.rewardValue.format()} on $name.',
          dedupeKey: 'milestone:${userCard.id}:${milestone.id}:$bucket:${completed ? 'completed' : 'warning'}',
        );
      }
    }
  }

  Future<void> _checkFeeWaivers() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final (userCard, product) in owned) {
      for (final fw in userCard.feeWaiverStates) {
        if (fw.waivedAt != null) continue;
        // Same ratio >= 0.9 "worth a nudge" threshold FeeWaiversScreen
        // already shows as its amber warning icon — kept consistent rather
        // than inventing a second threshold for the same signal.
        final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
        if (ratio < 0.9) continue;
        final name = _displayName(userCard.nickname, product.name);
        await gate.fire(
          category: 'fee_waivers',
          title: 'Almost there on $name\'s fee waiver',
          body:
              'You\'ve spent ${(ratio * 100).round()}% of what\'s needed to waive '
              '${fw.waivesFee.format()} — keep going before the period ends.',
          dedupeKey: 'fee_waiver:${userCard.id}:${fw.feeWaiverRuleId}:${fw.periodEnd.toIso8601String().substring(0, 10)}',
        );
      }
    }
  }

  Future<void> _checkBillsDue() async {
    final due = ref.read(paymentsDueProvider).valueOrNull;
    if (due == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final row in due) {
      // Same daysUntilDue <= 5 "urgent" window PaymentsDueScreen's hero
      // card already uses; only for cards autopay doesn't fully cover.
      if (row.daysUntilDue > 5 || row.daysUntilDue < 0 || !row.needsAttention) continue;
      final name = _displayName(row.card.nickname, row.card.cardName);
      await gate.fire(
        category: 'bills',
        title: row.daysUntilDue == 0 ? '$name payment due today' : '$name payment due in ${row.daysUntilDue} days',
        body:
            'You\'ve logged ${row.loggedThisCycle.format()} on this card this cycle — '
            'your issuer\'s statement may be higher.',
        dedupeKey: 'bill_due:${row.card.id}:${row.dueOn.toIso8601String().substring(0, 10)}',
      );
    }
  }

  Future<void> _checkPointsExpiry() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final (userCard, product) in owned) {
      final ledger = ref.read(pointsLedgerProvider(userCard.id)).valueOrNull;
      if (ledger == null) continue;
      final withExpiry = ledger.where((e) => e.expiresOn != null).toList()
        ..sort((a, b) => a.expiresOn!.compareTo(b.expiresOn!));
      if (withExpiry.isEmpty) continue;
      final nearest = withExpiry.first;
      // Same daysLeft <= 30 "urgent" window PointsExpiryScreen's own
      // _ExpiryChip already uses.
      final days = daysUntil(nearest.expiresOn!, DateTime.now());
      if (days > 30 || days < 0) continue;
      final name = _displayName(userCard.nickname, product.name);
      await gate.fire(
        category: 'expiry',
        title: '$name points expiring soon',
        body: '${nearest.deltaPoints.toStringAsFixed(0)} points expire in $days days.',
        dedupeKey: 'points_expiry:${userCard.id}:${nearest.expiresOn!.toIso8601String().substring(0, 10)}',
      );
    }
  }

  Future<void> _checkMonthlyReport() async {
    final report = ref.read(currentMonthlyReportProvider).valueOrNull;
    if (report == null || report.totalSpend.isZero) return; // nothing worth telling the user about yet
    final gate = ref.read(notificationGateProvider);
    final monthLabel = DateFormat('MMMM yyyy').format(report.periodMonth);
    await gate.fire(
      category: 'monthly_report',
      title: 'Your $monthLabel report is ready',
      body: report.extraEarned.isZero || report.extraEarned.isNegative
          ? 'See how your cards performed this month.'
          : 'You earned an extra ${report.extraEarned.format()} by using the right card.',
      dedupeKey: 'monthly_report:${report.periodMonth.year}-${report.periodMonth.month}',
    );
  }

  Future<void> _checkNeedsReview() async {
    final count = ref.read(needsReviewCountProvider);
    if (count <= 0) return;
    final gate = ref.read(notificationGateProvider);
    await gate.fire(
      category: 'needs_review',
      title: count == 1 ? '1 transaction needs review' : '$count transactions need review',
      body: 'A message didn\'t match automatically — check Needs Review to fill it in.',
      // Keyed by the count itself so a growing queue notifies again as it
      // grows, not just once ever — see the class doc-comment for why
      // there's no earlier/later comparison available to do this more
      // precisely without a push/cron backend.
      dedupeKey: 'needs_review:$count',
    );
  }
}
