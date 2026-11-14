import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Money;

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import 'shared_components.dart';
import 'shared_presentation.dart';

/// A friend's or a group's page, the Splitwise way: one scroll. The balance in
/// words at the top, a row of actions (Settle up, Balances, Totals, Payment
/// history), then every expense under its month. Balances and Totals open in
/// place under the actions instead of being tabs of their own, so nothing the
/// tabs held is lost and nothing needs a second tap level.
class SharedGroupScreen extends StatefulWidget {
  final SharedGroupPresentation data;

  /// 0 opens on the expenses; 1 opens with Balances shown, 2 with Totals.
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

  @override
  State<SharedGroupScreen> createState() => _SharedGroupScreenState();
}

class _SharedGroupScreenState extends State<SharedGroupScreen> {
  late SharedGroupTab? _open = switch (widget.initialIndex) {
    1 => SharedGroupTab.balances,
    2 => SharedGroupTab.totals,
    _ => null,
  };

  SharedGroupPresentation get data => widget.data;

  void _toggle(SharedGroupTab section) =>
      setState(() => _open = _open == section ? null : section);

  bool get _hasBalance {
    final summary = data.summary;
    return summary == null ||
        !summary.youOwe.isZero ||
        !summary.owedToYou.isZero;
  }

  Widget _chip({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool selected = false,
    Key? key,
  }) => Pressable(
    key: key,
    onTap: onTap,
    semanticLabel: label,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? BambooInk.slate : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: selected ? BambooInk.lime : BambooInk.ink900,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: BambooFonts.ui(
              13.5,
              weight: FontWeight.w700,
              color: selected ? BambooInk.lime : BambooInk.ink900,
            ),
          ),
        ],
      ),
    ),
  );

  Widget _actions() => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.sm),
    child: Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        if (widget.onSettleUp != null && _hasBalance)
          _chip(
            key: const Key('expenses-settle-up'),
            label: 'Settle up',
            icon: Icons.payments_outlined,
            onTap: widget.onSettleUp!,
          ),
        // A friend's page already says what is owed both ways at the top.
        if (!data.direct)
          _chip(
            label: 'Balances',
            icon: Icons.account_balance_wallet_outlined,
            selected: _open == SharedGroupTab.balances,
            onTap: () => _toggle(SharedGroupTab.balances),
          ),
        _chip(
          label: 'Totals',
          icon: Icons.bar_chart_rounded,
          selected: _open == SharedGroupTab.totals,
          onTap: () => _toggle(SharedGroupTab.totals),
        ),
        if (widget.onViewSettlements != null)
          _chip(
            label: 'Payment history',
            icon: Icons.receipt_long_outlined,
            onTap: widget.onViewSettlements!,
          ),
      ],
    ),
  );

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(top: AppSpace.xs, bottom: AppSpace.sm),
    child: Text(
      text,
      style: BambooFonts.ui(
        13,
        weight: FontWeight.w700,
        color: BambooInk.ink700,
      ),
    ),
  );

  List<Widget> _balances() {
    final page = data.balances;
    return [
      _sectionTitle('Balances'),
      if (page.hasPrevious && widget.onPreviousPage != null)
        SharedTextAction(
          label: 'Previous page',
          onTap: () => widget.onPreviousPage!(SharedGroupTab.balances),
        ),
      if (page.incomplete) const SharedNotice(sharedCatchingUpCopy),
      if (page.items.isEmpty)
        switch (page.state) {
          SharedLoadState.loading => const Padding(
            padding: EdgeInsets.all(AppSpace.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          SharedLoadState.error => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SharedNotice('Could not refresh balances'),
              if (widget.onRetry != null)
                SharedTextAction(
                  label: 'Try again',
                  onTap: () => widget.onRetry!(SharedGroupTab.balances),
                ),
            ],
          ),
          _ => const SharedNotice(
            'No balances yet. Reviewed shared expenses will appear here.',
          ),
        },
      for (final row in page.items)
        SharedContextTile(
          row: row,
          hideAmounts: data.hideAmounts,
          onTap: widget.onOpenBalance == null
              ? null
              : () => widget.onOpenBalance!(row.id),
        ),
      if (page.hasMore && widget.onLoadMore != null)
        SharedTextAction(
          label: page.loadingMore ? 'Loading…' : page.nextLabel,
          onTap: () => widget.onLoadMore!(SharedGroupTab.balances),
        ),
      const SizedBox(height: AppSpace.sm),
    ];
  }

  List<Widget> _totals() {
    final totals = data.totals;
    return [
      _sectionTitle('Totals'),
      if (totals == null)
        switch (data.totalsState) {
          SharedLoadState.loading => const Padding(
            padding: EdgeInsets.all(AppSpace.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          SharedLoadState.error => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SharedNotice('Could not refresh totals'),
              if (widget.onRetry != null)
                SharedTextAction(
                  label: 'Try again',
                  onTap: () => widget.onRetry!(SharedGroupTab.totals),
                ),
            ],
          ),
          _ => const SharedNotice(
            'Expense totals will appear after shared expenses are reviewed.',
          ),
        }
      else
        SharedPanel(
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
        ),
      const SizedBox(height: AppSpace.sm),
    ];
  }

  Widget _expenses() => SharedPageBody(
    key: ValueKey('${data.id}:expenses'),
    state: data.expenses.state,
    hasItems: data.expenses.items.isNotEmpty,
    nextLabel: data.expenses.nextLabel,
    header: [
      if (data.summary case final summary?)
        SharedSummaryCard(
          summary: summary,
          hideAmounts: data.hideAmounts,
          name: data.direct ? data.title : null,
        ),
      if (data.expenses.incomplete) const SharedNotice(sharedCatchingUpCopy),
      _actions(),
      if (_open == SharedGroupTab.balances) ..._balances(),
      if (_open == SharedGroupTab.totals) ..._totals(),
      if (data.expenses.hasPrevious && widget.onPreviousPage != null)
        SharedAction(
          label: 'Previous page',
          onTap: () => widget.onPreviousPage!(SharedGroupTab.expenses),
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
            onTap: widget.onOpenExpense == null
                ? null
                : () => widget.onOpenExpense!(row.id),
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
    onRetry: widget.onRetry == null
        ? null
        : () => widget.onRetry!(SharedGroupTab.expenses),
    onLoadMore: widget.onLoadMore == null
        ? null
        : () => widget.onLoadMore!(SharedGroupTab.expenses),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BambooInk.paper,
    appBar: AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      title: Text(
        data.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: BambooFonts.heading(17),
      ),
      actions: [
        if (widget.onMembers != null)
          IconButton(
            tooltip: data.direct ? 'Invite or view person' : 'Group members',
            onPressed: widget.onMembers,
            icon: const Icon(Icons.people_outline_rounded),
          ),
        if (widget.onSettings != null)
          IconButton(
            tooltip: data.direct ? 'Friend settings' : 'Group settings',
            onPressed: widget.onSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
      ],
    ),
    floatingActionButton: widget.onAddExpense == null
        ? null
        : AppAddButton(tooltip: 'Add expense', onPressed: widget.onAddExpense!),
    body: AppBackground(child: _expenses()),
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
