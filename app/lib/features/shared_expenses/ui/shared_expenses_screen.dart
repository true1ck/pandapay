import 'package:flutter/material.dart';

import '../../../app/design/app_theme.dart';
import 'shared_components.dart';
import 'shared_presentation.dart';

/// Insights → Splits. Repository adapters own account fencing, accepted balance
/// snapshots and server search; this screen never sums a loaded page as a total.
class SharedExpensesScreen extends StatefulWidget {
  final SharedHubPresentation data;
  final int initialIndex;
  final ValueChanged<String>? onOpenFriend;
  final ValueChanged<String>? onOpenGroup;
  final ValueChanged<String>? onOpenActivity;
  final VoidCallback? onAddExpense;
  final VoidCallback? onAddFriend;
  final VoidCallback? onCreateGroup;
  final void Function(SharedHubTab, String)? onSearchChanged;
  final ValueChanged<SharedHubTab>? onRetry;
  final ValueChanged<SharedHubTab>? onLoadMore;
  final ValueChanged<SharedHubTab>? onPreviousPage;
  const SharedExpensesScreen({
    super.key,
    required this.data,
    this.initialIndex = 0,
    this.onOpenFriend,
    this.onOpenGroup,
    this.onOpenActivity,
    this.onAddExpense,
    this.onAddFriend,
    this.onCreateGroup,
    this.onSearchChanged,
    this.onRetry,
    this.onLoadMore,
    this.onPreviousPage,
  });
  @override
  State<SharedExpensesScreen> createState() => _SharedExpensesScreenState();
}

class _SharedExpensesScreenState extends State<SharedExpensesScreen> {
  final _search = {
    for (final tab in SharedHubTab.values) tab: TextEditingController(),
  };
  final _showSettled = {
    SharedHubTab.friends: false,
    SharedHubTab.groups: false,
  };
  @override
  void dispose() {
    for (final controller in _search.values) {
      controller.dispose();
    }
    super.dispose();
  }

