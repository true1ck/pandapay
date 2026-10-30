import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/bills_projection_api.dart';
import '../../data/commitments_repository.dart';
import '../../data/spend_reports_repository.dart';
import '../activity/sms_learning_capture.dart';
import 'central_bills_section.dart';
import 'subscription_detail_screen.dart';
import '../cards/card_summary.dart';
import '../../main.dart' show MoneyText;

const _subscriptionIcons = <IconData>[
  Icons.autorenew_rounded,
  Icons.play_circle_outline_rounded,
  Icons.receipt_long_outlined,
  Icons.workspace_premium_outlined,
  Icons.favorite_border_rounded,
];
const _subscriptionAccent = BambooInk.jade;
const _subscriptionTint = BambooInk.rankBadgeBg;

bool _isExcludedNonSubscription(String name) {
  final lower = name.toLowerCase();
  // If it's a recognized subscription service, do not exclude
  if (isSubscriptionAutoPay(name)) {
    return false;
  }
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

bool _isDisplayableSubscription(RecurringSeries series) {
  final name = series.displayName.trim();
  if (name.length < 2 || !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
    return false;
  }
  if (_isExcludedNonSubscription(name)) {
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
  if (series.isMandate || series.detectionSource == 'mandate') {
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

enum SubscriptionCadenceFilter { all, monthly, quarterly, yearly }

final _subscriptionFilterProvider =
    StateProvider.autoDispose<SubscriptionCadenceFilter>(
      (ref) => SubscriptionCadenceFilter.all,
    );

bool _matchesCadence(RecurringSeries series, SubscriptionCadenceFilter filter) {
  if (filter == SubscriptionCadenceFilter.all) return true;
  final days = series.cadenceDays;
  final label = series.cadenceLabel.toLowerCase();
  switch (filter) {
    case SubscriptionCadenceFilter.monthly:
      return (days >= 20 && days <= 45) ||
          days == 28 ||
          label.contains('month');
    case SubscriptionCadenceFilter.quarterly:
      return (days >= 70 && days < 150) ||
          days == 84 ||
          label.contains('quarter');
    case SubscriptionCadenceFilter.yearly:
      return days >= 300 || label.contains('year') || label.contains('annual');
    case SubscriptionCadenceFilter.all:
      return true;
  }
}

String _subscriptionStatus(RecurringSeries series) {
  final lifecycle = series.lifecycleStatus.trim().toLowerCase();
  if (lifecycle.isNotEmpty && lifecycle != 'active') return lifecycle;
  return series.status;
}

/// Subscriptions — the charges that repeat, found in the user's own history.
///
/// Detected rather than declared. Asking someone to list their
/// subscriptions is asking them to remember the ones they've forgotten,
/// which are exactly the ones worth surfacing. Everything needed was
/// already in the transaction history; nothing had ever read it.
///
/// The annual figure is the point. A ₹649 monthly charge doesn't feel like
/// much; ₹7,788 a year does, and that is the same fact stated in the unit
/// people actually make decisions in.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(recurringReportProvider);
    // Keep the signed-out copy tied to the app-wide session, not to a
    // report's temporary null value while that session is being restored.
    final namespace = ref.watch(cacheNamespaceProvider);
    final signedIn = namespace != 'signed-out';
    final cache = ref.watch(responseCacheProvider).valueOrNull;
    final localMandates = cache == null
        ? <Map<String, dynamic>>[]
        : cache.financialStore
            .entities(namespace, 'sms_observations')
            .where((row) =>
                row['event_type'] == 'autopay' &&
                !(row['reason_codes'] is List &&
                    (row['reason_codes'] as List).contains('explicit_subscription_service')) &&
                (row['autopay_limit_paise'] is num ||
                    row['amount_due_paise'] is num ||
                    row['amount_paise'] is num) &&
                isSubscriptionAutoPay(row['biller_name'] as String?))
            .toList(growable: false);
    final localMandateKeys = <String>{};
    final uniqueLocalMandates = <Map<String, dynamic>>[];
    for (final row in localMandates) {
      final key =
          '${_cleanIdentity(row['biller_name'] as String?)}|${row['card_last4'] ?? row['account_last4'] ?? ''}';
      if (localMandateKeys.add(key)) uniqueLocalMandates.add(row);
    }

    final snapshot = ref.watch(centralBillsProjectionProvider).valueOrNull;
    final centralMandates = (snapshot?.available == true
            ? snapshot!.projections
            : const <BillProjection>[])
        .where((row) =>
            row.projectionKind == 'mandate' &&
            isSubscriptionAutoPay(row.billerName ?? row.serviceName))
        .where((row) {
          final key =
              '${_cleanIdentity(row.billerName ?? row.serviceName)}|${row.last4 ?? ''}';
          return !localMandateKeys.contains(key);
        })
        .toList(growable: false);
    final centralMandateKeys = <String>{};
    final uniqueCentralMandates = <BillProjection>[];
    for (final row in centralMandates) {
      final key =
          '${_cleanIdentity(row.billerName ?? row.serviceName)}|${row.last4 ?? ''}';
      if (centralMandateKeys.add(key)) uniqueCentralMandates.add(row);
    }
    final hasSubscriptionAutopays =
        uniqueLocalMandates.isNotEmpty || uniqueCentralMandates.isNotEmpty;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, size: 25),
          color: BambooInk.ink900,
          tooltip: 'Back',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        titleSpacing: 0,
        title: Text(
          'Subscriptions',
          style: BambooFonts.heading(20, color: BambooInk.ink900),
        ),
        actions: [
          if (signedIn)
            IconButton(
              tooltip: 'Add subscription',
              onPressed: () => _addSubscription(context, ref),
              icon: const Icon(Icons.add_rounded, size: 27),
              color: BambooInk.jade,
            ),
        ],
      ),
      body: AppBackground(
        child: report.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(recurringReportProvider),
          ),
          data: (data) {
            if (data == null) {
              if (signedIn) {
                return RefreshableEmptyState(
                  icon: Icons.sync_problem_rounded,
                  title: 'Subscriptions are still loading',
                  message:
                      'Your account is signed in, but the subscription report is not available yet.',
                  onRefresh: () async =>
                      ref.invalidate(recurringReportProvider),
                );
              }
              return const EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to find your subscriptions',
                message:
                    'Recurring charges are found in your transaction history, which lives '
                    'with your account.',
              );
            }
            final subscriptions = data.series
                .where(_isDisplayableSubscription)
                .toList(growable: false);
            final rawCandidates = data.series
                .where((series) => series.reviewCandidate)
                .where((series) => series.displayName.trim().length >= 2)
                .where((series) => series.cadenceDays >= 20)
                .where((series) => !_isExcludedNonSubscription(series.displayName))
                .toList(growable: false);
            final uniqueCandidatesMap = <String, RecurringSeries>{};
            for (final item in rawCandidates) {
              final k = item.displayName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
              final existing = uniqueCandidatesMap[k];
              if (existing == null || item.occurrenceCount > existing.occurrenceCount) {
                uniqueCandidatesMap[k] = item;
              }
            }
            final reviewCandidates = uniqueCandidatesMap.values.toList(growable: false);
            if (subscriptions.isEmpty) {
              if (hasSubscriptionAutopays || reviewCandidates.isNotEmpty) {
                return RefreshIndicator(
                  onRefresh: () async => ref.invalidate(recurringReportProvider),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.lg,
                      AppSpace.sm,
                      AppSpace.lg,
                      AppShell.navClearance,
                    ),
                    children: [
                      if (reviewCandidates.isNotEmpty) ...[
                        _PossibleSubscriptionsSection(series: reviewCandidates),
                        const SizedBox(height: AppSpace.lg),
                      ],
                      _SubscriptionAutopaySection(
                        localMandates: uniqueLocalMandates,
                        centralMandates: uniqueCentralMandates,
                      ),
                      const SizedBox(height: AppSpace.lg),
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.xs),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.verified_outlined,
                              size: 16,
                              color: BambooInk.ink500,
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text(
                                'Renewal dates are shown only when the charge pattern or AutoPay alert confirms them.',
                                style: BambooFonts.ui(
                                  11.5,
                                  color: BambooInk.ink500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }
              // A service can be one-time, free, or still awaiting a charge.
              // Keep the empty state neutral and refreshable.
              return RefreshableEmptyState(
                icon: Icons.autorenew_rounded,
                title: 'No subscriptions found yet',
                message:
                    'Named service subscriptions appear here when a setup, plan, or payment is identified. '
                    'Bills stay in Bills & Commitments.',
                onRefresh: () async => ref.invalidate(recurringReportProvider),
              );
            }
            final filter = ref.watch(_subscriptionFilterProvider);
            final monthlyCount = subscriptions
                .where(
                  (s) => _matchesCadence(s, SubscriptionCadenceFilter.monthly),
                )
                .length;
            final quarterlyCount = subscriptions
                .where(
                  (s) =>
                      _matchesCadence(s, SubscriptionCadenceFilter.quarterly),
                )
                .length;
            final yearlyCount = subscriptions
                .where(
                  (s) => _matchesCadence(s, SubscriptionCadenceFilter.yearly),
                )
                .length;

            final filteredSubscriptions = subscriptions
                .where((s) => _matchesCadence(s, filter))
                .toList(growable: false);

            // The engine split them; the screen groups the same truth.
            final billing = filteredSubscriptions
                .where(
                  (s) =>
                      s.setupConfirmed ||
                      _subscriptionStatus(s) == 'confirmed' ||
                      _subscriptionStatus(s) == 'active',
                )
                .toList(growable: false);
            final flagged = filteredSubscriptions
                .where(
                  (s) =>
                      !s.setupConfirmed &&
                      _subscriptionStatus(s) != 'confirmed' &&
                      _subscriptionStatus(s) != 'active' &&
                      _subscriptionStatus(s) != 'needs_cadence',
                )
                .toList(growable: false);
            final needsCadence = filteredSubscriptions
                .where((s) => _subscriptionStatus(s) == 'needs_cadence')
                .toList(growable: false);
            // The server total already counts only proven, still-billing
            // series; re-folding here would put guesses back in the headline.
            final totalAnnual = billing.fold<Money>(
              Money.zero(),
              (sum, s) => sum + s.annualCost,
            );
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(recurringReportProvider),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.sm,
                  AppSpace.lg,
                  AppShell.navClearance,
                ),
                children: [
                  if (reviewCandidates.isNotEmpty) ...[
                    _PossibleSubscriptionsSection(series: reviewCandidates),
                    const SizedBox(height: AppSpace.lg),
                  ],
                  _TotalCard(
                    series: billing,
                    totalAnnual: totalAnnual,
                    pendingCount: flagged.length + needsCadence.length,
                    title: switch (filter) {
                      SubscriptionCadenceFilter.monthly => 'Your monthly spend',
                      SubscriptionCadenceFilter.quarterly =>
                        'Your quarterly spend',
                      SubscriptionCadenceFilter.yearly => 'Your yearly spend',
                      SubscriptionCadenceFilter.all => 'Your recurring spend',
                    },
                  ),
                  const SizedBox(height: AppSpace.md),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        ChoiceChip(
                          avatar: Icon(
                            Icons.apps_rounded,
                            size: 15,
                            color: filter == SubscriptionCadenceFilter.all
                                ? BambooInk.onSlate
                                : BambooInk.ink700,
                          ),
                          label: Text('All (${subscriptions.length})'),
                          labelStyle: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: filter == SubscriptionCadenceFilter.all
                                ? BambooInk.onSlate
                                : BambooInk.ink900,
                          ),
                          selected: filter == SubscriptionCadenceFilter.all,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paperMuted,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          onSelected: (_) =>
                              ref
                                  .read(_subscriptionFilterProvider.notifier)
                                  .state = SubscriptionCadenceFilter
                                  .all,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        ChoiceChip(
                          avatar: Icon(
                            Icons.calendar_view_month_rounded,
                            size: 15,
                            color: filter == SubscriptionCadenceFilter.monthly
                                ? BambooInk.lime
                                : BambooInk.jade,
                          ),
                          label: Text('Monthly ($monthlyCount)'),
                          labelStyle: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: filter == SubscriptionCadenceFilter.monthly
                                ? BambooInk.onSlate
                                : BambooInk.ink900,
                          ),
                          selected: filter == SubscriptionCadenceFilter.monthly,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paperMuted,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          onSelected: (_) =>
                              ref
                                  .read(_subscriptionFilterProvider.notifier)
                                  .state = SubscriptionCadenceFilter
                                  .monthly,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        ChoiceChip(
                          avatar: Icon(
                            Icons.date_range_rounded,
                            size: 15,
                            color: filter == SubscriptionCadenceFilter.quarterly
                                ? BambooInk.lime
                                : BambooInk.jade,
                          ),
                          label: Text('Quarterly ($quarterlyCount)'),
                          labelStyle: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: filter == SubscriptionCadenceFilter.quarterly
                                ? BambooInk.onSlate
                                : BambooInk.ink900,
                          ),
                          selected:
                              filter == SubscriptionCadenceFilter.quarterly,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paperMuted,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          onSelected: (_) =>
                              ref
                                  .read(_subscriptionFilterProvider.notifier)
                                  .state = SubscriptionCadenceFilter
                                  .quarterly,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        ChoiceChip(
                          avatar: Icon(
                            Icons.event_repeat_rounded,
                            size: 15,
                            color: filter == SubscriptionCadenceFilter.yearly
                                ? BambooInk.lime
                                : BambooInk.jade,
                          ),
                          label: Text('Yearly ($yearlyCount)'),
                          labelStyle: BambooFonts.ui(
                            12.5,
                            weight: FontWeight.w600,
                            color: filter == SubscriptionCadenceFilter.yearly
                                ? BambooInk.onSlate
                                : BambooInk.ink900,
                          ),
                          selected: filter == SubscriptionCadenceFilter.yearly,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paperMuted,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          onSelected: (_) =>
                              ref
                                  .read(_subscriptionFilterProvider.notifier)
                                  .state = SubscriptionCadenceFilter
                                  .yearly,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.md),
                  if (filteredSubscriptions.isEmpty)
                    CardSummaryPanel(
                      elevated: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 28,
                      ),
                      child: Center(
                        child: Column(
                          children: [
                            const Icon(
                              Icons.event_busy_outlined,
                              size: 36,
                              color: BambooInk.ink500,
                            ),
                            const SizedBox(height: AppSpace.sm),
                            Text(
                              switch (filter) {
                                SubscriptionCadenceFilter.monthly =>
                                  'No monthly subscriptions found',
                                SubscriptionCadenceFilter.quarterly =>
                                  'No quarterly subscriptions found',
                                SubscriptionCadenceFilter.yearly =>
                                  'No yearly subscriptions found',
                                SubscriptionCadenceFilter.all =>
                                  'No subscriptions found',
                              },
                              style: BambooFonts.heading(
                                15,
                                color: BambooInk.ink900,
                              ),
                            ),
                            const SizedBox(height: AppSpace.xs),
                            Text(
                              switch (filter) {
                                SubscriptionCadenceFilter.monthly =>
                                  'Recurring services with a monthly cycle will appear here.',
                                SubscriptionCadenceFilter.quarterly =>
                                  'Recurring services with a quarterly cycle will appear here.',
                                SubscriptionCadenceFilter.yearly =>
                                  'Recurring services with an annual or yearly cycle will appear here.',
                                SubscriptionCadenceFilter.all =>
                                  'Recurring services with confirmed billing cadence will appear here.',
                              },
                              textAlign: TextAlign.center,
                              style: BambooFonts.ui(
                                12.5,
                                color: BambooInk.ink500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpace.lg),
                  for (var i = 0; i < billing.length; i++) ...[
                    _SeriesCard(series: billing[i], toneIndex: i),
                    const SizedBox(height: AppSpace.md),
                  ],
                  if (flagged.isNotEmpty) ...[
                    _SectionLabel('Flagged — watch or fix', Icons.flag_rounded),
                    const SizedBox(height: AppSpace.xs),
                    for (var i = 0; i < flagged.length; i++) ...[
                      _SeriesCard(series: flagged[i], toneIndex: i),
                      const SizedBox(height: AppSpace.md),
                    ],
                  ],
                  if (needsCadence.isNotEmpty) ...[
                    _SectionLabel(
                      'Confirm the cadence',
                      Icons.schedule_rounded,
                    ),
                    const SizedBox(height: AppSpace.xs),
                    for (var i = 0; i < needsCadence.length; i++) ...[
                      _SeriesCard(series: needsCadence[i], toneIndex: i),
                      const SizedBox(height: AppSpace.md),
                    ],
                  ],
                  if (hasSubscriptionAutopays) ...[
                    const SizedBox(height: AppSpace.lg),
                    _SubscriptionAutopaySection(
                      localMandates: uniqueLocalMandates,
                      centralMandates: uniqueCentralMandates,
                    ),
                    const SizedBox(height: AppSpace.sm),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.verified_outlined,
                          size: 16,
                          color: BambooInk.ink500,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            'Renewal dates are shown only when the charge pattern or AutoPay alert confirms them.',
                            style: BambooFonts.ui(
                              11.5,
                              color: BambooInk.ink500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _addSubscription(BuildContext context, WidgetRef ref) async {
    final draft = await showDialog<_SubscriptionDraft>(
      context: context,
      builder: (_) => const _AddSubscriptionDialog(),
    );
    if (draft == null || !context.mounted) return;

    final repository = ref.read(spendReportsRepositoryProvider);
    if (repository == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to add a subscription.')),
      );
      return;
    }

    try {
      await repository.createRecurring(
        displayName: draft.displayName,
        amountInr: draft.amountInr,
        cadenceDays: draft.cadenceDays,
        nextExpectedOn: draft.nextExpectedOn,
        autopayStatus: draft.autopayStatus,
      );
      ref.invalidate(recurringReportProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription added.')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(error))));
      }
    }
  }
}

class _PossibleSubscriptionsSection extends StatelessWidget {
  final List<RecurringSeries> series;

  const _PossibleSubscriptionsSection({required this.series});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.md),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Possible subscriptions',
            style: BambooFonts.heading(16, color: BambooInk.ink900)),
        const SizedBox(height: AppSpace.xs),
        Text('Repeated payments can be regular shopping. Review these patterns before adding a subscription.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
        const SizedBox(height: AppSpace.sm),
        for (final item in series)
          Material(
            color: Colors.transparent,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.displayName),
              subtitle: Text('${item.occurrenceCount} similar payments · not confirmed'),
              trailing: Text(item.typicalAmount.format()),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SubscriptionDetailScreen(series: item),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _SubscriptionDraft {
  final String displayName;
  final double amountInr;
  final int cadenceDays;
  final DateTime nextExpectedOn;
  final String autopayStatus;

  const _SubscriptionDraft({
    required this.displayName,
    required this.amountInr,
    required this.cadenceDays,
    required this.nextExpectedOn,
    required this.autopayStatus,
  });
}

class _AddSubscriptionDialog extends StatefulWidget {
  const _AddSubscriptionDialog();

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _amountController = TextEditingController();
  int _cadenceDays = 30;
  String _autopayStatus = 'unknown';
  DateTime _nextExpectedOn = _dateAfterCycle(30);
  bool _renewalDateEdited = false;

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.88;
    return Dialog(
      backgroundColor: BambooInk.paper,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: BambooInk.hairlineOnPaper),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: maxHeight),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Add subscription',
                        style: BambooFonts.heading(19, color: BambooInk.ink900),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      color: BambooInk.ink500,
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CardSummaryPanel(
                        elevated: false,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FormFieldGroup(
                              title: 'Service name',
                              child: TextFormField(
                                controller: _nameController,
                                textCapitalization: TextCapitalization.words,
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w500,
                                ),
                                decoration: _fieldDecoration(
                                  'e.g. Music or video plan',
                                  icon: Icons.subscriptions_outlined,
                                ),
                                validator: (value) {
                                  final name = value?.trim() ?? '';
                                  if (name.length < 2 ||
                                      !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
                                    return 'Enter a service name';
                                  }
                                  if (name.length > 80) {
                                    return 'Use 80 characters or fewer';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const _SubscriptionFormDivider(),
                            _FormFieldGroup(
                              title: 'Typical amount',
                              child: TextFormField(
                                controller: _amountController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                style: BambooFonts.ui(
                                  14,
                                  weight: FontWeight.w500,
                                ),
                                decoration: _fieldDecoration(
                                  '0.00',
                                  icon: Icons.currency_rupee_rounded,
                                ),
                                validator: (value) {
                                  final amount = double.tryParse(
                                    value?.trim() ?? '',
                                  );
                                  if (amount == null ||
                                      amount <= 0 ||
                                      amount > 10000000) {
                                    return 'Enter a valid amount';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      CardSummaryPanel(
                        elevated: false,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _FormFieldGroup(
                              title: 'Billing frequency',
                              child: _CycleSelector(
                                selectedDays: _cadenceDays,
                                onChanged: _selectCadence,
                              ),
                            ),
                            const SizedBox(height: AppSpace.md),
                            _FormFieldGroup(
                              title: 'Next renewal',
                              child: _renewalDateField(),
                            ),
                            const SizedBox(height: AppSpace.md),
                            _FormFieldGroup(
                              title: 'AutoPay status',
                              child: _AutoPaySelector(
                                value: _autopayStatus,
                                onChanged: (value) =>
                                    setState(() => _autopayStatus = value),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      Container(
                        padding: const EdgeInsets.all(AppSpace.md),
                        decoration: BoxDecoration(
                          color: BambooInk.rankBadgeBg,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 18,
                              color: BambooInk.jade,
                            ),
                            const SizedBox(width: AppSpace.sm),
                            Expanded(
                              child: Text(
                                'This tracks the renewal date. A payment appears in Expenses when it is recorded by SMS or added as a transaction.',
                                style: BambooFonts.ui(
                                  11.5,
                                  color: BambooInk.ink700,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        foregroundColor: BambooInk.ink700,
                        minimumSize: const Size(76, 48),
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: BambooInk.slate,
                          foregroundColor: BambooInk.lime,
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                        ),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Add subscription'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _renewalDateField() => Material(
    color: BambooInk.slate.withValues(alpha: 0.035),
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: _pickRenewalDate,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.event_outlined, size: 19, color: BambooInk.ink700),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_nextExpectedOn.day} ${_monthName(_nextExpectedOn.month)} ${_nextExpectedOn.year}',
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w500,
                  color: BambooInk.ink900,
                ),
              ),
            ),
            const Icon(
              Icons.edit_calendar_outlined,
              color: BambooInk.ink500,
              size: 19,
            ),
          ],
        ),
      ),
    ),
  );

  InputDecoration _fieldDecoration(String hint, {required IconData icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
        filled: true,
        fillColor: BambooInk.slate.withValues(alpha: 0.035),
        prefixIcon: Icon(icon, size: 19, color: BambooInk.ink700),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BambooInk.slate),
        ),
      );

  void _selectCadence(int cadenceDays) {
    setState(() {
      _cadenceDays = cadenceDays;
      if (!_renewalDateEdited) {
        _nextExpectedOn = _dateAfterCycle(cadenceDays);
      }
    });
  }

  Future<void> _pickRenewalDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _nextExpectedOn,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _nextExpectedOn = DateUtils.dateOnly(picked);
        _renewalDateEdited = true;
      });
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      _SubscriptionDraft(
        displayName: _nameController.text.trim(),
        amountInr: double.parse(_amountController.text.trim()),
        cadenceDays: _cadenceDays,
        nextExpectedOn: _nextExpectedOn,
        autopayStatus: _autopayStatus,
      ),
    );
  }

  static String _monthName(int month) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][month - 1];

  static DateTime _dateAfterCycle(int cadenceDays) {
    final today = DateUtils.dateOnly(DateTime.now());
    final targetYear = cadenceDays == 365 ? today.year + 1 : today.year;
    final targetMonth = cadenceDays == 365 ? today.month : today.month + 1;
    final normalizedYear = targetMonth > 12 ? targetYear + 1 : targetYear;
    final normalizedMonth = targetMonth > 12 ? targetMonth - 12 : targetMonth;
    final lastDay = DateTime(normalizedYear, normalizedMonth + 1, 0).day;
    return DateTime(
      normalizedYear,
      normalizedMonth,
      today.day.clamp(1, lastDay),
    );
  }
}

class _FormFieldGroup extends StatelessWidget {
  final String title;
  final Widget child;

  const _FormFieldGroup({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink700,
        ),
      ),
      const SizedBox(height: 10),
      child,
    ],
  );
}

class _SubscriptionFormDivider extends StatelessWidget {
  const _SubscriptionFormDivider();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 14),
    child: Divider(height: 1, color: BambooInk.hairlineOnPaper),
  );
}

class _CycleSelector extends StatelessWidget {
  final int selectedDays;
  final ValueChanged<int> onChanged;

  const _CycleSelector({required this.selectedDays, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: BambooInk.slate.withValues(alpha: 0.045),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      children: [
        for (final option in const [(30, 'Monthly'), (365, 'Yearly')])
          Expanded(
            child: _CycleOption(
              label: option.$2,
              selected: selectedDays == option.$1,
              onTap: () => onChanged(option.$1),
            ),
          ),
      ],
    ),
  );
}

class _CycleOption extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CycleOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    child: Material(
      color: selected ? BambooInk.lime : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: BambooFonts.ui(
              12,
              weight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? BambooInk.ink900 : BambooInk.ink700,
            ),
          ),
        ),
      ),
    ),
  );
}

