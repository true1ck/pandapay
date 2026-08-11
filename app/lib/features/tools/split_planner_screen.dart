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

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Multi-Card Split Planner', style: BambooFonts.heading(16.5, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: owned.when(
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
                Text('Total amount to spend', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: InputDecoration(
                    prefixText: '₹ ',
                    hintText: 'e.g. 50000',
                    hintStyle: BambooFonts.ui(14, color: BambooInk.ink500),
                    filled: true,
                    fillColor: BambooInk.glassFillOnPaper,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                    ),
                  ),
                  onChanged: (value) {
                    final parsed = double.tryParse(value);
                    ref.read(splitPlannerAmountProvider.notifier).state = parsed == null
                        ? const Money.zero()
                        : Money.fromRupees(parsed);
                  },
                ),
                const SizedBox(height: AppSpace.xxl),
                if (amount.isZero)
                  const EmptyState(
                    icon: Icons.request_quote_outlined,
                    title: 'Enter an amount to see a split',
                    message:
                        'PandaPay will divide it across your cards to maximize rewards, respecting '
                        'each card\'s caps and (where you\'ve entered a credit limit) staying under 30% '
                        'utilization.',
                  )
                else if (plan.isEmpty)
                  const EmptyState(
                    icon: Icons.block_rounded,
                    title: 'No eligible allocation',
                    message:
                        'Every owned card is either excluded for this amount or already at its cap/'
                        'utilization ceiling — try a smaller amount.',
                  )
                else
                  _SplitResult(
                    plan: plan,
                    total: amount,
                    ownedProducts: [for (final (_, product) in pairs) product],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SplitResult extends StatelessWidget {
  final List<SplitAllocation> plan;
  final Money total;
  final List<CardProduct> ownedProducts;
  const _SplitResult({required this.plan, required this.total, required this.ownedProducts});

  /// Design 11's counterfactual: what the best SINGLE card would have paid
  /// on the whole purchase.
  ///
  /// Base rate only, via the shared [baseRateValueFor] — the same
  /// deliberately-scoped calculator D6 and design 04 use, so this can't
  /// disagree with them. That makes it a conservative comparison: it
  /// ignores the caps that are usually the reason splitting wins at all,
  /// so the real gap is typically wider than shown, never narrower.
  Money get _singleBestCardValue {
    var best = const Money.zero();
    for (final product in ownedProducts) {
      final value = baseRateValueFor(product: product, amount: total);
      if (value > best) best = value;
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final totalExpectedValue = plan.fold<Money>(const Money.zero(), (a, b) => a + b.expectedValue);
    final placed = plan.fold<Money>(const Money.zero(), (a, b) => a + b.amount);
    final singleCard = _singleBestCardValue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [BambooInk.slateRaised, BambooInk.slate],
            ),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Total expected reward value',
                      style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                    ),
                    const SizedBox(height: 4),
                    MoneyText(
                      totalExpectedValue,
                      confidence: Confidence.estimated,
                      style: BambooFonts.money(24, color: BambooInk.lime),
                    ),
                  ],
                ),
              ),
              // Design 11's whole argument: the split total means nothing
              // without what one card alone would have paid. Hidden when
              // there's no counterfactual (a single owned card) or when
              // splitting didn't actually win — claiming a gain of zero
              // would be worse than saying nothing.
              if (ownedProducts.length > 1 && totalExpectedValue > singleCard) ...[
                const SizedBox(width: AppSpace.md),
                Container(width: 1, height: 46, color: BambooInk.slateHairline),
                const SizedBox(width: AppSpace.md),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('One card only', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
                    const SizedBox(height: 4),
                    MoneyText(
                      singleCard,
                      confidence: Confidence.estimated,
                      style: BambooFonts.money(20, color: BambooInk.onSlateSubtle),
                      showConfidenceIcon: false,
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (placed < total) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            '${(total - placed).format()} of this amount has no eligible card left to place — shown '
            'as unallocated below, not silently dropped.',
            style: BambooFonts.ui(12.5, color: BambooInk.clay),
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
    // num.clamp() returns num, not double — LinearProgressIndicator.value
    // is double?, so this needs an explicit .toDouble() rather than
    // relying on the clamp() result being assignable directly (it isn't,
    // under sound null safety).
    final rawFraction = total.isZero ? 0.0 : allocation.amount.paise / total.paise;
    final fraction = rawFraction.clamp(0.0, 1.0).toDouble();
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(allocation.card.name, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
              ),
              MoneyText(
                allocation.amount,
                confidence: Confidence.estimated,
                style: BambooFonts.money(14, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              backgroundColor: BambooInk.paperMuted,
              color: BambooInk.jade,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text(
                '${(fraction * 100).toStringAsFixed(0)}% of total · expected reward ',
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
              MoneyText(
                allocation.expectedValue,
                confidence: Confidence.estimated,
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
