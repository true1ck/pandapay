import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md G3 EMI Advisor. `adviseEmi()` (calculators.dart) already
/// returns exactly total interest / effective cost / forfeited rewards /
/// verdict line — per the plan's audit, this screen supplies inputs to an
/// already-correct calculator via `emiAdviceProvider` (app/providers.dart),
/// nothing here recomputes EMI math itself.
///
/// Offline behaviour: pure local computation off the already-fetched
/// wallet/catalogue — no network in the critical path, same as G2.
class EmiAdvisorScreen extends ConsumerStatefulWidget {
  const EmiAdvisorScreen({super.key});

  @override
  ConsumerState<EmiAdvisorScreen> createState() => _EmiAdvisorScreenState();
}

class _EmiAdvisorScreenState extends ConsumerState<EmiAdvisorScreen> {
  final _amountController = TextEditingController();
  final _rateController = TextEditingController(text: '15');
  int _tenureMonths = 6;
  String? _selectedCardProductId;

  @override
  void dispose() {
    _amountController.dispose();
    _rateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final owned = ref.watch(ownedCardsWithProductProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('EMI Advisor')),
      body: owned.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
        ),
        data: (pairs) {
          if (pairs.isEmpty) {
            return const EmptyState(
              icon: Icons.calculate_outlined,
              title: 'No cards yet',
              message: 'Add a card to get EMI advice for it.',
            );
          }
          _selectedCardProductId ??= pairs.first.$2.id;

          final principal = double.tryParse(_amountController.text) ?? 0;
          final rate = double.tryParse(_rateController.text) ?? 0;
          final params = (
            cardProductId: _selectedCardProductId!,
            principalRupees: principal,
            tenureMonths: _tenureMonths,
            annualInterestRatePercent: rate,
          );
          final advice = ref.watch(emiAdviceProvider(params));

          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(
                'Which card would you pay on?',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpace.sm),
              DropdownButtonFormField<String>(
                initialValue: _selectedCardProductId,
                items: [
                  for (final (userCard, product) in pairs)
                    DropdownMenuItem(
                      value: product.id,
                      child: Text(
                        userCard.nickname?.isNotEmpty == true
                            ? userCard.nickname!
                            : product.name,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _selectedCardProductId = v),
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'Purchase amount',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  prefixText: '₹ ',
                  hintText: 'e.g. 60000',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpace.lg),
              Text('Tenure', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpace.sm),
              Wrap(
                spacing: AppSpace.sm,
                children: [
                  for (final months in const [3, 6, 9, 12, 18, 24])
                    ChoiceChip(
                      label: Text('$months mo'),
                      selected: _tenureMonths == months,
                      onSelected: (_) => setState(() => _tenureMonths = months),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              Text(
                'Annual interest rate (%)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                controller: _rateController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(suffixText: '% per year'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpace.xxl),
              if (principal <= 0)
                const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'Enter a purchase amount',
                  message:
                      'PandaPay will compare paying via EMI against paying in full on this card.',
                )
              else if (advice == null)
                const EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Can\'t compute this yet',
                  message:
                      'Check the amount and tenure are both greater than zero.',
                )
              else
                _AdviceResult(advice: advice),
            ],
          );
        },
      ),
    );
  }
}

class _AdviceResult extends StatelessWidget {
  final EmiAdvice advice;
  const _AdviceResult({required this.advice});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final costly = advice.effectiveCost.paise > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: costly
                ? AppColors.errorBg
                : AppColors.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                costly
                    ? Icons.trending_down_rounded
                    : Icons.check_circle_outline_rounded,
                color: costly ? AppColors.error : AppColors.success,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  advice.verdictLine,
                  style: textTheme.titleSmall?.copyWith(
                    color: costly ? AppColors.error : AppColors.success,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        _AdviceRow(label: 'Total interest', amount: advice.totalInterest),
        _AdviceRow(
          label: 'Rewards you\'d forfeit by not paying in full',
          amount: advice.forfeitedRewards,
        ),
        _AdviceRow(
          label: 'Effective cost of choosing EMI',
          amount: advice.effectiveCost,
          emphasized: true,
        ),
      ],
    );
  }
}

class _AdviceRow extends StatelessWidget {
  final String label;
  final Money amount;
  final bool emphasized;
  const _AdviceRow({
    required this.label,
    required this.amount,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.ink100),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: emphasized ? textTheme.titleSmall : textTheme.bodyMedium,
              ),
            ),
            MoneyText(
              amount,
              confidence: Confidence.estimated,
              style: emphasized ? textTheme.titleMedium : textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
