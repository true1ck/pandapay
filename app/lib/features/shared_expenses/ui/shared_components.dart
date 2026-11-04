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
  const SharedTabbedFrame({
    super.key,
    required this.title,
    required this.tabs,
    required this.children,
    this.actions = const [],
    this.initialIndex = 0,
    this.controller,
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
      body: AppBackground(
        child: TabBarView(controller: controller, children: children),
      ),
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
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.lg),
    margin: const EdgeInsets.only(bottom: AppSpace.sm),
    decoration: BoxDecoration(
      color: BambooInk.slate,
      borderRadius: BorderRadius.circular(AppRadius.lg),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          sharedNetLabel(summary),
          style: BambooFonts.ui(
            13,
            color: BambooInk.onSlate,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: SharedAmount(
            sharedNetMagnitude(summary),
            confidence: summary.confidence,
            hidden: hideAmounts,
            color: BambooInk.lime,
            size: 32,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Divider(color: BambooInk.slateHairline),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            Widget value(String label, Money money) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
                ),
                const SizedBox(height: AppSpace.xs),
                Align(
                  alignment: Alignment.centerLeft,
                  child: SharedAmount(
                    money,
                    confidence: summary.confidence,
                    hidden: hideAmounts,
                    color: BambooInk.onSlate,
                    size: 19,
                  ),
                ),
              ],
            );
            final owed = value('You are owed', summary.owedToYou);
            final owing = value('You owe', summary.youOwe);
            if (constraints.maxWidth <
                260 * MediaQuery.textScalerOf(context).scale(1)) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  owed,
                  const SizedBox(height: AppSpace.md),
                  owing,
                ],
              );
            }
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: owed),
                  const VerticalDivider(
                    color: BambooInk.slateHairline,
                    width: 28,
                  ),
                  Expanded(child: owing),
                ],
              ),
            );
          },
        ),
        if (summary.incomplete)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Balance snapshot incomplete',
              style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
            ),
          ),
        if (!summary.confidence.isConfirmed)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Estimated amounts',
              style: BambooFonts.ui(12, color: BambooInk.onSlateSubtle),
            ),
          ),
      ],
    ),
  );
}

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
  SharedContextState.incomplete => 'Snapshot incomplete',
};

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
    final mixed = !row.balance.owedToYou.isZero && !row.balance.youOwe.isZero;
    final owed = row.balance.youOwe.isZero;
    final label = mixed
        ? (row.balance.netBalance.isZero ? 'Net' : sharedNetLabel(row.balance))
        : owed
        ? 'You are owed'
        : 'You owe';
    final color = mixed
        ? (row.balance.netBalance.paise > 0
              ? BambooInk.jade
              : row.balance.netBalance.paise < 0
              ? BambooInk.clayInk
              : BambooInk.ink900)
        : owed
        ? BambooInk.jade
        : BambooInk.clayInk;
    final value = mixed
        ? sharedNetMagnitude(row.balance)
        : owed
        ? row.balance.owedToYou
        : row.balance.youOwe;
    final hasBalance =
        !row.balance.owedToYou.isZero || !row.balance.youOwe.isZero;
    final state =
        row.state == SharedContextState.settled && !row.canHideAsSettled
        ? 'Balance changed · needs review'
        : sharedStateLabel(row.state);
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(row.title, style: BambooFonts.heading(15)),
        if (row.subtitle != null)
          Text(
            row.subtitle!,
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
      ],
    );
    final position = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state != null)
          Text(state, style: BambooFonts.ui(12, color: BambooInk.ink700)),
        if (hasBalance) ...[
          Text(label, style: BambooFonts.ui(12, color: color)),
          const SizedBox(height: AppSpace.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: SharedAmount(
              value,
              confidence: row.balance.confidence,
              hidden: hideAmounts,
              color: color,
            ),
          ),
        ],
        if (row.balance.incomplete)
          Text(
            'Balance snapshot incomplete',
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
        if (!row.balance.confidence.isConfirmed)
          Text(
            'Estimated amounts',
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
      ],
    );
    return Pressable(
      onTap: onTap,
      child: SharedPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked =
                    constraints.maxWidth <
                    285 * MediaQuery.textScalerOf(context).scale(1);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SharedAvatar(name: row.title, group: isGroup),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: stacked
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [identity, position],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(child: identity),
                                const SizedBox(width: AppSpace.sm),
                                Flexible(child: position),
                              ],
                            ),
                    ),
                    if (onTap != null)
                      const Padding(
                        padding: EdgeInsets.only(top: AppSpace.sm),
                        child: Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: BambooInk.ink700,
                        ),
                      ),
                  ],
                );
              },
            ),
            // Netting is informational; opposite obligations stay distinct below it.
            if (mixed) ...[
              const Divider(color: BambooInk.hairlineOnPaper),
              SharedMoneyLine(
                'You are owed',
                row.balance.owedToYou,
                confidence: row.balance.confidence,
                hidden: hideAmounts,
                color: BambooInk.jade,
              ),
              SharedMoneyLine(
                'You owe',
                row.balance.youOwe,
                confidence: row.balance.confidence,
                hidden: hideAmounts,
                color: BambooInk.clayInk,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Keeps each tab's scroll and local controls while another tab is selected.
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
      padding: const EdgeInsets.all(AppSpace.lg),
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
