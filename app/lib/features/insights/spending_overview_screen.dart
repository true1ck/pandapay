import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E11 Spending Overview. Pure client-side aggregation over
/// GET /transactions?from=&to= (Task E-0's shared query-param work) for
/// the current calendar month — category and merchant breakdown.
/// "Context, not a budgeting tool": copy stays descriptive ("you spent
/// here"), deliberately no progress bars toward any spending "limit" —
/// this screen never asked the user to set one.
class SpendingOverviewScreen extends ConsumerWidget {
  const SpendingOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final monthEnd = DateTime(now.year, now.month + 1, 1);
    final txns = ref.watch(_monthTransactionsProvider((monthStart, monthEnd)));

    return txns.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(_monthTransactionsProvider((monthStart, monthEnd))),
      ),
      data: (list) {
        if (list.isEmpty) {
          return const EmptyState(
            icon: Icons.donut_small_outlined,
            title: 'No spend logged this month yet',
            message: 'Once you log a few transactions, a category and merchant breakdown shows up here — '
                'context on where money went, not a budget to hit.',
          );
        }

        final byCategory = <String, Money>{};
        final byMerchant = <String, Money>{};
        var total = const Money.zero();
        for (final t in list) {
          total += t.amount;
          final cat = t.categoryName ?? 'Uncategorized';
          byCategory[cat] = (byCategory[cat] ?? const Money.zero()) + t.amount;
          final merch = t.merchantName ?? 'Unknown merchant';
          byMerchant[merch] = (byMerchant[merch] ?? const Money.zero()) + t.amount;
        }
        final sortedCategories = byCategory.entries.toList()..sort((a, b) => b.value.paise.compareTo(a.value.paise));
        final sortedMerchants = byMerchant.entries.toList()..sort((a, b) => b.value.paise.compareTo(a.value.paise));

        final textTheme = Theme.of(context).textTheme;
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpace.lg),
              decoration: BoxDecoration(color: AppColors.surfaceMuted, borderRadius: BorderRadius.circular(AppRadius.lg)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('This month', style: textTheme.bodyMedium),
                  MoneyText(total, confidence: Confidence.estimated, style: textTheme.displaySmall),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            Text('By category', style: textTheme.labelLarge),
            const SizedBox(height: AppSpace.sm),
            for (final e in sortedCategories)
              _BreakdownRow(label: e.key, amount: e.value, total: total),
            const SizedBox(height: AppSpace.xl),
            Text('By merchant', style: textTheme.labelLarge),
            const SizedBox(height: AppSpace.sm),
            for (final e in sortedMerchants.take(10))
              _BreakdownRow(label: e.key, amount: e.value, total: total),
          ],
        );
      },
    );
  }
}

final _monthTransactionsProvider =
    FutureProvider.family<List<TransactionEntry>, (DateTime, DateTime)>((ref, range) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  // `to` is exclusive-by-a-day server-side convention (see GET /transactions'
  // doc-comment) — subtract a day so the range reads as "this month".
  return repo.fetchTransactions(from: range.$1, to: range.$2.subtract(const Duration(days: 1)));
});

class _BreakdownRow extends StatelessWidget {
  final String label;
  final Money amount;
  final Money total;
  const _BreakdownRow({required this.label, required this.amount, required this.total});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final ratio = total.isZero ? 0.0 : (amount.paise / total.paise).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(child: Text(label, style: textTheme.bodyMedium, overflow: TextOverflow.ellipsis)),
              MoneyText(amount, confidence: Confidence.estimated, style: textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 4,
              backgroundColor: AppColors.surfaceMuted,
              color: AppColors.teal500,
            ),
          ),
        ],
      ),
    );
  }
}
