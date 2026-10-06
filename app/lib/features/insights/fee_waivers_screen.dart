import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import 'grouped_insight_screen.dart';

/// ui-spec.md E5 Annual Fee Waivers. Per the plan, mostly assembly:
/// UserCard.feeWaiverStates was already parsed and shown only as a Cards-tab
/// badge — this is its own screen over the same already-fetched data.
/// Days-to-anniversary uses UserCard.anniversaryOn (Task E-0).
class FeeWaiversScreen extends ConsumerWidget {
  final bool embedded;

  const FeeWaiversScreen({super.key, this.embedded = false});

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
            message:
                'None of your cards have an annual-fee waiver rule — or you haven\'t added a card yet.',
          );
        }
        // Task E-0c urgency sort: closer-to-threshold and closer-to-deadline
        // first, same shared scorer E1/E2 use.
        rows.sort((a, b) {
          final scoreA = UrgencyScore(
            ratioConsumed: capRatio(a.$3.qualifiedSpend, a.$3.thresholdSpend),
            daysRemaining: daysUntil(a.$3.periodEnd, DateTime.now()),
          );
          final scoreB = UrgencyScore(
            ratioConsumed: capRatio(b.$3.qualifiedSpend, b.$3.thresholdSpend),
            daysRemaining: daysUntil(b.$3.periodEnd, DateTime.now()),
          );
          return scoreA.compareTo(scoreB);
        });

        final groups =
            <
              String,
              ({
                UserCard userCard,
                CardProduct product,
                List<FeeWaiverProgress> waivers,
              })
            >{};
        for (final (userCard, product, fw) in rows) {
          final group = groups.putIfAbsent(
            userCard.id,
            () => (
              userCard: userCard,
              product: product,
              waivers: <FeeWaiverProgress>[],
            ),
          );
          group.waivers.add(fw);
        }

        return ListView(
          padding: embedded
              ? EdgeInsets.zero
              : const EdgeInsets.all(AppSpace.lg),
          shrinkWrap: embedded,
          physics: embedded ? const NeverScrollableScrollPhysics() : null,
          children: [
            for (final group in groups.values)
              CardCapabilitySection(
                cardName: group.userCard.nickname?.isNotEmpty == true
                    ? group.userCard.nickname!
                    : group.product.name,
                capabilityLabel:
                    'fee waiver${group.waivers.length == 1 ? '' : 's'}',
                capabilityCount: group.waivers.length,
                children: [
                  const CardCapabilitySubheading('Fee waivers'),
                  for (final fw in group.waivers)
                    _FeeWaiverTile(userCard: group.userCard, fw: fw),
                ],
              ),
          ],
        );
      },
    );
  }
}

class _FeeWaiverTile extends StatelessWidget {
  final UserCard userCard;
  final FeeWaiverProgress fw;
  const _FeeWaiverTile({required this.userCard, required this.fw});

  @override
  Widget build(BuildContext context) {
    final waived = fw.waivedAt != null;
    final ratio = capRatio(fw.qualifiedSpend, fw.thresholdSpend);
    final anniversaryDays = userCard.anniversaryOn == null
        ? null
        : daysUntil(userCard.anniversaryOn!, DateTime.now());

    return Container(
      decoration: BoxDecoration(
        color: waived
            ? BambooInk.jade.withValues(alpha: 0.10)
            : BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: waived ? BambooInk.jade : BambooInk.hairlineOnPaper,
        ),
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
                    Row(
                      children: [
                        Text(
                          'Fee waived at ',
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                        MoneyText(
                          fw.waivesFee,
                          confidence: Confidence.estimated,
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (waived)
                const StatusPill(
                  label: 'WAIVED',
                  foreground: BambooInk.onSlate,
                  background: BambooInk.jade,
                  icon: Icons.check_rounded,
                )
              else if (ratio >= 0.9)
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: BambooInk.amber,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          if (!waived) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 8,
                backgroundColor: BambooInk.paperMuted,
                color: ratio >= 0.9 ? BambooInk.amber : BambooInk.jade,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    MoneyText(
                      fw.qualifiedSpend,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    Text(
                      ' of ',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                    MoneyText(
                      fw.thresholdSpend,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
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
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
          ],
        ],
      ),
    );
  }
}
