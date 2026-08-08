import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E5 Annual Fee Waivers. Per the plan, mostly assembly:
/// UserCard.feeWaiverStates was already parsed and shown only as a Cards-tab
/// badge — this is its own screen over the same already-fetched data.
/// Days-to-anniversary uses UserCard.anniversaryOn (Task E-0).
class FeeWaiversScreen extends ConsumerWidget {
  const FeeWaiversScreen({super.key});

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
        final rows = <(UserCard, CardProduct, FeeWaiverProgress)>[
          for (final (userCard, product) in owned)
            for (final fw in userCard.feeWaiverStates) (userCard, product, fw),
        ];
        if (rows.isEmpty) {
          return const EmptyState(
            icon: Icons.card_giftcard_outlined,
            title: 'No fee waivers to track',
            message: 'None of your cards have an annual-fee waiver rule — or you haven\'t added a card yet.',
          );
        }
        // Task E-0c urgency sort: closer-to-threshold and closer-to-deadline
        // first, same shared scorer E1/E2 use.
        rows.sort((a, b) {
          final scoreA = UrgencyScore(
            ratioConsumed: capRatio(a.$3.qualifiedSpend, a.$3.thresholdSpend),
            daysRemaining: a.$3.periodEnd == null ? null : daysUntil(a.$3.periodEnd!, DateTime.now()),
          );
          final scoreB = UrgencyScore(
            ratioConsumed: capRatio(b.$3.qualifiedSpend, b.$3.thresholdSpend),
            daysRemaining: b.$3.periodEnd == null ? null : daysUntil(b.$3.periodEnd!, DateTime.now()),
          );
          return scoreA.compareTo(scoreB);
        });

        return ListView.builder(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final (userCard, product, fw) = rows[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _FeeWaiverTile(userCard: userCard, product: product, fw: fw),
            );
          },
        );
      },
    );
  }
}

class _FeeWaiverTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final FeeWaiverProgress fw;
  const _FeeWaiverTile({required this.userCard, required this.product, required this.fw});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final waived = fw.waivedAt != null;
    final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
    final anniversaryDays =
        userCard.anniversaryOn == null ? null : daysUntil(userCard.anniversaryOn!, DateTime.now());

    return Container(
      decoration: BoxDecoration(
        color: waived ? AppColors.successBg : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: waived ? AppColors.success : AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                      style: textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text('Fee waived at ', style: textTheme.bodySmall),
                        MoneyText(fw.waivesFee, confidence: Confidence.estimated, style: textTheme.bodySmall),
                      ],
                    ),
                  ],
                ),
              ),
              if (waived)
                const StatusPill(
                  label: 'WAIVED',
                  foreground: Colors.white,
                  background: AppColors.success,
                  icon: Icons.check_rounded,
                )
              else if (ratio >= 0.9)
                const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (!waived) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: AppColors.surfaceMuted,
                color: ratio >= 0.9 ? AppColors.warning : AppColors.teal600,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    MoneyText(fw.qualifiedSpend, confidence: Confidence.estimated, style: textTheme.bodySmall),
                    Text(' of ', style: textTheme.bodySmall),
                    MoneyText(fw.thresholdSpend, confidence: Confidence.estimated, style: textTheme.bodySmall),
                  ],
                ),
              ],
            ),
          ],
          if (anniversaryDays != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              anniversaryDays >= 0
                  ? 'Card anniversary in $anniversaryDays days'
                  : 'Card anniversary was ${-anniversaryDays} days ago',
              style: textTheme.bodySmall?.copyWith(color: AppColors.ink500),
            ),
          ],
        ],
      ),
    );
  }
}
