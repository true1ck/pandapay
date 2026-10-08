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

class _SeriesCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
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
        ],
      ),
    );
  }
}
