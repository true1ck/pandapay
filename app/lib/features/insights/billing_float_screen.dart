import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';

/// The grace period between a statement date and its due date is set by the
/// issuer per-product and isn't modeled anywhere in this schema (no bank
/// scrape or admin entry captures it yet). 20 days is the common minimum
/// across Indian issuers per RBI's fair-practices guidance — used as an
/// explicit, documented floor rather than a fabricated precise value. Every
/// place this number reaches the UI says "up to" for exactly this reason.
const _assumedGracePeriodDays = 20;

/// ui-spec.md E7 Billing Cycle / Float. `billingCycleFloat()` was fully
/// built and tested in the engine with zero callers. Needs
/// `UserCard.statementDay` (Task 11 — GET /user-cards didn't expose it
/// until now); a card with no statement day set yet degrades to a prompt
/// rather than fabricating one.
class BillingFloatScreen extends ConsumerWidget {
  const BillingFloatScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider);
    final clock = ref.watch(clockProvider);
    return pairs.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) {
        if (owned.isEmpty) {
          return const EmptyState(
            icon: Icons.event_available_outlined,
            title: 'No cards yet',
            message: 'Add a card to see how many interest-free days you have left.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(AppSpace.lg),
          itemCount: owned.length,
          itemBuilder: (context, index) {
            final (userCard, product) = owned[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _BillingFloatTile(userCard: userCard, product: product, clock: clock),
            );
          },
        );
      },
    );
  }
}

class _BillingFloatTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final Clock clock;
  const _BillingFloatTile({required this.userCard, required this.product, required this.clock});

  @override
  Widget build(BuildContext context) {
    final displayName = userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name;

    if (userCard.statementDay == null) {
      return Container(
        decoration: BoxDecoration(
          color: BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Row(
          children: [
            const Icon(Icons.event_busy_rounded, size: 20, color: BambooInk.ink500),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(displayName, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                  const SizedBox(height: 2),
                  Text('Set a statement day to see this card\'s float.', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final result = billingCycleFloat(
      statementDay: userCard.statementDay!,
      gracePeriodDays: _assumedGracePeriodDays,
      clock: clock,
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
          Text(displayName, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Use $displayName today → up to ${result.totalInterestFreeDays} interest-free days.',
            style: BambooFonts.heading(20, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Statement cuts in ${result.daysUntilStatement} day${result.daysUntilStatement == 1 ? '' : 's'} '
            '(assumes a $_assumedGracePeriodDays-day grace period to the due date).',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}
