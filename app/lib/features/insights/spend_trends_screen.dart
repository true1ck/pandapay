import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../main.dart' show MoneyText;

/// Spend Trends — where the money actually went, over time.
///
/// The app already had a Spending Overview, but it answered exactly one
/// question: this calendar month, split by category and merchant. No
/// comparison to last month, no week or year view, no per-card figure, and
/// its own doc-comment described it as "context, not a budgeting tool".
/// That left the single most common question about a spend tracker — "am I
/// spending more than usual?" — unanswerable inside the app that held all
/// the data needed to answer it.
///
/// Everything here comes from one `GET /spend-report` call. One request
/// rather than five, because every figure has to agree with every other:
/// a category breakdown fetched a moment after the headline, with a
/// transaction landing in between, produces a screen that contradicts
/// itself.
class SpendTrendsScreen extends ConsumerWidget {
  const SpendTrendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(selectedSpendPeriodProvider);
    final report = ref.watch(spendReportProvider(period));

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        title: Text('Spending', style: BambooFonts.heading(18, color: BambooInk.ink900)),
        actions: [
          // Export the period on screen, not "everything": someone sharing
          // a report with an accountant wants the quarter they're looking
          // at, and GET /export already covers the whole-account case.
          if (report.valueOrNull != null)
            IconButton(
              icon: const Icon(Icons.ios_share_rounded, size: 20),
              color: BambooInk.ink900,
              tooltip: 'Export as CSV',
              onPressed: () => _exportCsv(context, ref, report.valueOrNull!),
            ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            _PeriodSelector(selected: period),
            Expanded(
              child: report.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () => ref.invalidate(spendReportProvider(period)),
                ),
                data: (data) {
                  if (data == null) {
                    return const EmptyState(
                      icon: Icons.lock_outline_rounded,
                      title: 'Sign in to see your spending',
                      message: 'Spending reports are built from your transaction history, which lives '
                          'with your account.',
                    );
                  }
                  if (data.spend.txnCount == 0 && data.income.txnCount == 0) {
                    return RefreshableEmptyState(
                      icon: Icons.insights_outlined,
                      title: 'Nothing logged ${period.label.toLowerCase()}',
                      message: 'Add a transaction, or turn on SMS and email import, and this fills in '
                          'with where your money went and how that compares to before.',
                      onRefresh: () async => ref.invalidate(spendReportProvider(period)),
                    );
                  }
                  return _ReportBody(report: data, onRefresh: () => ref.invalidate(spendReportProvider(period)));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Writes the period's transactions to a temporary CSV and opens the
/// platform share sheet.
///
/// A temp file plus the share sheet, rather than a download: on both
/// platforms that is how a file reaches Drive, Mail, WhatsApp or a
/// spreadsheet app, and it's the same pattern the Savings Report already
/// uses to share its image.
Future<void> _exportCsv(BuildContext context, WidgetRef ref, SpendReport report) async {
  final repo = ref.read(spendReportsRepositoryProvider);
  if (repo == null) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    // `periodEnd` is exclusive; the export's `to` is inclusive, so the
    // last day of the period would otherwise be silently dropped.
    final bytes = await repo.fetchTransactionsCsv(
      from: report.periodStart,
      to: report.periodEnd.subtract(const Duration(days: 1)),
    );
    final dir = await getTemporaryDirectory();
    final stamp = '${report.periodStart.year}-'
        '${report.periodStart.month.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/pandapay-spending-$stamp.csv');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: 'My PandaPay spending report'),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Could not export. ${userFacingErrorMessage(e)}')),
    );
  }
}

