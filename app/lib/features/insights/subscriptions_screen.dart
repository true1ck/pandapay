import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;

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
        title: Text(
          'Subscriptions',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
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
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _TotalCard(series: subscriptions, totalAnnual: totalAnnual),
                  const SizedBox(height: AppSpace.lg),
                  for (final s in subscriptions) ...[
                    _SeriesCard(series: s),
                    const SizedBox(height: AppSpace.md),
                  ],
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Only confirmed services with a renewal date are shown.',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
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

class _TotalCard extends StatelessWidget {
  final List<RecurringSeries> series;
  final Money totalAnnual;
  const _TotalCard({required this.series, required this.totalAnnual});

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((totalAnnual.paise / 12).round());
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.slate,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${series.length} subscription${series.length == 1 ? '' : 's'}',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: 4),
          MoneyText(
            totalAnnual,
            confidence: Confidence.estimated,
            style: BambooFonts.money(30, color: BambooInk.onSlate),
          ),
          Text(
            'a year',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: 6),
          Text(
            'About ${monthly.format(hidePaise: true)} a month',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
        ],
      ),
    );
  }
}

class _SeriesCard extends ConsumerWidget {
  final RecurringSeries series;
  const _SeriesCard({required this.series});

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
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  series.displayName,
                  style: BambooFonts.ui(
                    14.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (series.typicalAmount.paise > 0)
                MoneyText(
                  series.typicalAmount,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(
                    14.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                )
              else
                Text(
                  'Amount varies',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            series.typicalAmount.paise > 0
                ? '${series.cadenceLabel} · ${series.annualCost.format(hidePaise: true)} a year'
                : '${series.cadenceLabel} · amount not stated in the SMS',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          if (next != null) ...[
            const SizedBox(height: 2),
            Text(
              'Renews around ${next.day} ${_months[next.month - 1]} ${next.year}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          if (series.isMandate || series.cardName != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                if (series.isMandate) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: AppColors.teal50,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: AppColors.teal400.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      'AutoPay',
                      style: BambooFonts.ui(11, weight: FontWeight.w600, color: AppColors.teal600),
                    ),
                  ),
                ],
                if (series.cardName != null)
                  Expanded(
                    child: Text(
                      series.cardName!,
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.sm),
          Wrap(spacing: AppSpace.sm, children: [
            OutlinedButton.icon(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.edit_outlined, size: 17),
              label: const Text('Edit'),
            ),
            TextButton.icon(
              onPressed: () => _dismiss(context, ref),
              icon: const Icon(Icons.visibility_off_outlined, size: 17),
              label: const Text('Ignore'),
            ),
          ]),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController(text: series.displayName);
    final amount = TextEditingController(text: series.typicalAmount.rupees.toStringAsFixed(2));
    final cadence = TextEditingController(text: series.cadenceDays.toString());
    var next = series.nextExpectedOn ?? DateTime.now().add(const Duration(days: 30));
    final formKey = GlobalKey<FormState>();
    final saved = await showDialog<bool>(context: context, builder: (dialogContext) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Edit subscription'),
        content: Form(key: formKey, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Service name'), validator: (v) => (v == null || v.trim().length < 2) ? 'Enter a service name' : null),
          TextFormField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (₹)'), validator: (v) => (double.tryParse(v ?? '') ?? 0) <= 0 ? 'Enter a valid amount' : null),
          TextFormField(controller: cadence, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Renewal interval (days)'), validator: (v) { final n = int.tryParse(v ?? ''); return n == null || n < 1 || n > 3650 ? 'Enter 1–3650 days' : null; }),
          ListTile(contentPadding: EdgeInsets.zero, title: const Text('Next renewal'), subtitle: Text('${next.day} ${_months[next.month - 1]} ${next.year}'), trailing: const Icon(Icons.calendar_month_outlined), onTap: () async { final picked = await showDatePicker(context: context, initialDate: next, firstDate: DateTime(2000), lastDate: DateTime(2100)); if (picked != null) setDialogState(() => next = picked); }),
        ]))),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(context, true); }, child: const Text('Save'))],
      ),
    ));
    if (saved == true && context.mounted) {
      try {
        await ref.read(spendReportsRepositoryProvider)!.updateRecurring(series.id, displayName: name.text.trim(), amountInr: double.parse(amount.text), cadenceDays: int.parse(cadence.text), nextExpectedOn: next);
        ref.invalidate(recurringReportProvider);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscription updated.')));
      } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e)))); }
    }
    name.dispose(); amount.dispose(); cadence.dispose();
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Ignore this subscription?'),
      content: Text('Hide ${series.displayName} from your subscriptions. You can still find its charges in Transactions.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ignore'))],
    ));
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(spendReportsRepositoryProvider)!.dismissRecurring(series.id);
      ref.invalidate(recurringReportProvider);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscription hidden.')));
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e)))); }
  }
}
