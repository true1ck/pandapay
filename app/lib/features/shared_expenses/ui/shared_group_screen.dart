import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'shared_components.dart';
import 'shared_presentation.dart';

/// The selected group's deeper route replaces the hub's tab context; it does
/// not nest a second tab bar, recreate an expense editor or synthesize payments.
class SharedGroupScreen extends StatelessWidget {
  final SharedGroupPresentation data;
  final int initialIndex;
  final VoidCallback? onAddExpense;
  final VoidCallback? onSettings;
  final VoidCallback? onMembers;
  final ValueChanged<String>? onOpenExpense;
  final ValueChanged<String>? onOpenBalance;
  final ValueChanged<SharedGroupTab>? onRetry;
  final ValueChanged<SharedGroupTab>? onLoadMore;
  const SharedGroupScreen({
    super.key,
    required this.data,
    this.initialIndex = 0,
    this.onAddExpense,
    this.onSettings,
    this.onMembers,
    this.onOpenExpense,
    this.onOpenBalance,
    this.onRetry,
    this.onLoadMore,
  });

  List<Widget> _header({bool incomplete = false}) => [
    if (data.offline)
      const SharedNotice(
        'Offline · showing saved splits',
        icon: Icons.cloud_off_outlined,
      ),
    if (data.summary case final summary?)
      SharedSummaryCard(summary: summary, hideAmounts: data.hideAmounts),
    if (incomplete) const SharedNotice('Some results are still syncing'),
  ];

  Widget _expenses() => SharedPageBody(
    key: ValueKey('${data.id}:expenses'),
    state: data.expenses.state,
    hasItems: data.expenses.items.isNotEmpty,
    header: _header(incomplete: data.expenses.incomplete),
    itemCount: data.expenses.items.length,
    itemBuilder: (_, index) => SharedExpenseTile(
      row: data.expenses.items[index],
      hideAmounts: data.hideAmounts,
      onTap: onOpenExpense == null
          ? null
          : () => onOpenExpense!(data.expenses.items[index].id),
    ),
    emptyTitle: 'No expenses yet',
    emptyMessage: 'Add the first shared expense for this group.',
    hasMore: data.expenses.hasMore,
    loadingMore: data.expenses.loadingMore,
    onRetry: onRetry == null ? null : () => onRetry!(SharedGroupTab.expenses),
    onLoadMore: onLoadMore == null
        ? null
        : () => onLoadMore!(SharedGroupTab.expenses),
  );

  Widget _balances() => SharedPageBody(
    key: ValueKey('${data.id}:balances'),
    state: data.balances.state,
    hasItems: data.balances.items.isNotEmpty,
    header: _header(incomplete: data.balances.incomplete),
    itemCount: data.balances.items.length,
    itemBuilder: (_, index) => SharedContextTile(
      row: data.balances.items[index],
      hideAmounts: data.hideAmounts,
      onTap: onOpenBalance == null
          ? null
          : () => onOpenBalance!(data.balances.items[index].id),
    ),
    emptyTitle: 'No balances to show',
    emptyMessage: 'Reviewed shared expenses will appear here.',
    hasMore: data.balances.hasMore,
    loadingMore: data.balances.loadingMore,
    onRetry: onRetry == null ? null : () => onRetry!(SharedGroupTab.balances),
    onLoadMore: onLoadMore == null
        ? null
        : () => onLoadMore!(SharedGroupTab.balances),
  );

  Widget _totals() => SharedPageBody(
    key: ValueKey('${data.id}:totals'),
    state: data.totalsState,
    hasItems: data.totals != null,
    header: [
      if (data.offline)
        const SharedNotice(
          'Offline · showing saved splits',
          icon: Icons.cloud_off_outlined,
        ),
    ],
    itemCount: data.totals == null ? 0 : 1,
    itemBuilder: (_, _) {
      final totals = data.totals!;
      return SharedPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (totals.periodLabel != null)
              Text(
                totals.periodLabel!,
                style: BambooFonts.ui(13, color: BambooInk.ink700),
              ),
            SharedMoneyLine(
              'Total bills',
              totals.billTotal,
              confidence: totals.confidence,
              hidden: data.hideAmounts,
            ),
            SharedMoneyLine(
              'You paid',
              totals.yourPaid,
              confidence: totals.confidence,
              hidden: data.hideAmounts,
            ),
            SharedMoneyLine(
              'Your share',
              totals.yourShare,
              confidence: totals.confidence,
              hidden: data.hideAmounts,
            ),
            const SharedNotice(
              'Payments settle balances; they are separate from expense totals.',
            ),
            if (totals.incomplete)
              const SharedNotice('Totals snapshot incomplete'),
          ],
        ),
      );
    },
    emptyTitle: 'No expense totals yet',
    emptyMessage:
        'Expense totals will appear after shared expenses are reviewed.',
    onRetry: onRetry == null ? null : () => onRetry!(SharedGroupTab.totals),
  );

  @override
  Widget build(BuildContext context) => SharedTabbedFrame(
    title: data.title,
    tabs: const ['Expenses', 'Balances', 'Totals'],
    initialIndex: initialIndex,
    onAddExpense: onAddExpense,
    actions: [
      if (onMembers != null)
        IconButton(
          tooltip: 'Group members',
          onPressed: onMembers,
          icon: const Icon(Icons.people_outline_rounded),
        ),
      if (onSettings != null)
        IconButton(
          tooltip: 'Group settings',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
    ],
    children: [_expenses(), _balances(), _totals()],
  );
}

class SharedExpenseTile extends StatelessWidget {
  final SharedExpenseRow row;
  final bool hideAmounts;
  final VoidCallback? onTap;
  const SharedExpenseTile({
    super.key,
    required this.row,
    this.hideAmounts = false,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => SharedPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(row.title, style: BambooFonts.heading(16)),
        if (row.occurredAtLabel != null)
          Text(
            row.occurredAtLabel!,
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
        Text(
          'Paid by ${row.paidBy}',
          style: BambooFonts.ui(13, color: BambooInk.ink700),
        ),
        if (sharedStateLabel(row.state) case final label?)
          Text(label, style: BambooFonts.ui(12, color: BambooInk.ink700)),
        if (row.participation == SharedParticipation.paidForOthers)
          Text(
            'You paid for others',
            style: BambooFonts.ui(13, color: BambooInk.jade),
          ),
        if (row.participation == SharedParticipation.notIncluded)
          Text(
            'Not included in this split',
            style: BambooFonts.ui(13, color: BambooInk.ink700),
          ),
        const SizedBox(height: AppSpace.sm),
        SharedMoneyLine(
          'Bill total',
          row.billTotal,
          confidence: row.confidence,
          hidden: hideAmounts,
        ),
        SharedMoneyLine(
          'You paid',
          row.yourPaid,
          confidence: row.confidence,
          hidden: hideAmounts,
        ),
        SharedMoneyLine(
          'Your share',
          row.yourShare,
          confidence: row.confidence,
          hidden: hideAmounts,
        ),
        if (onTap != null)
          Align(
            alignment: Alignment.centerLeft,
            child: SharedAction(label: 'View expense', onTap: onTap!),
          ),
      ],
    ),
  );
}
