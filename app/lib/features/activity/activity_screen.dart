import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';

/// D1 Transaction List (ui-spec Group D, implementation-plan-group-c-d.md)
/// — extends the original flat list (UA-3+/Chunk 18) with date grouping,
/// card/category/type filters, a money-in/money-out summary for whatever's currently
/// filtered in, tap-through to D2 Transaction Detail, and free-text search
/// over merchant and note (`GET /transactions?q=`, debounced — see
/// [_SearchField]). Search was previously flagged here as a real gap
/// because no server-side text match existed; it does now.
///
/// The "needs-review" filter still isn't here, and shouldn't be: it isn't a
/// transactions-table concept at all (D4's parser_failures queue is a
/// separate surface with its own screen). The optimality indicator (✓
/// best / ⚠ better existed) depends on the shared historical-recompute
/// calculator, built separately and not yet wired into this row.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final filter = ref.watch(_activityFilterProvider);
    final transactions = ref.watch(activityTransactionsProvider);

    return AppBackground(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.lg,
              AppSpace.lg,
              0,
            ),
            child: Column(
              children: [
                const _SearchField(),
                const SizedBox(height: AppSpace.sm),
                _FilterRow(filter: filter),
              ],
            ),
          ),
          Expanded(
            child: transactions.when(
              // See my_cards_screen.dart for why a list-shaped skeleton
              // rather than a centred spinner.
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: SkeletonList(count: 5),
              ),
              error: (err, _) => ErrorState(
                message: userFacingErrorMessage(err),
              onRetry: () => ref.invalidate(activityTransactionsProvider),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: filter.isActive
                        ? 'No activity matches these filters'
                        : 'No activity yet',
                    message: filter.isActive
                        ? null
                        : 'Transactions you log from the Cards tab show up here.',
                  );
                }
                final grouped = _groupByDay(entries);
                final incomingEntries = entries.where(_isMoneyInEntry).toList();
                final outgoingEntries = entries.where(_isMoneyOutEntry).toList();
                final totalIncoming = incomingEntries.fold<Money>(
                  const Money.zero(),
                  (a, e) => a + e.amount,
                );
                final totalOutgoing = outgoingEntries.fold<Money>(
                  const Money.zero(),
                  (a, e) => a + e.amount,
                );

                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    0,
                  ),
                  children: [
                    _SummaryCard(
                      totalIncoming: totalIncoming,
                      totalOutgoing: totalOutgoing,
                      count: entries.length,
                    ),
                    const SizedBox(height: AppSpace.lg),
                    for (final group in grouped) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: Text(
                          _dayLabel(group.day),
                          style: BambooFonts.heading(
                            13,
                            color: BambooInk.ink500,
                          ),
                        ),
                      ),
                      for (final entry in group.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.sm),
                          child: _TransactionTile(
                            entry,
                            onTap: () => context.push(
                              '/activity/${entry.id}',
                              extra: entry,
                            ),
                          ),
                        ),
                      const SizedBox(height: AppSpace.sm),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static List<_DayGroup> _groupByDay(List<TransactionEntry> entries) {
    final byDay = <DateTime, List<TransactionEntry>>{};
    for (final e in entries) {
      final day = DateTime(
        e.occurredAt.year,
        e.occurredAt.month,
        e.occurredAt.day,
      );
      byDay.putIfAbsent(day, () => []).add(e);
    }
    final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final d in days) _DayGroup(d, byDay[d]!)];
  }

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  static bool _isMoneyInEntry(TransactionEntry entry) =>
      entry.status == 'active' &&
      entry.entryKind == TxnEntryKind.income &&
      entry.amount.paise > 0;

  static bool _isMoneyOutEntry(TransactionEntry entry) =>
      entry.status == 'active' &&
      (entry.entryKind == TxnEntryKind.spend ||
          entry.entryKind == TxnEntryKind.investment) &&
      entry.amount.paise > 0;
}

class _DayGroup {
  final DateTime day;
  final List<TransactionEntry> entries;
  const _DayGroup(this.day, this.entries);
}

/// D1's filter state — card + category + date range. A plain immutable
/// value class over a StateProvider, same shape as other multi-field
/// filter state in this app (none yet reused a common pattern, kept local).
class ActivityFilter {
  final String? cardId;
  final String? categoryId;
  final String? subcategoryId;
  final DateTime? from;
  final DateTime? to;

  /// Free-text search over merchant name and note, matched server-side
  /// (`GET /transactions?q=`). Client-side filtering would only ever have
  /// searched the rows already loaded, which is why this shipped as a
  /// documented gap rather than a box that quietly searched the last 50
  /// transactions.
  final String? query;
  final _ActivityTypeFilter type;

