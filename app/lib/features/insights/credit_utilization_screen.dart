import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E3 Credit Utilization (Task E-0/G-0 unblocked this — the
/// calculator (`creditUtilization()`) and its provider
/// (`creditUtilizationProvider`) both already existed with zero callers).
/// Offline behaviour: requires the same signed-in card/catalogue fetch as
/// every other Insights screen — no local cache, degrades to ErrorState
/// with retry when offline.
class CreditUtilizationScreen extends ConsumerWidget {
  const CreditUtilizationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    final utilization = ref.watch(creditUtilizationProvider);

    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        if (owned.isEmpty) {
          return const EmptyState(
            icon: Icons.pie_chart_outline_rounded,
            title: 'No cards yet',
            message: 'Add a card to track credit utilization.',
          );
        }
        final withLimit = owned.where((p) => utilization.containsKey(p.$1.id)).toList();
        final withoutLimit = owned.where((p) => !utilization.containsKey(p.$1.id)).toList();

        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            // Spec's "explicit, un-dismissable disclaimer" — a permanent
            // banner, never a toast, so it can't be missed-then-forgotten.
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.paperMuted,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: BambooInk.hairlineOnPaper),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: BambooInk.ink500),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      'This is informational only — PandaPay does not guarantee how any '
                      'credit bureau computes or reports your credit score.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            if (withLimit.isEmpty)
              const _NoLimitsYetNotice()
            else ...[
              for (final (userCard, product) in withLimit)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _UtilizationTile(
                    userCard: userCard,
                    product: product,
                    result: utilization[userCard.id]!,
                  ),
                ),
            ],
            if (withoutLimit.isNotEmpty) ...[
              const SizedBox(height: AppSpace.md),
              Text(
                'Add a credit limit to track these',
                style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              for (final (userCard, product) in withoutLimit)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.sm),
                  child: _AddLimitPrompt(userCard: userCard, product: product),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _NoLimitsYetNotice extends StatelessWidget {
  const _NoLimitsYetNotice();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.credit_score_outlined,
      title: 'Add a credit limit to see utilization',
      message:
          'None of your cards have a credit limit entered yet — utilization can\'t be '
          'calculated without one.',
    );
  }
}

class _AddLimitPrompt extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  const _AddLimitPrompt({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context) {
    return Container(
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
              userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
              style: BambooFonts.ui(13.5, color: BambooInk.ink900),
            ),
          ),
          // C4 Edit Card isn't confirmed built yet in this pass — a plain
          // disabled-looking hint rather than a broken navigation target,
          // per the plan's "acceptable stopgap" note on this exact gap.
          Text('Add credit limit in Cards → Edit', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
        ],
      ),
    );
  }
}

class _UtilizationTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final UtilizationResult result;
  const _UtilizationTile({required this.userCard, required this.product, required this.result});

  @override
  Widget build(BuildContext context) {
    final ratio = result.ratio.clamp(0.0, 1.0);
    final over = result.overThreshold;
    final color = over ? BambooInk.clay : BambooInk.jade;

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
                child: Text(
                  userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
              ),
              // Never colour-alone: icon + text alongside the colour.
              Icon(
                over ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                '${(ratio * 100).toStringAsFixed(0)}%',
                style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: color),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: BambooInk.paperMuted,
              color: color,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text('Limit ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              MoneyText(
                userCard.creditLimit!,
                confidence: Confidence.confirmed,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ],
          ),
          if (over) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              'Above the 30% guideline most bureaus use — consider moving spend to another card.',
              style: BambooFonts.ui(12.5, color: BambooInk.clay),
            ),
          ],
        ],
      ),
    );
  }
}
