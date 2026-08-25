import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;

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

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        title: Text('Subscriptions', style: BambooFonts.heading(18, color: BambooInk.ink900)),
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
              return const EmptyState(
                icon: Icons.lock_outline_rounded,
                title: 'Sign in to find your subscriptions',
                message: 'Recurring charges are found in your transaction history, which lives '
                    'with your account.',
              );
            }
            if (data.series.isEmpty) {
              // Refreshable, not a dead end: this screen only fills in once
              // a third matching charge lands, so "nothing yet" is the
              // state a user most wants to retry from.
              return RefreshableEmptyState(
                icon: Icons.autorenew_rounded,
                title: 'No repeating charges found yet',
                message: 'PandaPay looks for the same merchant charging a similar amount on a '
                    'regular cycle. It needs at least three of them before it will call '
                    'something a subscription.',
                onRefresh: () async => ref.invalidate(recurringReportProvider),
              );
            }
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(recurringReportProvider),
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _TotalCard(report: data),
                  const SizedBox(height: AppSpace.lg),
                  for (final s in data.series) ...[
                    _SeriesCard(series: s),
                    const SizedBox(height: AppSpace.md),
                  ],
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    'Found by looking for the same merchant charging a similar amount on a '
                    'regular cycle. If something here isn\'t a subscription, dismiss it and it '
                    'won\'t come back.',
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
  final RecurringReport report;
  const _TotalCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final monthly = Money.fromPaise((report.totalAnnual.paise / 12).round());
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
            '${report.series.length} repeating charge${report.series.length == 1 ? '' : 's'}',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: 4),
          MoneyText(
            report.totalAnnual,
            confidence: Confidence.estimated,
            style: BambooFonts.money(30, color: BambooInk.onSlate),
          ),
          Text('a year', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
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
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
                  style: BambooFonts.ui(14.5, weight: FontWeight.w700, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              MoneyText(
                series.typicalAmount,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(14.5, weight: FontWeight.w700, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${series.cadenceLabel} · ${series.annualCost.format(hidePaise: true)} a year',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
          if (next != null) ...[
            const SizedBox(height: 2),
            Text(
              // "Expected", never "due": this is a prediction from an
              // observed pattern, not a bill the app has been told about.
              'Next expected around ${next.day} ${_months[next.month - 1]}',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
          if (series.cardName != null) ...[
            const SizedBox(height: 2),
            Text(
              'Usually on ${series.cardName}',
              style: BambooFonts.ui(12, color: BambooInk.ink500),
            ),
          ],
          const SizedBox(height: AppSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => _dismiss(context, ref),
              child: Text(
                'Not a subscription',
                style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _dismiss(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(spendReportsRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.dismissRecurring(series.id);
      ref.invalidate(recurringReportProvider);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(userFacingErrorMessage(e))),
        );
      }
    }
  }
}