  List<Widget> _header(SharedHubTab tab, {required bool incomplete}) => [
    if (widget.data.pendingChanges > 0)
      SharedNotice(
        '${widget.data.pendingChanges} changes pending sync or review',
      ),
    if (widget.data.offline)
      const SharedNotice(
        'Offline · showing saved splits',
        icon: Icons.cloud_off_outlined,
      ),
    if (widget.data.summary case final summary?)
      SharedSummaryCard(summary: summary, hideAmounts: widget.data.hideAmounts),
    if (incomplete) const SharedNotice('Some results are still syncing'),
    Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: TextField(
        controller: _search[tab],
        style: BambooFonts.ui(14),
        textInputAction: TextInputAction.search,
        onChanged: (value) => widget.onSearchChanged?.call(tab, value),
        onSubmitted: (_) => FocusScope.of(context).unfocus(),
        onTapOutside: (_) => FocusScope.of(context).unfocus(),
        decoration: InputDecoration(
          labelText: 'Search ${tab.name}',
          labelStyle: BambooFonts.ui(13, color: BambooInk.ink700),
          prefixIcon: const Icon(Icons.search_rounded, color: BambooInk.ink700),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
          ),
        ),
      ),
    ),
  ];

  Widget _contexts(
    SharedHubTab tab,
    SharedPage<SharedContextRow> page,
    ValueChanged<String>? open,
  ) {
    final visible = page.items
        .where((row) => _showSettled[tab]! || !row.canHideAsSettled)
        .toList(growable: false);
    final permitted = page.state != SharedLoadState.accessRevoked;
    return SharedPageBody(
      key: ValueKey(tab.name),
      state: page.state,
      hasItems: page.items.isNotEmpty,
      nextLabel: page.nextLabel,
      header: permitted
          ? [
              if (page.hasPrevious && widget.onPreviousPage != null)
                SharedAction(
                  label: 'Previous page',
                  onTap: () => widget.onPreviousPage!(tab),
                ),
              ..._header(tab, incomplete: page.incomplete),
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: SharedAction(
                    label: _showSettled[tab]! ? 'Hide settled' : 'Show settled',
                    onTap: () =>
                        setState(() => _showSettled[tab] = !_showSettled[tab]!),
                  ),
                ),
              ),
              if (tab == SharedHubTab.friends && widget.onAddFriend != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: SharedAction(
                      label: 'Add friend',
                      onTap: widget.onAddFriend!,
                      icon: Icons.person_add_outlined,
                    ),
                  ),
                ),
              if (tab == SharedHubTab.groups && widget.onCreateGroup != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: SharedAction(
                      label: 'Create group',
                      onTap: widget.onCreateGroup!,
                      icon: Icons.group_add_outlined,
                    ),
                  ),
                ),
              if (page.items.isNotEmpty && visible.isEmpty)
                const SharedNotice(
                  'Settled splits are hidden. Show settled to see your history.',
                ),
            ]
          : const [],
      itemCount: visible.length,
      itemBuilder: (_, index) => SharedContextTile(
        row: visible[index],
        hideAmounts: widget.data.hideAmounts,
        onTap: open == null ? null : () => open(visible[index].id),
      ),
      emptyTitle: tab == SharedHubTab.friends
          ? 'No shared expenses yet'
          : 'No groups yet',
      emptyMessage: tab == SharedHubTab.friends
          ? 'Add an expense with a friend to start.'
          : 'Create a group when you share expenses together.',
      hasMore: page.hasMore,
      loadingMore: page.loadingMore,
      onRetry: widget.onRetry == null ? null : () => widget.onRetry!(tab),
      onLoadMore: widget.onLoadMore == null
          ? null
          : () => widget.onLoadMore!(tab),
    );
  }

  Widget _activity() {
    final page = widget.data.activity;
    return SharedPageBody(
      key: const ValueKey('activity'),
      nextLabel: page.nextLabel,
      state: page.state,
      hasItems: page.items.isNotEmpty,
      header: page.state == SharedLoadState.accessRevoked
          ? const []
          : [
              if (page.hasPrevious && widget.onPreviousPage != null)
                SharedAction(
                  label: 'Previous page',
                  onTap: () => widget.onPreviousPage!(SharedHubTab.activity),
                ),
              ..._header(SharedHubTab.activity, incomplete: page.incomplete),
            ],
      itemCount: page.items.length,
      itemBuilder: (_, index) {
        final row = page.items[index];
        return SharedActivityTile(
          row: row,
          hideAmounts: widget.data.hideAmounts,
          onTap: widget.onOpenActivity == null
              ? null
              : () => widget.onOpenActivity!(row.id),
        );
      },
      emptyTitle: 'No shared activity yet',
      emptyMessage:
          'Expense updates and payment confirmations will appear here.',
      hasMore: page.hasMore,
      loadingMore: page.loadingMore,
      onRetry: widget.onRetry == null
          ? null
          : () => widget.onRetry!(SharedHubTab.activity),
      onLoadMore: widget.onLoadMore == null
          ? null
          : () => widget.onLoadMore!(SharedHubTab.activity),
    );
  }

  @override
  Widget build(BuildContext context) => SharedTabbedFrame(
    title: 'Splits',
    tabs: const ['Friends', 'Groups', 'Activity'],
    initialIndex: widget.initialIndex,
    onAddExpense: widget.onAddExpense,
    children: [
      _contexts(SharedHubTab.friends, widget.data.friends, widget.onOpenFriend),
      _contexts(SharedHubTab.groups, widget.data.groups, widget.onOpenGroup),
      _activity(),
    ],
  );
}

class SharedActivityTile extends StatelessWidget {
  final SharedActivityRow row;
  final bool hideAmounts;
  final VoidCallback? onTap;
  const SharedActivityTile({
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
        Text(
          row.description,
          style: BambooFonts.ui(15, weight: FontWeight.w600),
        ),
        if (row.contextLabel != null)
          Text(
            row.contextLabel!,
            style: BambooFonts.ui(12, color: BambooInk.ink700),
          ),
        if (row.impactAmount case final amount?)
          SharedMoneyLine(
            row.impactLabel ?? 'Your impact',
            amount,
            confidence: row.confidence,
            hidden: hideAmounts,
          )
        else if (row.impactLabel != null)
          Text(
            row.impactLabel!,
            style: BambooFonts.ui(13, color: BambooInk.ink700),
          ),
        Text(
          row.occurredAtLabel,
          style: BambooFonts.ui(12, color: BambooInk.ink700),
        ),
        if (onTap != null)
          Align(
            alignment: Alignment.centerLeft,
            child: SharedAction(label: 'View update', onTap: onTap!),
          ),
      ],
    ),
  );
}
