import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../cards/card_summary.dart';
import 'billing_float_screen.dart';
import 'caps_screen.dart';
import 'credit_utilization_screen.dart';
import 'fee_waivers_screen.dart';
import 'grouped_insight_screen.dart';
import 'lounge_access_screen.dart';
import 'milestones_screen.dart';

bool _isLounge(CardBenefit b) =>
    b.kind == BenefitKind.loungeDomestic ||
    b.kind == BenefitKind.loungeInternational;

/// Limits & perks is a three-tab grouped insight: the card-by-card perks view
/// (lounge summary plus each card's caps, milestones, fee waivers and lounge
/// rows) alongside the two per-card views that answer the same question —
/// how much breathing room does this wallet give me, and for how long.
class LimitsAndPerksScreen extends StatelessWidget {
  const LimitsAndPerksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const GroupedInsightScreen(
      title: 'Limits & perks',
      tabs: [
        (label: 'Perks', body: _PerksTab()),
        (label: 'Interest-free days', body: BillingFloatScreen()),
        (label: 'Utilization', body: CreditUtilizationScreen()),
      ],
    );
  }
}

class _PerksTab extends ConsumerWidget {
  const _PerksTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cards = ref.watch(ownedCardsWithProductProvider);
    return cards.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorState(
        message: userFacingErrorMessage(error),
        onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
      ),
      data: (owned) => owned.isEmpty
          ? const EmptyState(
              icon: Icons.credit_card_rounded,
              title: 'Your card benefits, together',
              message: 'Add a card to track its limits and perks.',
            )
          : ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                if (owned.any((p) => p.$2.benefits.any(_isLounge))) ...[
                  _LoungeOverview(owned: owned),
                  const SizedBox(height: AppSpace.lg),
                ],
                const CardCapabilitySubheading('Your cards'),
                for (final (card, product) in owned)
                  _CardPerks(card: card, product: product),
              ],
            ),
    );
  }
}

class _CardPerks extends StatelessWidget {
  final UserCard card;
  final CardProduct product;
  const _CardPerks({required this.card, required this.product});

  @override
  Widget build(BuildContext context) {
    final hasCaps = product.capRules.isNotEmpty || product.fuelRule != null;
    final hasMilestones = product.milestoneRules.isNotEmpty;
    final hasWaivers = card.feeWaiverStates.isNotEmpty;
    final hasLounge = product.benefits.any(_isLounge);
    final labels = [
      if (hasCaps) 'Caps',
      if (hasMilestones) 'Milestones',
      if (hasWaivers) 'Fee waivers',
      if (hasLounge) 'Lounge',
    ];
    return CardSummaryPanel(
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('perks-${card.id}'),
            tilePadding: const EdgeInsets.all(AppSpace.md),
            childrenPadding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              0,
              AppSpace.md,
              AppSpace.md,
            ),
            title: CardSummaryHeader(
              product: product,
              title: card.nickname?.isNotEmpty == true
                  ? card.nickname!
                  : product.name,
              subtitle: labels.isEmpty
                  ? 'No tracked benefits'
                  : labels.join(' · '),
              visualWidth: 72,
            ),
            children: [
              if (hasCaps) CapsScreen(embedded: true, cardId: card.id),
              if (hasMilestones)
                MilestonesScreen(embedded: true, cardId: card.id),
              if (hasWaivers) FeeWaiversScreen(embedded: true, cardId: card.id),
              if (hasLounge)
                LoungeAccessScreen(embedded: true, cardId: card.id),
              if (labels.isEmpty)
                const Text(
                  'No limits or perks are available for this card yet.',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoungeOverview extends ConsumerWidget {
  final List<(UserCard, CardProduct)> owned;
  const _LoungeOverview({required this.owned});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(loungeUsageProvider);
    return CardSummaryPanel(
      elevated: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.airline_seat_flat_angled_rounded,
                color: BambooInk.jade,
              ),
              const SizedBox(width: AppSpace.sm),
              Text('Lounge access', style: BambooFonts.heading(17)),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Remaining visits by card. Expand a card for details and to log a visit.',
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          usage.when(
            loading: () => const LinearProgressIndicator(),
            error: (error, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(userFacingErrorMessage(error)),
                TextButton(
                  onPressed: () => ref.invalidate(loungeUsageProvider),
                  child: const Text('Retry lounge usage'),
                ),
              ],
            ),
            data: (visits) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (card, product) in owned)
                  for (final benefit in uniqueCardBenefits(
                    product.benefits,
                  ).where(_isLounge))
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.sm),
                      child: Text(
                        '${card.nickname?.isNotEmpty == true ? card.nickname! : product.name}\n'
                        '${benefit.kind == BenefitKind.loungeDomestic ? 'Domestic' : 'International'} · '
                        '${benefit.quotaCount == null ? 'Unlimited quota' : '${(benefit.quotaCount! - visits.where((v) => v.userCardId == card.id && v.benefitId == benefit.id && isInCurrentLoungeWindow(v.usedOn, benefit.quotaPeriod)).length).clamp(0, benefit.quotaCount!)} of ${benefit.quotaCount} left'}'
                        ' · ${_period(benefit.quotaPeriod)}',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink900),
                      ),
                    ),
                Text(
                  'Access remains subject to your card’s eligibility and spend conditions.',
                  style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _period(CapPeriod? period) => switch (period) {
    CapPeriod.calendarMonth || null => 'this month',
    CapPeriod.statementCycle => 'this month (cycle estimate)',
    CapPeriod.quarter => 'this quarter',
    CapPeriod.halfYear => 'this half-year',
    CapPeriod.annual => 'this year',
    CapPeriod.lifetime => 'lifetime',
  };
}