class _PeriodSelector extends ConsumerWidget {
  final SpendPeriod selected;
  const _PeriodSelector({required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
      child: Row(
        children: [
          for (final p in SpendPeriod.values) ...[
            ChoiceChip(
              label: Text(p.label),
              selected: p == selected,
              onSelected: (_) => ref.read(selectedSpendPeriodProvider.notifier).state = p,
              labelStyle: BambooFonts.ui(
                13,
                weight: p == selected ? FontWeight.w700 : FontWeight.w500,
                color: p == selected ? BambooInk.onSlate : BambooInk.ink900,
              ),
              selectedColor: BambooInk.slate,
              backgroundColor: BambooInk.paperMuted,
              side: BorderSide.none,
              showCheckmark: false,
            ),
            const SizedBox(width: AppSpace.sm),
          ],
        ],
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  final SpendReport report;
  final VoidCallback onRefresh;
  const _ReportBody({required this.report, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xl),
        children: [
          _HeadlineCard(report: report),
          const SizedBox(height: AppSpace.lg),
          if (report.series.length > 1) ...[
            _TrendChart(report: report),
            const SizedBox(height: AppSpace.lg),
          ],
          if (!report.income.total.isZero || !report.investment.total.isZero) ...[
            _FlowCard(report: report),
            const SizedBox(height: AppSpace.lg),
          ],
          _SectionHeader('Where it went'),
          for (final row in report.byCategory)
            _BreakdownRow(label: row.label, amount: row.total, total: report.spend.total, count: row.txnCount),
          const SizedBox(height: AppSpace.lg),
          _SectionHeader('Which card'),
          for (final row in report.byCard) _CardRow(row: row, total: report.spend.total),
          const SizedBox(height: AppSpace.lg),
          _SectionHeader('Top merchants'),
          for (final row in report.byMerchant.take(10))
            _BreakdownRow(label: row.label, amount: row.total, total: report.spend.total, count: row.txnCount),
          const SizedBox(height: AppSpace.lg),
          // The transaction list is the drill-down from a spend summary, so
          // it lives here rather than as its own tile on a grid of
          // eighteen. Every figure above is an aggregate of these rows.
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            icon: const Icon(Icons.receipt_long_rounded, size: 18),
            label: const Text('See every transaction'),
            onPressed: () => context.push(AppRoute.activity),
          ),
        ],
      ),
    );
  }
}

/// The headline: what was spent, how that compares, and where it's heading.
///
/// The comparison is the point. A bare "₹42,000" says almost nothing; the
/// same figure next to "18% more than last month" is a fact someone can act
/// on.
class _HeadlineCard extends StatelessWidget {
  final SpendReport report;
  const _HeadlineCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final change = report.changeVsPrevious;
    final projected = report.projectedSpend;

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
            '${report.period.label} · ${report.spend.txnCount} transaction'
            '${report.spend.txnCount == 1 ? '' : 's'}',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: 4),
          MoneyText(
            report.spend.total,
            confidence: Confidence.estimated,
            style: BambooFonts.money(32, color: BambooInk.onSlate),
          ),
          if (change != null) ...[
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Icon(
                  change >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                  size: 15,
                  // Neither direction is coloured as good or bad. Spending
                  // less isn't automatically a win (it might be a month with
                  // no rent due), and this screen reports rather than judges.
                  color: BambooInk.onSlateMuted,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    '${(change.abs() * 100).toStringAsFixed(0)}% '
                    '${change >= 0 ? 'more' : 'less'} than ${report.period.previousLabel.toLowerCase()}'
                    ' (${report.previousSpend.total.format(hidePaise: true)})',
                    style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (projected != null && report.elapsedFraction < 0.95) ...[
            const SizedBox(height: 6),
            Text(
              'On track for about ${projected.format(compact: true)} by '
              '${report.period.label.toLowerCase().replaceFirst('this ', 'the end of this ')}',
              style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
            ),
          ],
          if (!report.spend.rewards.isZero) ...[
            const SizedBox(height: AppSpace.md),
            Container(height: 1, color: BambooInk.onSlateMuted.withValues(alpha: 0.2)),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Text('Rewards earned', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
                const Spacer(),
                MoneyText(
                  report.spend.rewards,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(14, weight: FontWeight.w700, color: BambooInk.lime),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Income, spend and investment on their own lines, plus what's left.
///
/// Deliberately three separate figures rather than one blended total:
/// an investment is not spending, and money moved into an SIP is not money
/// gone. Folding them together is the fastest way to make every number on
/// this screen wrong.
class _FlowCard extends StatelessWidget {
  final SpendReport report;
  const _FlowCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final net = report.netFlow;
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        children: [
          _FlowRow(label: 'Money in', amount: report.income.total),
          const SizedBox(height: AppSpace.sm),
          _FlowRow(label: 'Spent', amount: report.spend.total),
          if (!report.investment.total.isZero) ...[
            const SizedBox(height: AppSpace.sm),
            _FlowRow(label: 'Invested', amount: report.investment.total),
          ],
          const SizedBox(height: AppSpace.sm),
          Container(height: 1, color: BambooInk.ink500.withValues(alpha: 0.15)),
          const SizedBox(height: AppSpace.sm),
          _FlowRow(
            label: net.isNegative ? 'Short by' : 'Left over',
            amount: net.isNegative ? -net : net,
            emphasise: true,
          ),
        ],
      ),
    );
  }
}

class _FlowRow extends StatelessWidget {
  final String label;
  final Money amount;
  final bool emphasise;
  const _FlowRow({required this.label, required this.amount, this.emphasise = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: BambooFonts.ui(
            13,
            weight: emphasise ? FontWeight.w700 : FontWeight.w500,
            color: BambooInk.ink900,
          ),
        ),
        const Spacer(),
        MoneyText(
          amount,
          confidence: Confidence.estimated,
          style: BambooFonts.ui(
            13.5,
            weight: emphasise ? FontWeight.w700 : FontWeight.w500,
            color: BambooInk.ink900,
          ),
        ),
      ],
    );
  }
}

