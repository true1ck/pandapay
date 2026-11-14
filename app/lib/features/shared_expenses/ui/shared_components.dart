import 'package:flutter/material.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
import '../../../main.dart' show MoneyText;
import 'shared_presentation.dart';

/// One header and tab level, matching the existing GroupedInsightScreen. This
/// deeper route owns no app-level bottom navigation or second editor.
class SharedTabbedFrame extends StatelessWidget {
  final String title;
  final List<String> tabs;
  final List<Widget> children;
  final List<Widget> actions;
  final int initialIndex;
  final TabController? controller;
  final VoidCallback? onAddExpense;
  final Widget? header;
  final Widget? titleTrailing;
  final VoidCallback? onBack;
  const SharedTabbedFrame({
    super.key,
    this.header,
    this.titleTrailing,
    this.onBack,
    required this.title,
    required this.tabs,
    required this.children,
    this.actions = const [],
    this.initialIndex = 0,
    this.controller,
    this.onAddExpense,
  });

  Widget _title() => Text(
    title,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: BambooFonts.heading(17),
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: tabs.length,
    initialIndex: initialIndex.clamp(0, tabs.length - 1),
    child: Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        leading: onBack == null ? null : BackButton(onPressed: onBack),
        title: titleTrailing == null
            ? _title()
            : Row(
                children: [
                  _title(),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(child: titleTrailing!),
                ],
              ),
        actions: actions,
        bottom: TabBar(
          controller: controller,
          isScrollable:
              MediaQuery.sizeOf(context).width <
              330 * MediaQuery.textScalerOf(context).scale(1),
          tabAlignment:
              MediaQuery.sizeOf(context).width <
                  330 * MediaQuery.textScalerOf(context).scale(1)
              ? TabAlignment.start
              : TabAlignment.fill,
          labelColor: BambooInk.slate,
          unselectedLabelColor: BambooInk.ink500,
          indicatorColor: BambooInk.slate,
          labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
          unselectedLabelStyle: BambooFonts.ui(13.5, weight: FontWeight.w500),
          tabs: [for (final label in tabs) Tab(text: label)],
        ),
      ),
      floatingActionButton: onAddExpense == null
          ? null
          : AppAddButton(tooltip: 'Add expense', onPressed: onAddExpense!),
      body: AppBackground(
        child: Column(
          children: [
            ?header,
            Expanded(
              child: TabBarView(controller: controller, children: children),
            ),
          ],
        ),
      ),
    ),
  );
}

class SharedAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  final bool primary;
  const SharedAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.primary = false,
  });
  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    semanticLabel: label,
    child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.md,
      ),
      decoration: BoxDecoration(
        color: primary ? BambooInk.slate : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Row(
        mainAxisSize: primary ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 20,
              color: primary ? BambooInk.lime : BambooInk.ink900,
            ),
            const SizedBox(width: AppSpace.sm),
          ],
          Flexible(
            child: Text(
              label,
              style: BambooFonts.ui(
                14,
                weight: FontWeight.w700,
                color: primary ? BambooInk.lime : BambooInk.ink900,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// The one primary action style for Splits sheets and screens: slate with lime
/// text, full width, 52 high. Use this instead of hand-copied button styles.
ButtonStyle sharedPrimaryButtonStyle() => FilledButton.styleFrom(
  backgroundColor: BambooInk.slate,
  foregroundColor: BambooInk.lime,
  minimumSize: const Size.fromHeight(52),
);

/// Plain-language status for work that is saved on this phone but not yet
/// confirmed by the server. Never exposes queue or sync vocabulary.
String sharedPendingCopy(int count) =>
    'Syncing your latest changes. Balances will update in a moment.';

/// Shown when a list is only partly loaded.
const sharedCatchingUpCopy =
    'Still loading the latest. Amounts may change shortly.';

class SharedNotice extends StatelessWidget {
  final String text;
  final IconData icon;
  const SharedNotice(
    this.text, {
    super.key,
    this.icon = Icons.info_outline_rounded,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: BambooInk.ink700),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Text(text, style: BambooFonts.ui(13, color: BambooInk.ink700)),
        ),
      ],
    ),
  );
}

