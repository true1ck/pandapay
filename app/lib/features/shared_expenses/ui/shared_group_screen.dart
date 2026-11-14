import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pandapay_domain/pandapay_domain.dart' show Confidence, Money;
import 'package:share_plus/share_plus.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import 'shared_components.dart';
import 'shared_presentation.dart';

/// A friend's or a group's page, the Splitwise way: one scroll, nothing to
/// open. At the top, who it is and the balance in words; under it where that
/// balance sits (each group and non-group expenses for a friend, each member
/// for a group, a tap settles with them), what was shared in total, and the
/// actions (Settle up, Remind, History). Then every expense under its month.
class SharedGroupScreen extends StatefulWidget {
  final SharedGroupPresentation data;

  /// Kept for old links that opened a tab; everything is on one page now.
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
  bool _allBalances = false;
  static const _shownBalances = 5;

  SharedGroupPresentation get data => widget.data;

  /// The balance shown at the top: on a friend's page, the total over every
  /// place you share; otherwise this page's own.
  SharedBalanceSummary? get _summary {
    final lines = data.breakdown;
    if (!data.direct || lines.isEmpty) return data.summary;
    var owed = 0, owing = 0;
    for (final line in lines) {
      if (line.owedToYou) {
        owed += line.amount.paise;
      } else {
        owing += line.amount.paise;
      }
    }
    return SharedBalanceSummary(
      owedToYou: Money.fromPaise(owed),
      youOwe: Money.fromPaise(owing),
      netBalance: Money.fromPaise(owed - owing),
      confidence: data.summary?.confidence ?? Confidence.confirmed,
      incomplete: data.summary?.incomplete ?? false,
    );
  }

  String _money(Money money) => data.hideAmounts ? '••••' : money.format();

  /// "Sujay owes you ₹1,500.00 overall" with the amount in colour.
  Widget _headline() {
    final summary = _summary;
    if (summary == null) return const SizedBox.shrink();
    final net = summary.netBalance.paise;
    final amount = Money.fromPaise(net.abs());
    final overall = !data.direct || data.breakdown.isNotEmpty ? ' overall' : '';
    final color = net > 0 ? BambooInk.jade : BambooInk.clayInk;
    final style = BambooFonts.ui(16, weight: FontWeight.w700);
    final List<InlineSpan> spans;
    if (net == 0) {
      final settled = summary.owedToYou.isZero && summary.youOwe.isZero;
      spans = [
        TextSpan(
          text: settled
              ? 'All settled up'
              : data.direct
              ? 'You and ${data.title} are even$overall'
              : 'You are even$overall',
        ),
      ];
    } else if (net > 0) {
      spans = [
        TextSpan(
          text: data.direct ? '${data.title} owes you ' : 'You are owed ',
        ),
        TextSpan(
          text: _money(amount),
          style: TextStyle(color: color),
        ),
        TextSpan(text: overall),
      ];
    } else {
      spans = [
        TextSpan(text: data.direct ? 'You owe ${data.title} ' : 'You owe '),
        TextSpan(
          text: _money(amount),
          style: TextStyle(color: color),
        ),
        TextSpan(text: overall),
      ];
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      key: const Key('group-headline'),
    );
  }