  const ActivityFilter({
    this.cardId,
    this.categoryId,
    this.subcategoryId,
    this.from,
    this.to,
    this.query,
    this.type = _ActivityTypeFilter.all,
  });

  bool get isActive =>
      cardId != null ||
      categoryId != null ||
      subcategoryId != null ||
      from != null ||
      to != null ||
      (query != null && query!.isNotEmpty) ||
      hasTypeFilter;

  bool get hasTypeFilter => type != _ActivityTypeFilter.all;

  ActivityFilter copyWith({
    String? Function()? cardId,
    String? Function()? categoryId,
    String? Function()? subcategoryId,
    DateTime? Function()? from,
    DateTime? Function()? to,
    String? Function()? query,
    _ActivityTypeFilter? type,
  }) {
    return ActivityFilter(
      cardId: cardId != null ? cardId() : this.cardId,
      categoryId: categoryId != null ? categoryId() : this.categoryId,
      subcategoryId: subcategoryId != null ? subcategoryId() : this.subcategoryId,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
      query: query != null ? query() : this.query,
      type: type ?? this.type,
    );
  }
}

final _activityFilterProvider = StateProvider<ActivityFilter>(
  (ref) => const ActivityFilter(),
);

final activityTransactionsProvider = FutureProvider<List<TransactionEntry>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final filter = ref.watch(_activityFilterProvider);

  // Keep the unfiltered Activity surface on the same provider as every
  // other transaction consumer. SMS reconciliation, quick-add, imports and
  // resume refreshes invalidate [transactionsProvider]; using a second
  // independently cached request here used to leave Activity showing an old
  // empty result until the app was restarted or the user tapped Retry.
  // Type-only filters can still be applied locally without a second fetch.
  final hasServerFilter =
      filter.from != null ||
      filter.to != null ||
      filter.cardId != null ||
      filter.categoryId != null ||
      filter.subcategoryId != null ||
      (filter.query != null && filter.query!.trim().isNotEmpty);
  final entries = hasServerFilter
      ? await (() {
          // Subscribe to the canonical provider as a refresh signal even
          // while a narrower server query is active. When a new SMS arrives,
          // its invalidation must cause this filtered view to refetch too.
          ref.watch(transactionsProvider);
          return loadTransactionsWithOfflineCache(
            ref,
            repo: repo,
            cacheKey: 'transactions:activity',
            from: filter.from,
            to: filter.to,
            cardId: filter.cardId,
            categoryId: filter.categoryId,
            userCategoryId: filter.subcategoryId,
            query: filter.query,
          );
        })()
      : await ref.watch(transactionsProvider.future);
  return entries.where((entry) => filter.type.matches(entry)).toList();
});

enum _ActivityTypeFilter { all, moneyIn, moneyOut, transfers, investments }

extension on _ActivityTypeFilter {
  String get label => switch (this) {
    _ActivityTypeFilter.all => 'All activity',
    _ActivityTypeFilter.moneyIn => 'Money in',
    _ActivityTypeFilter.moneyOut => 'Money out',
    _ActivityTypeFilter.transfers => 'Transfers',
    _ActivityTypeFilter.investments => 'Investments',
  };

  bool matches(TransactionEntry entry) => switch (this) {
    _ActivityTypeFilter.all => true,
    _ActivityTypeFilter.moneyIn => entry.entryKind == TxnEntryKind.income,
    _ActivityTypeFilter.moneyOut => entry.entryKind == TxnEntryKind.spend ||
        entry.entryKind == TxnEntryKind.investment,
    _ActivityTypeFilter.transfers => entry.entryKind == TxnEntryKind.transfer,
    _ActivityTypeFilter.investments => entry.entryKind == TxnEntryKind.investment,
  };
}

IconData _typeIcon(_ActivityTypeFilter type) => switch (type) {
  _ActivityTypeFilter.all => Icons.receipt_long_outlined,
  _ActivityTypeFilter.moneyIn => Icons.arrow_downward_rounded,
  _ActivityTypeFilter.moneyOut => Icons.arrow_upward_rounded,
  _ActivityTypeFilter.transfers => Icons.swap_horiz_rounded,
  _ActivityTypeFilter.investments => Icons.trending_up_rounded,
};