class SharedAmount extends StatelessWidget {
  final Money value;
  final Confidence confidence;
  final bool hidden;
  final Color color;
  final double size;
  const SharedAmount(
    this.value, {
    super.key,
    required this.confidence,
    this.hidden = false,
    this.color = BambooInk.ink900,
    this.size = 17,
  });
  @override
  Widget build(BuildContext context) => hidden
      ? Semantics(
          label: 'Amount hidden',
          excludeSemantics: true,
          child: Text('••••', style: BambooFonts.money(size, color: color)),
        )
      : FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: MoneyText(
            value,
            confidence: confidence,
            style: BambooFonts.money(size, color: color),
            showConfidenceIcon: false,
          ),
        );
}

class SharedMoneyLine extends StatelessWidget {
  final String label;
  final Money amount;
  final Confidence confidence;
  final bool hidden;
  final Color color;
  const SharedMoneyLine(
    this.label,
    this.amount, {
    super.key,
    required this.confidence,
    this.hidden = false,
    this.color = BambooInk.ink900,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: AppSpace.lg,
      runSpacing: AppSpace.xs,
      children: [
        Text(label, style: BambooFonts.ui(13, color: color)),
        SharedAmount(
          amount,
          confidence: confidence,
          hidden: hidden,
          color: color,
        ),
      ],
    ),
  );
}

class SharedPanel extends StatelessWidget {
  final Widget child;
  const SharedPanel({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(AppSpace.lg),
    margin: const EdgeInsets.only(bottom: AppSpace.md),
    decoration: BoxDecoration(
      color: BambooInk.glassFillOnPaper,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      border: Border.all(color: BambooInk.hairlineOnPaper),
    ),
    child: child,
  );
}

/// The white rounded box every Splits row and header sits in, the same look as
/// the Activity rows: one thing per box, so lists read as separate, tappable
/// items on the page background.
BoxDecoration sharedCardDecoration() => BoxDecoration(
  color: BambooInk.glassFillOnPaper,
  borderRadius: BorderRadius.circular(AppRadius.lg),
  border: Border.all(color: BambooInk.hairlineOnPaper),
);

/// Where the person stands, in one line, the Splitwise way: "Overall, you owe
/// ₹500.00", or on a friend's page "You owe Ravi ₹500.00". The two gross
/// figures appear only when both are real (somebody owes you and you owe
/// somebody), because otherwise they only repeat the line.
class SharedSummaryCard extends StatelessWidget {
  final SharedBalanceSummary summary;
  final bool hideAmounts;

  /// The friend, on a friend's page; null for a group or the hub.
  final String? name;
  const SharedSummaryCard({
    super.key,
    required this.summary,
    this.hideAmounts = false,
    this.name,
  });
  @override
  Widget build(BuildContext context) {
    final net = summary.netBalance.paise;
    final both = !summary.owedToYou.isZero && !summary.youOwe.isZero;
    final color = net > 0
        ? BambooInk.jade
        : net < 0
        ? BambooInk.clayInk
        : BambooInk.ink900;
    final who = name;
    final label = who == null || (net == 0)
        ? sharedOverallLabel(summary)
        : net < 0
        ? 'You owe $who'
        : '$who owes you';
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: sharedCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 2,
            children: [
              Text(
                label,
                style: BambooFonts.ui(
                  16,
                  weight: FontWeight.w700,
                  color: net == 0 ? BambooInk.ink900 : color,
                ),
              ),
              if (net != 0 || both)
                SharedAmount(
                  sharedNetMagnitude(summary),
                  confidence: summary.confidence,
                  hidden: hideAmounts,
                  color: color,
                  size: 18,
                ),
            ],
          ),
          if (both) ...[
            const SizedBox(height: AppSpace.xs),
            _line('You are owed', summary.owedToYou, BambooInk.jade),
            const SizedBox(height: 2),
            _line('You owe', summary.youOwe, BambooInk.clayInk),
          ],
          if (summary.incomplete)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(
                'Some balances may be missing',
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            ),
          if (!summary.confidence.isConfirmed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.xs),
              child: Text(
                'Estimated amounts',
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            ),
        ],
      ),
    );
  }

  Widget _line(String label, Money money, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(label, style: BambooFonts.ui(12, color: BambooInk.ink700)),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SharedAmount(
            money,
            confidence: summary.confidence,
            hidden: hideAmounts,
            color: color,
            size: 14,
          ),
        ),
      ),
    ],
  );
}

/// "Overall, you owe", "Overall, you are owed" or "All settled up".
String sharedOverallLabel(SharedBalanceSummary summary) =>
    summary.netBalance.paise > 0
    ? 'Overall, you are owed'
    : summary.netBalance.paise < 0
    ? 'Overall, you owe'
    : (summary.owedToYou.isZero && summary.youOwe.isZero)
    ? 'All settled up'
    : 'Overall, even';

