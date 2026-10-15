import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/offline_banner.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../cards/card_summary.dart';
import 'spending_visuals.dart';

/// Rows for the same calendar period as the aggregate report. The report
/// endpoint remains the source of truth for totals; this companion request
/// only supplies the transaction-level rows needed by expandable details.
final spendPeriodTransactionsProvider =
    FutureProvider.family<List<TransactionEntry>, SpendPeriod>((
      ref,
      period,
    ) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) return const [];

      final report = await ref.watch(spendReportProvider(period).future);
      if (report == null) return const [];

      return loadTransactionsWithOfflineCache(
        ref,
        repo: repo,
        cacheKey:
            'spend_detail:${period.wireValue}:${report.periodStart.toIso8601String()}:${report.periodEnd.toIso8601String()}',
        from: report.periodStart,
        to: report.periodEnd.subtract(const Duration(days: 1)),
      );
    });

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
    final transactions = ref.watch(spendPeriodTransactionsProvider(period));

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        elevation: 0,
        title: Text(
          'Spending',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
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
            OfflineBanner(
              gutter: AppSpace.lg,
              onRetry: () {
                ref.invalidate(spendReportProvider(period));
                ref.invalidate(spendPeriodTransactionsProvider(period));
              },
            ),
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
                      message:
                          'Spending reports are built from your transaction history, which lives '
                          'with your account.',
                    );
                  }
                  if (data.spend.txnCount == 0 && data.income.txnCount == 0) {
                    return _NoSpendingReportState(
                      period: period,
                      onRefresh: () async =>
                          ref.invalidate(spendReportProvider(period)),
                    );
                  }
                  return _ReportBody(
                    report: data,
                    transactions: transactions.valueOrNull ?? const [],
                    transactionDetailsLoading: transactions.isLoading,
                    onRefresh: () {
                      ref.invalidate(spendReportProvider(period));
                      ref.invalidate(spendPeriodTransactionsProvider(period));
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoSpendingReportState extends StatelessWidget {
  final SpendPeriod period;
  final Future<void> Function() onRefresh;

  const _NoSpendingReportState({required this.period, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.xl,
          AppSpace.lg,
          AppSpace.xl,
        ),
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  BambooInk.slateRaised,
                  BambooInk.slate,
                  BambooInk.slateLow,
                ],
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${period.label} spending',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.xs),
                MoneyText(
                  const Money.zero(),
                  confidence: Confidence.estimated,
                  style: BambooFonts.money(30, color: BambooInk.lime),
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  'No spending recorded',
                  style: BambooFonts.heading(16, color: BambooInk.onSlate),
                ),
                const SizedBox(height: AppSpace.xs),
                Text(
                  'Bill payments, transfers, refunds, and reversals are excluded from spending. '
                  'Purchases will appear here after SMS import completes.',
                  style: BambooFonts.ui(13, color: BambooInk.onSlateMuted),
                ),
              ],
            ),
          ),
        ],
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
Future<void> _exportCsv(
  BuildContext context,
  WidgetRef ref,
  SpendReport report,
) async {
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
    final stamp =
        '${report.periodStart.year}-'
        '${report.periodStart.month.toString().padLeft(2, '0')}';
    final file = File('${dir.path}/pandapay-spending-$stamp.csv');
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'My PandaPay spending report',
      ),
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
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      child: Row(
        children: [
          for (final p in SpendPeriod.values) ...[
            ChoiceChip(
              label: Text(p.label),
              selected: p == selected,
              onSelected: (_) =>
                  ref.read(selectedSpendPeriodProvider.notifier).state = p,
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

class _ReportBody extends StatefulWidget {
  final SpendReport report;
  final List<TransactionEntry> transactions;
  final bool transactionDetailsLoading;
  final VoidCallback onRefresh;
  const _ReportBody({
    required this.report,
    required this.transactions,
    required this.transactionDetailsLoading,
    required this.onRefresh,
  });

  @override
  State<_ReportBody> createState() => _ReportBodyState();
}

class _ReportBodyState extends State<_ReportBody> {
  List<TransactionEntry> _transactionsForCategory(SpendBreakdownRow row) {
    return widget.transactions.where((entry) {
      if (entry.status != 'active' || entry.entryKind != TxnEntryKind.spend) {
        return false;
      }
      if (row.categoryId != null) return entry.categoryId == row.categoryId;
      return (entry.categoryName ?? 'Other').toLowerCase() ==
          row.label.toLowerCase();
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    return RefreshIndicator(
      onRefresh: () async => widget.onRefresh(),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.sm,
          AppSpace.lg,
          AppSpace.xl,
        ),
        children: [
          _HeadlineCard(report: report),
          const SizedBox(height: AppSpace.lg),
          if (!report.income.total.isZero ||
              !report.investment.total.isZero) ...[
            _FlowCard(report: report),
            const SizedBox(height: AppSpace.lg),
          ],
          if (report.byCategory.isNotEmpty) ...[
            _SpendingMixCard(report: report),
            const SizedBox(height: AppSpace.lg),
            _SectionHeader('Categories'),
            for (final row in report.byCategory)
              _ExpandableCategoryRow(
                row: row,
                total: report.spend.total,
                entries: _transactionsForCategory(row),
                detailsLoading: widget.transactionDetailsLoading,
              ),
            const SizedBox(height: AppSpace.lg),
          ],
          if (report.byInstrument.isNotEmpty) ...[
            _BreakdownPanel(
              title: 'Payment method',
              visual: const SpendingVisual(
                icon: Icons.payments_rounded,
                accent: BambooChartColors.blue,
              ),
              child: Column(
                children: [
                  for (final row in report.byInstrument)
                    _BreakdownRow(
                      label: row.label,
                      amount: row.total,
                      total: report.spend.total,
                      count: row.txnCount,
                      visual: spendingInstrumentVisual(row.instrument),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          if (report.byCard.isNotEmpty) ...[
            _BreakdownPanel(
              title: 'Which card',
              visual: const SpendingVisual(
                icon: Icons.credit_card_rounded,
                accent: BambooChartColors.violet,
              ),
              child: Column(
                children: [
                  for (final row in report.byCard)
                    _CardRow(row: row, total: report.spend.total),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          if (report.byCardCategory.isNotEmpty) ...[
            _BreakdownPanel(
              title: 'Card spending by category',
              visual: const SpendingVisual(
                icon: Icons.auto_graph_rounded,
                accent: BambooChartColors.amber,
              ),
              child: Column(
                children: [
                  for (final row in report.byCardCategory)
                    _BreakdownRow(
                      label: '${row.cardName} · ${row.categoryName}',
                      amount: row.total,
                      total: report.spend.total,
                      count: row.txnCount,
                      visual: spendingCategoryVisual(row.categoryName),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          if (report.byMerchant.isNotEmpty) ...[
            _BreakdownPanel(
              title: 'Top merchants',
              visual: const SpendingVisual(
                icon: Icons.storefront_rounded,
                accent: BambooChartColors.coral,
              ),
              child: Column(
                children: [
                  for (final row in report.byMerchant.take(10))
                    _BreakdownRow(
                      label: row.label,
                      amount: row.total,
                      total: report.spend.total,
                      count: row.txnCount,
                      visual: const SpendingVisual(
                        icon: Icons.storefront_rounded,
                        accent: BambooChartColors.coral,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
          ],
          // The transaction list is the drill-down from a spend summary, so
          // it lives here rather than as its own tile on a grid of
          // eighteen. Every figure above is an aggregate of these rows.
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
              foregroundColor: BambooInk.ink900,
              side: const BorderSide(color: BambooInk.hairlineOnPaper),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
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
                  change >= 0
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded,
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
            Container(
              height: 1,
              color: BambooInk.onSlateMuted.withValues(alpha: 0.2),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                Text(
                  'Rewards earned',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                ),
                const Spacer(),
                MoneyText(
                  report.spend.rewards,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w700,
                    color: BambooInk.lime,
                  ),
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
  const _FlowRow({
    required this.label,
    required this.amount,
    this.emphasise = false,
  });

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

/// A visual summary of the same category totals shown in the expandable rows
/// below it. The chart is deliberately decorative rather than a second data
/// source: every slice is built directly from [SpendReport.byCategory].
class _SpendingMixCard extends StatelessWidget {
  final SpendReport report;

  const _SpendingMixCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final rows = [...report.byCategory]
      ..removeWhere((row) => row.total.isZero)
      ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
    final visibleRows = rows.take(4).toList();
    final remaining = rows.length - visibleRows.length;

    return CardSummaryPanel(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SpendingVisualBadge(
                visual: const SpendingVisual(
                  icon: Icons.pie_chart_rounded,
                  accent: BambooChartColors.teal,
                ),
                size: 38,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Spending mix',
                      style: BambooFonts.heading(15, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rows.length} ${rows.length == 1 ? 'category' : 'categories'} · tap a row below for details',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _SpendingDonut(rows: rows, total: report.spend.total),
              const SizedBox(width: AppSpace.lg),
              Expanded(
                child: Column(
                  children: [
                    for (final row in visibleRows)
                      _MixLegendRow(row: row, total: report.spend.total),
                    if (remaining > 0) ...[
                      const SizedBox(height: AppSpace.xs),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '+$remaining more ${remaining == 1 ? 'category' : 'categories'} below',
                          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpendingDonut extends StatelessWidget {
  final List<SpendBreakdownRow> rows;
  final Money total;

  const _SpendingDonut({required this.rows, required this.total});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      height: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size.square(132),
            painter: _SpendingDonutPainter(rows: rows),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: MoneyText(
                  total,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(
                    16,
                    weight: FontWeight.w800,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
              Text(
                'spent',
                style: BambooFonts.ui(10.5, color: BambooInk.ink500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpendingDonutPainter extends CustomPainter {
  final List<SpendBreakdownRow> rows;

  const _SpendingDonutPainter({required this.rows});

  @override
  void paint(Canvas canvas, Size size) {
    final totalPaise = rows.fold<int>(0, (sum, row) => sum + row.total.paise);
    final rect = Offset.zero & size;
    final track = Paint()
      ..color = BambooChartColors.chartTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18;
    canvas.drawArc(rect.deflate(10), 0, math.pi * 2, false, track);

    if (totalPaise == 0) return;

    var start = -math.pi / 2;
    for (final row in rows) {
      final sweep = math.pi * 2 * row.total.paise / totalPaise;
      final paint = Paint()
        ..color = spendingCategoryVisual(row.label).accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18;
      canvas.drawArc(rect.deflate(10), start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _SpendingDonutPainter oldDelegate) =>
      oldDelegate.rows != rows;
}

class _MixLegendRow extends StatelessWidget {
  final SpendBreakdownRow row;
  final Money total;

  const _MixLegendRow({required this.row, required this.total});

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final visual = spendingCategoryVisual(row.label);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          _SpendingVisualBadge(visual: visual, size: 27),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              '${row.label} · ${(ratio * 100).toStringAsFixed(0)}%',
              style: BambooFonts.ui(12, color: BambooInk.ink900),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(
                row.total,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(
                  12,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              const SizedBox.shrink(),
            ],
          ),
        ],
      ),
    );
  }
}

class _BreakdownPanel extends StatelessWidget {
  final String title;
  final SpendingVisual visual;
  final Widget child;

  const _BreakdownPanel({
    required this.title,
    required this.visual,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return CardSummaryPanel(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SpendingVisualBadge(
                visual: visual,
                size: 34,
              ),
              const SizedBox(width: AppSpace.md),
              Text(
                title.toUpperCase(),
                style: BambooFonts.ui(
                  11.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink500,
                ).copyWith(letterSpacing: 0.8),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          child,
        ],
      ),
    );
  }
}

class _SpendingVisualBadge extends StatelessWidget {
  final SpendingVisual visual;
  final double size;

  const _SpendingVisualBadge({required this.visual, required this.size});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: visual.surface,
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    alignment: Alignment.center,
    child: Icon(visual.icon, size: size * 0.46, color: visual.accent),
  );
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      label.toUpperCase(),
      style: BambooFonts.ui(
        11.5,
        weight: FontWeight.w700,
        color: BambooInk.ink500,
      ).copyWith(letterSpacing: 0.8),
    ),
  );
}

/// A category total that can be opened without leaving the report. The
/// expanded content is built from the same transaction rows used by Activity,
/// so merchants, cards, dates and rewards remain traceable to a real payment.
class _ExpandableCategoryRow extends StatelessWidget {
  final SpendBreakdownRow row;
  final Money total;
  final List<TransactionEntry> entries;
  final bool detailsLoading;

  const _ExpandableCategoryRow({
    required this.row,
    required this.total,
    required this.entries,
    required this.detailsLoading,
  });

  List<MapEntry<String, List<TransactionEntry>>> _merchantGroups() {
    final grouped = <String, List<TransactionEntry>>{};
    for (final entry in entries) {
      final merchant = (entry.merchantName?.trim().isNotEmpty ?? false)
          ? entry.merchantName!.trim()
          : 'Unknown merchant';
      grouped.putIfAbsent(merchant, () => []).add(entry);
    }
    final result = grouped.entries.toList()
      ..sort((a, b) {
        final aTotal = a.value.fold<int>(
          0,
          (sum, entry) => sum + entry.amount.paise,
        );
        final bTotal = b.value.fold<int>(
          0,
          (sum, entry) => sum + entry.amount.paise,
        );
        return bTotal.compareTo(aTotal);
      });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final groups = _merchantGroups();

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.fromLTRB(
          AppSpace.md,
          AppSpace.sm,
          AppSpace.sm,
          AppSpace.sm,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(
          AppSpace.md,
          0,
          AppSpace.md,
          AppSpace.sm,
        ),
        shape: const Border(),
        collapsedShape: const Border(),
        leading: _SpendingVisualBadge(
          visual: spendingCategoryVisual(row.label),
          size: 38,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row.label,
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
                  row.total,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(
                    13.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${row.txnCount} ${row.txnCount == 1 ? 'transaction' : 'transactions'} · Tap to see merchants',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: BambooInk.paperMuted,
                color: spendingCategoryVisual(row.label).accent,
              ),
            ),
          ],
        ),
        children: [
          if (detailsLoading && entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Loading transaction details…'),
              ),
            )
          else if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Transaction details are not available for this period yet.',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              ),
            )
          else
            for (final group in groups)
              _MerchantGroup(merchant: group.key, entries: group.value),
        ],
      ),
    );
  }
}

class _MerchantGroup extends StatelessWidget {
  final String merchant;
  final List<TransactionEntry> entries;

  const _MerchantGroup({required this.merchant, required this.entries});

  @override
  Widget build(BuildContext context) {
    final amount = entries.fold<Money>(
      const Money.zero(),
      (sum, entry) => sum + entry.amount,
    );
    final rewards = entries.fold<Money>(
      const Money.zero(),
      (sum, entry) => sum + (entry.rewardValue ?? const Money.zero()),
    );
    final hasRewardData = entries.any((entry) => entry.rewardValue != null);
    final cards = entries
        .map((entry) => entry.cardDisplayName ?? _paymentLabel(entry))
        .toSet()
        .join(', ');
    final sorted = [...entries]
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return CardSummaryPanel(
      padding: const EdgeInsets.all(AppSpace.sm),
      elevated: false,
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _SpendingVisualBadge(
                visual: SpendingVisual(
                  icon: Icons.storefront_rounded,
                  accent: BambooChartColors.coral,
                ),
                size: 30,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  merchant,
                  style: BambooFonts.ui(
                    12.5,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
              ),
              MoneyText(
                amount,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${entries.length} ${entries.length == 1 ? 'transaction' : 'transactions'} · $cards',
            style: BambooFonts.ui(11, color: BambooInk.ink500),
          ),
          if (hasRewardData)
            Text(
              'Rewards earned ${rewards.format()}',
              style: BambooFonts.ui(11, color: BambooInk.ink500),
            ),
          const SizedBox(height: 2),
          for (final entry in sorted)
            Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  '${_shortDate(entry.occurredAt)} · ${_paymentLabel(entry)}',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink900),
                ),
                subtitle: Text(
                  entry.cardDisplayName ?? entry.instrument.label,
                  style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                ),
                trailing: MoneyText(
                  entry.amount,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(
                    11.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
                onTap: () => context.push('/activity/${entry.id}'),
              ),
            ),
        ],
      ),
    );
  }

  static String _shortDate(DateTime date) {
    final local = date.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/${local.year}';
  }

  static String _paymentLabel(TransactionEntry entry) {
    if (entry.cardLast4 != null) {
      return '${entry.instrument.label} ••${entry.cardLast4}';
    }
    return entry.instrument.label;
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final Money amount;
  final Money total;
  final int count;
  final SpendingVisual visual;

  const _BreakdownRow({
    required this.label,
    required this.amount,
    required this.total,
    required this.count,
    required this.visual,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (amount.paise / total.paise).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SpendingVisualBadge(visual: visual, size: 34),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$count ${count == 1 ? 'transaction' : 'transactions'}',
                      style: BambooFonts.ui(11, color: BambooInk.ink500),
                    ),
                  ],
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
                style: BambooFonts.ui(
                  13.5,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: BambooInk.paperMuted,
              color: visual.accent,
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
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final rate = row.effectiveRatePerRupee;
    final visual = SpendingVisual(
      icon: row.cardId == null
          ? Icons.account_balance_rounded
          : Icons.credit_card_rounded,
      accent: row.cardId == null
          ? BambooChartColors.violet
          : BambooChartColors.blue,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _SpendingVisualBadge(
                visual: visual,
                size: 34,
              ),
              const SizedBox(width: AppSpace.sm),
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
                style: BambooFonts.ui(
                  13.5,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${row.txnCount} ${row.txnCount == 1 ? 'transaction' : 'transactions'}',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: 2),
          Text(
            rate != null && !row.rewards.isZero
                ? 'Rewards earned ${row.rewards.format(hidePaise: true)} — '
                      '${(rate * 100).toStringAsFixed(2)}% back on what you spent here'
                : 'Rewards earned ${row.rewards.format(hidePaise: true)}',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: BambooInk.paperMuted,
              color: visual.accent,
            ),
          ),
        ],
      ),
    );
  }
}
