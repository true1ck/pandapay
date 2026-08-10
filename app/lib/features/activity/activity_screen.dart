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
/// card/category filters, a spend summary for whatever's currently
/// filtered in, and tap-through to D2 Transaction Detail. "Search" and the
/// "needs-review" filter aren't built here — search has no server-side
/// text-match route yet, and needs-review isn't a transactions-table
/// concept (D4's parser_failures queue is a separate surface) — both
/// flagged as real gaps, not silently faked. The optimality indicator (✓
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
    final transactions = ref.watch(_filteredTransactionsProvider);

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.9, -0.7),
          radius: 1.3,
          colors: [BambooInk.wash, BambooInk.paper],
          stops: [0.0, 0.6],
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
            child: _FilterRow(filter: filter),
          ),
          Expanded(
            child: transactions.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => ErrorState(
                message: userFacingErrorMessage(err),
                onRetry: () => ref.invalidate(_filteredTransactionsProvider),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: filter.isActive ? 'No activity matches these filters' : 'No activity yet',
                    message: filter.isActive ? null : 'Spend you log from the Cards tab shows up here.',
                  );
                }
                final grouped = _groupByDay(entries);
                final totalSpend = entries.fold<Money>(const Money.zero(), (a, e) => a + e.amount);

                return ListView(
                  padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
                  children: [
                    _SummaryCard(totalSpend: totalSpend, count: entries.length),
                    const SizedBox(height: AppSpace.lg),
                    for (final group in grouped) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: Text(_dayLabel(group.day), style: BambooFonts.heading(13, color: BambooInk.ink500)),
                      ),
                      for (final entry in group.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpace.sm),
                          child: _TransactionTile(
                            entry,
                            onTap: () => context.push('/activity/${entry.id}'),
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
      final day = DateTime(e.occurredAt.year, e.occurredAt.month, e.occurredAt.day);
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
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }
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
  final DateTime? from;
  final DateTime? to;

  const ActivityFilter({this.cardId, this.categoryId, this.from, this.to});

  bool get isActive => cardId != null || categoryId != null || from != null || to != null;

  ActivityFilter copyWith({
    String? Function()? cardId,
    String? Function()? categoryId,
    DateTime? Function()? from,
    DateTime? Function()? to,
  }) {
    return ActivityFilter(
      cardId: cardId != null ? cardId() : this.cardId,
      categoryId: categoryId != null ? categoryId() : this.categoryId,
      from: from != null ? from() : this.from,
      to: to != null ? to() : this.to,
    );
  }
}

final _activityFilterProvider = StateProvider<ActivityFilter>((ref) => const ActivityFilter());

final _filteredTransactionsProvider = FutureProvider<List<TransactionEntry>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final filter = ref.watch(_activityFilterProvider);
  return repo.fetchTransactions(
    from: filter.from,
    to: filter.to,
    cardId: filter.cardId,
    categoryId: filter.categoryId,
  );
});

class _FilterRow extends ConsumerWidget {
  final ActivityFilter filter;
  const _FilterRow({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(userCardsProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _FilterChipButton(
            label: filter.cardId == null
                ? 'Card'
                : (cards.where((c) => c.id == filter.cardId).firstOrNull?.nickname ?? 'Card'),
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
                        title: Text(c.nickname?.isNotEmpty == true ? c.nickname! : c.cardName),
                        onTap: () => Navigator.of(context).pop(c.id),
                      ),
                  ],
                ),
              );
              ref.read(_activityFilterProvider.notifier).state = filter.copyWith(cardId: () => picked);
            },
          ),
          const SizedBox(width: AppSpace.xs),
          _FilterChipButton(
            label: filter.categoryId == null
                ? 'Category'
                : (categories.where((c) => c.id == filter.categoryId).firstOrNull?.name ?? 'Category'),
            active: filter.categoryId != null,
            onTap: () async {
              final picked = await showModalBottomSheet<String?>(
                context: context,
                builder: (context) => ListView(
                  shrinkWrap: true,
                  children: [
                    const ListTile(title: Text('All categories')),
                    for (final c in categories)
                      ListTile(title: Text(c.name), onTap: () => Navigator.of(context).pop(c.id)),
                  ],
                ),
              );
              ref.read(_activityFilterProvider.notifier).state = filter.copyWith(categoryId: () => picked);
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
                firstDate: DateTime.now().subtract(const Duration(days: 365 * 3)),
                lastDate: DateTime.now(),
                initialDateRange: filter.from != null && filter.to != null
                    ? DateTimeRange(start: filter.from!, end: filter.to!)
                    : null,
              );
              if (range != null) {
                ref.read(_activityFilterProvider.notifier).state =
                    filter.copyWith(from: () => range.start, to: () => range.end);
              }
            },
          ),
          if (filter.isActive) ...[
            const SizedBox(width: AppSpace.xs),
            _FilterChipButton(
              label: 'Clear',
              active: false,
              onTap: () => ref.read(_activityFilterProvider.notifier).state = const ActivityFilter(),
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
  const _FilterChipButton({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 0),
      child: ActionChip(
        label: Text(label, overflow: TextOverflow.ellipsis),
        backgroundColor: active ? BambooInk.slate : BambooInk.paperMuted,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: BambooFonts.ui(13, weight: FontWeight.w600, color: active ? BambooInk.onSlate : BambooInk.ink900),
        onPressed: onTap,
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final Money totalSpend;
  final int count;
  const _SummaryCard({required this.totalSpend, required this.count});

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
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Spend', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
              const SizedBox(height: 2),
              MoneyText(totalSpend, confidence: Confidence.estimated, style: BambooFonts.money(26, color: BambooInk.lime)),
            ],
          ),
          Text(
            '$count transaction${count == 1 ? '' : 's'}',
            style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
          ),
        ],
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final TransactionEntry entry;
  final VoidCallback onTap;
  const _TransactionTile(this.entry, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final subtitleParts = <String>[
      if (entry.cardDisplayName != null) entry.cardDisplayName!,
      if (entry.categoryName != null) entry.categoryName!,
    ];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
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
              decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.shopping_bag_outlined, size: 18, color: BambooInk.ink900),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.merchantName ?? 'Spend',
                    style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitleParts.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(subtitleParts.join(' · '), style: BambooFonts.ui(12, color: BambooInk.ink500)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            MoneyText(entry.amount, confidence: Confidence.estimated, style: BambooFonts.money(15, color: BambooInk.ink900)),
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
