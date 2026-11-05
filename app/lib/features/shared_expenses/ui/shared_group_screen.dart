import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
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
  final VoidCallback? onSettleUp;
  final VoidCallback? onViewSettlements;
  final ValueChanged<SharedGroupTab>? onRetry;
  final ValueChanged<SharedGroupTab>? onLoadMore;
  final ValueChanged<SharedGroupTab>? onPreviousPage;
  const SharedGroupScreen({
    super.key,
    required this.data,
    this.initialIndex = 0,
    this.onAddExpense,
    this.onSettings,
    this.onMembers,
    this.onOpenExpense,
    this.onOpenBalance,
    this.onSettleUp,
    this.onViewSettlements,
    this.onRetry,
    this.onLoadMore,
    this.onPreviousPage,
  });

  List<Widget> _header({bool incomplete = false}) => [
    if (data.offline)
      const SharedNotice(
        'Offline · showing saved splits',
        icon: Icons.cloud_off_outlined,
      ),
    if (data.summary case final summary?)
      SharedSummaryCard(summary: summary, hideAmounts: data.hideAmounts),
    if (incomplete) const SharedNotice(sharedCatchingUpCopy),
  ];

  Widget _expenses() => SharedPageBody(
    key: ValueKey('${data.id}:expenses'),
    state: data.expenses.state,
    hasItems: data.expenses.items.isNotEmpty,
    nextLabel: data.expenses.nextLabel,
    header: [
      if (data.expenses.hasPrevious && onPreviousPage != null)
        SharedAction(
          label: 'Previous page',
          onTap: () => onPreviousPage!(SharedGroupTab.expenses),
        ),
      ..._header(incomplete: data.expenses.incomplete),
    ],
    itemCount: data.expenses.items.length,
    itemBuilder: (_, index) => SharedExpenseTile(
      row: data.expenses.items[index],
      hideAmounts: data.hideAmounts,
      onTap: onOpenExpense == null
          ? null
          : () => onOpenExpense!(data.expenses.items[index].id),
    ),
    emptyTitle: 'No expenses yet',
    emptyMessage: data.direct
        ? 'Add the first expense you share with ${data.title}.'
        : 'Add the first shared expense for this group.',
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
    nextLabel: data.balances.nextLabel,
    header: [
      if (data.balances.hasPrevious && onPreviousPage != null)
        SharedAction(
          label: 'Previous page',
          onTap: () => onPreviousPage!(SharedGroupTab.balances),
        ),
      ..._header(incomplete: data.balances.incomplete),
      if (onSettleUp != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: SharedAction(
            label: 'Settle up',
            icon: Icons.payments_outlined,
            onTap: onSettleUp!,
          ),
        ),
      if (onViewSettlements != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: SharedAction(
            label: 'Payment history',
            icon: Icons.receipt_long_outlined,
            onTap: onViewSettlements!,
          ),
        ),
    ],
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
              totals.totalLabel,
              totals.billTotal,
              confidence: totals.confidence,
              hidden: data.hideAmounts,
            ),
            SharedMoneyLine(
              totals.paidLabel,
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
              const SharedNotice('Some totals may be missing'),
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
          tooltip: data.direct ? 'Invite or view person' : 'Group members',
          onPressed: onMembers,
          icon: const Icon(Icons.people_outline_rounded),
        ),
      if (onSettings != null)
        IconButton(
          tooltip: data.direct ? 'Friend settings' : 'Group settings',
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
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: SharedPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BambooInk.slate,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const ExcludeSemantics(
              child: Icon(
                Icons.receipt_long_outlined,
                color: BambooInk.lime,
                size: 22,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  row.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.heading(15),
                ),
                Text(
                  '${row.payerLabel} ${row.paidBy}',
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
                if (sharedStateLabel(row.state) case final label?)
                  Text(
                    label,
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                if (row.reviewLabel != null)
                  Text(
                    row.reviewLabel!,
                    style: BambooFonts.ui(12, color: BambooInk.clayInk),
                  ),
                if (row.participation == SharedParticipation.paidForOthers)
                  Text(
                    'You paid for others',
                    style: BambooFonts.ui(12, color: BambooInk.jade),
                  ),
                if (row.participation == SharedParticipation.notIncluded)
                  Text(
                    'Not included in this split',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                if (!row.confidence.isConfirmed)
                  Text(
                    'Estimated amounts',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                const SizedBox(height: AppSpace.xs),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: AppSpace.md,
                    runSpacing: AppSpace.xs,
                    children: [
                      for (final metric in [
                        (row.totalLabel, row.billTotal),
                        ('Your share', row.yourShare),
                        (row.paidLabel, row.yourPaid),
                      ])
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth,
                          ),
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: AppSpace.xs,
                            runSpacing: AppSpace.xs,
                            children: [
                              Text(
                                metric.$1,
                                style: BambooFonts.ui(
                                  12,
                                  color: BambooInk.ink700,
                                ),
                              ),
                              SharedAmount(
                                metric.$2,
                                confidence: row.confidence,
                                hidden: hideAmounts,
                                size: 14,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (row.occurredAtLabel != null)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xs),
                    child: Text(
                      _expenseDate(row.occurredAtLabel!),
                      style: BambooFonts.ui(11, color: BambooInk.ink700),
                    ),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            const Icon(
              Icons.chevron_right_rounded,
              color: BambooInk.ink700,
              size: 18,
            ),
        ],
      ),
    ),
  );
}

String _expenseDate(String value) {
  final date = DateTime.tryParse(value);
  // Expense dates are calendar dates; do not shift them across time zones.
  return date == null ? value : DateFormat.yMMMd().format(date);
}
