import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md G2 Multi-Card Split Planner. `SplitOptimizer.optimize()`
/// (packages/pandapay_domain/lib/src/engine/calculators.dart) was already
/// fully built with zero UI callers — per the plan's own audit, this screen
/// is "build the screen," not "build the algorithm." `splitPlanProvider`
/// (app/providers.dart) already wires caps + a 30%-utilization ceiling in.
///
/// Offline behaviour: ranks entirely off already-fetched wallet/catalogue
/// state (Cross-Cutting Requirements' performance rule — no network in the
/// critical path), same degrade-with-retry as every other Insights screen.
class SplitPlannerScreen extends ConsumerStatefulWidget {
  const SplitPlannerScreen({super.key});

  @override
  ConsumerState<SplitPlannerScreen> createState() => _SplitPlannerScreenState();
}

class _SplitPlannerScreenState extends ConsumerState<SplitPlannerScreen> {
  final _amountController = TextEditingController();

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owned = ref.watch(ownedCardsWithProductProvider);
    final plan = ref.watch(splitPlanProvider);
    final amount = ref.watch(splitPlannerAmountProvider);

    return owned.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (pairs) {
        if (pairs.isEmpty) {
          return const EmptyState(
            icon: Icons.call_split_rounded,
            title: 'No cards yet',
            message: 'Add at least one card to plan a split.',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'Total amount to spend',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: AppSpace.sm),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
              decoration: const InputDecoration(prefixText: '₹ ', hintText: 'e.g. 50000'),
              onChanged: (value) {
                final parsed = double.tryParse(value);
                ref.read(splitPlannerAmountProvider.notifier).state =
                    parsed == null ? const Money.zero() : Money.fromRupees(parsed);
              },
            ),
            const SizedBox(height: AppSpace.xxl),
            if (amount.isZero)
              const EmptyState(
                icon: Icons.request_quote_outlined,
                title: 'Enter an amount to see a split',
                message: 'PandaPay will divide it across your cards to maximize rewards, respecting '
                    'each card\'s caps and (where you\'ve entered a credit limit) staying under 30% '
                    'utilization.',
              )
            else if (plan.isEmpty)
              const EmptyState(
                icon: Icons.block_rounded,
                title: 'No eligible allocation',
                message: 'Every owned card is either excluded for this amount or already at its cap/'
                    'utilization ceiling — try a smaller amount.',
              )
            else
              _SplitResult(plan: plan, total: amount),
          ],
        );
      },
    );
  }
}

class _SplitResult extends StatelessWidget {
  final List<SplitAllocation> plan;
  final Money total;
  const _SplitResult({required this.plan, required this.total});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final totalExpectedValue = plan.fold<Money>(const Money.zero(), (a, b) => a + b.expectedValue);
    final placed = plan.fold<Money>(const Money.zero(), (a, b) => a + b.amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: AppColors.navy900,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Total expected reward value',
                        style: textTheme.bodySmall?.copyWith(color: Colors.white70)),
                    const SizedBox(height: 4),
                    MoneyText(totalExpectedValue, confidence: Confidence.estimated,
                        style: textTheme.headlineSmall?.copyWith(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (placed < total) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            '${(total - placed).format()} of this amount has no eligible card left to place — shown '
            'as unallocated below, not silently dropped.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.error),
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        for (final alloc in plan)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: _AllocationBar(allocation: alloc, total: total),
          ),
      ],
    );
  }
}

class _AllocationBar extends StatelessWidget {
  final SplitAllocation allocation;
  final Money total;
  const _AllocationBar({required this.allocation, required this.total});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    // num.clamp() returns num, not double — LinearProgressIndicator.value
    // is double?, so this needs an explicit .toDouble() rather than
    // relying on the clamp() result being assignable directly (it isn't,
    // under sound null safety).
    final rawFraction = total.isZero ? 0.0 : allocation.amount.paise / total.paise;
    final fraction = rawFraction.clamp(0.0, 1.0).toDouble();
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(allocation.card.name, style: textTheme.titleSmall)),
              MoneyText(allocation.amount, confidence: Confidence.estimated, style: textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              backgroundColor: AppColors.surfaceMuted,
              color: AppColors.teal600,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text('${(fraction * 100).toStringAsFixed(0)}% of total · expected reward ',
                  style: textTheme.bodySmall),
              MoneyText(allocation.expectedValue, confidence: Confidence.estimated, style: textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }
}
