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
  final VoidCallback? onAddExpense;
  const SharedTabbedFrame({
    super.key,
    required this.title,
    required this.tabs,
    required this.children,
    this.actions = const [],
    this.initialIndex = 0,
    this.onAddExpense,
  });

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: tabs.length,
    initialIndex: initialIndex.clamp(0, tabs.length - 1),
    child: Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: BambooFonts.heading(17),
        ),
        actions: actions,
        bottom: TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: BambooInk.slate,
          unselectedLabelColor: BambooInk.ink500,
          indicatorColor: BambooInk.slate,
          labelStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
          unselectedLabelStyle: BambooFonts.ui(13.5, weight: FontWeight.w500),
          tabs: [for (final label in tabs) Tab(text: label)],
        ),
      ),
      body: AppBackground(child: TabBarView(children: children)),
      bottomNavigationBar: onAddExpense == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: SharedAction(
                  label: 'Add expense',
                  icon: Icons.add_rounded,
                  onTap: onAddExpense!,
                  primary: true,
                ),
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
              color: primary ? BambooInk.onSlate : BambooInk.ink900,
            ),
            const SizedBox(width: AppSpace.sm),
          ],
          Flexible(
            child: Text(
              label,
              style: BambooFonts.ui(
                14,
                weight: FontWeight.w700,
                color: primary ? BambooInk.onSlate : BambooInk.ink900,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

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

class SharedSummaryCard extends StatelessWidget {
  final SharedBalanceSummary summary;
  final bool hideAmounts;
  const SharedSummaryCard({
    super.key,
    required this.summary,
    this.hideAmounts = false,
  });
  @override
  Widget build(BuildContext context) => SharedPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SharedMoneyLine(
          'You are owed',
          summary.owedToYou,
          confidence: summary.confidence,
          hidden: hideAmounts,
          color: BambooInk.jade,
        ),
        SharedMoneyLine(
          'You owe',
          summary.youOwe,
          confidence: summary.confidence,
          hidden: hideAmounts,
          color: BambooInk.clayInk,
        ),
        const Divider(color: BambooInk.hairlineOnPaper),
        SharedMoneyLine(
          'Net balance',
          summary.netBalance,
          confidence: summary.confidence,
          hidden: hideAmounts,
        ),
        if (summary.incomplete)
          const SharedNotice('Balance snapshot incomplete'),
        if (!summary.confidence.isConfirmed)
          const SharedNotice('Estimated amounts'),
      ],
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
  SharedContextState.incomplete => 'Snapshot incomplete',
};

class SharedContextTile extends StatelessWidget {
  final SharedContextRow row;
  final bool hideAmounts;
  final VoidCallback? onTap;
  const SharedContextTile({
    super.key,
    required this.row,
    this.hideAmounts = false,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: SharedPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(row.title, style: BambooFonts.heading(16))),
              if (onTap != null)
                const Icon(
                  Icons.chevron_right_rounded,
                  color: BambooInk.ink500,
                ),
            ],
          ),
          if (row.subtitle != null)
            Text(
              row.subtitle!,
              style: BambooFonts.ui(12, color: BambooInk.ink700),
            ),
          if (row.state == SharedContextState.settled && !row.canHideAsSettled)
            const SharedNotice('Balance changed · needs review')
          else if (sharedStateLabel(row.state) case final label?)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(
                label,
                style: BambooFonts.ui(12, color: BambooInk.ink700),
              ),
            ),
          if (!row.canHideAsSettled) ...[
            if (!row.balance.owedToYou.isZero)
              SharedMoneyLine(
                'You are owed',
                row.balance.owedToYou,
                confidence: row.balance.confidence,
                hidden: hideAmounts,
                color: BambooInk.jade,
              ),
            if (!row.balance.youOwe.isZero)
              SharedMoneyLine(
                'You owe',
                row.balance.youOwe,
                confidence: row.balance.confidence,
                hidden: hideAmounts,
                color: BambooInk.clayInk,
              ),
            if (row.balance.incomplete)
              const SharedNotice('Balance snapshot incomplete'),
          ],
        ],
      ),
    ),
  );
}

/// Keeps each tab's scroll and local controls while another tab is selected.
class SharedPageBody extends StatefulWidget {
  final SharedLoadState state;
  final bool hasItems;
  final List<Widget> header;
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
      padding: const EdgeInsets.all(AppSpace.lg),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: widget.header.length + widget.itemCount + tail.length,
      itemBuilder: (context, index) {
        if (index < widget.header.length) return widget.header[index];
        final row = index - widget.header.length;
        if (row < widget.itemCount) return widget.itemBuilder(context, row);
        return tail[row - widget.itemCount];
      },
    );
  }
}
