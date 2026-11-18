import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../../../data/api_exception.dart';
import '../../../data/reward_counting.dart';
import '../../../data/user_cards_repository.dart';
import '../../../main.dart' show MoneyText;
import '../../cards/card_summary.dart';
import '../../cards/card_visual.dart';
import '../as_of_caption.dart';
import '../spending_visuals.dart';
import 'rewards_filter.dart';
import 'rewards_filter_sheet.dart';
import 'rewards_report.dart';
import 'rewards_screen.dart' show RewardsTab;

typedef RewardsOpenTab =
    void Function(RewardsTab tab, {RewardRowStatus? status});

String _percent(double value) =>
    value >= 10 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);

String _plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : (many ?? '${one}s')}';

void _openTransaction(BuildContext context, TransactionEntry entry) {
  context.push('/activity/${entry.id}', extra: entry);
}

/// What an empty page says, depending on whether filters are hiding things.
Widget _emptyScope({
  required RewardsReport report,
  required RewardsFilter filter,
  required ValueChanged<RewardsFilter> onFilterChanged,
}) {
  if (filter.narrowed) {
    return EmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'Nothing matches these filters',
      message:
          'No card spends in ${rewardsRangeLabel(report.range)} for the cards '
          'and categories you picked.',
      action: OutlinedButton(
        onPressed: () => onFilterChanged(
          filter.copyWith(cardIds: const {}, categories: const {}),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: BambooInk.ink900,
          side: const BorderSide(color: BambooInk.hairlineOnPaper),
          minimumSize: const Size(0, 44),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        child: const Text('Clear filters'),
      ),
    );
  }
  return EmptyState(
    icon: Icons.workspace_premium_outlined,
    title: 'No card spends in ${rewardsRangeLabel(report.range)}',
    message:
        'Rewards show up here for purchases paid by a credit card in your '
        'wallet. Try a longer date range.',
  );
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

/// Summary: everything on one phone screen, display only. Nothing here
/// changes the page's filters: an earlier version narrowed the page when a
/// month bar or category was tapped, which made the chart disappear and the
/// date at the top change, and read as broken. Dates, cards and categories
/// are set with the bar above the tabs only.
class RewardsSummaryTab extends StatefulWidget {
  final RewardsReport report;
  final RewardsFilter filter;
  final ValueChanged<RewardsFilter> onFilterChanged;
  final RewardsOpenTab onOpenTab;

  const RewardsSummaryTab({
    super.key,
    required this.report,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpenTab,
  });

  @override
  State<RewardsSummaryTab> createState() => _RewardsSummaryTabState();
}

class _RewardsSummaryTabState extends State<RewardsSummaryTab> {
  final _shareKey = GlobalKey();

  Future<void> _share() async {
    try {
      final boundary =
          _shareKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/pandapay_rewards.png');
      await file.writeAsBytes(bytes.buffer.asUint8List());
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'My PandaPay rewards'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not share. ${userFacingErrorMessage(e)}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    if (report.rows.isEmpty) {
      return _emptyScope(
        report: report,
        filter: widget.filter,
        onFilterChanged: widget.onFilterChanged,
      );
    }
    final scopeLine = [
      for (final id in widget.filter.cardIds) report.cardLabel(id) ?? 'Card',
      ...widget.filter.categories,
    ].join(' · ');

    final tiles = <Widget>[
      if (report.notCountedCount > 0)
        _StatTile(
          key: const Key('rewards-not-counted'),
          icon: Icons.hourglass_top_rounded,
          accent: BambooInk.amber,
          label: 'Not counted yet',
          semanticLabel:
              '${_plural(report.notCountedCount, 'spend')} not counted yet',
          value: Text(
            _plural(report.notCountedCount, 'spend'),
            style: BambooFonts.ui(
              14.5,
              weight: FontWeight.w700,
              color: BambooInk.ink900,
            ),
          ),
          onTap: () => widget.onOpenTab(
            RewardsTab.transactions,
            status: RewardRowStatus.notCounted,
          ),
        ),
      if (report.missedCount > 0)
        _StatTile(
          key: const Key('rewards-missed-line'),
          icon: Icons.trending_down_rounded,
          accent: BambooInk.clay,
          label: 'Missed on ${_plural(report.missedCount, 'spend')}',
          semanticLabel:
              'Missed on ${_plural(report.missedCount, 'spend')}, '
              '${report.missed.format(hidePaise: true)}',
          value: MoneyText(
            report.missed,
            confidence: Confidence.estimated,
            showConfidenceIcon: false,
            hidePaise: true,
            prefix: '≈ ',
            style: BambooFonts.money(14.5, color: BambooInk.clay),
          ),
          onTap: () => widget.onOpenTab(RewardsTab.missed),
        ),
    ];

    return ListView(
      key: const PageStorageKey('rewards-summary'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.xl,
      ),
      children: [
        const AsOfLastSyncCaption(),
        Stack(
          children: [
            RepaintBoundary(
              key: _shareKey,
              child: _Hero(
                report: report,
                rangeLabel: rewardsRangeLabel(report.range),
                scopeLine: scopeLine.isEmpty ? null : scopeLine,
              ),
            ),
            // Outside the boundary, so the shared image has no button on it.
            Positioned(
              right: 0,
              bottom: 0,
              child: IconButton(
                key: const Key('rewards-share'),
                tooltip: 'Share',
                onPressed: _share,
                icon: const Icon(
                  Icons.ios_share_rounded,
                  size: 18,
                  color: BambooInk.onSlateMuted,
                ),
              ),
            ),
          ],
        ),
        if (tiles.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpace.sm),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          ),
        ],
        if (report.byCategory.isNotEmpty) ...[
          const _SectionTitle('Where it came from'),
          _CategoryBreakdown(slices: report.byCategory, earned: report.earned),
        ],
        if (report.buckets.isNotEmpty) ...[
          _SectionTitle(
            report.buckets.first.isYear ? 'Year by year' : 'Month by month',
          ),
          _EarnedBars(buckets: report.buckets),
        ],
        const SizedBox(height: AppSpace.md),
        Text(
          'Estimated from each card\'s rules. What the bank credits can differ.',
          style: BambooFonts.ui(11, color: BambooInk.ink500, height: 1.35),
        ),
      ],
    );
  }
}

