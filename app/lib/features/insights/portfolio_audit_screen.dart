import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../cards/card_summary.dart';

/// ui-spec.md E10 Portfolio Audit. Live aggregation, no dedicated table:
/// annual fee from the user's override when present, otherwise
/// CardProduct.annualFeeInr (Task C-0), rewards from
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
            message:
                'Add a card to see its annual-fee break-even and usage here.',
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
    final annualFee = userCard.annualFeeOverride ?? product.annualFeeInr;
    final rewardsEarnedInr = Money.fromRupees(
      userCard.totalPointsEarned * product.pointValueInr,
    );
    final breakEven = annualFee == null
        ? null
        : rewardsEarnedInr.paise >= annualFee.paise;

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
    final untrackedBenefits = uniqueCardBenefits(product.benefits).where(
      (b) =>
          b.kind != BenefitKind.loungeDomestic &&
          b.kind != BenefitKind.loungeInternational,
    );

    final title = userCard.nickname?.isNotEmpty == true
        ? userCard.nickname!
        : product.name;
    final usageLabel = usageAsync.when(
      loading: () => 'Checking usage…',
      error: (_, _) => 'Usage unavailable',
      data: (count) => '$count transaction${count == 1 ? '' : 's'}',
    );
    final feeLabel = annualFee == null
        ? 'Fee not listed'
        : annualFee.isZero
        ? 'Lifetime free'
        : 'Fee ${annualFee.format(hidePaise: true)}';
    final paidForItself = breakEven == true;

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.sm,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            0,
            AppSpace.lg,
            AppSpace.md,
          ),
          title: CardSummaryHeader(
            product: product,
            title: title,
            subtitle: usageLabel,
            visualWidth: 84,
            badgeIcon: annualFee == null
                ? Icons.help_outline_rounded
                : paidForItself
                ? Icons.check_rounded
                : Icons.timelapse_rounded,
            footer: Wrap(
              spacing: AppSpace.xs,
              runSpacing: AppSpace.xs,
              children: [
                CardSummaryPill(label: feeLabel),
                if (untrackedBenefits.isNotEmpty)
                  CardSummaryPill(
                    label: '${untrackedBenefits.length} benefits',
                    foreground: BambooInk.ink500,
                  ),
              ],
            ),
          ),
          children: [
            if (annualFee == null)
              _AuditNotice(
                icon: Icons.help_outline_rounded,
                text:
                    'Add the annual fee in card settings to track break-even.',
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: _AuditMetric(
                      icon: Icons.receipt_long_rounded,
                      label: 'Annual fee',
                      value: annualFee.format(hidePaise: true),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: _AuditMetric(
                      icon: Icons.workspace_premium_rounded,
                      label: 'Rewards',
                      value: rewardsEarnedInr.format(hidePaise: true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.sm),
              _AuditNotice(
                icon: paidForItself
                    ? Icons.check_circle_outline_rounded
                    : Icons.trending_down_rounded,
                color: paidForItself ? BambooInk.jade : BambooInk.amber,
                text: paidForItself
                    ? 'Rewards have covered the annual fee.'
                    : 'Rewards have not covered the annual fee yet.',
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            _AuditNotice(
              icon: Icons.swap_horiz_rounded,
              text: usageAsync.when(
                loading: () => 'Checking transaction usage…',
                error: (_, _) => 'Transaction usage is unavailable.',
                data: (count) =>
                    '$count transaction${count == 1 ? '' : 's'} tracked on this card.',
              ),
            ),
            if (untrackedBenefits.isNotEmpty) ...[
              const SizedBox(height: AppSpace.xs),
              _AuditNotice(
                icon: Icons.visibility_off_outlined,
                text:
                    '${untrackedBenefits.length} benefit${untrackedBenefits.length == 1 ? '' : 's'} do not have usage tracking yet.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AuditMetric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _AuditMetric({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(AppSpace.sm),
    decoration: BoxDecoration(
      color: BambooInk.paperMuted,
      borderRadius: BorderRadius.circular(AppRadius.md),
    ),
    child: Row(
      children: [
        Icon(icon, size: 17, color: BambooInk.jade),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: BambooFonts.ui(10.5, color: BambooInk.ink500)),
              const SizedBox(height: 2),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: BambooFonts.ui(
                  12.5,
                  weight: FontWeight.w700,
                  color: BambooInk.ink900,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _AuditNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _AuditNotice({
    required this.icon,
    required this.text,
    this.color = BambooInk.ink500,
  });

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 16, color: color),
      const SizedBox(width: AppSpace.xs),
      Expanded(
        child: Text(text, style: BambooFonts.ui(11.5, color: color)),
      ),
    ],
  );
}

final _cardTxnCountProvider = FutureProvider.family<int, String>((
  ref,
  cardId,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return 0;
  final txns = await repo.fetchTransactions(cardId: cardId);
  return txns.length;
});
