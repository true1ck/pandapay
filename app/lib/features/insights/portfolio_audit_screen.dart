import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E10 Portfolio Audit. Live aggregation, no dedicated table:
/// annual fee from CardProduct.annualFeeInr (Task C-0), rewards from
/// UserCard.totalPointsEarned × CardProduct.pointValueInr, usage frequency
/// from GET /transactions?cardId= (Task E-0's shared query-param work).
/// Unused-benefit detection is intentionally narrow — see the per-card
/// widget's own comment for why most benefit kinds honestly can't be
/// marked "unused" without fabricating a signal the app doesn't have.
class PortfolioAuditScreen extends ConsumerWidget {
  const PortfolioAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        if (owned.isEmpty) {
          return const EmptyState(
            icon: Icons.fact_check_outlined,
            title: 'No cards to audit yet',
            message: 'Add a card to see its annual-fee break-even and usage here.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: owned.length,
          itemBuilder: (context, index) {
            final (userCard, product) = owned[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _AuditTile(userCard: userCard, product: product),
            );
          },
        );
      },
    );
  }
}

class _AuditTile extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  const _AuditTile({required this.userCard, required this.product});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annualFee = product.annualFeeInr;
    final rewardsEarnedInr = Money.fromRupees(userCard.totalPointsEarned * product.pointValueInr);
    final breakEven = annualFee == null ? null : rewardsEarnedInr.paise >= annualFee.paise;

    final repo = ref.watch(userCardsRepositoryProvider);
    final usageAsync = repo == null
        ? const AsyncValue<int>.data(0)
        : ref.watch(_cardTxnCountProvider(userCard.id));

    // Unused-benefit detection: only benefit kinds with a real consumption
    // signal (lounge, via lounge_usage) can honestly be marked "unused" —
    // everything else (insuranceTravel, concierge, extendedWarranty, ...)
    // has no tracked consumption anywhere in this schema, so it's labelled
    // "not tracked" rather than guessed at, per the cross-cutting "never
    // display a number the app can't justify" rule.
    final untrackedBenefits = product.benefits.where(
      (b) => b.kind != BenefitKind.loungeDomestic && b.kind != BenefitKind.loungeInternational,
    );

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
          Text(
            userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.md),
          if (annualFee == null)
            Text('Annual fee not listed for this card', style: BambooFonts.ui(12.5, color: BambooInk.ink500))
          else ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Annual fee', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                MoneyText(
                  annualFee,
                  confidence: Confidence.confirmed,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Rewards earned (lifetime)', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                MoneyText(
                  rewardsEarnedInr,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Icon(
                  breakEven! ? Icons.check_circle_outline_rounded : Icons.trending_down_rounded,
                  size: 16,
                  color: breakEven ? BambooInk.jade : BambooInk.amber,
                ),
                const SizedBox(width: 4),
                Text(
                  breakEven ? 'This card has paid for itself' : 'Hasn\'t earned back its fee yet',
                  style: BambooFonts.ui(12.5, color: breakEven ? BambooInk.jade : BambooInk.amber),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.md),
          usageAsync.when(
            loading: () =>
                const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            error: (_, __) =>
                Text('Usage frequency unavailable', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
            data: (count) => Text(
              '$count transactions logged on this card',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ),
          if (untrackedBenefits.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              '${untrackedBenefits.length} other benefit(s) on this card — usage not tracked, so "unused" can\'t be measured honestly.',
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
        ],
      ),
    );
  }
}

final _cardTxnCountProvider = FutureProvider.family<int, String>((ref, cardId) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return 0;
  final txns = await repo.fetchTransactions(cardId: cardId);
  return txns.length;
});
