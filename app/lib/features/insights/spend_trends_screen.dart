import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/spend_reports_repository.dart';
import '../../data/spending_selection.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../cards/card_summary.dart';
import '../import/data_transfer_screen.dart';
import 'spending_visuals.dart';

/// Rows for the same calendar period as the aggregate report. The report
/// endpoint remains the source of truth for totals; this companion request
/// only supplies the transaction-level rows needed by expandable details.
final spendPeriodTransactionsProvider =
    FutureProvider.family<List<TransactionEntry>, SpendReportQuery>((
      ref,
      query,
    ) async {
      final repo = ref.watch(userCardsRepositoryProvider);
      if (repo == null) return const [];

      final report = await ref.watch(spendReportProvider(query).future);
      if (report == null) return const [];

      return loadTransactionsWithOfflineCache(
        ref,
        repo: repo,
        cacheKey:
            'spend_detail:${query.cacheKey}:${report.periodStart.toIso8601String()}:${report.periodEnd.toIso8601String()}',
        from: query.isCustom ? query.from : report.periodStart,
        to: query.isCustom
            ? query.to
            : report.periodEnd.subtract(const Duration(days: 1)),
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
class SpendTrendsScreen extends ConsumerStatefulWidget {
  final String? initialCategory;
  final Set<String> initialTagIds;
  final Key? periodSelectorKey;
  final Key? overviewKey;

  const SpendTrendsScreen({
    super.key,
    this.initialCategory,
    this.initialTagIds = const {},
    this.periodSelectorKey,
    this.overviewKey,
  });

  @override
  ConsumerState<SpendTrendsScreen> createState() => _SpendTrendsScreenState();
}

class _SpendTrendsScreenState extends ConsumerState<SpendTrendsScreen> {
  final reportBodyKey = GlobalKey<_ReportBodyState>();
  bool _filtersActive = false;
  late _SpendFilterSelection _savedFilters = _SpendFilterSelection(
    tagIds: widget.initialTagIds,
  );

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(selectedSpendQueryProvider);
    final report = ref.watch(spendReportProvider(query));
    final transactions = ref.watch(spendPeriodTransactionsProvider(query));

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
          'Spending',
          style: BambooFonts.heading(20, color: BambooInk.ink900),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.ios_share_rounded, size: 20),
            color: BambooInk.ink900,
            tooltip: 'Import or export data',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DataTransferScreen()),
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            KeyedSubtree(
              key: widget.periodSelectorKey,
              child: _PeriodSelector(
                selected: query,
                filtersActive: _filtersActive,
                onFilters: () => reportBodyKey.currentState?.openFilters(),
              ),
            ),
            Expanded(
              child: report.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => ErrorState(
                  message: userFacingErrorMessage(err),
                  onRetry: () => ref.invalidate(spendReportProvider(query)),
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
                      report: data,
                      onRefresh: () async =>
                          ref.invalidate(spendReportProvider(query)),
                    );
                  }
                  if (transactions.hasError &&
                      transactions.valueOrNull == null) {
                    return ErrorState(
                      message: userFacingErrorMessage(transactions.error!),
                      onRetry: () {
                        ref.invalidate(spendReportProvider(query));
                        ref.invalidate(spendPeriodTransactionsProvider(query));
                      },
                    );
                  }
                  return _ReportBody(
                    key: reportBodyKey,
                    query: query,
                    report: data,
                    transactions: transactions.valueOrNull ?? const [],
                    transactionDetailsLoading: transactions.isLoading,
                    initialCategory: widget.initialCategory,
                    initialTagIds: widget.initialTagIds,
                    initialSelection: _savedFilters,
                    onSelectionChanged: (selection) =>
                        _savedFilters = selection,
                    overviewKey: widget.overviewKey,
                    onFiltersActiveChanged: (active) =>
                        setState(() => _filtersActive = active),
                    onRefresh: () {
                      ref.invalidate(spendReportProvider(query));
                      ref.invalidate(spendPeriodTransactionsProvider(query));
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
  final SpendReport report;
  final Future<void> Function() onRefresh;

  const _NoSpendingReportState({required this.report, required this.onRefresh});

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
                  '${report.displayLabel} spending',
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

class _PeriodSelector extends ConsumerWidget {
  final SpendReportQuery selected;
  final bool filtersActive;
  final VoidCallback onFilters;

  const _PeriodSelector({
    required this.selected,
    required this.filtersActive,
    required this.onFilters,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(clockProvider).now();
    final periodButtonLabel = _periodButtonLabel(selected, now);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.sm,
            AppSpace.lg,
            AppSpace.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _choosePeriod(context, ref),
                  icon: const Icon(Icons.calendar_month_rounded, size: 18),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          periodButtonLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 18),
                    ],
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: BambooInk.ink900,
                    side: const BorderSide(color: BambooInk.hairlineOnPaper),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    minimumSize: const Size(0, 46),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              OutlinedButton.icon(
                onPressed: onFilters,
                icon: const Icon(Icons.tune_rounded, size: 18),
                label: Text(filtersActive ? 'Filters ·' : 'Filters'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: filtersActive
                      ? BambooInk.jade
                      : BambooInk.ink900,
                  side: BorderSide(
                    color: filtersActive
                        ? BambooInk.jade
                        : BambooInk.hairlineOnPaper,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _periodButtonLabel(SpendReportQuery selected, DateTime now) {
    const months = <String>[
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
    if (selected.isCustom) {
      final from = selected.from!;
      final to = selected.to!;
      if (from.year == to.year) {
        if (from.month == to.month) {
          return '${months[from.month - 1]} ${from.year}';
        }
        return '${months[from.month - 1]} – ${months[to.month - 1]} '
            '${from.year}';
      }
      return '${months[from.month - 1]} ${from.year} – '
          '${months[to.month - 1]} ${to.year}';
    }
    return switch (selected.period) {
      SpendPeriod.month => '${months[now.month - 1]} ${now.year}',
      SpendPeriod.year => '${now.year}',
      SpendPeriod.quarter => 'Q${((now.month - 1) ~/ 3) + 1} ${now.year}',
      SpendPeriod.week => 'Week',
      SpendPeriod.custom => 'Custom dates',
    };
  }

  Future<void> _choosePeriod(BuildContext context, WidgetRef ref) async {
    final now = ref.read(clockProvider).now();
    final choice = await showModalBottomSheet<_SpendDateRangeChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: BambooInk.paper,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _SpendDateRangeSheet(selected: selected, now: now),
    );
    if (choice == null || !context.mounted) return;
    ref.read(selectedSpendQueryProvider.notifier).state = choice.query;
  }
}

class _SpendDateRangeChoice {
  final SpendReportQuery query;

  const _SpendDateRangeChoice(this.query);
}

class _SpendRangeOption {
  final IconData icon;
  final String title;
  final String subtitle;
  final SpendReportQuery query;

  const _SpendRangeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.query,
  });
}

class _SpendDateRangeSheet extends StatefulWidget {
  final SpendReportQuery selected;
  final DateTime now;

  const _SpendDateRangeSheet({required this.selected, required this.now});

  @override
  State<_SpendDateRangeSheet> createState() => _SpendDateRangeSheetState();
}

class _SpendDateRangeSheetState extends State<_SpendDateRangeSheet> {
  late SpendReportQuery _draft;
  late DateTime _customFrom;
  late DateTime _customTo;

  @override
  void initState() {
    super.initState();
    _draft = widget.selected;
    _customFrom = widget.selected.isCustom
        ? widget.selected.from!
        : DateTime(widget.now.year, widget.now.month, 1);
    _customTo = widget.selected.isCustom
        ? widget.selected.to!
        : DateTime(widget.now.year, widget.now.month + 1, 0);
  }

  DateTime _monthStart(int year, int month) => DateTime(year, month, 1);

  DateTime _monthEnd(int year, int month) => DateTime(year, month + 1, 0);

  DateTime _weekStart() {
    final date = DateTime(widget.now.year, widget.now.month, widget.now.day);
    return date.subtract(Duration(days: date.weekday - DateTime.monday));
  }

  DateTime _weekEnd() => _weekStart().add(const Duration(days: 6));

  SpendReportQuery _custom(DateTime from, DateTime to) =>
      SpendReportQuery.custom(from: from, to: to);

  bool _sameDay(DateTime? a, DateTime? b) =>
      a == null && b == null ||
      a != null &&
          b != null &&
          a.year == b.year &&
          a.month == b.month &&
          a.day == b.day;

  bool _matches(SpendReportQuery query) =>
      query.period == _draft.period &&
      _sameDay(query.from, _draft.from) &&
      _sameDay(query.to, _draft.to);

  String _shortDate(DateTime date) {
    const months = <String>[
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
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _monthLabel(DateTime date) {
    const months = <String>[
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
    return '${months[date.month - 1]} ${date.year}';
  }

  int _monthCount(DateTime from, DateTime to) =>
      (to.year - from.year) * 12 + to.month - from.month + 1;

  String _selectedTitle(List<_SpendRangeOption> options) {
    for (final option in options) {
      if (_matches(option.query)) return option.title;
    }
    return 'Custom range';
  }

  ({DateTime from, DateTime to}) _boundsForQuery(SpendReportQuery query) {
    if (query.isCustom) {
      return (from: query.from!, to: query.to!);
    }
    switch (query.period) {
      case SpendPeriod.week:
        return (from: _weekStart(), to: _weekEnd());
      case SpendPeriod.month:
        return (
          from: _monthStart(widget.now.year, widget.now.month),
          to: _monthEnd(widget.now.year, widget.now.month),
        );
      case SpendPeriod.quarter:
        final startMonth = ((widget.now.month - 1) ~/ 3) * 3 + 1;
        return (
          from: _monthStart(widget.now.year, startMonth),
          to: _monthEnd(widget.now.year, startMonth + 2),
        );
      case SpendPeriod.year:
        return (
          from: DateTime(widget.now.year, 1, 1),
          to: DateTime(widget.now.year, 12, 31),
        );
      case SpendPeriod.custom:
        return (from: _customFrom, to: _customTo);
    }
  }

  String _selectedDescription() {
    final bounds = _boundsForQuery(_draft);
    final from = bounds.from;
    final to = bounds.to;
    return '${_shortDate(from)} – ${_shortDate(to)} '
        '(${_monthCount(from, to)} ${_monthCount(from, to) == 1 ? 'month' : 'months'})';
  }

  Future<void> _pickDate({required bool from}) async {
    final firstDate = DateTime(2020);
    final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
    // Presets use complete calendar months, so a selected range can end
    // after today (for example, 31 Oct while the clock is 17 Oct). Keep that
    // existing boundary selectable instead of handing showDatePicker an
    // invalid initial date.
    final lastDate = _customTo.isAfter(today) ? _customTo : today;
    final requestedInitial = from ? _customFrom : _customTo;
    final initialDate = requestedInitial.isBefore(firstDate)
        ? firstDate
        : requestedInitial.isAfter(lastDate)
        ? lastDate
        : requestedInitial;
    final picked = await showDatePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDate: initialDate,
      helpText: from ? 'Select start date' : 'Select end date',
    );
    if (picked == null) return;
    setState(() {
      if (from) {
        _customFrom = picked;
        if (_customFrom.isAfter(_customTo)) _customTo = picked;
      } else {
        _customTo = picked;
        if (_customTo.isBefore(_customFrom)) _customFrom = picked;
      }
      _draft = _custom(_customFrom, _customTo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final lastMonth = _custom(
      _monthStart(widget.now.year, widget.now.month - 1),
      _monthEnd(widget.now.year, widget.now.month - 1),
    );
    final lastThreeMonths = _custom(
      _monthStart(widget.now.year, widget.now.month - 2),
      _monthEnd(widget.now.year, widget.now.month),
    );
    final yearToDate = _custom(
      DateTime(widget.now.year, 1, 1),
      DateTime(widget.now.year, widget.now.month, widget.now.day),
    );
    final lastTwelveMonths = _custom(
      _monthStart(widget.now.year, widget.now.month - 11),
      _monthEnd(widget.now.year, widget.now.month),
    );

    final options = <_SpendRangeOption>[
      _SpendRangeOption(
        icon: Icons.calendar_month_rounded,
        title: 'This month',
        subtitle: _monthLabel(widget.now),
        query: const SpendReportQuery.preset(SpendPeriod.month),
      ),
      _SpendRangeOption(
        icon: Icons.calendar_month_rounded,
        title: 'Last month',
        subtitle: _monthLabel(DateTime(widget.now.year, widget.now.month - 1)),
        query: lastMonth,
      ),
      _SpendRangeOption(
        icon: Icons.bar_chart_rounded,
        title: 'Last 3 months',
        subtitle:
            '${_monthLabel(DateTime(widget.now.year, widget.now.month - 2))} – ${_monthLabel(widget.now)}',
        query: lastThreeMonths,
      ),
      _SpendRangeOption(
        icon: Icons.pie_chart_outline_rounded,
        title: 'This quarter',
        subtitle:
            'Q${((widget.now.month - 1) ~/ 3) + 1} ${widget.now.year}\n'
            '(${_monthLabel(DateTime(widget.now.year, ((widget.now.month - 1) ~/ 3) * 3 + 1))} – '
            '${_monthLabel(DateTime(widget.now.year, ((widget.now.month - 1) ~/ 3) * 3 + 3))})',
        query: const SpendReportQuery.preset(SpendPeriod.quarter),
      ),
      _SpendRangeOption(
        icon: Icons.date_range_rounded,
        title: 'Year to date',
        subtitle: 'Jan – ${_monthLabel(widget.now)}',
        query: yearToDate,
      ),
      _SpendRangeOption(
        icon: Icons.bar_chart_rounded,
        title: 'Last 12 months',
        subtitle:
            '${_monthLabel(DateTime(widget.now.year, widget.now.month - 11))} – ${_monthLabel(widget.now)}',
        query: lastTwelveMonths,
      ),
    ];

    Widget optionCard(_SpendRangeOption option) {
      final selectedOption = _matches(option.query);
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => setState(() {
            _draft = option.query;
            final bounds = _boundsForQuery(option.query);
            _customFrom = bounds.from;
            _customTo = bounds.to;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: const BoxConstraints(minHeight: 66),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: selectedOption ? const Color(0xFFF1FFDF) : BambooInk.paper,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selectedOption
                    ? BambooInk.lime
                    : BambooInk.hairlineOnPaper,
                width: selectedOption ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(option.icon, color: BambooInk.ink900, size: 21),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        option.title,
                        style: BambooFonts.ui(
                          11.5,
                          weight: FontWeight.w700,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        option.subtitle,
                        style: BambooFonts.ui(9.5, color: BambooInk.ink500),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (selectedOption)
                  const Icon(
                    Icons.check_circle_rounded,
                    color: BambooInk.jade,
                    size: 18,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Choose date range',
                    style: BambooFonts.heading(20, color: BambooInk.ink900),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded, size: 28),
                  color: BambooInk.ink900,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Selected: ${_selectedTitle(options)}',
              style: BambooFonts.ui(13, color: BambooInk.ink900),
            ),
            const SizedBox(height: 3),
            Text(
              _selectedDescription(),
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            for (var index = 0; index < options.length; index += 2) ...[
              Row(
                // The sheet is inside a SingleChildScrollView, so its height
                // is unbounded. Stretching the row children asks each card
                // to use an infinite height and makes the range options fail
                // layout on real/test devices.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  optionCard(options[index]),
                  const SizedBox(width: AppSpace.sm),
                  if (index + 1 < options.length)
                    optionCard(options[index + 1])
                  else
                    const Expanded(child: SizedBox()),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            const Divider(height: AppSpace.lg),
            Row(
              children: [
                const Icon(Icons.calendar_month_rounded, size: 25),
                const SizedBox(width: AppSpace.sm),
                Text(
                  'Custom range',
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Expanded(
                  child: _DateField(
                    label: 'From',
                    value: _customFrom,
                    onTap: () => _pickDate(from: true),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: _DateField(
                    label: 'To',
                    value: _customTo,
                    onTap: () => _pickDate(from: false),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () =>
                    Navigator.pop(context, _SpendDateRangeChoice(_draft)),
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.lime,
                  foregroundColor: BambooInk.ink900,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                child: const Text('Apply range'),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 19,
                  color: BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(
                    'For ranges over one month, spending is grouped by month.',
                    style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime value;
  final VoidCallback onTap;

  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  String _format(DateTime date) {
    const months = <String>[
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
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          color: BambooInk.paper,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _format(value),
                    style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Icon(Icons.calendar_month_rounded, size: 21),
          ],
        ),
      ),
    );
  }
}

class _ReportBody extends ConsumerStatefulWidget {
  final SpendReportQuery query;
  final SpendReport report;
  final List<TransactionEntry> transactions;
  final bool transactionDetailsLoading;
  final String? initialCategory;
  final Set<String> initialTagIds;
  final _SpendFilterSelection initialSelection;
  final ValueChanged<_SpendFilterSelection> onSelectionChanged;
  final Key? overviewKey;
  final ValueChanged<bool> onFiltersActiveChanged;
  final VoidCallback onRefresh;
  const _ReportBody({
    super.key,
    required this.query,
    required this.report,
    required this.transactions,
    required this.transactionDetailsLoading,
    this.initialCategory,
    this.initialTagIds = const {},
    required this.initialSelection,
    required this.onSelectionChanged,
    this.overviewKey,
    required this.onFiltersActiveChanged,
    required this.onRefresh,
  });

  @override
  ConsumerState<_ReportBody> createState() => _ReportBodyState();
}

bool _spansMultipleCalendarMonths(SpendReportQuery query) {
  switch (query.period) {
    case SpendPeriod.week:
    case SpendPeriod.month:
      return false;
    case SpendPeriod.quarter:
    case SpendPeriod.year:
      return true;
    case SpendPeriod.custom:
      final from = query.from!;
      final to = query.to!;
      return from.year != to.year || from.month != to.month;
  }
}

class _ReportBodyState extends ConsumerState<_ReportBody> {
  _SpendingTab _tab = _SpendingTab.categories;
  final _spendingTabsKey = GlobalKey();
  late TxnInstrument? _paymentFilter = widget.initialSelection.payment;
  late Set<String> _categoryFilters = {...widget.initialSelection.categories};
  late String? _merchantFilter = widget.initialSelection.merchant;
  late String? _cardFilter = widget.initialSelection.card;
  late Set<String> _tagFilters = {...widget.initialSelection.tagIds};
  late bool _untagged = widget.initialSelection.untagged;

  List<BankAccountSummary> get _bankAccounts =>
      ref.read(bankAccountSummariesProvider).valueOrNull ?? const [];

  void _notifyFilters() {
    widget.onSelectionChanged(
      _SpendFilterSelection(
        payment: _paymentFilter,
        categories: {..._categoryFilters},
        merchant: _merchantFilter,
        card: _cardFilter,
        tagIds: {..._tagFilters},
        untagged: _untagged,
      ),
    );
    widget.onFiltersActiveChanged(_filtersActive);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _notifyFilters();
    });
  }

  List<TransactionTag> get _allTags =>
      ref.read(transactionTagsProvider)?.allTags ??
      [
        ...{
          for (final entry in _spendEntries)
            for (final tag in entry.tags) tag.id: tag,
        }.values,
      ];

  List<TransactionTag> _tagsFor(TransactionEntry entry) =>
      ref
          .read(transactionTagsProvider)
          ?.tagsForTransaction(entry.id, fallback: entry.tags) ??
      entry.tags;

  List<TransactionTag> get _visibleTags {
    final tags = <String, TransactionTag>{
      for (final entry in _visibleEntries)
        for (final tag in _tagsFor(entry)) tag.id: tag,
    }.values.toList();
    tags.sort((a, b) {
      final aTotal = _sum(_entriesForTag(a.id));
      final bTotal = _sum(_entriesForTag(b.id));
      return bTotal.paise.compareTo(aTotal.paise);
    });
    return tags;
  }

  List<TransactionEntry> _entriesForTag(String tagId) => _visibleEntries
      .where((entry) => _tagsFor(entry).any((tag) => tag.id == tagId))
      .toList();

  List<SpendBreakdownRow> _categoryRowsForTag(String tagId) {
    final groups = <String, List<TransactionEntry>>{};
    for (final entry in _entriesForTag(tagId)) {
      final categoryId =
          entry.categoryId ??
          (entry.userCategoryId == null
              ? null
              : 'custom:${entry.userCategoryId}');
      final identity =
          categoryId ??
          'label:${SpendingSelection.normalize(entry.categoryLabel)}';
      groups
          .putIfAbsent('$identity:${entry.categoryLabel}', () => [])
          .add(entry);
    }
    final rows = groups.entries.map((group) {
      final entries = group.value;
      final first = entries.first;
      return SpendBreakdownRow(
        label: first.categoryLabel,
        categoryId:
            first.categoryId ??
            (first.userCategoryId == null
                ? null
                : 'custom:${first.userCategoryId}'),
        total: _sum(entries),
        txnCount: entries.length,
      );
    }).toList();
    rows.sort((a, b) => b.total.paise.compareTo(a.total.paise));
    return rows;
  }

  void _openTagCategoryTransactions(
    TransactionTag tag,
    SpendBreakdownRow category,
  ) {
    DateTime day(DateTime value) =>
        DateTime(value.year, value.month, value.day);
    String dateParam(DateTime value) =>
        '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';

    final from = widget.query.isCustom
        ? day(widget.query.from!)
        : day(widget.report.periodStart.toLocal());
    final to = widget.query.isCustom
        ? day(widget.query.to!)
        : day(
            widget.report.periodEnd.subtract(const Duration(days: 1)).toLocal(),
          );
    final query = <String, String>{
      'tag': tag.id,
      'from': dateParam(from),
      'to': dateParam(to),
      'spendOnly': 'true',
      if (category.categoryId != null) 'category': category.categoryId!,
      if (category.categoryId == null) 'categoryLabel': category.label,
    };
    context.push(
      Uri(path: AppRoute.activity, queryParameters: query).toString(),
    );
  }

  bool get _filtersActive =>
      _paymentFilter != null ||
      _categoryFilters.isNotEmpty ||
      _merchantFilter != null ||
      _cardFilter != null ||
      _tagFilters.isNotEmpty ||
      _untagged;

  List<TransactionEntry> get _spendEntries =>
      {for (final entry in widget.transactions) entry.id: entry}.values
          .where(
            (entry) =>
                entry.status == 'active' &&
                entry.entryKind == TxnEntryKind.spend,
          )
          .toList();

  List<TransactionEntry> _entriesFor({
    TxnInstrument? payment,
    Set<String>? categories,
    String? merchant,
    String? card,
  }) {
    final selection = SpendingSelection(
      payment: payment ?? _paymentFilter,
      categories: categories ?? _categoryFilters,
      merchant: merchant ?? _merchantFilter,
      card: card ?? _cardFilter,
      tagIds: _tagFilters,
      untagged: _untagged,
    );
    return _spendEntries
        .where(
          (entry) => selection.matches(
            entry,
            tags: _tagsFor(entry).map((tag) => tag.id),
            bankAccounts: _bankAccounts,
          ),
        )
        .toList();
  }

  List<TransactionEntry> get _visibleEntries =>
      _filtersActive ? _entriesFor() : _spendEntries;

  Money _sum(List<TransactionEntry> entries) => entries.fold<Money>(
    const Money.zero(),
    (sum, entry) => sum + entry.amount,
  );

  String _categoryName(TransactionEntry entry) => entry.categoryLabel;

  String _merchantName(TransactionEntry entry) =>
      entry.merchantName?.trim().isNotEmpty == true
      ? entry.merchantName!.trim()
      : 'Unknown merchant';

  String _cardName(TransactionEntry entry) =>
      SpendingSelection.sourceName(entry, bankAccounts: _bankAccounts);

  List<TransactionEntry> _transactionsForCard(CardSpendRow row) {
    return _visibleEntries.where((entry) {
      if (row.cardId != null) return entry.userCardId == row.cardId;
      return _cardName(entry) == row.cardName;
    }).toList();
  }

  List<String> _distinct(Iterable<String> values) {
    final result = values
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    result.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return result;
  }

  Map<String, String> get _categoryOptions => {
    for (final row in widget.report.byCategory)
      if (row.categoryId != null) row.categoryId!: row.label,
    for (final entry in _spendEntries)
      (entry.categoryId ??
              (entry.userCategoryId == null
                  ? 'label:${SpendingSelection.normalize(entry.categoryLabel)}'
                  : 'custom:${entry.userCategoryId}')):
          entry.categoryLabel,
    for (final entry in _spendEntries)
      if (entry.parentCategoryId != null)
        entry.parentCategoryId!: entry.categoryName ?? 'Category',
    for (final entry in _spendEntries)
      if (entry.parentUserCategoryId != null)
        'custom:${entry.parentUserCategoryId}':
            entry.categoryName ?? 'Category',
  };

  List<String> get _merchantOptions => _distinct([
    ...widget.report.byMerchant.map((row) => row.label),
    ..._spendEntries.map(_merchantName),
  ]);

  List<String> get _cardOptions => _distinct([
    if (_spendEntries.isEmpty)
      ...widget.report.byCard.map((row) => row.cardName),
    ..._spendEntries.map(_cardName),
  ]);

  List<SpendBreakdownRow> _rowsFromEntries(
    List<TransactionEntry> entries,
    String Function(TransactionEntry) labelOf,
  ) {
    final totals = <String, _SpendBucket>{};
    for (final entry in entries) {
      final label = labelOf(entry);
      final bucket = totals.putIfAbsent(label, _SpendBucket.new);
      bucket.total += entry.amount;
      bucket.count += 1;
    }
    return totals.entries
        .map(
          (item) => SpendBreakdownRow(
            label: item.key,
            total: item.value.total,
            txnCount: item.value.count,
          ),
        )
        .toList()
      ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
  }

  List<SpendBreakdownRow> _categoryRows() {
    if (!_filtersActive && widget.report.byCategory.isNotEmpty) {
      return widget.report.byCategory;
    }
    return _rowsFromEntries(_visibleEntries, _categoryName);
  }

  List<SpendBreakdownRow> _merchantRows() {
    if (!_filtersActive && widget.report.byMerchant.isNotEmpty) {
      return widget.report.byMerchant;
    }
    return _rowsFromEntries(_visibleEntries, _merchantName);
  }

  List<CardSpendRow> _cardRows() {
    // Keep the aggregate report visible while detail rows are loading. Once
    // loaded, group the same transactions users can expand so bank-account
    // suffixes and unlinked cards are preserved consistently.
    if (_spendEntries.isEmpty) {
      if (_filtersActive) return const [];
      return widget.report.byCard;
    }
    final groups = <String, List<TransactionEntry>>{};
    for (final entry in _visibleEntries) {
      final key = entry.userCardId == null
          ? 'source:${_cardName(entry)}'
          : 'card:${entry.userCardId}';
      groups.putIfAbsent(key, () => []).add(entry);
    }
    final rows = groups.entries.map((item) {
      final sourceEntries = item.value;
      final amount = _sum(item.value);
      final rewards = item.value.fold<Money>(
        const Money.zero(),
        (sum, entry) => sum + (entry.rewardValue ?? const Money.zero()),
      );
      return CardSpendRow(
        cardId: sourceEntries.first.userCardId,
        cardName: _cardName(sourceEntries.first),
        total: amount,
        rewards: rewards,
        txnCount: item.value.length,
        effectiveRatePerRupee: amount.isZero
            ? null
            : rewards.paise / amount.paise,
      );
    }).toList();
    rows.sort((a, b) => b.total.paise.compareTo(a.total.paise));
    return rows;
  }

  List<InstrumentSpendRow> _instrumentRows() {
    if (!_filtersActive && widget.report.byInstrument.isNotEmpty) {
      return widget.report.byInstrument;
    }
    final groups = <TxnInstrument, List<TransactionEntry>>{};
    for (final entry in _visibleEntries) {
      groups
          .putIfAbsent(SpendingSelection.effectiveInstrument(entry), () => [])
          .add(entry);
    }
    return groups.entries
        .map(
          (item) => InstrumentSpendRow(
            instrument: item.key.wireValue,
            total: _sum(item.value),
            txnCount: item.value.length,
          ),
        )
        .toList()
      ..sort((a, b) => b.total.paise.compareTo(a.total.paise));
  }

  Money _visibleTotal() =>
      _filtersActive ? _sum(_visibleEntries) : widget.report.spend.total;

  int _visibleCount() =>
      _filtersActive ? _visibleEntries.length : widget.report.spend.txnCount;

  List<DateTime> _monthsInReport(SpendReport report) {
    // Custom ranges are date-only selections. Use those dates directly
    // instead of converting the API's UTC boundary back through the device
    // timezone, which can shift Aug 1 to Jul 31 and create a phantom bar.
    final start = widget.query.isCustom
        ? widget.query.from!
        : report.periodStart.toLocal();
    final end = widget.query.isCustom
        ? widget.query.to!
        : report.periodEnd.subtract(const Duration(days: 1)).toLocal();
    final months = <DateTime>[];
    var cursor = DateTime(start.year, start.month);
    final last = DateTime(end.year, end.month);
    while (!cursor.isAfter(last)) {
      months.add(cursor);
      cursor = DateTime(cursor.year, cursor.month + 1);
    }
    return months;
  }

  List<SpendSeriesPoint> _seriesFor(SpendReport report) {
    final totals = <DateTime, Money>{};
    final counts = <DateTime, int>{};
    for (final entry in _visibleEntries) {
      final local = entry.occurredAt.toLocal();
      final month = DateTime(local.year, local.month);
      totals[month] = (totals[month] ?? const Money.zero()) + entry.amount;
      counts[month] = (counts[month] ?? 0) + 1;
    }

    final months = _monthsInReport(report);
    months.sort();
    final rangeHasOneMonth = months.length == 1;
    if (rangeHasOneMonth) {
      return [
        SpendSeriesPoint(
          periodStart: months.single,
          spend: _filtersActive ? _visibleTotal() : report.spend.total,
          rewards: const Money.zero(),
          txnCount: _filtersActive ? _visibleCount() : report.spend.txnCount,
        ),
      ];
    }

    // Custom ranges and active filters have no trustworthy server series.
    // Bucket the same visible rows used by the totals and category pie chart
    // so all visualisations respond to the exact same selection.
    final derived = months
        .map(
          (month) => SpendSeriesPoint(
            periodStart: month,
            spend: totals[month] ?? const Money.zero(),
            rewards: const Money.zero(),
            txnCount: counts[month] ?? 0,
          ),
        )
        .toList();
    if (_filtersActive || report.period == SpendPeriod.custom) return derived;

    // Preset quarter/year reports may have a server series at a larger
    // cadence. Keep only points that belong to the selected range; monthly
    // comparison itself is intentionally driven by calendar-month buckets.
    final serverPoints = report.series.where((point) {
      final local = point.periodStart.toLocal();
      final month = DateTime(local.year, local.month);
      return months.contains(month);
    }).toList();
    return serverPoints.length == months.length ? serverPoints : derived;
  }

  String _reportRangeLabel(SpendReport report) {
    const months = <String>[
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
    final first = widget.query.isCustom
        ? widget.query.from!
        : report.periodStart.toLocal();
    final last = widget.query.isCustom
        ? widget.query.to!
        : report.periodEnd.subtract(const Duration(days: 1)).toLocal();
    return first.year == last.year
        ? '${months[first.month - 1]}–${months[last.month - 1]}'
        : '${months[first.month - 1]} ${first.year}–${months[last.month - 1]} ${last.year}';
  }

  List<TransactionEntry> _transactionsForCategory(SpendBreakdownRow row) {
    return _visibleEntries.where((entry) {
      if (row.categoryId != null) {
        return entry.categoryId == row.categoryId ||
            entry.userCategoryId == row.categoryId ||
            entry.parentUserCategoryId == row.categoryId;
      }
      return _categoryName(entry).toLowerCase() == row.label.toLowerCase();
    }).toList();
  }

  List<TransactionEntry> _transactionsForInstrument(InstrumentSpendRow row) {
    return _visibleEntries
        .where(
          (entry) =>
              SpendingSelection.effectiveInstrument(entry).wireValue ==
              row.instrument,
        )
        .toList();
  }

  List<TransactionEntry> _transactionsForMerchant(SpendBreakdownRow row) {
    return _visibleEntries
        .where(
          (entry) =>
              _merchantName(entry).toLowerCase() == row.label.toLowerCase(),
        )
        .toList();
  }

  Future<void> openFilters() async {
    final selection = await showModalBottomSheet<_SpendFilterSelection>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: BambooInk.paper,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _SpendFilterSheet(
        report: widget.report,
        transactions: _spendEntries,
        categories: _categoryOptions,
        merchants: _merchantOptions,
        cards: _cardOptions,
        bankAccounts: _bankAccounts,
        tags: _allTags,
        tagsFor: _tagsFor,
        initial: _SpendFilterSelection(
          payment: _paymentFilter,
          categories: _categoryFilters,
          merchant: _merchantFilter,
          card: _cardFilter,
          tagIds: _tagFilters,
          untagged: _untagged,
        ),
      ),
    );
    if (!mounted || selection == null) return;
    setState(() {
      _paymentFilter = selection.payment;
      _categoryFilters = selection.categories;
      _merchantFilter = selection.merchant;
      _cardFilter = selection.card;
      _tagFilters = selection.tagIds;
      _untagged = selection.untagged;
    });
    _notifyFilters();
  }

  void _showAllCategories() {
    if (!mounted) return;
    setState(() => _tab = _SpendingTab.categories);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = _spendingTabsKey.currentContext;
      if (!mounted || targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        alignment: 0.08,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(transactionTagsProvider);
    ref.watch(bankAccountSummariesProvider);
    final report = widget.report;
    final categoryRows = _categoryRows();
    final merchantRows = _merchantRows();
    final cardRows = _cardRows();
    final instrumentRows = _instrumentRows();
    final total = _visibleTotal();
    final series = _seriesFor(report);
    final multiMonth = _spansMultipleCalendarMonths(widget.query);
    final categoryEntries = _transactionsForCategory;
    final showFilteredLoading =
        _filtersActive &&
        widget.transactionDetailsLoading &&
        _spendEntries.isEmpty;

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
          if (_tagFilters.isNotEmpty || _untagged) ...[
            Wrap(
              spacing: 6,
              children: [
                if (_untagged)
                  InputChip(
                    label: const Text('Untagged'),
                    onDeleted: () {
                      setState(() => _untagged = false);
                      _notifyFilters();
                    },
                  ),
                for (final tag in _allTags)
                  if (_tagFilters.contains(tag.id))
                    InputChip(
                      label: Text(tag.name),
                      onDeleted: () {
                        setState(() => _tagFilters.remove(tag.id));
                        _notifyFilters();
                      },
                    ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
          ],
          Column(
            key: widget.overviewKey,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (categoryRows.isNotEmpty) ...[
                _SpendingMixCard(
                  rows: categoryRows,
                  total: total,
                  compact: multiMonth,
                  rangeLabel: multiMonth ? _reportRangeLabel(report) : null,
                  change: !_filtersActive && !multiMonth
                      ? report.changeVsPrevious
                      : null,
                  comparisonLabel: report.previousDisplayLabel,
                  onViewAll: multiMonth ? _showAllCategories : null,
                ),
                const SizedBox(height: AppSpace.lg),
              ],
              _SpendMetricsCard(
                report: _filtersActive
                    ? _filteredReport(report, total)
                    : report,
              ),
              const SizedBox(height: AppSpace.lg),
              if (multiMonth) ...[
                _MonthlyComparisonCard(series: series),
                const SizedBox(height: AppSpace.lg),
              ],
            ],
          ),
          KeyedSubtree(
            key: _spendingTabsKey,
            child: _SpendingTabs(
              selected: _tab,
              onChanged: (tab) => setState(() => _tab = tab),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (showFilteredLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpace.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            if (_tab == _SpendingTab.tags) ...[
              const _SectionHeader('Tags'),
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: Text(
                  'A transaction can have several tags. Tag totals can overlap.',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                ),
              ),
              for (final tag in _visibleTags)
                _ExpandableTagRow(
                  tag: tag,
                  total: _sum(_entriesForTag(tag.id)),
                  txnCount: _entriesForTag(tag.id).length,
                  categories: _categoryRowsForTag(tag.id),
                  onCategoryTap: (category) =>
                      _openTagCategoryTransactions(tag, category),
                ),
              if (_visibleEntries.every((entry) => _tagsFor(entry).isEmpty))
                const _EmptyTabState(
                  message: 'No tags on these transactions yet.',
                ),
            ] else if (_tab == _SpendingTab.categories &&
                categoryRows.isNotEmpty) ...[
              _SectionHeader('Categories'),
              for (final row in categoryRows)
                _ExpandableCategoryRow(
                  row: row,
                  total: total,
                  entries: categoryEntries(row),
                  detailsLoading: widget.transactionDetailsLoading,
                  initiallyExpanded:
                      widget.initialCategory == row.categoryId ||
                      widget.initialCategory?.toLowerCase() ==
                          row.label.toLowerCase(),
                ),
              if (instrumentRows.isNotEmpty) ...[
                const SizedBox(height: AppSpace.md),
                _BreakdownPanel(
                  title: 'Payment method',
                  visual: const SpendingVisual(
                    icon: Icons.payments_rounded,
                    accent: BambooChartColors.blue,
                  ),
                  child: Column(
                    children: [
                      for (final row in instrumentRows)
                        _ExpandableInstrumentRow(
                          row: row,
                          total: total,
                          entries: _transactionsForInstrument(row),
                          detailsLoading: widget.transactionDetailsLoading,
                        ),
                    ],
                  ),
                ),
              ],
            ] else if (_tab == _SpendingTab.merchants &&
                merchantRows.isNotEmpty) ...[
              _SectionHeader('Merchants'),
              for (final row in merchantRows.take(20))
                _ExpandableMerchantRow(
                  row: row,
                  total: total,
                  entries: _transactionsForMerchant(row),
                  detailsLoading: widget.transactionDetailsLoading,
                ),
            ] else if (_tab == _SpendingTab.accounts &&
                cardRows.isNotEmpty) ...[
              _SectionHeader('Accounts'),
              for (final row in cardRows)
                _AccountRow(
                  row: row,
                  total: total,
                  entries: _transactionsForCard(row),
                  detailsLoading: widget.transactionDetailsLoading,
                ),
            ] else if (!_filtersActive && cardRows.isNotEmpty) ...[
              // A useful fallback for older reports that have card totals but
              // no category rows yet.
              _SectionHeader('Accounts'),
              for (final row in cardRows)
                _AccountRow(
                  row: row,
                  total: total,
                  entries: _transactionsForCard(row),
                  detailsLoading: widget.transactionDetailsLoading,
                ),
            ] else if (instrumentRows.isNotEmpty) ...[
              _BreakdownPanel(
                title: 'Payment method',
                visual: const SpendingVisual(
                  icon: Icons.payments_rounded,
                  accent: BambooChartColors.blue,
                ),
                child: Column(
                  children: [
                    for (final row in instrumentRows)
                      _ExpandableInstrumentRow(
                        row: row,
                        total: total,
                        entries: _transactionsForInstrument(row),
                        detailsLoading: widget.transactionDetailsLoading,
                      ),
                  ],
                ),
              ),
            ] else
              _EmptyTabState(
                message: _filtersActive
                    ? 'No transactions match these filters.'
                    : 'There is no breakdown available for this period yet.',
              ),
          ],
          const SizedBox(height: AppSpace.lg),
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

  SpendReport _filteredReport(SpendReport report, Money total) {
    final count = _visibleCount();
    return SpendReport(
      period: report.period,
      periodStart: report.periodStart,
      periodEnd: report.periodEnd,
      elapsedFraction: report.elapsedFraction,
      spend: EntryKindTotals(
        total: total,
        txnCount: count,
        rewards: _visibleEntries.fold<Money>(
          const Money.zero(),
          (sum, entry) => sum + (entry.rewardValue ?? const Money.zero()),
        ),
      ),
      income: _filteredKindTotals(TxnEntryKind.income),
      investment: _filteredKindTotals(TxnEntryKind.investment),
      previousSpend: EntryKindTotals.zero,
      byCategory: _categoryRows(),
      byMerchant: _merchantRows(),
      byCard: _cardRows(),
      byInstrument: _instrumentRows(),
      series: _seriesFor(report),
    );
  }

  EntryKindTotals _filteredKindTotals(TxnEntryKind kind) {
    final selection = SpendingSelection(
      payment: _paymentFilter,
      categories: _categoryFilters,
      merchant: _merchantFilter,
      card: _cardFilter,
      tagIds: _tagFilters,
      untagged: _untagged,
    );
    final rows = {for (final row in widget.transactions) row.id: row}.values
        .where(
          (row) =>
              row.status == 'active' &&
              row.entryKind == kind &&
              selection.matches(
                row,
                tags: _tagsFor(row).map((tag) => tag.id),
                bankAccounts: _bankAccounts,
              ),
        )
        .toList();
    return EntryKindTotals(
      total: _sum(rows),
      txnCount: rows.length,
      rewards: const Money.zero(),
    );
  }
}

enum _SpendingTab { categories, merchants, accounts, tags }

class _ExpandableTagRow extends StatefulWidget {
  final TransactionTag tag;
  final Money total;
  final int txnCount;
  final List<SpendBreakdownRow> categories;
  final ValueChanged<SpendBreakdownRow> onCategoryTap;

  const _ExpandableTagRow({
    required this.tag,
    required this.total,
    required this.txnCount,
    required this.categories,
    required this.onCategoryTap,
  });

  @override
  State<_ExpandableTagRow> createState() => _ExpandableTagRowState();
}

class _ExpandableTagRowState extends State<_ExpandableTagRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => CardSummaryPanel(
    padding: EdgeInsets.zero,
    margin: const EdgeInsets.only(bottom: AppSpace.sm),
    child: ExpansionTile(
      key: PageStorageKey<String>('spending-tag-${widget.tag.id}'),
      onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
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
      leading: const _SpendingVisualBadge(
        visual: SpendingVisual(
          icon: Icons.sell_rounded,
          accent: BambooChartColors.teal,
        ),
        size: 38,
      ),
      title: Text(
        widget.tag.name,
        style: BambooFonts.ui(13.5, color: BambooInk.ink900),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${widget.txnCount} ${widget.txnCount == 1 ? 'transaction' : 'transactions'}',
        style: BambooFonts.ui(11.5, color: BambooInk.ink500),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoneyText(
            widget.total,
            confidence: Confidence.estimated,
            style: BambooFonts.ui(
              13.5,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          AnimatedRotation(
            turns: _expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ],
      ),
      children: [
        if (widget.categories.isEmpty)
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpace.xl,
              AppSpace.sm,
              AppSpace.md,
              AppSpace.md,
            ),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                'No category details for this tag yet.',
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ),
          )
        else
          for (var i = 0; i < widget.categories.length; i++) ...[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: BambooInk.hairlineOnPaper,
                indent: AppSpace.xl,
                endIndent: AppSpace.sm,
              ),
            _TagCategoryRow(
              key: ValueKey(
                'tag-category-${widget.tag.id}-${widget.categories[i].categoryId ?? widget.categories[i].label}',
              ),
              category: widget.categories[i],
              onTap: () => widget.onCategoryTap(widget.categories[i]),
            ),
          ],
      ],
    ),
  );
}

class _TagCategoryRow extends StatelessWidget {
  final SpendBreakdownRow category;
  final VoidCallback onTap;

  const _TagCategoryRow({
    super.key,
    required this.category,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          AppSpace.xl,
          AppSpace.sm,
          AppSpace.sm,
          AppSpace.sm,
        ),
        child: Row(
          children: [
            _SpendingVisualBadge(
              visual: spendingCategoryVisual(category.label),
              size: 34,
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category.label,
                    style: BambooFonts.ui(13, color: BambooInk.ink900),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${category.txnCount} ${category.txnCount == 1 ? 'transaction' : 'transactions'} · View transactions',
                    style: BambooFonts.ui(11, color: BambooInk.ink500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            MoneyText(
              category.total,
              confidence: Confidence.estimated,
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w600,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
          ],
        ),
      ),
    ),
  );
}

class _SpendBucket {
  Money total = const Money.zero();
  int count = 0;
}

class _SpendingTabs extends StatelessWidget {
  final _SpendingTab selected;
  final ValueChanged<_SpendingTab> onChanged;

  const _SpendingTabs({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: BambooInk.hairlineOnPaper)),
      ),
      child: Row(
        children: [
          for (final tab in _SpendingTab.values)
            Expanded(
              child: InkWell(
                onTap: () => onChanged(tab),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: selected == tab
                            ? BambooInk.lime
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    switch (tab) {
                      _SpendingTab.categories => 'Categories',
                      _SpendingTab.merchants => 'Merchants',
                      _SpendingTab.accounts => 'Accounts',
                      _SpendingTab.tags => 'Tags',
                    },
                    textAlign: TextAlign.center,
                    style: BambooFonts.ui(
                      12.5,
                      weight: selected == tab
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: selected == tab
                          ? BambooInk.ink900
                          : BambooInk.ink500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyTabState extends StatelessWidget {
  final String message;
  const _EmptyTabState({required this.message});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xl),
    child: Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
      ),
    ),
  );
}

class _SpendFilterSelection {
  final TxnInstrument? payment;
  final Set<String> categories;
  final String? merchant;
  final String? card;
  final Set<String> tagIds;
  final bool untagged;

  const _SpendFilterSelection({
    this.payment,
    this.categories = const <String>{},
    this.merchant,
    this.card,
    this.tagIds = const {},
    this.untagged = false,
  });
}

class _SpendFilterSheet extends StatefulWidget {
  final SpendReport report;
  final List<TransactionEntry> transactions;
  final Map<String, String> categories;
  final List<String> merchants;
  final List<String> cards;
  final List<BankAccountSummary> bankAccounts;
  final List<TransactionTag> tags;
  final List<TransactionTag> Function(TransactionEntry) tagsFor;
  final _SpendFilterSelection initial;

  const _SpendFilterSheet({
    required this.report,
    required this.transactions,
    required this.categories,
    required this.merchants,
    required this.cards,
    required this.bankAccounts,
    required this.tags,
    required this.tagsFor,
    required this.initial,
  });

  @override
  State<_SpendFilterSheet> createState() => _SpendFilterSheetState();
}

class _SpendFilterSheetState extends State<_SpendFilterSheet> {
  late TxnInstrument? _payment = widget.initial.payment;
  late Set<String> _categories = {...widget.initial.categories};
  late String? _merchant = widget.initial.merchant;
  late String? _card = widget.initial.card;
  late Set<String> _tagIds = {...widget.initial.tagIds};
  late bool _untagged = widget.initial.untagged;

  List<TransactionEntry> get _matching {
    final selection = SpendingSelection(
      payment: _payment,
      categories: _categories,
      merchant: _merchant,
      card: _card,
      tagIds: _tagIds,
      untagged: _untagged,
    );
    return widget.transactions
        .where(
          (entry) => selection.matches(
            entry,
            tags: widget.tagsFor(entry).map((tag) => tag.id),
            bankAccounts: widget.bankAccounts,
          ),
        )
        .toList();
  }

  Money get _total => _matching.fold<Money>(
    const Money.zero(),
    (sum, entry) => sum + entry.amount,
  );

  @override
  Widget build(BuildContext context) {
    final footer = Container(
      padding: EdgeInsets.fromLTRB(
        28,
        AppSpace.md,
        28,
        MediaQuery.viewInsetsOf(context).bottom + AppSpace.xs,
      ),
      decoration: const BoxDecoration(
        color: BambooInk.paper,
        border: Border(top: BorderSide(color: BambooInk.hairlineOnPaper)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            text: TextSpan(
              style: BambooFonts.ui(14, color: BambooInk.ink900),
              children: [
                TextSpan(
                  text:
                      '${_matching.length} matching ${_matching.length == 1 ? 'transaction' : 'transactions'} · ',
                ),
                TextSpan(
                  text: _total.format(hidePaise: true),
                  style: BambooFonts.ui(
                    14,
                    weight: FontWeight.w700,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _SpendFilterSelection(
                  payment: _payment,
                  categories: {..._categories},
                  merchant: _merchant,
                  card: _card,
                  tagIds: {..._tagIds},
                  untagged: _untagged,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.lime,
                foregroundColor: BambooInk.slate,
                minimumSize: const Size.fromHeight(52),
                textStyle: BambooFonts.ui(16, weight: FontWeight.w700),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Text('Show results'),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: TextButton.styleFrom(
              foregroundColor: BambooInk.jade,
              textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.97,
        ),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Filter spending',
                          style: BambooFonts.heading(
                            22,
                            color: BambooInk.ink900,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => setState(() {
                            _payment = null;
                            _categories = {};
                            _merchant = null;
                            _card = null;
                            _tagIds = {};
                            _untagged = false;
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: BambooInk.jade,
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: BambooFonts.ui(
                              15,
                              weight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    Text(
                      'Applies across all views',
                      style: BambooFonts.ui(14.5, color: BambooInk.ink500),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Date range'),
                    _selectionField(
                      icon: Icons.calendar_today_outlined,
                      label: _dateRangeLabel,
                      trailing: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Payment method'),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: [
                        for (final option in <(TxnInstrument?, String)>[
                          (null, 'All'),
                          (TxnInstrument.creditCard, 'Credit card'),
                          (TxnInstrument.debitCard, 'Debit card'),
                          (TxnInstrument.upiBank, 'UPI'),
                          (TxnInstrument.wallet, 'Wallet'),
                          (TxnInstrument.cash, 'Cash'),
                          (TxnInstrument.other, 'Unknown'),
                        ])
                          SizedBox(
                            width: 100,
                            child: _paymentButton(
                              option.$2,
                              _payment == option.$1,
                              () => setState(() => _payment = option.$1),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Category'),
                    _selectionField(
                      icon: Icons.shopping_bag_outlined,
                      onTap: widget.categories.isEmpty
                          ? null
                          : () => _chooseCategory(),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (_categories.isNotEmpty)
                            ..._categories.map(
                              (category) => Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: _valueChip(
                                  _displayCategory(category),
                                  onRemove: () => setState(
                                    () => _categories.remove(category),
                                  ),
                                ),
                              ),
                            ),
                          const Icon(
                            Icons.add_rounded,
                            color: BambooInk.jade,
                            size: 23,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Add category',
                            style: BambooFonts.ui(14, color: BambooInk.ink500),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Tags'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilterChip(
                          label: const Text('Untagged'),
                          selected: _untagged,
                          onSelected: (value) => setState(() {
                            _untagged = value;
                            if (value) _tagIds.clear();
                          }),
                        ),
                        for (final tag in widget.tags)
                          FilterChip(
                            label: Text(tag.name),
                            selected: _tagIds.contains(tag.id),
                            onSelected: (value) => setState(() {
                              _untagged = false;
                              value
                                  ? _tagIds.add(tag.id)
                                  : _tagIds.remove(tag.id);
                            }),
                          ),
                      ],
                    ),
                    Text(
                      'Matches any selected tag across categories.',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Merchant'),
                    _selectionField(
                      icon: Icons.storefront_outlined,
                      label: _merchant ?? 'All merchants',
                      trailing: const Icon(Icons.keyboard_arrow_down_rounded),
                      onTap: widget.merchants.isEmpty
                          ? null
                          : () => _chooseMerchant(),
                    ),
                    const SizedBox(height: AppSpace.xl),
                    _FilterLabel('Account'),
                    _selectionField(
                      icon: Icons.credit_card_outlined,
                      child: _card == null
                          ? Text(
                              'All accounts',
                              style: BambooFonts.ui(
                                14,
                                color: BambooInk.ink500,
                              ),
                            )
                          : _valueChip(
                              _card!,
                              onRemove: () => setState(() => _card = null),
                            ),
                      trailing: _card == null
                          ? const Icon(Icons.keyboard_arrow_down_rounded)
                          : null,
                      onTap: widget.cards.isEmpty ? null : () => _chooseCard(),
                    ),
                  ],
                ),
              ),
            ),
            footer,
          ],
        ),
      ),
    );
  }

  String get _dateRangeLabel {
    final start = widget.report.periodStart.toLocal();
    final end = widget.report.periodEnd
        .subtract(const Duration(days: 1))
        .toLocal();
    const months = <String>[
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
    if (start.year == end.year && start.month == end.month) {
      return '${months[start.month - 1]} ${start.year}';
    }
    return '${months[start.month - 1]} ${start.year} – '
        '${months[end.month - 1]} ${end.year}';
  }

  String _displayCategory(String key) => widget.categories[key] ?? key;

  Widget _selectionField({
    IconData? icon,
    String? label,
    Widget? child,
    Widget? trailing,
    VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(16),
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7),
      decoration: BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 23, color: BambooInk.ink900),
            const SizedBox(width: 15),
          ],
          Expanded(
            child:
                child ??
                Text(
                  label ?? '',
                  style: BambooFonts.ui(14.5, color: BambooInk.ink500),
                  overflow: TextOverflow.ellipsis,
                ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    ),
  );

  Widget _paymentButton(String label, bool selected, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? BambooInk.lime : BambooInk.paper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? BambooInk.lime : BambooInk.hairlineOnPaper,
            ),
          ),
          child: Text(
            label,
            style: BambooFonts.ui(
              14,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
          ),
        ),
      );

  Widget _valueChip(String label, {required VoidCallback onRemove}) =>
      Container(
        padding: const EdgeInsets.only(left: 12, right: 5),
        height: 38,
        decoration: BoxDecoration(
          color: BambooInk.rankBadgeBg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(
                  14,
                  weight: FontWeight.w600,
                  color: BambooInk.ink900,
                ),
              ),
            ),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 18),
              color: BambooInk.ink900,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 28, height: 28),
              splashRadius: 16,
            ),
          ],
        ),
      );

  Future<void> _chooseCategory() async {
    final category = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final category in widget.categories.entries)
              ListTile(
                title: Text(category.value),
                onTap: () => Navigator.pop(context, category.key),
              ),
          ],
        ),
      ),
    );
    if (!mounted || category == null) return;
    setState(() => _categories.add(category));
  }

  Future<void> _chooseMerchant() async {
    final value = await _chooseOption(
      title: 'Merchant',
      options: widget.merchants,
      clearLabel: 'All merchants',
    );
    if (!mounted || value == null) return;
    setState(() => _merchant = value.isEmpty ? null : value);
  }

  Future<void> _chooseCard() async {
    final value = await _chooseOption(
      title: 'Account',
      options: widget.cards,
      clearLabel: 'All accounts',
    );
    if (!mounted || value == null) return;
    setState(() => _card = value.isEmpty ? null : value);
  }

  Future<String?> _chooseOption({
    required String title,
    required List<String> options,
    String? clearLabel,
  }) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: BambooInk.paper,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(title, style: BambooFonts.heading(20)),
          if (clearLabel != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(clearLabel, style: BambooFonts.ui(15)),
              onTap: () => Navigator.pop(context, ''),
            ),
          for (final option in options)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(option, style: BambooFonts.ui(15)),
              onTap: () => Navigator.pop(context, option),
            ),
        ],
      ),
    ),
  );
}

class _FilterLabel extends StatelessWidget {
  final String label;
  const _FilterLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Text(
      label,
      style: BambooFonts.ui(
        15.5,
        weight: FontWeight.w600,
        color: BambooInk.ink900,
      ),
    ),
  );
}

/// Compact supporting figures shown below the interactive spending mix.
class _SpendMetricsCard extends StatelessWidget {
  final SpendReport report;

  const _SpendMetricsCard({required this.report});

  @override
  Widget build(BuildContext context) {
    final shortBy = report.spend.total - report.income.total;
    return Container(
      key: const ValueKey('spending_summary_card'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: BambooInk.paper,
        borderRadius: BorderRadius.circular(24),
        border: const Border.fromBorderSide(
          BorderSide(color: BambooInk.hairlineOnPaper),
        ),
        boxShadow: [
          BoxShadow(
            color: BambooInk.ink900.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final metrics = [
                _SpendMetricTile(
                  label: 'Money in',
                  amount: report.income.total,
                  icon: Icons.south_rounded,
                  accent: BambooInk.jade,
                  tint: BambooInk.jade.withValues(alpha: .09),
                ),
                _SpendMetricTile(
                  label: 'Spent',
                  amount: report.spend.total,
                  icon: Icons.north_rounded,
                  accent: BambooInk.ink700,
                  tint: BambooInk.paperCool,
                ),
                _SpendMetricTile(
                  label: shortBy.isNegative ? 'Surplus' : 'Short by',
                  amount: Money.fromPaise(shortBy.paise.abs()),
                  icon: shortBy.isNegative
                      ? Icons.check_circle_outline_rounded
                      : Icons.adjust_rounded,
                  accent: shortBy.isNegative ? BambooInk.jade : BambooInk.clay,
                  tint: (shortBy.isNegative ? BambooInk.jade : BambooInk.clay)
                      .withValues(alpha: .09),
                ),
                _SpendMetricTile(
                  label: 'Rewards earned',
                  amount: report.spend.rewards,
                  icon: Icons.emoji_events_outlined,
                  accent: BambooInk.amber,
                  tint: BambooInk.amber.withValues(alpha: .10),
                  amountColor: BambooInk.jade,
                ),
              ];
              if (constraints.maxWidth < 280) {
                return Column(
                  children: [
                    for (var index = 0; index < metrics.length; index++) ...[
                      if (index > 0) ...[
                        const SizedBox(height: AppSpace.xs),
                        Container(height: 1, color: BambooInk.hairlineOnPaper),
                        const SizedBox(height: AppSpace.xs),
                      ],
                      metrics[index],
                    ],
                  ],
                );
              }
              return Column(
                children: [
                  _SpendMetricPair(left: metrics[0], right: metrics[1]),
                  const SizedBox(height: AppSpace.xs),
                  Container(height: 1, color: BambooInk.hairlineOnPaper),
                  const SizedBox(height: AppSpace.xs),
                  _SpendMetricPair(left: metrics[2], right: metrics[3]),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SpendMetricPair extends StatelessWidget {
  final Widget left;
  final Widget right;

  const _SpendMetricPair({required this.left, required this.right});

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: Row(
      children: [
        Expanded(child: left),
        Container(
          width: 1,
          margin: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
          color: BambooInk.hairlineOnPaper,
        ),
        Expanded(child: right),
      ],
    ),
  );
}

class _SpendMetricTile extends StatelessWidget {
  final String label;
  final Money amount;
  final IconData icon;
  final Color accent;
  final Color tint;
  final Color? amountColor;

  const _SpendMetricTile({
    required this.label,
    required this.amount,
    required this.icon,
    required this.accent,
    required this.tint,
    this.amountColor,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
          child: Icon(icon, size: 17, color: accent),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(
                  11.5,
                  weight: FontWeight.w500,
                  color: BambooInk.ink700,
                ),
              ),
              const SizedBox(height: 1),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: MoneyText(
                    amount,
                    confidence: Confidence.estimated,
                    showConfidenceIcon: false,
                    style: BambooFonts.money(
                      14,
                      color: amountColor ?? BambooInk.ink900,
                      weight: FontWeight.w700,
                    ),
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

class _SpendChangePill extends StatelessWidget {
  final double change;
  final String comparisonLabel;

  const _SpendChangePill({required this.change, required this.comparisonLabel});

  @override
  Widget build(BuildContext context) {
    final increase = change >= 0;
    return Container(
      key: const ValueKey('spending_mix_comparison'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: increase ? const Color(0xFFE8F8D9) : const Color(0xFFE8F1FA),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                increase
                    ? Icons.arrow_upward_rounded
                    : Icons.arrow_downward_rounded,
                size: 16,
                color: increase ? BambooInk.jade : BambooChartColors.blue,
              ),
              const SizedBox(width: 3),
              Text(
                '${(change.abs() * 100).toStringAsFixed(0)}%',
                style: BambooFonts.ui(
                  15,
                  weight: FontWeight.w800,
                  color: increase ? BambooInk.jade : BambooChartColors.blue,
                ),
              ),
            ],
          ),
          Text(
            'vs $comparisonLabel',
            style: BambooFonts.ui(10, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }
}

class _MonthlyComparisonCard extends StatefulWidget {
  final List<SpendSeriesPoint> series;

  const _MonthlyComparisonCard({required this.series});

  @override
  State<_MonthlyComparisonCard> createState() => _MonthlyComparisonCardState();
}

class _MonthlyComparisonCardState extends State<_MonthlyComparisonCard> {
  int _selectedIndex = 0;

  static String _monthLabel(DateTime date) {
    const months = <String>[
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
    final local = date.toLocal();
    return '${months[local.month - 1]} ${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final series = widget.series;
    if (series.length < 2) return const SizedBox.shrink();
    final selectedIndex = _selectedIndex.clamp(0, series.length - 1).toInt();
    final selected = series[selectedIndex];
    final latest = series.last;
    final previous = series[series.length - 2];
    final difference = latest.spend.paise - previous.spend.paise;
    final comparison = previous.spend.isZero
        ? null
        : difference / previous.spend.paise;
    final direction = difference >= 0 ? 'higher' : 'lower';
    final comparisonText = comparison == null
        ? '${_monthLabel(latest.periodStart)} spending was '
              '${Money.fromPaise(difference.abs()).format(hidePaise: true)} '
              '$direction than ${_monthLabel(previous.periodStart)}.'
        : '${_monthLabel(latest.periodStart)} spending was '
              '${Money.fromPaise(difference.abs()).format(hidePaise: true)} '
              '$direction than ${_monthLabel(previous.periodStart)} '
              '(${(comparison.abs() * 100).toStringAsFixed(0)}%).';

    return CardSummaryPanel(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Monthly comparison',
                  style: BambooFonts.heading(13, color: BambooInk.ink900),
                ),
              ),
              Tooltip(
                message: 'Tap or swipe across a bar to inspect that month',
                child: Icon(
                  Icons.info_outline_rounded,
                  color: BambooInk.ink500,
                  size: 18,
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: BambooInk.paper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BambooInk.hairlineOnPaper),
            ),
            child: Row(
              children: [
                Icon(Icons.touch_app_rounded, size: 16, color: BambooInk.jade),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _monthLabel(selected.periodStart),
                    style: BambooFonts.ui(
                      11,
                      weight: FontWeight.w700,
                      color: BambooInk.ink900,
                    ),
                  ),
                ),
                Text(
                  selected.spend.format(hidePaise: false),
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w800,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          _InteractiveMonthlyBarChart(
            series: series,
            selectedIndex: selectedIndex,
            onSelected: (index) => setState(() => _selectedIndex = index),
          ),
          const SizedBox(height: 5),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF1FFDF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5FBCB),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.trending_up_rounded,
                    color: BambooInk.jade,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '$comparisonText\nTap or swipe across bars to inspect each month.',
                    style: BambooFonts.ui(10.5, color: BambooInk.ink900),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InteractiveMonthlyBarChart extends StatelessWidget {
  final List<SpendSeriesPoint> series;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _InteractiveMonthlyBarChart({
    required this.series,
    required this.selectedIndex,
    required this.onSelected,
  });

  void _selectAt(Offset position, Size size) {
    const left = 48.0;
    const right = 4.0;
    if (position.dx < left || position.dx > size.width - right) return;
    final chartWidth = math.max(1.0, size.width - left - right).toDouble();
    final slot = chartWidth / series.length;
    final index = ((position.dx - left) / slot).floor();
    if (index >= 0 && index < series.length) onSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 145,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, 145);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _selectAt(details.localPosition, size),
            onHorizontalDragUpdate: (details) =>
                _selectAt(details.localPosition, size),
            child: Semantics(
              label:
                  'Monthly spending chart. Swipe or tap a bar to select a month.',
              child: CustomPaint(
                painter: _MonthlyBarChartPainter(
                  series: series,
                  selectedIndex: selectedIndex,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MonthlyBarChartPainter extends CustomPainter {
  final List<SpendSeriesPoint> series;
  final int selectedIndex;

  const _MonthlyBarChartPainter({
    required this.series,
    required this.selectedIndex,
  });

  String _axisLabel(int paise) {
    final rupees = paise / 100;
    if (rupees >= 100000) return '₹${(rupees / 100000).toStringAsFixed(1)}L';
    if (rupees >= 1000) return '₹${(rupees / 1000).toStringAsFixed(0)}K';
    return '₹${rupees.toStringAsFixed(0)}';
  }

  String _barLabel(Money amount) {
    final rupees = amount.paise / 100;
    if (rupees >= 100000) return '₹${(rupees / 100000).toStringAsFixed(1)}L';
    if (rupees >= 1000) return '₹${(rupees / 1000).toStringAsFixed(1)}K';
    return amount.format(hidePaise: true);
  }

  static String _monthLabel(DateTime date) {
    const months = <String>[
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
    final local = date.toLocal();
    return '${months[local.month - 1]} ${local.year}';
  }

  void _text(
    Canvas canvas,
    String value,
    Offset offset,
    double maxWidth,
    TextStyle style, {
    TextAlign align = TextAlign.left,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textAlign: align,
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    final x = align == TextAlign.center
        ? offset.dx + (maxWidth - painter.width) / 2
        : offset.dx;
    painter.paint(canvas, Offset(x, offset.dy));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (series.isEmpty || size.width <= 0 || size.height <= 0) return;
    const left = 48.0;
    const right = 4.0;
    const top = 22.0;
    const bottom = 38.0;
    final chartWidth = math.max(1.0, size.width - left - right).toDouble();
    final chartHeight = math.max(1.0, size.height - top - bottom).toDouble();
    final maxPaise = series.fold<int>(
      1,
      (maxValue, point) =>
          maxValue > point.spend.paise ? maxValue : point.spend.paise,
    );
    final gridPaint = Paint()
      ..color = BambooInk.hairlineOnPaper
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = BambooInk.ink500.withValues(alpha: 0.45)
      ..strokeWidth = 1.2;

    for (final fraction in <double>[0, 0.5, 1]) {
      final y = top + chartHeight * (1 - fraction);
      canvas.drawLine(
        Offset(left, y),
        Offset(size.width - right, y),
        gridPaint,
      );
      _text(
        canvas,
        _axisLabel((maxPaise * fraction).round()),
        Offset(0, y - 7),
        left - 7,
        BambooFonts.ui(10.5, color: BambooInk.ink500),
        align: TextAlign.right,
      );
    }
    canvas.drawLine(
      Offset(left, top),
      Offset(left, top + chartHeight),
      axisPaint,
    );
    canvas.drawLine(
      Offset(left, top + chartHeight),
      Offset(size.width - right, top + chartHeight),
      axisPaint,
    );

    final slot = chartWidth / series.length;
    final barWidth = math.min(64.0, math.max(20.0, slot * 0.56)).toDouble();
    for (var index = 0; index < series.length; index += 1) {
      final point = series[index];
      final normalized = point.spend.paise / maxPaise;
      final barHeight = chartHeight * normalized;
      final x = left + slot * index + (slot - barWidth) / 2;
      final y = top + chartHeight - barHeight;
      final barPaint = Paint()
        ..color = index == selectedIndex
            ? BambooInk.lime
            : BambooInk.ink500.withValues(alpha: 0.25);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, y, barWidth, math.max(3.0, barHeight)),
          topLeft: const Radius.circular(10),
          topRight: const Radius.circular(10),
        ),
        barPaint,
      );
      _text(
        canvas,
        _barLabel(point.spend),
        Offset(left + slot * index, math.max(0, y - 19)),
        slot,
        BambooFonts.ui(10.5, weight: FontWeight.w700, color: BambooInk.ink900),
        align: TextAlign.center,
      );
      _text(
        canvas,
        _monthLabel(point.periodStart),
        Offset(left + slot * index, top + chartHeight + 9),
        slot,
        BambooFonts.ui(10.5, color: BambooInk.ink500),
        align: TextAlign.center,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MonthlyBarChartPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.selectedIndex != selectedIndex;
}

/// A visual summary of the same category totals shown in the expandable rows
/// below it. Every slice and its selected detail use [SpendReport.byCategory].
class _SpendingMixCard extends StatefulWidget {
  final List<SpendBreakdownRow> rows;
  final Money total;
  final bool compact;
  final String? rangeLabel;
  final double? change;
  final String? comparisonLabel;
  final VoidCallback? onViewAll;

  const _SpendingMixCard({
    required this.rows,
    required this.total,
    this.compact = false,
    this.rangeLabel,
    this.change,
    this.comparisonLabel,
    this.onViewAll,
  });

  @override
  State<_SpendingMixCard> createState() => _SpendingMixCardState();
}

class _SpendingMixCardState extends State<_SpendingMixCard> {
  String? _selectedCategoryKey;
  bool _showAllCategories = false;

  String _categoryKey(SpendBreakdownRow row) => row.categoryId ?? row.label;

  void _selectCategory(int? index) {
    final rows = widget.rows.where((row) => !row.total.isZero).toList();
    setState(() {
      _selectedCategoryKey = index == null || index >= rows.length
          ? null
          : _categoryKey(rows[index]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final total = widget.total;
    final compact = widget.compact;
    final rangeLabel = widget.rangeLabel;
    final change = widget.change;
    final comparisonLabel = widget.comparisonLabel;
    final nonZeroRows = rows.where((row) => !row.total.isZero).toList();
    final matchedIndex = _selectedCategoryKey == null
        ? -1
        : nonZeroRows.indexWhere(
            (row) => _categoryKey(row) == _selectedCategoryKey,
          );
    final selectedIndex = matchedIndex < 0 ? null : matchedIndex;
    final initialVisibleCount = compact ? 5 : 4;
    final visibleRows = nonZeroRows
        .take(
          _showAllCategories && !compact
              ? nonZeroRows.length
              : initialVisibleCount,
        )
        .toList();
    final remaining = nonZeroRows.length - initialVisibleCount;

    return CardSummaryPanel(
      padding: compact
          ? const EdgeInsets.fromLTRB(10, 8, 10, 10)
          : const EdgeInsets.fromLTRB(
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
              if (!compact) ...[
                _SpendingVisualBadge(
                  visual: const SpendingVisual(
                    icon: Icons.pie_chart_rounded,
                    accent: BambooChartColors.teal,
                  ),
                  size: 38,
                ),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      compact && rangeLabel != null
                          ? 'Spending mix · $rangeLabel'
                          : 'Spending mix',
                      style: BambooFonts.heading(
                        compact ? 13 : 15,
                        color: BambooInk.ink900,
                      ),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${nonZeroRows.length} ${nonZeroRows.length == 1 ? 'category' : 'categories'} · tap a slice for details',
                        style: BambooFonts.ui(12, color: BambooInk.ink500),
                      ),
                    ],
                  ],
                ),
              ),
              if (change != null && comparisonLabel != null) ...[
                const SizedBox(width: AppSpace.sm),
                _SpendChangePill(
                  change: change,
                  comparisonLabel: comparisonLabel,
                ),
              ],
            ],
          ),
          SizedBox(height: compact ? 6 : AppSpace.lg),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeInOutCubic,
            alignment: Alignment.topCenter,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final stack = !compact && constraints.maxWidth < 360;
                final legend = Column(
                  children: [
                    for (final row in visibleRows)
                      _MixLegendRow(
                        row: row,
                        total: total,
                        compact: compact,
                        onTap: () => _selectCategory(nonZeroRows.indexOf(row)),
                      ),
                    if (remaining > 0)
                      Padding(
                        padding: EdgeInsets.only(
                          top: compact ? 2 : AppSpace.xs,
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: compact
                              ? Semantics(
                                  button: true,
                                  label:
                                      'View all $remaining smaller categories',
                                  child: InkWell(
                                    key: const ValueKey(
                                      'spending_mix_view_all',
                                    ),
                                    onTap: widget.onViewAll,
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: Text(
                                        '$remaining smaller ${remaining == 1 ? 'category' : 'categories'} · View all  ›',
                                        style: BambooFonts.ui(
                                          9.5,
                                          color: BambooChartColors.violet,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : Semantics(
                                  button: true,
                                  label: _showAllCategories
                                      ? 'Show fewer categories'
                                      : 'Show all $remaining more ${remaining == 1 ? 'category' : 'categories'}',
                                  child: InkWell(
                                    key: const ValueKey(
                                      'spending_mix_toggle_categories',
                                    ),
                                    onTap: () => setState(
                                      () => _showAllCategories =
                                          !_showAllCategories,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 4,
                                      ),
                                      child: Text(
                                        _showAllCategories
                                            ? 'Show fewer categories  ↑'
                                            : '+$remaining more ${remaining == 1 ? 'category' : 'categories'} below',
                                        style: BambooFonts.ui(
                                          11.5,
                                          color: BambooInk.ink500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                  ],
                );

                if (stack) {
                  return Column(
                    children: [
                      SpendingDonut(
                        rows: nonZeroRows,
                        total: total,
                        selectedIndex: selectedIndex,
                        onSelected: _selectCategory,
                      ),
                      const SizedBox(height: AppSpace.lg),
                      legend,
                    ],
                  );
                }

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SpendingDonut(
                      rows: nonZeroRows,
                      total: total,
                      size: compact ? 106 : 132,
                      compact: compact,
                      selectedIndex: selectedIndex,
                      onSelected: _selectCategory,
                    ),
                    SizedBox(width: compact ? 7 : AppSpace.lg),
                    Expanded(child: legend),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class SpendingDonut extends StatelessWidget {
  final List<SpendBreakdownRow> rows;
  final Money total;
  final double size;
  final bool compact;
  final String? totalLabel;
  final int? selectedIndex;
  final ValueChanged<int?> onSelected;
  final VoidCallback? onCenterTap;

  const SpendingDonut({
    super.key,
    required this.rows,
    required this.total,
    this.size = 132,
    this.compact = false,
    this.totalLabel,
    required this.selectedIndex,
    required this.onSelected,
    this.onCenterTap,
  });

  void _selectSlice(Offset point) {
    final totalPaise = rows.fold<int>(0, (sum, row) => sum + row.total.paise);
    if (totalPaise <= 0) return;

    final offset = point - Offset(size / 2, size / 2);
    final radius = offset.distance;
    final ringRadius = size / 2 - 10;
    final ringTolerance = compact ? 12.0 : 18.0;
    if ((radius - ringRadius).abs() > ringTolerance) return;

    var angle =
        (math.atan2(offset.dy, offset.dx) + math.pi / 2) % (math.pi * 2);
    if (angle < 0) angle += math.pi * 2;
    var cumulative = 0.0;
    for (var index = 0; index < rows.length; index++) {
      final sweep = math.pi * 2 * rows[index].total.paise / totalPaise;
      if (angle <= cumulative + sweep) {
        onSelected(index);
        return;
      }
      cumulative += sweep;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = selectedIndex != null && selectedIndex! < rows.length
        ? rows[selectedIndex!]
        : null;
    final share = selected == null || total.isZero
        ? 0.0
        : (selected.total.paise / total.paise).clamp(0.0, 1.0);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, progress, child) => Semantics(
        key: const Key('spending_donut_chart'),
        button: true,
        label: selected == null
            ? 'Spending mix, total ${total.format(hidePaise: false)}. Tap a slice to see category details${onCenterTap == null ? '.' : ' or the center to open spending details.'}'
            : 'Spending mix, selected ${selected.label}, ${selected.total.format(hidePaise: false)}, ${(share * 100).round()}% of spending. ${onCenterTap == null ? 'Tap the center to show total.' : 'Tap the center to open spending details.'}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _selectSlice(details.localPosition),
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                TweenAnimationBuilder<double>(
                  key: ValueKey<int?>(selectedIndex),
                  tween: Tween<double>(
                    begin: 0,
                    end: selectedIndex == null ? 0 : 1,
                  ),
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  builder: (context, selectionProgress, _) => CustomPaint(
                    size: Size.square(size),
                    painter: _SpendingDonutPainter(
                      rows: rows,
                      progress: progress,
                      selectionProgress: selectionProgress,
                      strokeWidth: 18,
                      selectedIndex: selectedIndex,
                    ),
                  ),
                ),
                GestureDetector(
                  key: const Key('spending_donut_center'),
                  behavior: HitTestBehavior.opaque,
                  onTap:
                      onCenterTap ??
                      (selected == null ? null : () => onSelected(null)),
                  child: SizedBox(
                    width: size * 0.60,
                    height: size * 0.60,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: 0.94,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: selected == null
                            ? KeyedSubtree(
                                key: const ValueKey('donut-total'),
                                child: child!,
                              )
                            : _SelectedMixDetail(
                                key: ValueKey(selected.label),
                                row: selected,
                                share: share,
                                compact: compact,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: size * 0.7,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: MoneyText(
                total,
                confidence: Confidence.estimated,
                showConfidenceIcon: false,
                style: BambooFonts.ui(
                  compact ? 12 : 16,
                  weight: FontWeight.w800,
                  color: BambooInk.ink900,
                ),
              ),
            ),
          ),
          Text(
            totalLabel ?? (compact ? 'Total spent' : 'spent'),
            style: BambooFonts.ui(
              compact ? 8.5 : 10.5,
              color: BambooInk.ink500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectedMixDetail extends StatelessWidget {
  final SpendBreakdownRow row;
  final double share;
  final bool compact;

  const _SelectedMixDetail({
    super.key,
    required this.row,
    required this.share,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    key: const Key('spending_donut_selected_detail'),
    label:
        '${row.label}, ${row.total.format(hidePaise: false)}, ${(share * 100).round()}% of spending',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          row.label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: BambooFonts.ui(
            compact ? 8.5 : 9.5,
            weight: FontWeight.w600,
            color: BambooInk.ink500,
          ),
        ),
        const SizedBox(height: 1),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: MoneyText(
            row.total,
            confidence: Confidence.estimated,
            showConfidenceIcon: false,
            style: BambooFonts.ui(
              compact ? 10.5 : 12,
              weight: FontWeight.w800,
              color: BambooInk.ink900,
            ),
          ),
        ),
        Text(
          '${(share * 100).round()}% of spending',
          textAlign: TextAlign.center,
          maxLines: 1,
          style: BambooFonts.ui(compact ? 7.5 : 8.5, color: BambooInk.ink500),
        ),
      ],
    ),
  );
}

class _SpendingDonutPainter extends CustomPainter {
  final List<SpendBreakdownRow> rows;
  final double progress;
  final double selectionProgress;
  final double strokeWidth;
  final int? selectedIndex;

  const _SpendingDonutPainter({
    required this.rows,
    required this.progress,
    this.selectionProgress = 1,
    this.strokeWidth = 18,
    this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final totalPaise = rows.fold<int>(0, (sum, row) => sum + row.total.paise);
    final rect = Offset.zero & size;
    final track = Paint()
      ..color = BambooChartColors.chartTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawArc(rect.deflate(10), 0, math.pi * 2, false, track);

    if (totalPaise == 0) return;

    var start = -math.pi / 2;
    final activeIndex = selectedIndex != null && selectedIndex! < rows.length
        ? selectedIndex
        : null;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final sweep = math.pi * 2 * row.total.paise / totalPaise * progress;
      final isSelected = activeIndex == index;
      final alpha = activeIndex == null || isSelected
          ? 1.0
          : 1.0 - 0.66 * selectionProgress;
      final paint = Paint()
        ..color = spendingCategoryVisual(
          row.label,
        ).accent.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth + (isSelected ? 6 * selectionProgress : 0);
      canvas.drawArc(rect.deflate(10), start, sweep, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _SpendingDonutPainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.progress != progress ||
      oldDelegate.selectionProgress != selectionProgress ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.selectedIndex != selectedIndex;
}

class _MixLegendRow extends StatelessWidget {
  final SpendBreakdownRow row;
  final Money total;
  final bool compact;
  final VoidCallback? onTap;

  const _MixLegendRow({
    required this.row,
    required this.total,
    this.compact = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final visual = spendingCategoryVisual(row.label);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : AppSpace.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              if (compact)
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: visual.accent,
                  ),
                )
              else
                _SpendingVisualBadge(visual: visual, size: 27),
              SizedBox(width: compact ? 5 : AppSpace.sm),
              Expanded(
                child: Text(
                  '${row.label} · ${(ratio * 100).toStringAsFixed(0)}%',
                  style: BambooFonts.ui(
                    compact ? 9.5 : 12,
                    color: compact ? BambooInk.ink500 : BambooInk.ink900,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: compact ? 3 : AppSpace.xs),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: MoneyText(
                    row.total,
                    confidence: Confidence.estimated,
                    style: BambooFonts.ui(
                      compact ? 9.5 : 12,
                      weight: FontWeight.w700,
                      color: BambooInk.ink900,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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
              _SpendingVisualBadge(visual: visual, size: 34),
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
  final bool initiallyExpanded;

  const _ExpandableCategoryRow({
    required this.row,
    required this.total,
    required this.entries,
    required this.detailsLoading,
    this.initiallyExpanded = false,
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
        initiallyExpanded: initiallyExpanded,
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
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: MoneyText(
                      row.total,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
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

/// A payment-method total that opens into its payees and the underlying
/// transactions. UPI rows prefer the stored VPA as the grouping key; card and
/// other methods use the merchant name when no counterparty identifier exists.
class _ExpandableInstrumentRow extends StatelessWidget {
  final InstrumentSpendRow row;
  final Money total;
  final List<TransactionEntry> entries;
  final bool detailsLoading;

  const _ExpandableInstrumentRow({
    required this.row,
    required this.total,
    required this.entries,
    required this.detailsLoading,
  });

  Map<String, List<TransactionEntry>> _recipientGroups() {
    final isUpi = row.instrument == 'upi_bank';
    final groups = <String, List<TransactionEntry>>{};
    for (final entry in entries) {
      final vpa = entry.merchantVpa?.trim();
      final merchant = entry.merchantName?.trim();
      final label = isUpi && vpa != null && vpa.isNotEmpty
          ? vpa
          : (merchant == null || merchant.isEmpty ? 'Unknown payee' : merchant);
      groups.putIfAbsent(label, () => []).add(entry);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final groups = _recipientGroups().entries.toList()
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
          visual: spendingInstrumentVisual(row.instrument),
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
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: MoneyText(
                      row.total,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${row.txnCount} ${row.txnCount == 1 ? 'transaction' : 'transactions'} · Tap to see payees',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: BambooInk.paperMuted,
                color: spendingInstrumentVisual(row.instrument).accent,
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

/// A merchant (or UPI payee) total that opens in place — repeated payments to
/// the same person or merchant are clubbed into one expandable row whose
/// children are the underlying transactions.
class _ExpandableMerchantRow extends StatelessWidget {
  final SpendBreakdownRow row;
  final Money total;
  final List<TransactionEntry> entries;
  final bool detailsLoading;

  const _ExpandableMerchantRow({
    required this.row,
    required this.total,
    required this.entries,
    required this.detailsLoading,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(bottom: AppSpace.md),
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
          visual: const SpendingVisual(
            icon: Icons.storefront_rounded,
            accent: BambooChartColors.coral,
          ),
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
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: MoneyText(
                      row.total,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(
                        13.5,
                        weight: FontWeight.w600,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${row.txnCount} ${row.txnCount == 1 ? 'transaction' : 'transactions'} · Tap to see payments',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 4,
                backgroundColor: BambooInk.paperMuted,
                color: BambooChartColors.coral,
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
          else if (entries.isEmpty)
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
            _MerchantGroup(merchant: row.label, entries: entries),
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
                  [
                    if (entry.merchantName?.trim().isNotEmpty == true &&
                        entry.merchantName!.trim().toLowerCase() !=
                            merchant.toLowerCase())
                      entry.merchantName!.trim(),
                    if (entry.categoryName != null) entry.categoryLabel,
                    entry.cardDisplayName ?? entry.instrument.label,
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
                onTap: () =>
                    context.push('/activity/${entry.id}', extra: entry),
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
    final instrument = SpendingSelection.effectiveInstrument(entry);
    if (entry.cardLast4 != null) {
      return '${instrument.label} ••${entry.cardLast4}';
    }
    return entry.instrumentKnown ? instrument.label : 'Unknown payment method';
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
class _AccountRow extends StatelessWidget {
  final CardSpendRow row;
  final Money total;
  final List<TransactionEntry> entries;
  final bool detailsLoading;

  const _AccountRow({
    required this.row,
    required this.total,
    required this.entries,
    required this.detailsLoading,
  });

  Map<String, List<TransactionEntry>> _payeeGroups() {
    final groups = <String, List<TransactionEntry>>{};
    for (final entry in entries) {
      final vpa = entry.merchantVpa?.trim();
      final merchant = entry.merchantName?.trim();
      final label =
          entry.instrument == TxnInstrument.upiBank &&
              vpa != null &&
              vpa.isNotEmpty
          ? vpa
          : merchant == null || merchant.isEmpty
          ? 'Unknown merchant'
          : merchant;
      groups.putIfAbsent(label, () => []).add(entry);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final ratio = total.isZero
        ? 0.0
        : (row.total.paise / total.paise).clamp(0.0, 1.0);
    final rate = row.effectiveRatePerRupee;
    final hasCardEvidence =
        row.cardId != null || entries.any((entry) => entry.cardLast4 != null);
    final visual = SpendingVisual(
      icon: hasCardEvidence
          ? Icons.credit_card_rounded
          : row.cardName == 'Wallet'
          ? Icons.account_balance_wallet_rounded
          : row.cardName == 'Cash'
          ? Icons.payments_rounded
          : Icons.account_balance_rounded,
      accent: hasCardEvidence
          ? BambooChartColors.blue
          : BambooChartColors.violet,
    );
    final groups = _payeeGroups().entries.toList()
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
        leading: _SpendingVisualBadge(visual: visual, size: 34),
        title: Column(
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
                  style: BambooFonts.ui(
                    13.5,
                    weight: FontWeight.w600,
                    color: BambooInk.ink900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${row.txnCount} ${row.txnCount == 1 ? 'transaction' : 'transactions'} · Tap to see payees',
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