String sharedNetLabel(SharedBalanceSummary summary) =>
    summary.netBalance.paise > 0
    ? 'Net owed to you'
    : summary.netBalance.paise < 0
    ? 'Net you owe'
    : 'Net balance';

Money sharedNetMagnitude(SharedBalanceSummary summary) =>
    Money.fromPaise(summary.netBalance.paise.abs());

/// Secondary list controls retain a full touch target without outlined panels.
class SharedTextAction extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  const SharedTextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
  });
  @override
  Widget build(BuildContext context) => Pressable(
    semanticLabel: label,
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: BambooInk.slate),
            const SizedBox(width: AppSpace.sm),
          ],
          Flexible(
            child: Text(
              label,
              style: BambooFonts.ui(13, weight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );
}

class SharedAvatar extends StatelessWidget {
  final String name;
  final bool group;
  const SharedAvatar({super.key, required this.name, this.group = false});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: BambooInk.rankBadgeBg,
        shape: BoxShape.circle,
      ),
      child: group
          ? const Icon(
              Icons.people_outline_rounded,
              color: BambooInk.jade,
              size: 22,
            )
          : Text(
              name.trim().isEmpty
                  ? '·'
                  : name.trim().characters.first.toUpperCase(),
              textScaler: TextScaler.noScaling,
              style: BambooFonts.ui(
                17,
                weight: FontWeight.w600,
                color: BambooInk.jade,
              ),
            ),
    ),
  );
}

String? sharedStateLabel(SharedContextState state) => switch (state) {
  SharedContextState.active => null,
  SharedContextState.noExpenses => 'No expenses',
  SharedContextState.settled => 'Settled',
  SharedContextState.pendingInvite => 'Invitation pending',
  SharedContextState.pendingReview => 'Awaiting review',
  SharedContextState.pendingPayment => 'Payment confirmation pending',
  SharedContextState.creditOwedBack => 'Credit owed back',
  SharedContextState.disputed => 'Needs review',
  SharedContextState.incomplete => 'Some balances missing',
};

/// A friend or a group in the Splits lists, the Splitwise way: who, then what
/// that means for you on the right ("owes you ₹1,500.00", "you owe ₹500.00",
/// "settled up"), lined up the same on every row. A friend you share groups
/// with gets a line per place under the name, so one glance tells where the
/// money sits.
class SharedContextTile extends StatelessWidget {
  final SharedContextRow row;
  final bool hideAmounts;
  final VoidCallback? onTap;
  final bool isGroup;
  const SharedContextTile({
    super.key,
    required this.row,
    this.hideAmounts = false,
    this.onTap,
    this.isGroup = false,
  });