/// The shareable answer to "how much did my cards earn?". Only what is inside
/// this widget lands in the shared image. Kept to about a fifth of the screen
/// so the rest of Summary fits under it.
class _Hero extends StatelessWidget {
  final RewardsReport report;
  final String rangeLabel;
  final String? scopeLine;

  const _Hero({
    required this.report,
    required this.rangeLabel,
    required this.scopeLine,
  });

  @override
  Widget build(BuildContext context) {
    final rate = report.ratePct;
    final beat = report.beatBestSingleCard;
    final caption = BambooFonts.ui(12, color: BambooInk.onSlateMuted);
    return Container(
      key: const Key('rewards-hero'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.md,
      ),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const PandaMark(size: 18),
              const SizedBox(width: 6),
              Text('Rewards earned', style: caption),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  scopeLine == null ? rangeLabel : '$rangeLabel · $scopeLine',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w600,
                    color: BambooInk.onSlateMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: MoneyText(
              report.earned,
              key: const Key('rewards-earned'),
              confidence: Confidence.estimated,
              hidePaise: true,
              style: BambooFonts.money(32, color: BambooInk.lime),
            ),
          ),
          const SizedBox(height: 2),
          Padding(
            // Room for the share button on this corner.
            padding: EdgeInsets.only(right: beat == null ? 36 : 0),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                MoneyText(
                  report.spend,
                  confidence: Confidence.estimated,
                  showConfidenceIcon: false,
                  hidePaise: true,
                  prefix: 'on ',
                  suffix: ' by card',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlate),
                ),
                Text(
                  [
                    if (rate != null) '${_percent(rate)}% back',
                    _plural(report.rows.length, 'spend'),
                  ].map((part) => '· $part').join(' '),
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateSubtle),
                ),
              ],
            ),
          ),
          if (beat != null) ...[
            const SizedBox(height: AppSpace.sm),
            const Divider(height: 1, color: BambooInk.slateHairline),
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.only(right: 36),
              child: Row(
                children: [
                  const Icon(
                    Icons.trending_up_rounded,
                    size: 16,
                    color: BambooInk.lime,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'More than only ${report.bestSingleCardName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(12, color: BambooInk.onSlate),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  MoneyText(
                    beat,
                    key: const Key('rewards-beat-single-card'),
                    confidence: Confidence.estimated,
                    showConfidenceIcon: false,
                    hidePaise: true,
                    prefix: '+',
                    style: BambooFonts.money(13, color: BambooInk.lime),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A half-width figure that opens the tab with the detail behind it.
class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final String semanticLabel;
  final Widget value;
  final VoidCallback onTap;

  const _StatTile({
    super.key,
    required this.icon,
    required this.accent,
    required this.label,
    required this.semanticLabel,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      child: CardSummaryPanel(
        elevated: false,
        padding: const EdgeInsets.fromLTRB(
          AppSpace.md,
          AppSpace.sm,
          AppSpace.xs,
          AppSpace.sm,
        ),
        child: Row(
          children: [
            _IconBadge(icon: icon, accent: accent, size: 30),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: 1),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: value,
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: BambooInk.ink300,
            ),
          ],
        ),
      ),
    );
  }
}

/// Donut beside its legend, the top categories only, display only.
class _CategoryBreakdown extends StatefulWidget {
  final List<RewardSlice> slices;
  final Money earned;

  const _CategoryBreakdown({required this.slices, required this.earned});

  @override
  State<_CategoryBreakdown> createState() => _CategoryBreakdownState();
}

class _CategoryBreakdownState extends State<_CategoryBreakdown> {
  static const _shown = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final slices = widget.slices;
    final total = slices.fold<int>(0, (sum, s) => sum + s.earned.paise);
    if (total <= 0) return const SizedBox.shrink();
    const colors = BambooChartColors.categorical;
    final visible = _expanded ? slices : slices.take(_shown).toList();

    return CardSummaryPanel(
      key: const Key('rewards-categories'),
      elevated: false,
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 84,
                height: 84,
                child: CustomPaint(
                  painter: _DonutPainter(
                    values: [for (final s in slices) s.earned.paise.toDouble()],
                    colors: colors,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < visible.length; i++)
                      _LegendRow(
                        slice: visible[i],
                        share: visible[i].earned.paise / total,
                        color: colors[i % colors.length],
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (slices.length > _shown)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.ink700,
                  minimumSize: const Size(44, 36),
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: BambooFonts.ui(12, weight: FontWeight.w700),
                ),
                child: Text(
                  _expanded ? 'Show top $_shown' : 'Show all ${slices.length}',
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  final RewardSlice slice;
  final double share;
  final Color color;

  const _LegendRow({
    required this.slice,
    required this.share,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              slice.key,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: BambooInk.ink900,
              ),
            ),
          ),
          Text(
            '${(share * 100).round()}%',
            style: BambooFonts.ui(11.5, color: BambooInk.ink500),
          ),
          const SizedBox(width: AppSpace.sm),
          MoneyText(
            slice.earned,
            confidence: Confidence.estimated,
            showConfidenceIcon: false,
            hidePaise: true,
            style: BambooFonts.money(12.5, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }
}

/// Earned per month (or year), display only. The best bar is slate and
/// carries its amount; the rest are tinted.
class _EarnedBars extends StatelessWidget {
  final List<RewardBucket> buckets;

  const _EarnedBars({required this.buckets});

  @override
  Widget build(BuildContext context) {
    final maxPaise = buckets.fold<int>(
      0,
      (best, b) => math.max(best, b.earned.paise),
    );
    RewardBucket? best;
    for (final bucket in buckets) {
      if (best == null || bucket.earned > best.earned) best = bucket;
    }
    String label(RewardBucket b) =>
        b.isYear ? '${b.start.year}' : rewardsMonthShort(b.start);
    String longLabel(RewardBucket b) => b.isYear
        ? '${b.start.year}'
        : '${rewardsMonthShort(b.start)} ${b.start.year}';

    return CardSummaryPanel(
      key: const Key('rewards-month-bars'),
      elevated: false,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (best != null && maxPaise > 0)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Best: ${longLabel(best)}',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
                MoneyText(
                  best.earned,
                  confidence: Confidence.estimated,
                  showConfidenceIcon: false,
                  hidePaise: true,
                  style: BambooFonts.money(12.5, color: BambooInk.ink900),
                ),
              ],
            ),
          const SizedBox(height: AppSpace.xs),
          ExcludeSemantics(
            child: SizedBox(
              height: 72,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final bucket in buckets)
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, box) => Align(
                                alignment: Alignment.bottomCenter,
                                child: Container(
                                  width: math.min(24, box.maxWidth - 4),
                                  height: maxPaise <= 0
                                      ? 2
                                      : math.max(
                                          2,
                                          box.maxHeight *
                                              bucket.earned.paise /
                                              maxPaise,
                                        ),
                                  decoration: BoxDecoration(
                                    color:
                                        identical(bucket, best) && maxPaise > 0
                                        ? BambooInk.slate
                                        : BambooChartColors.teal.withValues(
                                            alpha: 0.55,
                                          ),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(4),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 15,
                            child: Text(
                              label(bucket),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                              textAlign: TextAlign.center,
                              style: BambooFonts.ui(
                                buckets.length > 9 ? 9.5 : 10.5,
                                color: BambooInk.ink500,
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
          // The chart is drawn for the eye; this one line carries it for a
          // screen reader.
          Semantics(
            label: [
              for (final b in buckets)
                '${longLabel(b)} ${b.earned.format(hidePaise: true)}',
            ].join(', '),
            child: const SizedBox(height: 0),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

enum _TxnSort {
  newest('Newest first'),
  reward('Highest reward'),
  amount('Largest amount');

  final String label;
  const _TxnSort(this.label);
}

class RewardsTransactionsTab extends StatefulWidget {
  final RewardsReport report;
  final RewardsFilter filter;
  final RewardRowStatus? status;
  final ValueChanged<RewardRowStatus?> onStatusChanged;
  final ValueChanged<RewardsFilter> onFilterChanged;

  const RewardsTransactionsTab({
    super.key,
    required this.report,
    required this.filter,
    required this.status,
    required this.onStatusChanged,
    required this.onFilterChanged,
  });

  @override
  State<RewardsTransactionsTab> createState() => _RewardsTransactionsTabState();
}

class _RewardsTransactionsTabState extends State<RewardsTransactionsTab> {
  _TxnSort _sort = _TxnSort.newest;

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    if (report.rows.isEmpty) {
      return _emptyScope(
        report: report,
        filter: widget.filter,
        onFilterChanged: widget.onFilterChanged,
      );
    }
    final status = widget.status;
    final rows = [
      for (final row in report.rows)
        if (status == null || row.status == status) row,
    ];
    switch (_sort) {
      case _TxnSort.newest:
        break; // the report is newest first already
      case _TxnSort.reward:
        rows.sort((a, b) => b.reward.paise.compareTo(a.reward.paise));
      case _TxnSort.amount:
        rows.sort(
          (a, b) => b.entry.amount.paise.compareTo(a.entry.amount.paise),
        );
    }
    final earnedInView = rows.fold<Money>(
      const Money.zero(),
      (sum, row) => sum + row.reward,
    );
    final multiYear = report.range.from.year != report.range.toInclusive.year;

    return Column(
      children: [
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.xs,
            ),
            children: [
              for (final (value, label, count) in [
                (null, 'All', report.rows.length),
                (RewardRowStatus.earned, 'Earned', report.earnedCount),
                (RewardRowStatus.noReward, 'No reward', report.noRewardCount),
                (
                  RewardRowStatus.notCounted,
                  'Not counted',
                  report.notCountedCount,
                ),
              ])
                // An empty choice is noise: hidden unless it is the one on.
                if (value == null || count > 0 || status == value)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpace.sm),
                    child: RewardsSelectChip(
                      key: Key('rewards-status-${value?.name ?? 'all'}'),
                      label: label,
                      count: count,
                      selected: status == value,
                      onTap: () => widget.onStatusChanged(value),
                    ),
                  ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.xs,
            AppSpace.sm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _plural(rows.length, 'spend'),
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ),
              MoneyText(
                earnedInView,
                confidence: Confidence.estimated,
                showConfidenceIcon: false,
                hidePaise: true,
                prefix: '≈ ',
                suffix: ' earned',
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
              PopupMenuButton<_TxnSort>(
                key: const Key('rewards-sort'),
                tooltip: 'Sort',
                initialValue: _sort,
                onSelected: (value) => setState(() => _sort = value),
                icon: const Icon(
                  Icons.swap_vert_rounded,
                  color: BambooInk.ink700,
                ),
                itemBuilder: (_) => [
                  for (final value in _TxnSort.values)
                    PopupMenuItem(
                      value: value,
                      child: Text(
                        value.label,
                        style: BambooFonts.ui(
                          14,
                          weight: value == _sort
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: BambooInk.ink900,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(AppSpace.xl),
                  child: Text(
                    'No spends with this status in the range.',
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(13, color: BambooInk.ink500),
                  ),
                )
              : ListView.builder(
                  key: const PageStorageKey('rewards-transactions'),
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.xs,
                    AppSpace.lg,
                    AppSpace.xxl,
                  ),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => _TransactionRow(
                    row: rows[index],
                    cardLabel: rows[index].entry.userCardId == null
                        ? rows[index].entry.cardDisplayName
                        : report.cardLabel(rows[index].entry.userCardId!),
                    showYear: multiYear,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TransactionRow extends StatelessWidget {
  final RewardRow row;
  final String? cardLabel;
  final bool showYear;

  const _TransactionRow({
    required this.row,
    required this.cardLabel,
    required this.showYear,
  });

  @override
  Widget build(BuildContext context) {
    final entry = row.entry;
    final category = rewardCategoryKey(entry);
    final visual = spendingCategoryVisual(category);
    final date = DateFormat(
      showYear ? 'd MMM yy' : 'd MMM',
    ).format(entry.occurredAt.toLocal());
    final title = entry.merchantName?.trim().isNotEmpty == true
        ? entry.merchantName!.trim()
        : entry.categoryLabel;

    final Widget rewardLine = switch (row.status) {
      RewardRowStatus.earned => MoneyText(
        row.reward,
        confidence: Confidence.estimated,
        showConfidenceIcon: false,
        prefix: '≈ ',
        suffix: ' reward',
        hidePaise: row.reward.paise % 100 == 0,
        style: BambooFonts.ui(
          11.5,
          weight: FontWeight.w700,
          color: BambooInk.jade,
        ),
      ),
      RewardRowStatus.noReward => _statusText('No reward', BambooInk.ink500),
      RewardRowStatus.notCounted =>
        row.notCountedReason == RewardNotCountedReason.notInWallet
            ? _statusText('Card not in wallet', BambooInk.amber)
            : _statusText('Not worked out yet', BambooInk.amber),
    };

    return Pressable(
      onTap: () => _openTransaction(context, entry),
      semanticLabel: '$title, $date',
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: BambooInk.hairlineOnPaper)),
        ),
        child: Row(
          children: [
            _IconBadge(icon: visual.icon, accent: visual.accent, size: 36),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(
                      14,
                      weight: FontWeight.w600,
                      color: BambooInk.ink900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [date, ?cardLabel, category].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                MoneyText(
                  entry.amount,
                  confidence: Confidence.confirmed,
                  showConfidenceIcon: false,
                  style: BambooFonts.money(14, color: BambooInk.ink900),
                ),
                const SizedBox(height: 2),
                rewardLine,
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Widget _statusText(String text, Color color) => Text(
    text,
    style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: color),
  );
}

// ---------------------------------------------------------------------------
// Missed
// ---------------------------------------------------------------------------

class RewardsMissedTab extends StatelessWidget {
  final RewardsReport report;
  final RewardsFilter filter;
  final ValueChanged<RewardsFilter> onFilterChanged;

  const RewardsMissedTab({
    super.key,
    required this.report,
    required this.filter,
    required this.onFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (report.rows.isEmpty) {
      return _emptyScope(
        report: report,
        filter: filter,
        onFilterChanged: onFilterChanged,
      );
    }
    if (!report.canCompare) {
      return const EmptyState(
        icon: Icons.add_card_outlined,
        title: 'Add a second card to compare',
        message:
            'Missed rewards compare each spend with your other wallet cards. '
            'With one card there is nothing else it could have gone on.',
      );
    }
    final missed = report.missedRows;
    if (missed.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline_rounded,
        title: 'No missed rewards',
        message:
            'Every spend in ${rewardsRangeLabel(report.range)} went on your '
            'best card for its category.',
      );
    }
    return ListView.builder(
      key: const PageStorageKey('rewards-missed'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      itemCount: missed.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.lg),
            child: _MissedTotal(report: report),
          );
        }
        final row = missed[index - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: _MissedTile(
            row: row,
            usedLabel:
                report.cardLabel(row.entry.userCardId!) ??
                row.missed!.usedCard.name,
          ),
        );
      },
    );
  }
}

class _MissedTotal extends StatelessWidget {
  final RewardsReport report;
  const _MissedTotal({required this.report});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('rewards-missed-total'),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rewardsRangeLabel(report.range),
                      style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Missed on ${_plural(report.missedCount, 'spend')}',
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w700,
                        color: BambooInk.onSlate,
                      ),
                    ),
                  ],
                ),
              ),
              MoneyText(
                report.missed,
                confidence: Confidence.estimated,
                hidePaise: true,
                prefix: '≈ ',
                style: BambooFonts.money(22, color: BambooInk.lime),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Compared at each card\'s base rate for the category. Caps, '
            'milestones and offers are not included.',
            style: BambooFonts.ui(11.5, color: BambooInk.onSlateSubtle),
          ),
        ],
      ),
    );
  }
}

class _MissedTile extends StatelessWidget {
  final RewardRow row;
  final String usedLabel;

  const _MissedTile({required this.row, required this.usedLabel});

  @override
  Widget build(BuildContext context) {
    final entry = row.entry;
    final comparison = row.missed!;
    final better = comparison.betterCard!;
    final category = rewardCategoryKey(entry);
    final visual = spendingCategoryVisual(category);
    final title = entry.merchantName?.trim().isNotEmpty == true
        ? entry.merchantName!.trim()
        : entry.categoryLabel;
    return Pressable(
      onTap: () => _openTransaction(context, entry),
      semanticLabel: '$title, ${better.name} would have earned more',
      child: CardSummaryPanel(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _IconBadge(icon: visual.icon, accent: visual.accent),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: BambooFonts.heading(
                          14.5,
                          color: BambooInk.ink900,
                        ),
                      ),
                      Text(
                        '${DateFormat('d MMM').format(entry.occurredAt.toLocal())} · $category',
                        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                MoneyText(
                  entry.amount,
                  confidence: Confidence.confirmed,
                  showConfidenceIcon: false,
                  style: BambooFonts.money(14, color: BambooInk.ink900),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              children: [
                _CardMini(
                  product: comparison.usedCard,
                  label: usedLabel,
                  muted: true,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    size: 17,
                    color: BambooInk.ink500,
                  ),
                ),
                _CardMini(product: better, label: better.name, muted: false),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Better card would have earned',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                ),
                MoneyText(
                  row.missedValue,
                  confidence: Confidence.estimated,
                  showConfidenceIcon: false,
                  hidePaise: row.missedValue.paise % 100 == 0,
                  prefix: '+',
                  style: BambooFonts.money(13, color: BambooInk.clay),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CardMini extends StatelessWidget {
  final CardProduct product;
  final String label;
  final bool muted;

  const _CardMini({
    required this.product,
    required this.label,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          Opacity(
            opacity: muted ? 0.58 : 1,
            child: CardVisual(
              product: product,
              showProductName: false,
              width: 54,
              height: 34,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(
                11,
                weight: muted ? FontWeight.w500 : FontWeight.w700,
                color: muted ? BambooInk.ink500 : BambooInk.ink900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class RewardsCardsTab extends StatelessWidget {
  final RewardsReport report;
  final RewardsFilter filter;
  final ValueChanged<RewardsFilter> onFilterChanged;
  final RewardsOpenTab onOpenTab;

  const RewardsCardsTab({
    super.key,
    required this.report,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpenTab,
  });

  @override
  Widget build(BuildContext context) {
    if (report.cards.isEmpty) {
      return const EmptyState(
        icon: Icons.credit_card_off_outlined,
        title: 'No cards in your wallet',
        message: 'Add a credit card to see what it earns here.',
      );
    }
    return ListView.builder(
      key: const PageStorageKey('rewards-cards'),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      itemCount: report.cards.length,
      itemBuilder: (context, index) {
        final summary = report.cards[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: _CardPanel(
            summary: summary,
            onShowSpends: summary.spends == 0
                ? null
                : () {
                    onFilterChanged(
                      filter.copyWith(cardIds: {summary.userCardId}),
                    );
                    onOpenTab(RewardsTab.transactions);
                  },
          ),
        );
      },
    );
  }
}

class _CardPanel extends StatelessWidget {
  final RewardCardSummary summary;
  final VoidCallback? onShowSpends;

  const _CardPanel({required this.summary, required this.onShowSpends});

  @override
  Widget build(BuildContext context) {
    final product = summary.product;
    final card = summary.card;
    final rate = summary.ratePct;
    final subtitle = summary.spends == 0
        ? 'No spends in this range'
        : [
            _plural(summary.spends, 'spend'),
            if (rate != null) '${_percent(rate)}% back',
          ].join(' · ');
    final earned = MoneyText(
      summary.earned,
      confidence: Confidence.estimated,
      showConfidenceIcon: false,
      hidePaise: true,
      style: BambooFonts.money(
        16,
        color: summary.spends == 0 ? BambooInk.ink500 : BambooInk.ink900,
      ),
    );

    return CardSummaryPanel(
      key: Key('rewards-card-${summary.userCardId}'),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (product != null)
            CardSummaryHeader(
              product: product,
              title: summary.label,
              subtitle: subtitle,
              visualWidth: 76,
              trailing: earned,
            )
          else
            Row(
              children: [
                const _IconBadge(
                  icon: Icons.credit_card_rounded,
                  accent: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.label,
                        style: BambooFonts.heading(15, color: BambooInk.ink900),
                      ),
                      Text(
                        '$subtitle · no longer in your wallet',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                earned,
              ],
            ),
          if (summary.spends > 0) ...[
            const SizedBox(height: AppSpace.md),
            _Metric(
              label: 'Paid with this card',
              value: MoneyText(
                summary.spend,
                confidence: Confidence.confirmed,
                showConfidenceIcon: false,
                hidePaise: true,
                style: BambooFonts.money(13, color: BambooInk.ink900),
              ),
            ),
            if (summary.missed.paise > 0)
              _Metric(
                label: 'Missed on this card',
                value: MoneyText(
                  summary.missed,
                  confidence: Confidence.estimated,
                  showConfidenceIcon: false,
                  hidePaise: true,
                  prefix: '≈ ',
                  style: BambooFonts.money(13, color: BambooInk.clay),
                ),
              ),
          ],
          if (card != null && product != null) ...[
            const Divider(height: AppSpace.xl),
            _FeeCheck(
              card: card,
              product: product,
              earnedInRange: summary.earned,
            ),
          ],
          if (onShowSpends != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onShowSpends,
                style: TextButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
                ),
                icon: const Icon(Icons.receipt_long_rounded, size: 17),
                label: const Text('See this card\'s spends'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final Widget value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.xs),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: BambooFonts.ui(12.5, color: BambooInk.ink700),
          ),
        ),
        value,
      ],
    ),
  );
}

/// Annual fee against everything the card has earned to date. Not
/// tied to the date filter on purpose: a fee is paid once a year, so a
/// month's rewards against it would always look like a loss.
class _FeeCheck extends StatelessWidget {
  final UserCard card;
  final CardProduct product;
  final Money earnedInRange;

  const _FeeCheck({
    required this.card,
    required this.product,
    required this.earnedInRange,
  });

  @override
  Widget build(BuildContext context) {
    final fee = card.annualFeeOverride ?? product.annualFeeInr;
    // The card's running total (same figure as the card screen). It can lag
    // the per-spend figures for a moment after a sync, and a total below what
    // the card earned in this range alone is never true, so it is floored at
    // that.
    final lifetime = lifetimeRewardValue(card, product);
    final earnedToDate = lifetime > earnedInRange ? lifetime : earnedInRange;
    if (fee == null) {
      return const _Note(
        icon: Icons.help_outline_rounded,
        color: BambooInk.ink500,
        text:
            'Add the annual fee in card settings to check if it pays for itself.',
      );
    }
    if (fee.isZero) {
      return const _Note(
        icon: Icons.check_circle_outline_rounded,
        color: BambooInk.jade,
        text: 'No annual fee.',
      );
    }
    final covered = earnedToDate.paise >= fee.paise;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Metric(
          label: 'Annual fee',
          value: MoneyText(
            fee,
            confidence: Confidence.confirmed,
            showConfidenceIcon: false,
            hidePaise: true,
            style: BambooFonts.money(13, color: BambooInk.ink900),
          ),
        ),
        _Metric(
          label: 'Rewards to date',
          value: MoneyText(
            earnedToDate,
            confidence: Confidence.estimated,
            showConfidenceIcon: false,
            hidePaise: true,
            style: BambooFonts.money(13, color: BambooInk.ink900),
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        _Note(
          icon: covered
              ? Icons.check_circle_outline_rounded
              : Icons.timelapse_rounded,
          color: covered ? BambooInk.jade : BambooInk.amber,
          text: covered
              ? 'Rewards have covered the annual fee.'
              : 'Rewards have not covered the annual fee yet.',
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Note({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: AppSpace.xs),
      Expanded(
        child: Text(text, style: BambooFonts.ui(12, color: color)),
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpace.xs,
      AppSpace.md,
      AppSpace.xs,
      AppSpace.xs,
    ),
    child: Text(
      text,
      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
    ),
  );
}

class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final double size;

  const _IconBadge({required this.icon, required this.accent, this.size = 36});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: accent.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    child: Icon(icon, size: size * 0.52, color: accent),
  );
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;

  const _DonutPainter({required this.values, required this.colors});

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (sum, value) => sum + value);
    if (total <= 0) return;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * math.pi * 2;
      canvas.drawArc(
        rect,
        start,
        sweep,
        true,
        Paint()..color = colors[i % colors.length],
      );
      start += sweep;
    }
    // The panel's own colour (glass over paper), opaque so the slices do
    // not show through behind the figure.
    canvas.drawCircle(
      center,
      radius * 0.64,
      Paint()
        ..color = Color.alphaBlend(BambooInk.glassFillOnPaper, BambooInk.paper),
    );
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      !_listEquals(oldDelegate.values, values);

  static bool _listEquals(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
