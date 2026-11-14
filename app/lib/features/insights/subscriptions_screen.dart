import 'dart:async';

import 'package:flutter/material.dart';
import '../../app/design/bamboo_components.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/required_field.dart';
import '../../data/local_first/pending_overlays.dart';
import '../../data/api_exception.dart';
import '../../data/bills_projection_api.dart';
import '../../data/commitments_repository.dart';
import '../../data/spend_reports_repository.dart';
import 'central_bills_section.dart';
import 'subscription_detail_screen.dart';
import 'subscription_view.dart';
import '../cards/card_summary.dart';
import '../../main.dart' show MoneyText;


String _subscriptionStatus(RecurringSeries series) =>
    subscriptionListStatus(series);

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
  final bool showChrome;
  const SubscriptionsScreen({super.key, this.showChrome = true});

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
              .where(
                (row) =>
                    row['event_type'] == 'autopay' &&
                    !(row['reason_codes'] is List &&
                        (row['reason_codes'] as List).contains(
                          'explicit_subscription_service',
                        )) &&
                    (row['autopay_limit_paise'] is num ||
                        row['amount_due_paise'] is num ||
                        row['amount_paise'] is num) &&
                    isSubscriptionAutoPay(row['biller_name'] as String?),
              )
              .toList(growable: false);
    final localMandateKeys = <String>{};
    final uniqueLocalMandates = <Map<String, dynamic>>[];
    for (final row in localMandates) {
      final key =
          '${_cleanIdentity(row['biller_name'] as String?)}|${row['card_last4'] ?? row['account_last4'] ?? ''}';
      if (localMandateKeys.add(key)) uniqueLocalMandates.add(row);
    }

    final snapshot = ref.watch(centralBillsProjectionProvider).valueOrNull;
    final centralMandates =
        (snapshot?.available == true
                ? snapshot!.projections
                : const <BillProjection>[])
            .where(
              (row) =>
                  row.projectionKind == 'mandate' &&
                  isSubscriptionAutoPay(row.billerName ?? row.serviceName),
            )
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

    return _SubscriptionFrame(
      showChrome: showChrome,
      backgroundColor: BambooInk.paper,
      onAdd: signedIn ? () => _addSubscription(context, ref) : null,
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
      ),
      body: AppBackground(
        child: report.when(skipLoadingOnReload: true, skipLoadingOnRefresh: true, 
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
            final view = buildSubscriptionView(data.series);
            final subscriptions = view.subscriptions;
            final reviewCandidates = view.candidates;
            // An AutoPay setup for a service already listed above (in any
            // state) is that row, not a second "AutoPay active" entry: the
            // raw setup message cannot tell a live mandate from a revoked one.
            final listedServices = {
              for (final s in subscriptions) recurringServiceKey(s.displayName),
            };
            bool unlisted(String? name) =>
                name == null ||
                name.trim().isEmpty ||
                !listedServices.contains(recurringServiceKey(name));
            final autopayLocal = uniqueLocalMandates
                .where(
                  (row) => unlisted(
                    row['biller_name'] as String? ??
                        row['service_name'] as String? ??
                        row['merchant'] as String?,
                  ),
                )
                .toList(growable: false);
            final autopayCentral = uniqueCentralMandates
                .where((row) => unlisted(row.billerName ?? row.serviceName))
                .toList(growable: false);
            final hasAutopaySection =
                autopayLocal.isNotEmpty || autopayCentral.isNotEmpty;
            if (subscriptions.isEmpty) {
              if (hasAutopaySection || reviewCandidates.isNotEmpty) {
                return RefreshIndicator(
                  onRefresh: () async =>
                      ref.invalidate(recurringReportProvider),
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
                        localMandates: autopayLocal,
                        centralMandates: autopayCentral,
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
            final filteredSubscriptions = subscriptions;

            Money? mandateLimitFor(RecurringSeries series) {
              final serviceKey = recurringServiceKey(series.displayName);
              bool matches(String? name) {
                if (name == null || name.trim().isEmpty) return false;
                final canonical = namedServiceAutoPayName(name) ?? name;
                return recurringServiceKey(name) == serviceKey ||
                    recurringServiceKey(canonical) == serviceKey;
              }

              for (final row in uniqueLocalMandates) {
                final name =
                    row['biller_name'] as String? ??
                    row['service_name'] as String? ??
                    row['merchant'] as String?;
                if (!matches(name)) continue;
                final raw =
                    row['autopay_limit_paise'] ??
                    row['amount_due_paise'] ??
                    row['amount_paise'];
                if (raw is num && raw > 0) return Money.fromPaise(raw.toInt());
              }

              for (final row in uniqueCentralMandates) {
                if (!matches(row.billerName) && !matches(row.serviceName)) {
                  continue;
                }
                final amount = row.authorizationLimitInr ?? row.amountInr;
                if (amount != null && amount > 0) {
                  return Money.fromRupees(amount);
                }
              }
              return null;
            }

            // The engine split them; the screen groups the same truth.
            // Only what is still billing is "active" and counted. Paused and
            // past services are listed apart, never in the totals or reminders.
            final live = filteredSubscriptions
                .where((s) => subscriptionPhase(s) == SubscriptionPhase.active)
                .toList(growable: false);
            final paused = filteredSubscriptions
                .where((s) => subscriptionPhase(s) == SubscriptionPhase.paused)
                .toList(growable: false);
            final past = filteredSubscriptions
                .where((s) => subscriptionPhase(s) == SubscriptionPhase.past)
                .toList(growable: false);
            // The same definition the Insights tile uses (SubscriptionView).
            final billing = view.billing;
            // Each live subscription lands in exactly one group: confirmed by a
            // setup or a proven cycle (billing), or one the engine still asks
            // about (flagged, or waiting for a cadence).
            final unplaced = [
              for (final s in live)
                if (!billing.contains(s)) s,
            ];
            final flagged = unplaced
                .where((s) => _subscriptionStatus(s) != 'needs_cadence')
                .toList(growable: false);
            final needsCadence = unplaced
                .where((s) => _subscriptionStatus(s) == 'needs_cadence')
                .toList(growable: false);
            // The server total already counts only proven, still-billing
            // series; re-folding here would put guesses back in the headline.
            final totalAnnual = view.billingAnnual;
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
                  _TotalCard(
                    series: billing,
                    totalAnnual: totalAnnual,
                    pendingCount: flagged.length + needsCadence.length,
                    pausedCount: paused.length,
                    pastCount: past.length,
                    title: 'Your recurring spend',
                  ),
                  if (billing.isNotEmpty ||
                      flagged.isNotEmpty ||
                      needsCadence.isNotEmpty)
                    _SubscriptionSection(
                      title: 'Active',
                      rows: [
                        for (final item in [
                          ...billing,
                          ...flagged,
                          ...needsCadence,
                        ])
                          _SeriesCard(
                            series: item,
                            toneIndex: 0,
                            authorizationLimit: mandateLimitFor(item),
                          ),
                      ],
                    ),
                  if (paused.isNotEmpty)
                    _SubscriptionSection(
                      title: 'Paused',
                      rows: [
                        for (final item in paused)
                          _SeriesCard(series: item, toneIndex: 0),
                      ],
                    ),
                  if (past.isNotEmpty)
                    _SubscriptionSection(
                      title: 'Past',
                      rows: [
                        for (final item in past)
                          _SeriesCard(series: item, toneIndex: 0),
                      ],
                    ),
                  if (reviewCandidates.isNotEmpty)
                    _PossibleSubscriptionsSection(series: reviewCandidates),
                  if (hasAutopaySection) ...[
                    const SizedBox(height: AppSpace.lg),
                    _SubscriptionAutopaySection(
                      localMandates: autopayLocal,
                      centralMandates: autopayCentral,
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

/// The existing subscription body and actions have one owner. Payments embeds
/// them without a nested Scaffold, title, Back button or duplicated service list.
class _SubscriptionFrame extends StatelessWidget {
  final bool showChrome;
  final Color backgroundColor;
  final AppBar appBar;
  final Widget body;
  final VoidCallback? onAdd;
  const _SubscriptionFrame({
    required this.showChrome,
    required this.backgroundColor,
    required this.appBar,
    required this.body,
    this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final add = onAdd == null
        ? null
        : AppAddButton(tooltip: 'Add subscription', onPressed: onAdd!);
    if (showChrome) {
      return Scaffold(
        backgroundColor: backgroundColor,
        appBar: appBar,
        body: body,
        floatingActionButton: add,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (add != null)
          Positioned(
            right: AppSpace.lg,
            bottom: AppSpace.lg,
            child: SafeArea(top: false, left: false, child: add),
          ),
      ],
    );
  }
}

/// One titled group of subscription rows: the same look as every other list in
/// the app (a section title, then one rounded panel with hairline dividers).
class _SubscriptionSection extends StatelessWidget {
  final String title;
  final List<Widget> rows;

  const _SubscriptionSection({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      BambooSectionLabel(
        title,
        asTitle: true,
        trailing: '${rows.length}',
        padding: const EdgeInsets.fromLTRB(4, AppSpace.xl, 4, 10),
      ),
      BambooPanel(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
        child: Column(
          children: [
            for (final (index, row) in rows.indexed) ...[
              if (index > 0)
                const Divider(indent: AppSpace.lg, endIndent: AppSpace.lg),
              row,
            ],
          ],
        ),
      ),
    ],
  );
}

/// Recurring charges the app could not confirm as a subscription. Each says why
/// it is asked about, and opens the same detail page as any other row.
class _PossibleSubscriptionsSection extends StatelessWidget {
  final List<RecurringSeries> series;

  const _PossibleSubscriptionsSection({required this.series});

  @override
  Widget build(BuildContext context) => _SubscriptionSection(
    title: 'Needs your review',
    rows: [
      for (final item in series)
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SubscriptionDetailScreen(series: item),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: 14,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BambooIconTile(Icons.help_outline_rounded, size: 40),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.displayName,
                          style: BambooFonts.ui(
                            15.5,
                            weight: FontWeight.w600,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.reviewReason ??
                              '${item.occurrenceCount} similar payments · not confirmed',
                          style: BambooFonts.ui(
                            12.5,
                            color: BambooInk.ink500,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (item.amountKnown && item.typicalAmount.paise > 0) ...[
                    const SizedBox(width: AppSpace.sm),
                    Text(
                      item.typicalAmount.format(),
                      style: BambooFonts.money(15, color: BambooInk.ink900),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
    ],
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
                              required: true,
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
                              required: true,
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

  final bool required;

  const _FormFieldGroup({
    required this.title,
    required this.child,
    this.required = false,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      () {
        final style = BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink700,
        );
        return required
            ? requiredLabel(title, style: style)
            : Text(title, style: style);
      }(),
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

class _TotalCard extends StatelessWidget {
  final List<RecurringSeries> series;
  final Money totalAnnual;
  final int pendingCount;
  final int pausedCount;
  final int pastCount;
  final String title;
  const _TotalCard({
    required this.series,
    required this.totalAnnual,
    this.pendingCount = 0,
    this.pausedCount = 0,
    this.pastCount = 0,
    this.title = 'Your recurring spend',
  });

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((totalAnnual.paise / 12).round());
    final totalMandateLimit = series.fold<Money>(
      Money.zero(),
      (sum, item) => sum + (item.autopayLimit ?? Money.zero()),
    );
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
                        '${pendingCount > 0 ? ' · $pendingCount to review' : ''}'
                        '${pausedCount > 0 ? ' · $pausedCount paused' : ''}'
                        '${pastCount > 0 ? ' · $pastCount past' : ''}',
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w600,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.lg),
                  if (setupOnly) ...[
                    Text(
                      totalMandateLimit.paise > 0
                          ? 'Up to ${totalMandateLimit.format(hidePaise: true)} authorized'
                          : 'Paid amount not known',
                      style: BambooFonts.ui(
                        15,
                        weight: FontWeight.w700,
                        color: BambooInk.onSlate,
                      ),
                    ),
                    if (totalMandateLimit.paise > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Mandate limit • Awaiting first charge',
                        style: BambooFonts.ui(
                          12,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                    ],
                  ] else ...[
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
  final Money? authorizationLimit;

  const _SeriesCard({
    required this.series,
    required this.toneIndex,
    this.authorizationLimit,
  });

  Money? get _displayAuthorizationLimit =>
      series.autopayLimit ?? authorizationLimit;

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

    if (labelLower.contains('as presented') ||
        labelLower.contains('on-demand')) {
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
  SubscriptionPhase get _phase => subscriptionPhase(series);

  /// The one-line reason a paused or past subscription is not active.
  String get _endedLine {
    final lifecycle = series.lifecycleStatus.trim().toLowerCase();
    final last = series.lastSeenOn == null
        ? 'No charge was ever detected'
        : 'Last charged ${_formatDate(series.lastSeenOn!.toLocal())}';
    if (_phase == SubscriptionPhase.paused) {
      return 'AutoPay is paused · $last';
    }
    if (lifecycle == 'cancelled' || lifecycle == 'expired') {
      final end = series.endDate;
      return '${lifecycle == 'expired' ? 'Expired' : 'Cancelled'}'
          '${end == null ? '' : ' on ${_formatDate(end.toLocal())}'} · $last';
    }
    return 'No charge for a while · $last';
  }

  String get _costLine {
    if (_phase != SubscriptionPhase.active) {
      final amount = series.amountKnown && series.typicalAmount.paise > 0
          ? '${series.typicalAmount.format(hidePaise: true)} per charge · '
          : '';
      return '$amount$_endedLine';
    }
    if (_setupOnly || !series.amountKnown) {
      final limit = _displayAuthorizationLimit;
      if (limit != null && limit.paise > 0) {
        return 'AutoPay limit up to ${limit.format(hidePaise: true)} • Awaiting first charge';
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
    final phase = _phase;
    final active = phase == SubscriptionPhase.active;
    final status = _subscriptionStatus(series);
    final issue = subscriptionHasPaymentIssue(series);
    final needsReview =
        active && (status == 'at_risk' || status == 'renewal_unverified');
    final noCharges = active && status == 'unused';
    final next = series.nextExpectedOn?.toLocal();
    const warn = Color(0xFF9B6500);

    // What the row says about the subscription, most important first.
    final headline = <String>[
      if (active) ...[
        if (_setupOnly) 'Setup confirmed' else _frequencyLabel,
        if (series.detectionSource == 'manual') 'Added by you',
        if (issue) 'Payment failed',
        if (needsReview) 'Needs review',
        if (noCharges) 'No charges yet',
        if (status == 'ended') 'Ended',
      ],
    ];
    final lines = <(String, Color, bool)>[
      if (active)
        (headline.join(' · '), issue || needsReview || noCharges ? warn : BambooInk.ink700, true),
      (_costLine, BambooInk.ink500, false),
      if (active && next != null && status == 'confirmed')
        (
          '${series.detectionSource == 'central_projection'
              ? 'Next payment'
              : series.detectionSource == 'manual'
              ? 'Next payment'
              : DateUtils.dateOnly(next).isBefore(DateUtils.dateOnly(DateTime.now()))
              ? 'Renewal expected'
              : 'Renews'} around ${next.day} ${_months[next.month - 1]} ${next.year}',
          BambooInk.ink700,
          true,
        ),
      if (needsReview && !series.hasPastRenewal && series.lastSeenOn != null)
        (
          'No recent charge detected since ${_formatDate(series.lastSeenOn!)}',
          warn,
          true,
        ),
      if (noCharges)
        (
          series.lastSeenOn == null
              ? 'No posted charge detected yet'
              : 'No posted charge since ${_formatDate(series.lastSeenOn!)}',
          warn,
          true,
        ),
      if (needsReview && series.hasPastRenewal)
        ('Saved renewal date has passed; please review it', warn, true),
      if (series.cardName != null) (series.cardName!, BambooInk.ink500, false),
    ];

    final Widget amount;
    if (series.typicalAmount.paise > 0) {
      amount = MoneyText(
        series.typicalAmount,
        confidence: Confidence.estimated,
        style: BambooFonts.money(15.5, color: BambooInk.ink900),
      );
    } else if (_displayAuthorizationLimit != null &&
        _displayAuthorizationLimit!.paise > 0) {
      amount = Text(
        'Up to ${_displayAuthorizationLimit!.format(hidePaise: true)}',
        style: BambooFonts.money(13.5, color: BambooInk.ink900),
      );
    } else {
      amount = Text(
        series.amountKnown ? 'Free' : 'Awaiting first charge',
        textAlign: TextAlign.end,
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w600,
          color: BambooInk.ink500,
        ),
      );
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SubscriptionDetailScreen(series: series),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(
            left: AppSpace.lg,
            top: 12,
            bottom: 12,
            right: AppSpace.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BambooIconTile(switch (phase) {
                SubscriptionPhase.active => Icons.autorenew_rounded,
                SubscriptionPhase.paused => Icons.pause_rounded,
                SubscriptionPhase.past => Icons.history_rounded,
              }, size: 40),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      series.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        15.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                    for (final (text, color, strong) in lines) ...[
                      const SizedBox(height: 3),
                      Text(
                        text,
                        style: BambooFonts.ui(
                          12.5,
                          weight: strong ? FontWeight.w600 : FontWeight.w400,
                          color: color,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Padding(padding: const EdgeInsets.only(top: 2), child: amount),
              PopupMenuButton<String>(
                tooltip: 'More',
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 20,
                  color: BambooInk.ink500,
                ),
                onSelected: (value) {
                  if (value == 'edit') _edit(context, ref);
                  if (value == 'ignore') _dismiss(context, ref);
                },
                itemBuilder: (_) => [
                  if (phase != SubscriptionPhase.past)
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'ignore', child: Text('Ignore')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Returns true when the subscription was changed.
  Future<bool> _edit(BuildContext context, WidgetRef ref) async {
    var changed = false;
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
    var submitted = false;
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
                    decoration: InputDecoration(
                      label: requiredLabel('Service name'),
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
                    decoration: InputDecoration(label: requiredLabel('Amount (₹)')),
                    validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0
                        ? 'Enter a valid amount'
                        : null,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  TextFormField(
                    controller: cadence,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      label: requiredLabel('Renewal interval (days)'),
                    ),
                    validator: (v) {
                      final n = int.tryParse(v ?? '');
                      return n == null || n < 1 || n > 3650
                          ? 'Enter 1–3650 days'
                          : null;
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                  RequiredBox(
                    invalid: submitted && next == null,
                    child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: requiredLabel(
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
              style: BambooButtons.primary,
              onPressed: () {
                setDialogState(() => submitted = true);
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
        // Local first: the edit shows at once; the command outbox sends it.
        final n = next!;
        await queueCommand(
          ref,
          kind: OverlayCommand.recurringUpdate,
          target: series.id,
          payload: {
            'id': series.id,
            'displayName': name.text.trim(),
            'amountInr': double.parse(amount.text),
            'cadenceDays': int.parse(cadence.text),
            'nextExpectedOn':
                '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}',
            'autopayStatus': autopayStatus,
          },
        );
        if (!context.mounted) return true;
        ref.invalidate(recurringReportProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription updated.')));
        changed = true;
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
    return changed;
  }

  /// Returns true when the subscription was hidden.
  Future<bool> _dismiss(BuildContext context, WidgetRef ref) async {
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
            style: BambooButtons.primary,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ignore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    try {
      // Hiding a subscription is saved on the phone first; a queued edit of
      // the same subscription is dropped because it is about to disappear.
      await queueCommand(
        ref,
        kind: OverlayCommand.recurringDismiss,
        target: series.id,
        payload: {'id': series.id},
        cancels: const [],
      );
      if (!context.mounted) return true;
      ref.invalidate(recurringReportProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Subscription hidden.')));
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
      }
      return false;
    }
  }
}

/// Edit a subscription (name, amount, cycle, next renewal, AutoPay). Used by the
/// list's menu and by the detail page. True when it was saved.
Future<bool> editSubscription(
  BuildContext context,
  WidgetRef ref,
  RecurringSeries series,
) => _SeriesCard(series: series, toneIndex: 0)._edit(context, ref);

/// Hide a subscription after confirming. True when it was hidden.
Future<bool> ignoreSubscription(
  BuildContext context,
  WidgetRef ref,
  RecurringSeries series,
) => _SeriesCard(series: series, toneIndex: 0)._dismiss(context, ref);

String _cleanIdentity(String? value) =>
    (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

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