/// A bar per period, tallest scaled to full height.
///
/// A CustomPaint would give finer control, but bars in a Row are legible,
/// accessible to the semantics tree, and cheap — and the question this
/// answers ("is the trend up or down?") needs shape, not precision.
class _TrendChart extends StatelessWidget {
  final SpendReport report;
  const _TrendChart({required this.report});

  @override
  Widget build(BuildContext context) {
    final maxPaise = report.series.fold<int>(0, (m, p) => p.spend.paise > m ? p.spend.paise : m);
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Last ${report.series.length} ${_unitLabel(report.period, report.series.length)}',
            style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          SizedBox(
            height: 96,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < report.series.length; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Semantics(
                        label: '${_barLabel(report.period, report.series[i].periodStart)}: '
                            '${report.series[i].spend.format(hidePaise: true)}',
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Container(
                              // A minimum height of 2 so a zero period is
                              // still visibly a period, not a gap in the
                              // chart that reads as missing data.
                              height: maxPaise == 0
                                  ? 2
                                  : (2 + 86 * (report.series[i].spend.paise / maxPaise)),
                              decoration: BoxDecoration(
                                color: i == report.series.length - 1 ? BambooInk.jade : BambooInk.ink500,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _barLabel(report.period, report.series.first.periodStart),
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
              Text(
                _barLabel(report.period, report.series.last.periodStart),
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _unitLabel(SpendPeriod period, int count) {
    final plural = count == 1 ? '' : 's';
    return switch (period) {
      SpendPeriod.week => 'week$plural',
      SpendPeriod.month => 'month$plural',
      SpendPeriod.quarter => 'quarter$plural',
      SpendPeriod.year => 'year$plural',
    };
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String _barLabel(SpendPeriod period, DateTime start) {
    return switch (period) {
      SpendPeriod.week => '${start.day} ${_months[start.month - 1]}',
      SpendPeriod.month => '${_months[start.month - 1]} ${start.year % 100}',
      SpendPeriod.quarter => 'Q${((start.month - 1) ~/ 3) + 1} ${start.year % 100}',
      SpendPeriod.year => '${start.year}',
    };
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      label.toUpperCase(),
      style: BambooFonts.ui(11.5, weight: FontWeight.w700, color: BambooInk.ink500)
          .copyWith(letterSpacing: 0.8),
    ),
  );
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final Money amount;
  final Money total;
  final int count;

  const _BreakdownRow({
    required this.label,
    required this.amount,
    required this.total,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero ? 0.0 : (amount.paise / total.paise).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                '${(ratio * 100).toStringAsFixed(0)}%',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              const SizedBox(width: AppSpace.sm),
              MoneyText(
                amount,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: BambooInk.paperMuted,
              color: BambooInk.jade,
            ),
          ),
        ],
      ),
    );
  }
}

/// One card's row: spend, and the rate it ACTUALLY paid on that spend.
///
/// The effective rate is the honest number — rewards divided by spend, not
/// the rate on the card's marketing page. A 5% headline card capped at
/// ₹3,000/month against ₹40,000 of spend has an effective rate near 1%, and
/// that is the figure that answers "is this annual fee worth paying".
class _CardRow extends StatelessWidget {
  final CardSpendRow row;
  final Money total;
  const _CardRow({required this.row, required this.total});

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero ? 0.0 : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final rate = row.effectiveRatePerRupee;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.cardName,
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              MoneyText(
                row.total,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
              ),
            ],
          ),
          if (rate != null && !row.rewards.isZero) ...[
            const SizedBox(height: 2),
            Text(
              'Earned ${row.rewards.format(hidePaise: true)} — '
              '${(rate * 100).toStringAsFixed(2)}% back on what you spent here',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ],
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: BambooInk.paperMuted,
              color: BambooInk.jade,
            ),
          ),
        ],
      ),
    );
  }
}
