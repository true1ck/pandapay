import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;

const _subscriptionTones = <_SubscriptionTone>[
  _SubscriptionTone(
    accent: BambooChartColors.teal,
    tint: Color(0xFFE8F7F0),
    icon: Icons.autorenew_rounded,
  ),
  _SubscriptionTone(
    accent: BambooChartColors.blue,
    tint: Color(0xFFEAF2FC),
    icon: Icons.play_circle_outline_rounded,
  ),
  _SubscriptionTone(
    accent: BambooChartColors.amber,
    tint: Color(0xFFFFF4E2),
    icon: Icons.receipt_long_outlined,
  ),
  _SubscriptionTone(
    accent: BambooChartColors.violet,
    tint: Color(0xFFF1EDFA),
    icon: Icons.workspace_premium_outlined,
  ),
  _SubscriptionTone(
    accent: BambooChartColors.coral,
    tint: Color(0xFFFFEEE9),
    icon: Icons.favorite_border_rounded,
  ),
];

class _SubscriptionTone {
  final Color accent;
  final Color tint;
  final IconData icon;

  const _SubscriptionTone({
    required this.accent,
    required this.tint,
    required this.icon,
  });
}

bool _isDisplayableSubscription(RecurringSeries series) {
  final name = series.displayName.trim();
  if (name.length < 2 || !RegExp(r'[A-Za-z]{2,}').hasMatch(name)) {
    return false;
  }
  if (series.typicalAmount.paise <= 0 || series.nextExpectedOn == null) {
    return false;
  }
  // Raw UPI VPAs containing '@' are peer/merchant transfer handles, not subscriptions
  if (name.contains('@')) {
    return false;
  }
  // Fuel fill-ups and petrol pumps are variable spends, not subscriptions
  if (RegExp(
    r'\b(petroleum|petrol|fuel|gas\s*station|oil\s*co|hpcl|bpcl|iocl)\b',
    caseSensitive: false,
  ).hasMatch(name)) {
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
    final signedIn = ref.watch(cacheNamespaceProvider) != 'signed-out';

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
            if (subscriptions.isEmpty) {
              // Refreshable, not a dead end: this screen only fills in once
              // a third matching charge lands, so "nothing yet" is the
              // state a user most wants to retry from.
              return RefreshableEmptyState(
                icon: Icons.autorenew_rounded,
                title: 'No confirmed subscriptions found yet',
                message:
                    'PandaPay shows a service only when it has a real merchant name, '
                    'amount, and a predictable renewal date.',
                onRefresh: () async => ref.invalidate(recurringReportProvider),
              );
            }
            final totalAnnual = subscriptions.fold(
              const Money.zero(),
              (total, subscription) => total + subscription.annualCost,
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
                  _TotalCard(series: subscriptions, totalAnnual: totalAnnual),
                  const SizedBox(height: AppSpace.lg),
                  for (var i = 0; i < subscriptions.length; i++) ...[
                    _SeriesCard(series: subscriptions[i], toneIndex: i),
                    const SizedBox(height: AppSpace.md),
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
                            'Only confirmed services with a renewal date are shown.',
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
}

class _CardSilhouette extends StatelessWidget {
  final double size;
  final Color color;

  const _CardSilhouette({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1.5),
        ),
        child: Center(
          child: Container(
            width: size * 0.68,
            height: size * 0.68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: color.withValues(alpha: 0.7),
                width: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
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

class _TotalCard extends StatelessWidget {
  final List<RecurringSeries> series;
  final Money totalAnnual;
  const _TotalCard({required this.series, required this.totalAnnual});

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((totalAnnual.paise / 12).round());
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
            const Positioned(
              right: -34,
              top: -42,
              child: _CardSilhouette(size: 148, color: Color(0x20CDF564)),
            ),
            const Positioned(
              right: 62,
              bottom: -64,
              child: _CardSilhouette(size: 118, color: Color(0x12FFFFFF)),
            ),
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
                          'Your recurring spend',
                          style: BambooFonts.heading(
                            15,
                            color: BambooInk.onSlate,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      Text(
                        '${series.length} subscription${series.length == 1 ? '' : 's'}',
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w600,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Text(
                    'Estimated annual cost',
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
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
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle),
                  ),
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final next = series.nextExpectedOn;
    final tone = _subscriptionTones[toneIndex % _subscriptionTones.length];
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D2B313A),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(width: 5, color: tone.accent),
            ),
            Positioned(
              top: -44,
              right: -32,
              child: _CardSilhouette(size: 118, color: tone.tint),
            ),
            Padding(
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
                          color: tone.tint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(tone.icon, color: tone.accent, size: 19),
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
                            style: BambooFonts.money(
                              16,
                              color: BambooInk.ink900,
                            ),
                          ),
                        )
                      else
                        Text(
                          'Amount varies',
                          style: BambooFonts.ui(12, color: BambooInk.ink500),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.md),
                  Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    children: [
                      _InfoPill(
                        icon: Icons.schedule_rounded,
                        label: series.cadenceLabel,
                        color: tone.accent,
                        background: tone.tint,
                      ),
                      if (series.isMandate)
                        const _InfoPill(
                          icon: Icons.bolt_rounded,
                          label: 'AutoPay',
                          color: AppColors.teal600,
                          background: AppColors.teal50,
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    series.typicalAmount.paise > 0
                        ? '${series.annualCost.format(hidePaise: true)} estimated per year'
                        : 'Amount not stated in the SMS',
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
                  if (next != null) ...[
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      children: [
                        Icon(
                          Icons.event_available_outlined,
                          size: 16,
                          color: tone.accent,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        Expanded(
                          child: Text(
                            'Renews around ${next.day} ${_months[next.month - 1]} ${next.year}',
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
                            style: BambooFonts.ui(
                              11.5,
                              color: BambooInk.ink500,
                            ),
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
                            side: BorderSide(
                              color: tone.accent.withValues(alpha: 0.45),
                            ),
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.52,
                            ),
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
                          icon: const Icon(
                            Icons.visibility_off_outlined,
                            size: 16,
                          ),
                          label: const Text('Ignore'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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
    var next =
        series.nextExpectedOn ?? DateTime.now().add(const Duration(days: 30));
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
                      '${next.day} ${_months[next.month - 1]} ${next.year}',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: next,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setDialogState(() => next = picked);
                      }
                    },
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
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, true);
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
              nextExpectedOn: next,
            );
        ref.invalidate(recurringReportProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Subscription updated.')));
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
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
      ref.invalidate(recurringReportProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Subscription hidden.')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
    }
  }
}