  Widget _line(
    String lead,
    Money money,
    bool owedToYou, {
    String tail = '',
    VoidCallback? onTap,
  }) {
    final text = Text.rich(
      TextSpan(
        style: BambooFonts.ui(13, color: BambooInk.ink700),
        children: [
          TextSpan(text: lead),
          TextSpan(
            text: _money(money),
            style: TextStyle(
              color: owedToYou ? BambooInk.jade : BambooInk.clayInk,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (tail.isNotEmpty) TextSpan(text: ' $tail'),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: onTap == null
          ? text
          : Pressable(
              onTap: onTap,
              child: Row(
                children: [
                  Expanded(child: text),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: BambooInk.ink500,
                  ),
                ],
              ),
            ),
    );
  }

  /// Where the balance sits: per place for a friend, per member for a group.
  List<Widget> _whereLines() {
    if (data.direct) {
      return [
        for (final line in data.breakdown)
          line.owedToYou
              ? _line(
                  '${data.title} owes you ',
                  line.amount,
                  true,
                  tail: line.groupName == null
                      ? 'in non-group expenses'
                      : 'in “${line.groupName}”',
                )
              : _line(
                  'You owe ${data.title} ',
                  line.amount,
                  false,
                  tail: line.groupName == null
                      ? 'in non-group expenses'
                      : 'in “${line.groupName}”',
                ),
      ];
    }
    final page = data.balances;
    final owing = [
      for (final row in page.items)
        if (!row.balance.owedToYou.isZero || !row.balance.youOwe.isZero) row,
    ];
    final shown = _allBalances ? owing : owing.take(_shownBalances).toList();
    return [
      for (final row in shown)
        row.balance.netBalance.isZero
            // Both directions, cancelling out: still somebody to settle with.
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Pressable(
                  onTap: widget.onOpenBalance == null
                      ? null
                      : () => widget.onOpenBalance!(row.id),
                  child: Text(
                    'You and ${row.title} are even, with debts both ways',
                    style: BambooFonts.ui(13, color: BambooInk.ink700),
                  ),
                ),
              )
            : row.balance.netBalance.paise > 0
            ? _line(
                '${row.title} owes you ',
                Money.fromPaise(row.balance.netBalance.paise),
                true,
                onTap: widget.onOpenBalance == null
                    ? null
                    : () => widget.onOpenBalance!(row.id),
              )
            : _line(
                'You owe ${row.title} ',
                Money.fromPaise(-row.balance.netBalance.paise),
                false,
                onTap: widget.onOpenBalance == null
                    ? null
                    : () => widget.onOpenBalance!(row.id),
              ),
      if (owing.length > _shownBalances)
        SharedTextAction(
          label: _allBalances
              ? 'Show fewer'
              : 'Show all ${owing.length} balances',
          onTap: () => setState(() => _allBalances = !_allBalances),
        ),
      if (page.hasMore && widget.onLoadMore != null)
        SharedTextAction(
          label: page.loadingMore ? 'Loading…' : 'More balances',
          onTap: () => widget.onLoadMore!(SharedGroupTab.balances),
        ),
      if (page.hasPrevious && widget.onPreviousPage != null)
        SharedTextAction(
          label: 'Previous balances',
          onTap: () => widget.onPreviousPage!(SharedGroupTab.balances),
        ),
      if (page.items.isEmpty && page.state == SharedLoadState.error)
        SharedTextAction(
          label: 'Could not load balances · Try again',
          onTap: () => widget.onRetry?.call(SharedGroupTab.balances),
        ),
    ];
  }

  Future<void> _remind() async {
    final summary = _summary;
    if (summary == null || summary.netBalance.paise <= 0) return;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text:
              'Hi ${data.title}, a quick reminder from PandaPay: you owe me '
              '${Money.fromPaise(summary.netBalance.paise).format()}.',
        ),
      );
    } catch (_) {}
  }

  Widget _button(
    String label,
    IconData icon,
    VoidCallback onTap, {
    bool primary = false,
    Key? key,
  }) => Pressable(
    key: key,
    onTap: onTap,
    semanticLabel: label,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: primary ? BambooInk.slate : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: primary ? BambooInk.slate : BambooInk.hairlineOnPaper,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 18,
            color: primary ? BambooInk.lime : BambooInk.ink900,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: BambooFonts.ui(
              13.5,
              weight: FontWeight.w700,
              color: primary ? BambooInk.lime : BambooInk.ink900,
            ),
          ),
        ],
      ),
    ),
  );

  List<Widget> _header() {
    final summary = _summary;
    final totals = data.totals;
    final where = _whereLines();
    final owedToYou = (summary?.netBalance.paise ?? 0) > 0;
    return [
      Row(
        children: [
          SharedAvatar(name: data.title, group: !data.direct),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              data.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.heading(20),
            ),
          ),
        ],
      ),
      const SizedBox(height: AppSpace.md),
      _headline(),
      if (where.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: AppSpace.xs),
          padding: const EdgeInsets.only(left: AppSpace.md),
          decoration: const BoxDecoration(
            border: Border(
              left: BorderSide(color: BambooInk.hairlineOnPaper, width: 2),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: where,
          ),
        ),
      if (summary?.incomplete == true)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xs),
          child: Text(
            'Some balances may be missing',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
        ),
      if (totals != null && !totals.billTotal.isZero)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            // The labels come with the totals, so a shared amount whose full
            // bill is unknown is never called the bill.
            '${totals.totalLabel} ${_money(totals.billTotal)} · '
            '${totals.paidLabel.toLowerCase()} ${_money(totals.yourPaid)} · '
            'your share ${_money(totals.yourShare)}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
      if (data.expenses.incomplete)
        const Padding(
          padding: EdgeInsets.only(top: AppSpace.sm),
          child: SharedNotice(sharedCatchingUpCopy),
        ),
      const SizedBox(height: AppSpace.md),
      Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: [
          if (widget.onSettleUp != null)
            _button(
              'Settle up',
              Icons.payments_outlined,
              widget.onSettleUp!,
              primary: true,
              key: const Key('expenses-settle-up'),
            ),
          if (data.direct && owedToYou)
            _button('Remind', Icons.notifications_none_rounded, _remind),
          if (widget.onViewSettlements != null)
            _button(
              'History',
              Icons.receipt_long_outlined,
              widget.onViewSettlements!,
            ),
        ],
      ),
      const SizedBox(height: AppSpace.md),
      if (data.expenses.hasPrevious && widget.onPreviousPage != null)
        SharedAction(
          label: 'Previous page',
          onTap: () => widget.onPreviousPage!(SharedGroupTab.expenses),
        ),
    ];
  }

  Widget _expenses() => SharedPageBody(
    key: ValueKey('${data.id}:expenses'),
    state: data.expenses.state,
    hasItems: data.expenses.items.isNotEmpty,
    nextLabel: data.expenses.nextLabel,
    header: _header(),
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
              padding: const EdgeInsets.only(top: AppSpace.md, bottom: 2),
              child: Text(
                month,
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w700,
                  color: BambooInk.ink700,
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
        ? 'you borrowed'
        : net > 0
        ? 'you lent'
        : 'settled';
    final color = !involved || row.proposed || net == 0
        ? BambooInk.ink500
        : net < 0
        ? BambooInk.clayInk
        : BambooInk.jade;
    final extra = <String>[
      if (row.reviewLabel != null)
        row.proposed ? 'Waiting for approval' : 'Change waiting for approval',
      ?sharedStateLabel(row.state),
      if (!row.confidence.isConfirmed) 'Estimated amounts',
    ];
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 36),
                child: date == null
                    ? const SizedBox.shrink()
                    : Column(
                        children: [
                          Text(
                            DateFormat.MMM().format(date),
                            style: BambooFonts.ui(11, color: BambooInk.ink500),
                          ),
                          Text('${date.day}', style: BambooFonts.heading(17)),
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(15.5, weight: FontWeight.w600),
                    ),
                    Text(
                      // A shared amount without its full bill is not called the
                      // bill.
                      '$_paidBy ${row.billTotal.format()}'
                      '${row.totalLabel == 'Bill total' ? '' : ' (shared amount)'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    for (final text in extra)
                      Text(
                        text,
                        style: BambooFonts.ui(
                          12,
                          color: text.contains('approval')
                              ? BambooInk.amber
                              : BambooInk.ink500,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: 76,
                  maxWidth: constraints.maxWidth * .36,
                ),
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
                          Money.fromPaise(net.abs()),
                          confidence: row.confidence,
                          hidden: hideAmounts,
                          color: color,
                          size: 15.5,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
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