/// D1's search box. Debounced, because every keystroke would otherwise be
/// a round trip — and the ILIKE behind it scans, so a burst of them on a
/// long history is exactly the query you don't want to fire six times.
class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      final trimmed = value.trim();
      ref
          .read(_activityFilterProvider.notifier)
          .update(
            (f) => f.copyWith(query: () => trimmed.isEmpty ? null : trimmed),
          );
    });
    // Rebuild for the clear button's visibility, which shouldn't wait on
    // the debounce.
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    ref
        .read(_activityFilterProvider.notifier)
        .update((f) => f.copyWith(query: () => null));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: _onChanged,
      textInputAction: TextInputAction.search,
      style: BambooFonts.ui(14.5, color: BambooInk.ink900),
      decoration: InputDecoration(
        hintText: 'Search merchant or note',
        prefixIcon: const Icon(
          Icons.search_rounded,
          size: 20,
          color: BambooInk.ink500,
        ),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: BambooInk.ink500,
                ),
                onPressed: _clear,
              ),
        isDense: true,
      ),
    );
  }
}

class _FilterRow extends ConsumerWidget {
  final ActivityFilter filter;
  const _FilterRow({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    final topLevelCategories = categories.where((c) => !c.isSubcategory).toList();
    final subcategories = categories.where((c) => c.isSubcategory).toList();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _FilterChipButton(
            label: filter.type.label,
            active: filter.hasTypeFilter,
            onTap: () async {
              final picked = await showModalBottomSheet<_ActivityTypeFilter>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: [
                    for (final type in _ActivityTypeFilter.values)
                      ListTile(
                        leading: Icon(_typeIcon(type)),
                        title: Text(type.label),
                        selected: type == filter.type,
                        onTap: () => Navigator.of(context).pop(type),
                      ),
                  ],
                ),
              );
              if (picked != null) {
                ref.read(_activityFilterProvider.notifier).state = filter
                    .copyWith(type: picked);
              }
            },
          ),
          const SizedBox(width: AppSpace.xs),
          _FilterChipButton(
            label: filter.cardId == null
                ? 'Card'
                : (cards
                          .where((c) => c.id == filter.cardId)
                          .firstOrNull
                          ?.nickname ??
                      'Card'),
            active: filter.cardId != null,
            onTap: () async {
              final picked = await showModalBottomSheet<String?>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('All cards')),
                    for (final c in cards)
                      ListTile(
                        title: Text(
                          c.nickname?.isNotEmpty == true
                              ? c.nickname!
                              : c.cardName,
                        ),
                        onTap: () => Navigator.of(context).pop(c.id),
                      ),
                  ],
                ),
              );
              ref.read(_activityFilterProvider.notifier).state = filter
                  .copyWith(cardId: () => picked);
            },
          ),
          const SizedBox(width: AppSpace.xs),
          _FilterChipButton(
            label: filter.categoryId == null
                ? 'Category'
                : (categories
                          .where((c) => c.id == filter.categoryId)
                          .firstOrNull
                          ?.name ??
                      'Category'),
            active: filter.categoryId != null,
            onTap: () async {
              final picked = await showModalBottomSheet<String?>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('All categories')),
                    for (final c in topLevelCategories)
                      ListTile(
                        title: Text(c.name),
                        onTap: () => Navigator.of(context).pop(c.id),
                      ),
                  ],
                ),
              );
              ref.read(_activityFilterProvider.notifier).state = filter
                  .copyWith(categoryId: () => picked);
            },
          ),
          const SizedBox(width: AppSpace.xs),
          _FilterChipButton(
            label: filter.subcategoryId == null
                ? 'Subcategory'
                : (subcategories
                          .where((c) => c.id == filter.subcategoryId)
                          .firstOrNull
                          ?.name ??
                      'Subcategory'),
            active: filter.subcategoryId != null,
            onTap: () async {
              final picked = await showModalBottomSheet<String?>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('All subcategories')),
                    for (final c in subcategories)
                      ListTile(
                        title: Text(c.name),
                        onTap: () => Navigator.of(context).pop(c.id),
                      ),
                  ],
                ),
              );
              ref.read(_activityFilterProvider.notifier).state = filter
                  .copyWith(subcategoryId: () => picked);
            },
          ),
          const SizedBox(width: AppSpace.xs),
          _FilterChipButton(
            label: filter.from == null && filter.to == null
                ? 'Date range'
                : '${filter.from?.toString().split(' ').first ?? '…'} – ${filter.to?.toString().split(' ').first ?? '…'}',
            active: filter.from != null || filter.to != null,
            onTap: () async {
              final range = await showDateRangePicker(
                context: context,
                firstDate: DateTime.now().subtract(
                  const Duration(days: 365 * 3),
                ),
                lastDate: DateTime.now(),
                initialDateRange: filter.from != null && filter.to != null
                    ? DateTimeRange(start: filter.from!, end: filter.to!)
                    : null,
              );
              if (range != null) {
                ref.read(_activityFilterProvider.notifier).state = filter
                    .copyWith(from: () => range.start, to: () => range.end);
              }
            },
          ),
          if (filter.isActive) ...[
            const SizedBox(width: AppSpace.xs),
            _FilterChipButton(
              label: 'Clear',
              active: false,
              onTap: () => ref.read(_activityFilterProvider.notifier).state =
                  const ActivityFilter(),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _FilterChipButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 0),
      child: ActionChip(
        label: Text(label, overflow: TextOverflow.ellipsis),
        backgroundColor: active ? BambooInk.slate : BambooInk.paperMuted,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: BambooFonts.ui(
          13,
          weight: FontWeight.w600,
          color: active ? BambooInk.onSlate : BambooInk.ink900,
        ),
        onPressed: onTap,
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Money totalIncoming;
  final Money totalOutgoing;
  final int count;
  const _SummaryCard({
    required this.totalIncoming,
    required this.totalOutgoing,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'All activity',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Expanded(
                child: _SummaryMetric(
                  label: 'Money in',
                  amount: totalIncoming,
                  prefix: '+',
                  color: BambooInk.jade,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _SummaryMetric(
                  label: 'Money out',
                  amount: totalOutgoing,
                  prefix: '−',
                  color: BambooInk.clay,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text(
                count == 0
                    ? 'No activity'
                    : '$count transaction${count == 1 ? '' : 's'}',
                style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
              ),
              if (totalOutgoing.paise == 0) ...[
                const SizedBox(width: AppSpace.sm),
                Text(
                  'No spending',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  final String label;
  final Money amount;
  final String prefix;
  final Color color;

  const _SummaryMetric({
    required this.label,
    required this.amount,
    required this.prefix,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: BambooFonts.ui(12, color: BambooInk.onSlateMuted)),
        const SizedBox(height: 2),
        MoneyText(
          amount,
          prefix: prefix,
          confidence: Confidence.estimated,
          style: BambooFonts.money(21, color: color),
          showConfidenceIcon: false,
          hidePaise: true,
        ),
      ],
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final TransactionEntry entry;
  final VoidCallback onTap;
  const _TransactionTile(this.entry, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isIncome = entry.entryKind == TxnEntryKind.income;
    final entryLabel = entry.entryKind.label;
    final isMoneyOut = entry.entryKind == TxnEntryKind.spend ||
        entry.entryKind == TxnEntryKind.investment;
    final amountPrefix = isIncome ? '+' : isMoneyOut ? '−' : null;
    final directionColor = isIncome
        ? BambooInk.jade
        : isMoneyOut
            ? BambooInk.clay
            : BambooInk.ink900;
    final subtitleParts = <String>[
      if (entry.entryKind != TxnEntryKind.spend) entryLabel,
      if (entry.cardDisplayName != null) entry.cardDisplayName!,
      if (entry.cardDisplayName == null &&
          entry.instrument == TxnInstrument.creditCard)
        entry.cardLast4 == null
            ? 'Credit card · unmatched'
            : 'Credit card ending ${entry.cardLast4}',
      if (entry.cardDisplayName == null &&
          entry.instrument == TxnInstrument.upiBank)
        entry.accountLast4 == null
            ? 'Bank account · unmatched'
            : 'Bank account ending ${entry.accountLast4}',
      if (entry.status == 'active' &&
          entry.rewardState == 'estimated' &&
          (entry.source == 'sms' || entry.source == 'sms_bulk'))
        'Pending confirmation',
      if (entry.categoryName != null) entry.categoryLabel,
    ];
    // See account_screen.dart's _AccountTile for why Pressable, not InkWell.
    return Pressable(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: directionColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isIncome
                    ? Icons.arrow_downward_rounded
                    : isMoneyOut
                        ? Icons.arrow_upward_rounded
                        : entry.entryKind == TxnEntryKind.transfer
                            ? Icons.swap_horiz_rounded
                            : Icons.trending_up_rounded,
                size: 18,
                color: directionColor,
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.merchantName ?? entryLabel,
                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join(' · '),
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            MoneyText(
              entry.amount,
              prefix: amountPrefix,
              confidence: Confidence.estimated,
              style: BambooFonts.money(15, color: directionColor),
            ),
          ],
        ),
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
