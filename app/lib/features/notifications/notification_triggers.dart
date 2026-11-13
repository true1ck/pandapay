import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/display_text.dart';
import '../../app/providers.dart';
import '../../data/catalogue_repository.dart' show SpendCategory;
import '../../data/user_cards_repository.dart' show UserCard;
import '../cards/cap_progress.dart';
import '../cards/next_best_card.dart';
import '../insights/payments_due_screen.dart' show paymentsDueProvider;
import '../../data/spend_reports_repository.dart' show RecurringSeries;
import '../insights/subscription_view.dart' show buildSubscriptionView;
import '../sms_v2/providers/runtime_provider.dart' show smsV2RuntimeProvider;
import '../sms_v2/storage/schema.dart' show SmsV2Schema;
import '../sms_v2/storage/sync_state_store.dart' show SyncStateStore;
import '../sms_v2/sync/ai_status.dart' show AiStatusReader;

/// One cap notification, ready for `NotificationGate.fire`.
class CapAlert {
  final String title;
  final String body;
  final String dedupeKey;
  const CapAlert({
    required this.title,
    required this.body,
    required this.dedupeKey,
  });
}

/// UA-8.3 (B3) — the trigger side of the notification system: given the
/// data each per-screen provider already computes for its own UI, decide
/// whether any of the 7 trackable conditions is newly true and, if so, ask
/// NotificationGate to fire it. Deliberately reuses each screen's existing
/// provider rather than re-deriving the same numbers a second time —
/// FeeWaiversScreen/BillingFloatScreen/PointsExpiryScreen/BillsAndCommitmentsTab/
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
  bool _running = false;
  bool _rerunRequested = false;

  NotificationTriggerRunner(this.ref);

  Future<void> runAll() async {
    // SMS reconciliation invalidates several providers at once and can also
    // coincide with an app-resume callback. Do not let overlapping sweeps
    // observe different generations of the same report and race to deliver
    // two notifications.
    if (_running) {
      _rerunRequested = true;
      return;
    }
    _running = true;
    try {
      // Independent try/catches: one failing check (e.g. a transient error
      // reading a provider that hasn't resolved yet) must never block the
      // other six.
      await _tryRun(_checkCaps);
      await _tryRun(_checkMilestones);
      await _tryRun(_checkFeeWaivers);
      await _tryRun(_checkBillsDue);
      await _tryRun(_checkSubscriptions);
      await _tryRun(_checkPointsExpiry);
      await _tryRun(_checkMonthlyReport);
      await _tryRun(_checkNeedsReview);
      await _tryRun(_checkBudgets);
    } finally {
      _running = false;
      if (_rerunRequested) {
        _rerunRequested = false;
        await runAll();
      }
    }
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

  /// The 80% / 100% alerts for a v2-shaped card's caps (WP9).
  ///
  /// The ratio is `consumed_native / cap_amount`, never the v1 measure. A cap
  /// with no row (nothing consumed) or an unknown figure (no native number
  /// yet, or from a period that has ended) raises nothing: an alert must be
  /// something the app can stand behind. The dedupe bucket is the server's
  /// `period_start`, so a new period alerts again; the key shape is the v1
  /// one, so the gate's dedupe and budget apply unchanged. Each alert adds
  /// the next-best OWNED card for the cap's category ("Use X for Y instead"),
  /// and only when it earns more than base.
  static List<CapAlert> planV2CapAlerts({
    required UserCard userCard,
    required CardProduct product,
    required List<(UserCard, CardProduct)> owned,
    required List<SpendCategory> categories,
    required DateTime now,
  }) {
    final alerts = <CapAlert>[];
    final name = userCard.nickname?.isNotEmpty == true
        ? userCard.nickname!
        : product.name;
    for (final cap in product.capRules) {
      final progress = capProgressFor(
        product: product,
        cap: cap,
        owned: userCard,
        now: now,
      );
      final consumed = progress?.consumed;
      if (progress == null || consumed == null) continue;
      final ratio = consumed / progress.amount;
      if (ratio < 0.8) continue;
      final reached = ratio >= 1.0;
      final start = progress.usage.row?.periodStart;
      final bucket = start == null
          ? capPeriodBucket(cap.period, now)
          : '${start.year}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
      final label = capRuleDisplayLabel(cap);
      final next = nextBestOwnedCard(
        owned: owned,
        cappedCard: userCard,
        cappedProduct: product,
        cap: cap,
        categories: categories,
        now: now,
      );
      final suffix = next == null ? '' : ' ${next.message}.';
      alerts.add(
        CapAlert(
          title: reached ? '$name cap reached' : '$name is close to its cap',
          body: reached
              ? 'You\'ve used up this period\'s "$label" — ${progress.reachedConsequence}.$suffix'
              : 'You\'ve used ${percentFloor(ratio)}% of $name\'s "$label" this period.$suffix',
          dedupeKey:
              'cap:${userCard.id}:${cap.id}:$bucket:${reached ? 'reached' : 'warning'}',
        ),
      );
    }
    return alerts;
  }

  /// Runs only the cap check (tests).
  @visibleForTesting
  Future<void> runCapChecks() => _checkCaps();

  Future<void> _checkCaps() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    final now = ref.read(clockProvider).now();
    final categories =
        ref.read(categoriesProvider).valueOrNull ?? const <SpendCategory>[];
    for (final (userCard, product) in owned) {
      if (product.isV2Shaped) {
        for (final alert in planV2CapAlerts(
          userCard: userCard,
          product: product,
          owned: owned,
          categories: categories,
          now: now,
        )) {
          await gate.fire(
            category: 'caps',
            title: alert.title,
            body: alert.body,
            dedupeKey: alert.dedupeKey,
          );
        }
        continue;
      }
      for (final cap in uniqueCapRules(product.capRules)) {
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
              ? 'You\'ve used up this period\'s "${capRuleDisplayLabel(cap)}" — extra spend here won\'t earn the bonus rate.'
              : 'You\'ve used ${(ratio * 100).round()}% of $name\'s "${capRuleDisplayLabel(cap)}" this period.',
          dedupeKey:
              'cap:${userCard.id}:${cap.id}:$bucket:${reached ? 'reached' : 'warning'}',
        );
      }
    }
  }

  Future<void> _checkMilestones() async {
    final owned = ref.read(ownedCardsWithProductProvider).valueOrNull;
    if (owned == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final (userCard, product) in owned) {
      for (final milestone in uniqueMilestoneRules(product.milestoneRules)) {
        final progress =
            userCard.milestoneQualifiedSpend[milestone.id] ??
            const Money.zero();
        final ratio = capRatio(progress, milestone.thresholdSpend);
        if (ratio < 0.8) continue;
        final name = _displayName(userCard.nickname, product.name);
        final completed = ratio >= 1.0;
        final periodEnd = userCard.milestonePeriodEnd[milestone.id];
        final bucket = periodEnd == null
            ? 'nodeadline'
            : periodEnd.toIso8601String().substring(0, 10);
        await gate.fire(
          category: 'milestones',
          title: completed
              ? '"${humanizeIdentifier(milestone.label)}" milestone completed on $name'
              : '"${humanizeIdentifier(milestone.label)}" is close on $name',
          body: completed
              ? 'You\'ve unlocked ${milestone.rewardValue.format()}.'
              : '${(ratio * 100).round()}% of the way to ${milestone.rewardValue.format()} on $name.',
          dedupeKey:
              'milestone:${userCard.id}:${milestone.id}:$bucket:${completed ? 'completed' : 'warning'}',
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
          dedupeKey:
              'fee_waiver:${userCard.id}:${fw.feeWaiverRuleId}:${fw.periodEnd.toIso8601String().substring(0, 10)}',
        );
      }
    }
  }

  Future<void> _checkBillsDue() async {
    final due = ref.read(paymentsDueProvider).valueOrNull;
    if (due == null) return;
    final gate = ref.read(notificationGateProvider);
    for (final row in due) {
      // Same daysUntilDue <= 5 "urgent" window the Bills & commitments tab
      // already uses; only for cards autopay doesn't fully cover.
      if (row.daysUntilDue > 5 || row.daysUntilDue < 0 || !row.needsAttention) {
        continue;
      }
      final name = _displayName(row.card.nickname, row.card.cardName);
      await gate.fire(
        category: 'bills',
        title: row.daysUntilDue == 0
            ? '$name payment due today'
            : '$name payment due in ${row.daysUntilDue} days',
        body:
            'You\'ve logged ${row.loggedThisCycle.format()} on this card this cycle — '
            'your issuer\'s statement may be higher.',
        dedupeKey:
            'bill_due:${row.card.id}:${row.dueOn.toIso8601String().substring(0, 10)}',
      );
    }
  }

  /// A calendar day, for comparing days. A date-only SMS is midnight in India,
  /// stored as 18:30 UTC the evening before, so the day is read in local time:
  /// reading the UTC fields would remind a day early.
  static DateTime _localDay(DateTime instant) {
    final local = instant.toLocal();
    return DateTime.utc(local.year, local.month, local.day);
  }

  /// Catch up the early reminder if the app was not opened exactly three
  /// days before renewal. The final reminder has a separate dedupe bucket.
  static int? subscriptionReminderStage(DateTime renewal, DateTime now) {
    final days = _localDay(renewal).difference(_localDay(now)).inDays;
    if (days == 1) return 1;
    if (days == 2 || days == 3) return 3;
    return null;
  }

  /// The subscriptions to remind about today, each with its stage (1: renews
  /// tomorrow, 3: renews in two or three days). Only what the Subscriptions page
  /// lists as still billing ([buildSubscriptionView]) is eligible, so a telecom,
  /// lender or insurance row, a possible subscription, or a paused or cancelled
  /// plan never gets a "renews tomorrow" notice.
  @visibleForTesting
  static List<(RecurringSeries, int)> subscriptionsDueForReminder(
    Iterable<RecurringSeries> series,
    DateTime now,
  ) {
    final due = <(RecurringSeries, int)>[];
    for (final s in buildSubscriptionView(series).active) {
      final renewal = s.nextExpectedOn;
      if (renewal == null || s.typicalAmount.paise <= 0) continue;
      final stage = subscriptionReminderStage(renewal, now);
      if (stage != null) due.add((s, stage));
    }
    return due;
  }

  Future<void> _checkSubscriptions() async {
    final report = await ref.read(recurringReportProvider.future);
    if (report == null) return;
    final now = DateTime.now();
    final gate = ref.read(notificationGateProvider);
    for (final (series, stage) in subscriptionsDueForReminder(
      report.series,
      now,
    )) {
      final renewal = series.nextExpectedOn!.toLocal();
      final date = DateFormat('yyyy-MM-dd').format(renewal);
      final when = stage == 1
          ? 'tomorrow'
          : 'in ${_localDay(renewal).difference(_localDay(now)).inDays} days';
      await gate.fire(
        category: 'bills',
        title: '${series.displayName} subscription renews $when',
        body:
            'About ${series.typicalAmount.format()} is expected to be deducted '
            'on ${DateFormat('d MMM yyyy').format(renewal)}. '
            'Review your subscription and cancel with the provider before renewal if you no longer want it.',
        deepLink: '/insights/subscriptions',
        dedupeKey: 'subscription_due:${series.id}:$date:$stage',
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
        body:
            '${nearest.deltaPoints.toStringAsFixed(0)} points expire in $days days.',
        dedupeKey:
            'points_expiry:${userCard.id}:${nearest.expiresOn!.toIso8601String().substring(0, 10)}',
      );
    }
  }

  Future<void> _checkMonthlyReport() async {
    final report = ref.read(currentMonthlyReportProvider).valueOrNull;
    if (report == null || report.totalSpend.isZero) {
      return; // nothing worth telling the user about yet
    }
    final gate = ref.read(notificationGateProvider);
    final monthLabel = DateFormat('MMMM yyyy').format(report.periodMonth);
    await gate.fire(
      category: 'monthly_report',
      title: 'Your $monthLabel report is ready',
      body: report.extraEarned.isZero || report.extraEarned.isNegative
          ? 'See how your cards performed this month.'
          : 'You earned an extra ${report.extraEarned.format()} by using the right card.',
      dedupeKey:
          'monthly_report:${report.periodMonth.year}-${report.periodMonth.month}',
    );
  }

  static const _lastNotifiedKey = 'needs_review_last_notified_count_v1';
  static const _needsReviewNotificationId = 0x4e52;

  /// How often the background watch re-checks, and how long it keeps trying
  /// before it tells the user anyway (e.g. an AI layout that never answers).
  static const _watchEvery = Duration(minutes: 2);
  static const _watchGiveUp = Duration(minutes: 20);

  /// The app counts as "in use" unless the OS has actually sent it to the
  /// background. Overridable for tests.
  @visibleForTesting
  bool Function() isForeground = () {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null ||
        s == AppLifecycleState.resumed ||
        s == AppLifecycleState.inactive;
  };

  Timer? _watch;
  DateTime? _watchSince;
  bool _watchBusy = false;

  /// Called when the app goes to the background: the user has stopped looking,
  /// so this is the earliest moment a "needs review" summary is welcome.
  void onBackgrounded() => unawaited(_tryRun(_checkNeedsReview));

  void onForegrounded() => _stopWatch();

  void dispose() => _stopWatch();

  void _startWatch() {
    if (_watch != null) return;
    _watchSince = DateTime.now();
    _watch = Timer.periodic(_watchEvery, (_) => unawaited(_watchTick()));
  }

  void _stopWatch() {
    _watch?.cancel();
    _watch = null;
    _watchSince = null;
  }

  bool get _watchExpired =>
      _watchSince != null &&
      DateTime.now().difference(_watchSince!) > _watchGiveUp;

  Future<void> _watchTick() async {
    if (_watchBusy) return;
    _watchBusy = true;
    try {
      if (isForeground()) {
        _stopWatch();
        return;
      }
      // Pull the AI's answers and finish any pending reading while the app is
      // away, so the count we announce is the final one.
      try {
        final runtime = await ref.read(smsV2RuntimeProvider.future);
        await runtime?.sync();
      } catch (_) {}
      await _tryRun(_checkNeedsReview);
    } finally {
      _watchBusy = false;
    }
  }

  /// True once nothing is still producing review items: the inbox scan and
  /// upload have finished, no captured message is waiting to be read, and no
  /// unreadable layout is still with the AI.
  Future<bool> _pipelineSettled() async {
    if (ref.read(smsAutoImportProvider).isBusy) return false;
    final runtime = await ref.read(smsV2RuntimeProvider.future);
    if (runtime == null) return true;
    if (runtime.isBusy || runtime.pendingIntake > 0) return false;
    final cache = await ref.read(responseCacheProvider.future);
    final db = cache.financialStore.database.db;
    SmsV2Schema.ensure(db);
    final reader = AiStatusReader(
      SyncStateStore(db, namespace: ref.read(cacheNamespaceProvider)),
    );
    return !reader.hasChecking();
  }

  /// One "N transactions need review" notification per finished import.
  ///
  /// It is held back while the app is open (the badge already shows the
  /// number there) and while the pipeline — scan, upload, Gemini drafting —
  /// is still changing the count. Once the app is in the background it waits
  /// for that work to settle, then sends a single notification with a fixed
  /// id so it replaces, rather than stacks on, an earlier one. A queue that
  /// only shrinks (the AI resolved some) never notifies again.
  Future<void> _checkNeedsReview() async {
    final count = await ref.read(needsReviewCountProvider.future);
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getInt(_lastNotifiedKey) ?? 0;
    if (count <= 0) {
      if (last != 0) await prefs.setInt(_lastNotifiedKey, 0);
      _stopWatch();
      return;
    }
    if (count <= last) {
      // Queue shrank or is unchanged since the last announcement: lower the
      // baseline so later growth is announced, but say nothing now.
      if (count < last) await prefs.setInt(_lastNotifiedKey, count);
      _stopWatch();
      return;
    }
    if (isForeground()) return;
    if (!_watchExpired && !await _pipelineSettled()) {
      _startWatch();
      return;
    }
    _stopWatch();
    // Re-read: the count can move while we were checking the pipeline.
    final finalCount = await ref.read(needsReviewCountProvider.future);
    if (finalCount <= last) return;
    final now = DateTime.now();
    final fired = await ref.read(notificationGateProvider).fire(
      category: 'needs_review',
      title: finalCount == 1
          ? '1 transaction needs review'
          : '$finalCount transactions need review',
      body:
          'A message didn\'t match automatically — check Needs Review to fill it in.',
      dedupeKey:
          'needs_review:$finalCount:${now.year}-${now.month}-${now.day}',
      notificationId: _needsReviewNotificationId,
    );
    if (fired) await prefs.setInt(_lastNotifiedKey, finalCount);
  }

  /// Budget warnings — the only trigger the user set the threshold for
  /// themselves.
  ///
  /// Two distinct events, not one. "Over budget" on the 30th is a
  /// post-mortem; "ahead of pace" on the 12th is something you can still
  /// act on, and it is the one that earns this notification its place.
  /// [BudgetStatus.isOffPace] carries a 5% margin so an ordinary purchase
  /// doesn't tip a budget into warning and straight back out — an alert
  /// that fires on noise is one people learn to dismiss without reading.
  ///
  /// The dedupe key includes the period start, so each period gets one
  /// warning and one over-budget alert rather than the same message every
  /// time the app is opened.
  Future<void> _checkBudgets() async {
    // valueOrNull can expose the previous value while an invalidated
    // FutureProvider is loading. Await the current request so a fresh SMS
    // sync cannot immediately trigger a push containing an old total.
    final budgets = await ref.read(budgetsProvider.future);
    final flagged = budgets.where((b) => b.isOver || b.isOffPace).toList()
      ..sort((a, b) {
        if (a.isOver != b.isOver) return a.isOver ? -1 : 1;
        return b.consumedFraction.compareTo(a.consumedFraction);
      });
    if (flagged.isEmpty) return;
    final gate = ref.read(notificationGateProvider);

    for (final budget in flagged) {
      final periodKey =
          '${budget.periodStart.year}-${budget.periodStart.month}-${budget.periodStart.day}';
      if (budget.isOver) {
        await gate.fire(
          category: 'budget_exceeded',
          title: 'Over budget on ${budget.label}',
          body:
              'You\'ve spent ${budget.spent.format(hidePaise: true)} of your '
              '${budget.amount.format(hidePaise: true)} ${budget.period.label.toLowerCase()} budget.',
          dedupeKey: 'budget_over:${budget.id}:$periodKey',
        );
      } else {
        await gate.fire(
          category: 'budget_warning',
          title: 'Running ahead on ${budget.label}',
          body:
              '${(budget.consumedFraction * 100).toStringAsFixed(0)}% of your budget is gone with '
              '${(100 - budget.elapsedFraction * 100).toStringAsFixed(0)}% of the period left.',
          dedupeKey: 'budget_pace:${budget.id}:$periodKey',
        );
      }
    }
  }
}
