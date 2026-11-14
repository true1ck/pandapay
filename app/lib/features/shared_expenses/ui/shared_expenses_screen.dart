import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/design/app_theme.dart';
import '../../../app/design/widgets.dart';
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
  final Widget? header;
  const SharedExpensesScreen({
    super.key,
    this.header,
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

class _SharedExpensesScreenState extends State<SharedExpensesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchVisible = <SharedHubTab>{};
  final _searchFocus = FocusNode();
  final _search = {
    for (final tab in SharedHubTab.values) tab: TextEditingController(),
  };
  final _showSettled = {
    SharedHubTab.friends: false,
    SharedHubTab.groups: false,
  };
  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialIndex.clamp(0, 2),
    );
    _tabs.addListener(_tabChanged);
  }

  void _tabChanged() {
    FocusScope.of(context).unfocus();
    setState(() {});
  }

  SharedHubTab get _selected => SharedHubTab.values[_tabs.index];

  @override
  void dispose() {
    _tabs.removeListener(_tabChanged);
    _tabs.dispose();
    _searchFocus.dispose();
    for (final controller in _search.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _filter() async {
    final tab = _selected;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: BambooInk.paper,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Filter ${tab.name}', style: BambooFonts.heading(18)),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: BambooInk.slate,
                  title: Text(
                    'Include settled ${tab.name}',
                    style: BambooFonts.ui(14),
                  ),
                  value: _showSettled[tab]!,
                  onChanged: (value) {
                    if (!mounted) return;
                    setState(() => _showSettled[tab] = value);
                    update(() {});
                  },
                ),
                SharedTextAction(
                  label: 'Done',
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _header(SharedHubTab tab, {required bool incomplete}) => [
    if (widget.data.pendingChanges > 0)
      SharedNotice(
        sharedPendingCopy(widget.data.pendingChanges),
        icon: Icons.sync_rounded,
      ),
    if (tab != SharedHubTab.activity) ...[
      if (widget.data.summary case final summary?)
        SharedSummaryCard(
          summary: summary,
          hideAmounts: widget.data.hideAmounts,
        ),
    ],
    if (tab == SharedHubTab.activity) ...[
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: Text('Recent changes', style: BambooFonts.heading(19)),
      ),
      if (widget.data.summary case final summary?)
        Container(
          padding: const EdgeInsets.all(AppSpace.md),
          margin: const EdgeInsets.only(bottom: AppSpace.md),
          decoration: BoxDecoration(
            color: BambooInk.rankBadgeBg,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: SharedMoneyLine(
            sharedNetLabel(summary),
            sharedNetMagnitude(summary),
            confidence: summary.confidence,
            hidden: widget.data.hideAmounts,
            color: summary.netBalance.paise < 0
                ? BambooInk.clayInk
                : BambooInk.ink900,
          ),
        ),
      if (widget.data.summary?.incomplete == true)
        const SharedNotice('Some balances may be missing'),
      if (widget.data.summary != null &&
          !widget.data.summary!.confidence.isConfirmed)
        const SharedNotice('Estimated amounts'),
    ],
    if (incomplete && widget.data.pendingChanges == 0)
      const SharedNotice(sharedCatchingUpCopy),
  ];

  Widget _contexts(
    SharedHubTab tab,
    SharedPage<SharedContextRow> page,
    ValueChanged<String>? open,
  ) {
    final visible = page.items
        .where((row) => !row.canHideAsSettled)
        .toList(growable: false);
    final settled = page.items
        .where((row) => row.canHideAsSettled)
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
              if (tab == SharedHubTab.friends && widget.onAddFriend != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.md),
                    child: SharedTextAction(
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
                    child: SharedTextAction(
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
        isGroup: tab == SharedHubTab.groups,
        hideAmounts: widget.data.hideAmounts,
        onTap: open == null ? null : () => open(visible[index].id),
      ),
      // Splitwise's way: settled people are tucked away behind one quiet line
      // that says how many there are, and the line is not there when none are.
      footer: permitted && settled.isNotEmpty
          ? [
              SharedTextAction(
                label: _showSettled[tab]!
                    ? 'Hide settled-up ${tab.name}'
                    : 'Show ${settled.length} settled-up '
                          '${settled.length == 1 ? tab.name.substring(0, tab.name.length - 1) : tab.name}',
                icon: _showSettled[tab]!
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                onTap: () =>
                    setState(() => _showSettled[tab] = !_showSettled[tab]!),
              ),
              if (_showSettled[tab]!)
                for (final row in settled)
                  SharedContextTile(
                    row: row,
                    isGroup: tab == SharedHubTab.groups,
                    hideAmounts: widget.data.hideAmounts,
                    onTap: open == null ? null : () => open(row.id),
                  ),
            ]
          : const [],
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
        final day = _activityDay(row.occurredAtLabel);
        final previous = index == 0
            ? null
            : _activityDay(page.items[index - 1].occurredAtLabel);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (day != null && day != previous)
              Padding(
                padding: const EdgeInsets.only(
                  top: AppSpace.sm,
                  bottom: AppSpace.md,
                ),
                child: Text(day, style: BambooFonts.heading(15)),
              ),
            SharedActivityTile(
              row: row,
              hideAmounts: widget.data.hideAmounts,
              onTap: widget.onOpenActivity == null
                  ? null
                  : () => widget.onOpenActivity!(row.id),
            ),
          ],
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

  bool get _searchOpen => _searchVisible.contains(_selected);

  void _openSearch() {
    setState(() => _searchVisible.add(_selected));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) _searchFocus.requestFocus();
    });
  }

  void _clearSearch() {
    _search[_selected]!.clear();
    widget.onSearchChanged?.call(_selected, '');
  }

  void _closeSearch() {
    if (_search[_selected]!.text.isNotEmpty) _clearSearch();
    _searchFocus.unfocus();
    setState(() => _searchVisible.remove(_selected));
  }

  Widget _searchField() => Semantics(
    label: 'Search ${_selected.name}',
    child: TextField(
      key: ValueKey('split-search-${_selected.name}'),
      controller: _search[_selected],
      focusNode: _searchFocus,
      style: BambooFonts.ui(14),
      textInputAction: TextInputAction.search,
      onChanged: (value) => widget.onSearchChanged?.call(_selected, value),
      onSubmitted: (_) => _searchFocus.unfocus(),
      onTapOutside: (_) => _searchFocus.unfocus(),
      decoration: InputDecoration(
        hintText: 'Search…',
        isDense: true,
        filled: true,
        fillColor: BambooInk.paperCool,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _search[_selected]!,
          builder: (context, value, _) => IconButton(
            tooltip: value.text.isEmpty ? 'Close search' : 'Clear search',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () {
              if (value.text.isEmpty) {
                _closeSearch();
              } else {
                _clearSearch();
                _searchFocus.requestFocus();
              }
            },
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_searchOpen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _searchOpen) _closeSearch();
    },
    child: SharedTabbedFrame(
      title: 'Splits',
      titleTrailing: _searchOpen ? _searchField() : null,
      onBack: _searchOpen ? _closeSearch : null,
      header: widget.header,
      tabs: const ['Friends', 'Groups', 'Activity'],
      initialIndex: widget.initialIndex,
      controller: _tabs,
      onAddExpense: widget.onAddExpense,
      actions: [
        if (!_searchOpen)
          IconButton(
            tooltip: 'Search splits',
            icon: const Icon(Icons.search_rounded),
            onPressed: _openSearch,
          ),
        if (_selected != SharedHubTab.activity)
          IconButton(
            tooltip: 'Filter splits',
            icon: const Icon(Icons.filter_list_rounded),
            onPressed: _filter,
          ),
      ],
      children: [
        _contexts(
          SharedHubTab.friends,
          widget.data.friends,
          widget.onOpenFriend,
        ),
        _contexts(SharedHubTab.groups, widget.data.groups, widget.onOpenGroup),
        _activity(),
      ],
    ),
  );
}

String? _activityDay(String value) {
  final time = DateTime.tryParse(value)?.toLocal();
  if (time == null) return null;
  final today = DateUtils.dateOnly(DateTime.now());
  final date = DateUtils.dateOnly(time);
  if (date == today) return 'Today';
  if (date == DateTime(today.year, today.month, today.day - 1)) {
    return 'Yesterday';
  }
  return DateFormat.yMMMd().format(time);
}

String _activityTime(String value) {
  final time = DateTime.tryParse(value)?.toLocal();
  return time == null ? value : DateFormat.jm().format(time);
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
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: SharedPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(
            child: CircleAvatar(
              radius: 20,
              backgroundColor: BambooInk.rankBadgeBg,
              child: Icon(
                Icons.history_rounded,
                size: 21,
                color: BambooInk.jade,
              ),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
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
                  _activityTime(row.occurredAtLabel),
                  style: BambooFonts.ui(12, color: BambooInk.ink700),
                ),
              ],
            ),
          ),
          if (onTap != null)
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: BambooInk.ink700,
            ),
        ],
      ),
    ),
  );
}
