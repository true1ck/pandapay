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
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('EMI Advisor', style: BambooFonts.heading(18, color: BambooInk.ink900)),
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
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
                const SizedBox(height: AppSpace.sm),
                DropdownButtonFormField<String>(
                  initialValue: _selectedCardProductId,
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: InputDecoration(
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
                  items: [
                    for (final (userCard, product) in pairs)
                      DropdownMenuItem(
                        value: product.id,
                        child: Text(
                          userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedCardProductId = v),
                ),
                const SizedBox(height: AppSpace.lg),
                Text('Purchase amount', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: InputDecoration(
                    prefixText: '₹ ',
                    hintText: 'e.g. 60000',
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
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpace.lg),
                Text('Tenure', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.sm,
                  children: [
                    for (final months in const [3, 6, 9, 12, 18, 24])
                      ChoiceChip(
                        label: Text('$months mo'),
                        labelStyle: BambooFonts.ui(
                          13,
                          weight: FontWeight.w600,
                          color: _tenureMonths == months ? BambooInk.onSlate : BambooInk.ink900,
                        ),
                        selected: _tenureMonths == months,
                        selectedColor: BambooInk.slate,
                        backgroundColor: BambooInk.paperMuted,
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        onSelected: (_) => setState(() => _tenureMonths = months),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.lg),
                Text('Annual interest rate (%)', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: AppSpace.sm),
                TextField(
                  controller: _rateController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                  style: BambooFonts.ui(14.5, color: BambooInk.ink900),
                  decoration: InputDecoration(
                    suffixText: '% per year',
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
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppSpace.xxl),
                if (principal <= 0)
                  const EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Enter a purchase amount',
                    message: 'PandaPay will compare paying via EMI against paying in full on this card.',
                  )
                else if (advice == null)
                  const EmptyState(
                    icon: Icons.error_outline_rounded,
                    title: 'Can\'t compute this yet',
                    message: 'Check the amount and tenure are both greater than zero.',
                  )
                else
                  _AdviceResult(advice: advice),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AdviceResult extends StatelessWidget {
  final EmiAdvice advice;
  const _AdviceResult({required this.advice});

  @override
  Widget build(BuildContext context) {
    final costly = advice.effectiveCost.paise > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: costly ? BambooInk.clay.withValues(alpha: 0.12) : BambooInk.jade.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                costly ? Icons.trending_down_rounded : Icons.check_circle_outline_rounded,
                color: costly ? BambooInk.clay : BambooInk.jade,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  advice.verdictLine,
                  style: BambooFonts.heading(14.5, color: costly ? BambooInk.clay : BambooInk.jade),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        _AdviceRow(label: 'Total interest', amount: advice.totalInterest),
        _AdviceRow(label: 'Rewards you\'d forfeit by not paying in full', amount: advice.forfeitedRewards),
        _AdviceRow(label: 'Effective cost of choosing EMI', amount: advice.effectiveCost, emphasized: true),
      ],
    );
  }
}

class _AdviceRow extends StatelessWidget {
  final String label;
  final Money amount;
  final bool emphasized;
  const _AdviceRow({required this.label, required this.amount, this.emphasized = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: emphasized
                    ? BambooFonts.heading(14.5, color: BambooInk.ink900)
                    : BambooFonts.ui(13.5, color: BambooInk.ink900),
              ),
            ),
            MoneyText(
              amount,
              confidence: Confidence.estimated,
              style: emphasized
                  ? BambooFonts.money(17, color: BambooInk.ink900)
                  : BambooFonts.money(14, weight: FontWeight.w600, color: BambooInk.ink900),
            ),
          ],
        ),
      ),
    );
  }
}
