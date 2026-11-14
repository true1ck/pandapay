import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;

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
      // The one thing to do about a balance sits right under it.
      if (onSettleUp != null &&
          data.summary != null &&
          (!data.summary!.youOwe.isZero || !data.summary!.owedToYou.isZero))
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: SharedAction(
            key: const Key('expenses-settle-up'),
            label: 'Settle up',
            icon: Icons.payments_outlined,
            onTap: onSettleUp!,
          ),
        ),
    ],
    itemCount: data.expenses.items.length,
    itemBuilder: (_, index) {
      final row = data.expenses.items[index];
      final month = _monthLabel(row.occurredAtLabel);
      final previous = index == 0
          ? null
          : _monthLabel(data.expenses.items[index - 1].occurredAtLabel);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (month != null && month != previous)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm, bottom: 6),
              child: Text(
                month,
                style: BambooFonts.ui(
                  12,
                  weight: FontWeight.w700,
                  color: BambooInk.ink500,
                ),
              ),
            ),
          SharedExpenseTile(
            row: row,
            hideAmounts: data.hideAmounts,
            otherName: data.direct ? data.title : null,
            onTap: onOpenExpense == null ? null : () => onOpenExpense!(row.id),
          ),
        ],
      );
    },
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
    header: const [],
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

/// One expense in a friend's or group's list, in the order a person reads it:
/// when, what, who paid, and what it means for them. The accounting (bill total,
/// shares) lives in the expense itself.
class SharedExpenseTile extends StatelessWidget {
  final SharedExpenseRow row;
  final bool hideAmounts;

  /// The other person in a friend's list, for "Ravi paid"; null in a group.
  final String? otherName;
  final VoidCallback? onTap;
  const SharedExpenseTile({
    super.key,
    required this.row,
    this.hideAmounts = false,
    this.otherName,
    this.onTap,
  });

  String get _paidBy => switch (row.paidBy) {
    'You' => 'You paid',
    'You and others' => 'You and others paid',
    'Other members' => '${otherName ?? 'Someone else'} paid',
    final name => '$name paid',
  };

  @override
  Widget build(BuildContext context) {
    final date = DateTime.tryParse(row.occurredAtLabel ?? '');
    final net = row.yourPaid.paise - row.yourShare.paise;
    final involved = row.participation != SharedParticipation.notIncluded;
    final caption = !involved
        ? 'not involved'
        : row.proposed
        ? 'pending'
        : net < 0
        ? 'you owe'
        : net > 0
        ? 'you lent'
        : 'settled';
    final color = !involved || row.proposed || net == 0
        ? BambooInk.ink500
        : net < 0
        ? BambooInk.clayInk
        : BambooInk.jade;
    final amount = Money.fromPaise(net.abs());
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpace.sm),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 34),
              child: date == null
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        Text('${date.day}', style: BambooFonts.heading(17)),
                        Text(
                          DateFormat.MMM().format(date),
                          style: BambooFonts.ui(11, color: BambooInk.ink500),
                        ),
                      ],
                    ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: BambooFonts.heading(15),
                  ),
                  Text(
                    // A shared amount without its full bill is not called the bill.
                    '$_paidBy ${row.billTotal.format()}'
                    '${row.totalLabel == 'Bill total' ? '' : ' (shared amount)'}',
                    style: BambooFonts.ui(12, color: BambooInk.ink700),
                  ),
                  if (row.proposed && row.reviewLabel != null)
                    Text(
                      'Waiting for approval',
                      style: BambooFonts.ui(12, color: BambooInk.amber),
                    )
                  else if (row.reviewLabel != null)
                    Text(
                      'Change waiting for approval',
                      style: BambooFonts.ui(12, color: BambooInk.amber),
                    ),
                  if (sharedStateLabel(row.state) case final label?)
                    Text(
                      label,
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                  if (!row.confidence.isConfirmed)
                    Text(
                      'Estimated amounts',
                      style: BambooFonts.ui(12, color: BambooInk.ink700),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    caption,
                    textAlign: TextAlign.end,
                    style: BambooFonts.ui(12, color: color),
                  ),
                  if (involved && !row.proposed && net != 0)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: SharedAmount(
                        amount,
                        confidence: row.confidence,
                        hidden: hideAmounts,
                        color: color,
                        size: 15,
                      ),
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

/// `November 2026` for a calendar date, null when there is none.
String? _monthLabel(String? value) {
  final date = DateTime.tryParse(value ?? '');
  return date == null ? null : DateFormat.yMMMM().format(date);
}