class _AutoPaySelector extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _AutoPaySelector({required this.value, required this.onChanged});

  static const _labels = <String, String>{
    'unknown': 'Not confirmed',
    'active': 'Active',
    'cancelled': 'Cancelled',
  };

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: _labels.containsKey(value) ? value : 'unknown',
    isExpanded: true,
    decoration: InputDecoration(
      filled: true,
      fillColor: BambooInk.slate.withValues(alpha: 0.035),
      prefixIcon: const Icon(Icons.bolt_outlined, color: BambooInk.ink700),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: BambooInk.slate),
      ),
    ),
    style: BambooFonts.ui(14, weight: FontWeight.w500, color: BambooInk.ink900),
    items: _labels.entries
        .map(
          (entry) => DropdownMenuItem<String>(
            value: entry.key,
            child: Text(entry.value),
          ),
        )
        .toList(),
    onChanged: (next) {
      if (next != null) onChanged(next);
    },
  );
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color background;

  const _InfoPill({
    required this.icon,
    required this.label,
    required this.color,
    required this.background,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final IconData icon;
  const _SectionLabel(this.label, this.icon);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.xs),
      child: Row(
        children: [
          Icon(icon, size: 14, color: BambooInk.ink500),
          const SizedBox(width: AppSpace.xs),
          Text(
            label,
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w700,
              color: BambooInk.ink700,
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final List<RecurringSeries> series;
  final Money totalAnnual;
  final int pendingCount;
  final String title;
  const _TotalCard({
    required this.series,
    required this.totalAnnual,
    this.pendingCount = 0,
    this.title = 'Your recurring spend',
  });

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((totalAnnual.paise / 12).round());
    final setupOnly =
        totalAnnual.isZero &&
        series.any(
          (item) =>
              item.setupConfirmed &&
              !item.amountKnown &&
              item.occurrenceCount == 0 &&
              item.nextExpectedOn == null,
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              BambooInk.slateRaised,
              BambooInk.slate,
              BambooInk.slateLow,
            ],
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: BambooInk.lime.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(
                            color: BambooInk.lime.withValues(alpha: 0.22),
                          ),
                        ),
                        child: const Icon(
                          Icons.calendar_month_rounded,
                          size: 21,
                          color: BambooInk.lime,
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Text(
                          title,
                          style: BambooFonts.heading(
                            15,
                            color: BambooInk.onSlate,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      Text(
                        '${series.length} active'
                        '${pendingCount > 0 ? ' · $pendingCount to review' : ''}',
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w600,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.lg),
                  if (setupOnly)
                    Text(
                      'Paid amount not known',
                      style: BambooFonts.ui(
                        15,
                        weight: FontWeight.w700,
                        color: BambooInk.onSlate,
                      ),
                    )
                  else ...[
                    Text(
                      'Estimated annual cost',
                      style: BambooFonts.ui(
                        12.5,
                        color: BambooInk.onSlateMuted,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: MoneyText(
                            totalAnnual,
                            confidence: Confidence.estimated,
                            style: BambooFonts.money(
                              30,
                              color: BambooInk.onSlate,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: Text(
                            '/ year',
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.onSlateMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      'About ${monthly.format(hidePaise: true)} a month',
                      style: BambooFonts.ui(
                        12.5,
                        color: BambooInk.onSlateSubtle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeriesCard extends ConsumerWidget {
  final RecurringSeries series;
  final int toneIndex;

  const _SeriesCard({required this.series, required this.toneIndex});

  bool get _setupOnly =>
      series.setupConfirmed &&
      !series.amountKnown &&
      series.occurrenceCount == 0 &&
      series.nextExpectedOn == null;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static String _formatDate(DateTime date) =>
      '${date.day} ${_months[date.month - 1]} ${date.year}';

  static DateTime _advanceCycle(DateTime date, int cadenceDays) {
    final current = DateUtils.dateOnly(date);
    if (cadenceDays >= 350) {
      final year = current.year + 1;
      final lastDay = DateTime(year, current.month + 1, 0).day;
      return DateTime(year, current.month, current.day.clamp(1, lastDay));
    }
    if (cadenceDays >= 26 && cadenceDays <= 32) {
      final nextMonth = current.month == 12 ? 1 : current.month + 1;
      final year = current.month == 12 ? current.year + 1 : current.year;
      final lastDay = DateTime(year, nextMonth + 1, 0).day;
      return DateTime(year, nextMonth, current.day.clamp(1, lastDay));
    }
    return current.add(Duration(days: cadenceDays));
  }

  static DateTime _nextEditableDate(DateTime date, int cadenceDays) {
    var next = DateUtils.dateOnly(date);
    final today = DateUtils.dateOnly(DateTime.now());
    while (next.isBefore(today)) {
      next = _advanceCycle(next, cadenceDays);
    }
    return next;
  }

  String get _frequencyLabel {
    if (!series.cadenceConfirmed) return 'Cadence not confirmed';
    final days = series.cadenceDays;
    final labelLower = series.cadenceLabel.toLowerCase();

    if (labelLower.contains('as presented') || labelLower.contains('on-demand')) {
      return 'As presented';
    }
    if (days >= 300 ||
        labelLower.contains('year') ||
        labelLower.contains('annual')) {
      return 'Yearly';
    }
    if ((days >= 70 && days < 150) ||
        days == 84 ||
        labelLower.contains('quarter')) {
      return days == 84 ? '84-day' : 'Quarterly';
    }
    if (days == 28) {
      return '28-day';
    }
    if (days == 56) {
      return '56-day';
    }
    if ((days >= 20 && days <= 45) || labelLower.contains('month')) {
      return 'Monthly';
    }
    if (labelLower.contains('week')) {
      return 'Weekly';
    }
    return series.cadenceLabel;
  }

  /// The yearly line is only honest once the cycle is proven. Until then the
  /// per-cycle amount is what's real; a fabricated annual number built on a
  /// guessed cadence would bleed into the headline later.
  String get _costLine {
    if (_setupOnly || !series.amountKnown) {
      if (series.autopayLimit != null && series.autopayLimit!.paise > 0) {
        return 'AutoPay limit up to ${series.autopayLimit!.format(hidePaise: true)} • Awaiting first charge';
      }
      if (series.hasActiveAutoPay ||
          series.autopayStatus == 'active' ||
          series.isMandate) {
        return 'AutoPay active • Awaiting first charge';
      }
      return 'Setup confirmed • Awaiting first charge';
    }
    if (series.typicalAmount.paise == 0) return 'Free';
    final perCycle =
        '${series.typicalAmount.format(hidePaise: true)} this cycle';
    switch (_subscriptionStatus(series)) {
      case 'needs_cadence':
        return '$perCycle — confirm the cadence to estimate the year';
      case 'unused':
        return '$perCycle — no posted charge yet';
      case 'renewal_unverified':
      case 'payment_issue':
      case 'ended':
      case 'unknown':
        return '$perCycle — next amount unknown';
      default:
        return '${series.annualCost.format(hidePaise: true)} estimated per year';
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = series.nextExpectedOn?.toLocal();
    final icon = _subscriptionIcons[toneIndex % _subscriptionIcons.length];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SubscriptionDetailScreen(series: series),
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: BambooInk.hairlineOnPaper),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0D2B313A),
              blurRadius: 14,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _subscriptionTint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: _subscriptionAccent, size: 19),
                  ),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        series.displayName,
                        style: BambooFonts.heading(
                          16,
                          color: BambooInk.ink900,
                          height: 1.15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  if (series.typicalAmount.paise > 0)
                    Flexible(
                      child: MoneyText(
                        series.typicalAmount,
                        confidence: Confidence.estimated,
                        style: BambooFonts.money(16, color: BambooInk.ink900),
                      ),
                    )
                  else if (series.autopayLimit != null && series.autopayLimit!.paise > 0)
                    Text(
                      'Up to ${series.autopayLimit!.format(hidePaise: true)}',
                      style: BambooFonts.money(14, color: BambooInk.ink900),
                    )
                  else
                    Text(
                      series.amountKnown ? 'Free' : 'Awaiting first charge',
                      style: BambooFonts.ui(
                        12,
                        weight: FontWeight.w600,
                        color: BambooInk.ink500,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.xs,
                runSpacing: AppSpace.xs,
                children: [
                  if (_setupOnly)
                    const _InfoPill(
                      icon: Icons.verified_outlined,
                      label: 'Setup confirmed',
                      color: _subscriptionAccent,
                      background: _subscriptionTint,
                    )
                  else
                    _InfoPill(
                      icon: Icons.bolt_rounded,
                      label: _frequencyLabel,
                      color: _subscriptionAccent,
                      background: _subscriptionTint,
                    ),
                  if (series.detectionSource == 'manual')
                    const _InfoPill(
                      icon: Icons.edit_outlined,
                      label: 'Added by you',
                      color: _subscriptionAccent,
                      background: _subscriptionTint,
                    ),
                  if (series.hasActiveAutoPay ||
                      series.autopayStatus == 'active' ||
                      series.isMandate)
                    const _InfoPill(
                      icon: Icons.bolt_rounded,
                      label: 'AutoPay Active',
                      color: BambooInk.jade,
                      background: BambooInk.rankBadgeBg,
                    ),
                  if (_subscriptionStatus(series) == 'at_risk' ||
                      _subscriptionStatus(series) == 'renewal_unverified')
                    const _InfoPill(
                      icon: Icons.warning_amber_rounded,
                      label: 'Needs review',
                      color: Color(0xFF9B6500),
                      background: Color(0xFFFFF3D6),
                    ),
                  if (_subscriptionStatus(series) == 'unused')
                    const _InfoPill(
                      icon: Icons.bolt_rounded,
                      label: 'No charges yet',
                      color: Color(0xFF9B6500),
                      background: Color(0xFFFFF3D6),
                    ),
                  if (_subscriptionStatus(series) == 'payment_issue')
                    const _InfoPill(
                      icon: Icons.error_outline_rounded,
                      label: 'Payment issue',
                      color: Color(0xFF9B3D00),
                      background: Color(0xFFFFE9DF),
                    ),
                  if (_subscriptionStatus(series) == 'ended')
                    const _InfoPill(
                      icon: Icons.stop_circle_outlined,
                      label: 'Ended',
                      color: BambooInk.ink500,
                      background: BambooInk.paperMuted,
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                _costLine,
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              if (next != null &&
                  _subscriptionStatus(series) == 'confirmed') ...[
                const SizedBox(height: AppSpace.xs),
                Row(
                  children: [
                    Icon(
                      Icons.event_available_outlined,
                      size: 16,
                      color: _subscriptionAccent,
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        '${series.detectionSource == 'central_projection'
                            ? 'Next payment'
                            : series.detectionSource == 'manual'
                            ? 'Next payment'
                            : 'Renews'} around ${next.day} ${_months[next.month - 1]} ${next.year}',
                        style: BambooFonts.ui(
                          12,
                          weight: FontWeight.w600,
                          color: BambooInk.ink700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if ((_subscriptionStatus(series) == 'at_risk' ||
                      _subscriptionStatus(series) == 'renewal_unverified') &&
                  !series.hasPastRenewal &&
                  series.lastSeenOn != null) ...[
                const SizedBox(height: AppSpace.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.history_toggle_off_rounded,
                      size: 16,
                      color: Color(0xFF9B6500),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        'No recent charge detected since ${_formatDate(series.lastSeenOn!)}',
                        style: BambooFonts.ui(
                          12,
                          weight: FontWeight.w600,
                          color: BambooInk.ink700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (_subscriptionStatus(series) == 'unused') ...[
                const SizedBox(height: AppSpace.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.pause_circle_outline_rounded,
                      size: 16,
                      color: Color(0xFF9B6500),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        series.lastSeenOn == null
                            ? 'No posted charge detected yet'
                            : 'No posted charge since '
                                  '${_formatDate(series.lastSeenOn!)}',
                        style: BambooFonts.ui(
                          12,
                          weight: FontWeight.w600,
                          color: BambooInk.ink700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if ((_subscriptionStatus(series) == 'at_risk' ||
                      _subscriptionStatus(series) == 'renewal_unverified') &&
                  series.hasPastRenewal) ...[
                const SizedBox(height: AppSpace.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.event_busy_outlined,
                      size: 16,
                      color: Color(0xFF9B6500),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        'Saved renewal date has passed; please review it',
                        style: BambooFonts.ui(
                          12,
                          weight: FontWeight.w600,
                          color: BambooInk.ink700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (series.cardName != null) ...[
                const SizedBox(height: AppSpace.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.credit_card_outlined,
                      size: 16,
                      color: BambooInk.ink500,
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Expanded(
                      child: Text(
                        series.cardName!,
                        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpace.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _edit(context, ref),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(42),
                        foregroundColor: BambooInk.ink900,
                        side: BorderSide(color: BambooInk.hairlineOnPaper),
                        backgroundColor: Colors.white.withValues(alpha: 0.52),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                      ),
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Edit'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: TextButton.icon(
                      onPressed: () => _dismiss(context, ref),
                      style: TextButton.styleFrom(
                        minimumSize: const Size.fromHeight(42),
                        foregroundColor: BambooInk.ink700,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.visibility_off_outlined, size: 16),
                      label: const Text('Ignore'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: series.displayName);
    final amount = TextEditingController(
      text: series.typicalAmount.rupees.toStringAsFixed(2),
    );
    final cadence = TextEditingController(text: series.cadenceDays.toString());
    var autopayStatus = series.hasActiveAutoPay
        ? 'active'
        : series.autopayStatus;
    DateTime? next = series.nextExpectedOn == null
        ? null
        : _nextEditableDate(series.nextExpectedOn!, series.cadenceDays);
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            'Edit subscription',
            style: BambooFonts.heading(18, color: BambooInk.ink900),
          ),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Service name',
                    ),
                    validator: (v) => (v == null || v.trim().length < 2)
                        ? 'Enter a service name'
                        : null,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Amount (₹)'),
                    validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                        ? 'Enter a valid amount'
                        : null,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: cadence,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Renewal interval (days)',
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 3650
                          ? 'Enter 1–3650 days'
                          : null;
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: Text(
                      'Next renewal',
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    subtitle: Text(
                      next == null
                          ? 'No date stated · tap to set'
                          : _formatDate(next!),
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate:
                            next ??
                            DateTime.now().add(const Duration(days: 30)),
                        firstDate: DateUtils.dateOnly(DateTime.now()),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() => next = picked);
                      }
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'AutoPay status',
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  _AutoPaySelector(
                    value: autopayStatus,
                    onChanged: (value) =>
                        setDialogState(() => autopayStatus = value),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState!.validate() && next != null) {
                  Navigator.pop(dialogContext, true);
                } else if (next == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Choose a next payment date or cancel.'),
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && context.mounted) {
      try {
        await ref
            .read(spendReportsRepositoryProvider)!
            .updateRecurring(
              series.id,
              displayName: name.text.trim(),
              amountInr: double.parse(amount.text),
              cadenceDays: int.parse(cadence.text),
              nextExpectedOn: next!,
              autopayStatus: autopayStatus,
            );
        unawaited(
          _recordSubscriptionEditFeedback(
            ref,
            displayName: name.text.trim(),
            amountInr: double.parse(amount.text),
            cadenceDays: int.parse(cadence.text),
            nextExpectedOn: next!,
          ),
        );
        if (!context.mounted) return;
        ref.invalidate(recurringReportProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription updated.')));
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
        }
      }
    }
    name.dispose();
    amount.dispose();
    cadence.dispose();
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Ignore this subscription?',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
        content: Text(
          'Hide ${series.displayName} from your subscriptions. You can still find its charges in Transactions.',
          style: BambooFonts.ui(13.5, color: BambooInk.ink500, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ignore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref
          .read(spendReportsRepositoryProvider)!
          .dismissRecurring(series.id);
      unawaited(_recordSubscriptionDismissFeedback(ref));
      if (!context.mounted) return;
      ref.invalidate(recurringReportProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Subscription hidden.')));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
    }
  }

  /// Queues one consented correction for an SMS-backed subscription after the
  /// PATCH committed. Only a real change produces evidence. The service name
  /// travels as `billerName` and is redacted server-side; a series without a
  /// captured SMS on this device stays local.
  Future<void> _recordSubscriptionEditFeedback(
    WidgetRef ref, {
    required String displayName,
    required double amountInr,
    required int cadenceDays,
    required DateTime nextExpectedOn,
  }) async {
    final amountChanged = amountInr != series.typicalAmount.rupees;
    final dateChanged =
        series.nextExpectedOn != null &&
        !nextExpectedOn.toUtc().isAtSameMomentAs(series.nextExpectedOn!.toUtc());
    final nameChanged = displayName.trim() != series.displayName;
    if (!amountChanged &&
        !dateChanged &&
        !nameChanged &&
        cadenceDays == series.cadenceDays) {
      return;
    }
    await queueSmsLearningEvent(
      ref: ref,
      sourceKey: series.sourceKey ?? '',
      action: 'edited',
      resolvedKind: 'bill',
      occurredAtIso:
          (series.lastSeenOn ?? DateTime.now()).toUtc().toIso8601String(),
      originalDecision: {
        'kind': 'bill_obligation',
        'origin': 'parser',
        'fields': {
          'billerName': series.displayName,
          'amountInr': series.typicalAmount.rupees,
          'cadenceDays': series.cadenceDays,
          if (series.nextExpectedOn != null)
            'dueDate': series.nextExpectedOn!.toUtc().toIso8601String(),
        },
      },
      correctedFields: {
        'billerName': displayName.trim(),
        'amountInr': amountInr,
        'cadenceDays': cadenceDays,
        'dueDate': nextExpectedOn.toUtc().toIso8601String(),
      },
      correctionKind: amountChanged
          ? 'wrong_amount'
          : dateChanged
              ? 'wrong_date'
              : 'wrong_bill_fields',
    );
  }

  /// A subscription ignore is a tracking preference, not a claim that the
  /// message was misclassified, so it is tagged `preference_only` and never
  /// trains a shared rule.
  Future<void> _recordSubscriptionDismissFeedback(WidgetRef ref) async {
    await queueSmsLearningEvent(
      ref: ref,
      sourceKey: series.sourceKey ?? '',
      action: 'dismissed',
      resolvedKind: 'bill',
      occurredAtIso:
          (series.lastSeenOn ?? DateTime.now()).toUtc().toIso8601String(),
      originalDecision: {
        'kind': 'bill_obligation',
        'origin': 'parser',
        'fields': {'billerName': series.displayName},
      },
      correctedFields: const {},
      correctionKind: 'preference_only',
      reason: 'user_ignored_subscription',
    );
  }
}

String _cleanIdentity(String? value) => (value ?? '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '');

class _SubscriptionAutopaySection extends StatelessWidget {
  final List<Map<String, dynamic>> localMandates;
  final List<BillProjection> centralMandates;

  const _SubscriptionAutopaySection({
    required this.localMandates,
    required this.centralMandates,
  });

  @override
  Widget build(BuildContext context) {
    if (localMandates.isEmpty && centralMandates.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Autopay authorizations',
          style: BambooFonts.ui(
            13,
            color: BambooInk.ink700,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        for (final row in localMandates) LocalMandateRow(row: row),
        for (final row in centralMandates) CentralRow(row: row),
      ],
    );
  }
}