  @override
  Widget build(BuildContext context) {
    final net = row.balance.netBalance.paise;
    final mixed =
        !row.balance.owedToYou.isZero &&
        !row.balance.youOwe.isZero &&
        row.breakdown.isEmpty;
    final hasBalance =
        !row.balance.owedToYou.isZero || !row.balance.youOwe.isZero;
    final color = net > 0
        ? BambooInk.jade
        : net < 0
        ? BambooInk.clayInk
        : BambooInk.ink500;
    final caption = !hasBalance
        ? (sharedStateLabel(row.state) ?? 'settled up').toLowerCase()
        : net > 0
        ? (isGroup ? 'you are owed' : 'owes you')
        : net < 0
        ? 'you owe'
        : 'even';
    // What is happening with the row, under the name, so the right side only
    // ever says money.
    final stateLabel = sharedStateLabel(row.state);
    final status = <String>[
      ?row.subtitle,
      if (hasBalance &&
          stateLabel != null &&
          row.state != SharedContextState.settled)
        stateLabel,
      if (row.state == SharedContextState.settled && !row.canHideAsSettled)
        'Balance changed · needs review',
      if (row.balance.incomplete) 'Some balances may be missing',
      if (!row.balance.confidence.isConfirmed) 'Estimated amounts',
    ];
    final lines = <(String, String, Money, String, bool)>[
      for (final line in row.breakdown)
        line.owedToYou
            ? ('${row.title} owes you ', '', line.amount, _where(line), true)
            : ('You owe ${row.title} ', '', line.amount, _where(line), false),
      if (mixed) ...[
        ('You are owed ', '', row.balance.owedToYou, '', true),
        ('You owe ', '', row.balance.youOwe, '', false),
      ],
    ];
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpace.sm),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: sharedCardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  SharedAvatar(name: row.title, group: isGroup),
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          row.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BambooFonts.ui(16, weight: FontWeight.w600),
                        ),
                        for (final text in status)
                          Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BambooFonts.ui(12, color: BambooInk.ink500),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: constraints.maxWidth * .42,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          caption,
                          textAlign: TextAlign.end,
                          style: BambooFonts.ui(12, color: color),
                        ),
                        if (hasBalance)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: SharedAmount(
                              Money.fromPaise(net.abs()),
                              confidence: row.balance.confidence,
                              hidden: hideAmounts,
                              color: color,
                              size: 16,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (onTap != null)
                    const Padding(
                      padding: EdgeInsets.only(left: 2),
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: BambooInk.ink500,
                      ),
                    ),
                ],
              ),
            ),
            if (lines.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(left: 19, top: AppSpace.xs),
                padding: const EdgeInsets.only(left: 33),
                decoration: const BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: BambooInk.hairlineOnPaper,
                      width: 1.5,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (lead, _, money, where, owed) in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text.rich(
                          TextSpan(
                            style: BambooFonts.ui(
                              12.5,
                              color: BambooInk.ink700,
                            ),
                            children: [
                              TextSpan(text: lead),
                              TextSpan(
                                text: hideAmounts ? '••••' : money.format(),
                                style: TextStyle(
                                  color: owed
                                      ? BambooInk.jade
                                      : BambooInk.clayInk,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (where.isNotEmpty) TextSpan(text: ' $where'),
                            ],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
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

  static String _where(SharedBreakdownLine line) => line.groupName == null
      ? 'in non-group expenses'
      : 'in “${line.groupName}”';
}

class SharedPageBody extends StatefulWidget {
  final SharedLoadState state;
  final bool hasItems;
  final List<Widget> header;
  final List<Widget> footer;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final String emptyTitle;
  final String emptyMessage;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onRetry;
  final VoidCallback? onLoadMore;
  final String nextLabel;
  const SharedPageBody({
    this.nextLabel = 'Load more',
    super.key,
    required this.state,
    required this.hasItems,
    required this.header,
    this.footer = const [],
    required this.itemCount,
    required this.itemBuilder,
    required this.emptyTitle,
    required this.emptyMessage,
    this.hasMore = false,
    this.loadingMore = false,
    this.onRetry,
    this.onLoadMore,
  });
  @override
  State<SharedPageBody> createState() => _SharedPageBodyState();
}

class _SharedPageBodyState extends State<SharedPageBody>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.state == SharedLoadState.accessRevoked) {
      return const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'You no longer have access',
        message: 'Your private bank records are unchanged.',
      );
    }
    final terminal = !widget.hasItems;
    final List<Widget> tail = [];
    if (terminal && widget.state == SharedLoadState.loading) {
      tail.add(const SkeletonList());
    } else if (widget.state == SharedLoadState.error) {
      tail.add(
        Column(
          children: [
            const SharedNotice('Could not refresh splits'),
            if (widget.onRetry != null)
              SharedAction(label: 'Try again', onTap: widget.onRetry!),
          ],
        ),
      );
    } else if (terminal) {
      tail.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xl),
          child: Column(
            children: [
              Text(
                widget.emptyTitle,
                style: BambooFonts.heading(16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                widget.emptyMessage,
                style: BambooFonts.ui(13, color: BambooInk.ink700),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    if (widget.hasMore) {
      tail.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
          child: widget.loadingMore
              ? const SharedNotice('Loading more…')
              : widget.onLoadMore == null
              ? const SharedNotice('More results available')
              : SharedAction(
                  label: widget.nextLabel,
                  onTap: widget.onLoadMore!,
                ),
        ),
      );
    }
    return ListView.builder(
      key: PageStorageKey(widget.key),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        96,
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount:
          widget.header.length +
          widget.itemCount +
          widget.footer.length +
          tail.length,
      itemBuilder: (context, index) {
        if (index < widget.header.length) return widget.header[index];
        final row = index - widget.header.length;
        if (row < widget.itemCount) return widget.itemBuilder(context, row);
        final end = row - widget.itemCount;
        if (end < widget.footer.length) return widget.footer[end];
        return tail[end - widget.footer.length];
      },
    );
  }
}
