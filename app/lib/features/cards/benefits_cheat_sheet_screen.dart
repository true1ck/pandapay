import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;

/// C5 Benefits Cheat Sheet (ui-spec Group C): "what am I actually paying
/// for?" — every benefit across every owned card, grouped by type. Purely
/// derived from [ownedCardsWithProductProvider] (already fetched by the
/// time a user reaches Cards) — no new network call in this screen's own
/// render path, which is what makes "renders with airplane mode on and no
/// session" (this screen's own DoD, ui-spec) true by construction rather
/// than by extra offline-handling code.
class BenefitsCheatSheetScreen extends ConsumerWidget {
  const BenefitsCheatSheetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedCardsWithProductProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Benefits cheat sheet', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: owned.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(userCardsProvider),
          ),
          data: (pairs) {
            // One (CardBenefit, ownerCardDisplayName) tuple per benefit,
            // across every owned card — a card with two benefits of the
            // same kind (e.g. domestic + international lounge) shows both,
            // not a collapsed one, since their quotas/programs may differ.
            final entries = <(CardBenefit, String)>[
              for (final (userCard, product) in pairs)
                for (final benefit in product.benefits)
                  (benefit, userCard.nickname?.isNotEmpty == true ? userCard.nickname! : userCard.cardName),
            ];

            if (entries.isEmpty) {
              return const EmptyState(
                icon: Icons.workspace_premium_outlined,
                title: 'No benefits to show yet',
                message: 'Add a card to see its lounge access, insurance, warranty, and other benefits here.',
              );
            }

            final grouped = <BenefitKind, List<(CardBenefit, String)>>{};
            for (final entry in entries) {
              grouped.putIfAbsent(entry.$1.kind, () => []).add(entry);
            }
            // Stable, meaningful order rather than enum declaration order —
            // the highest-value/most-asked-about benefit types first.
            const kindOrder = [
              BenefitKind.loungeDomestic,
              BenefitKind.loungeInternational,
              BenefitKind.golf,
              BenefitKind.insuranceTravel,
              BenefitKind.insurancePurchase,
              BenefitKind.extendedWarranty,
              BenefitKind.diningProgram,
              BenefitKind.movie,
              BenefitKind.fuelSurcharge,
              BenefitKind.roadsideAssistance,
              BenefitKind.concierge,
              BenefitKind.other,
            ];

            return ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                for (final kind in kindOrder)
                  if (grouped[kind] case final items? when items.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpace.lg, bottom: AppSpace.sm),
                      child: Text(_kindLabel(kind), style: BambooFonts.heading(16, color: BambooInk.ink900)),
                    ),
                    for (final (benefit, cardLabel) in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: _BenefitTile(benefit: benefit, cardLabel: cardLabel),
                      ),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }

  static String _kindLabel(BenefitKind kind) => switch (kind) {
    BenefitKind.loungeDomestic => 'Domestic lounge access',
    BenefitKind.loungeInternational => 'International lounge access',
    BenefitKind.golf => 'Golf',
    BenefitKind.concierge => 'Concierge',
    BenefitKind.insuranceTravel => 'Travel insurance',
    BenefitKind.insurancePurchase => 'Purchase protection insurance',
    BenefitKind.extendedWarranty => 'Extended warranty',
    BenefitKind.diningProgram => 'Dining',
    BenefitKind.movie => 'Movies',
    BenefitKind.fuelSurcharge => 'Fuel surcharge waiver',
    BenefitKind.roadsideAssistance => 'Roadside assistance',
    BenefitKind.other => 'Other benefits',
  };

  static IconData _kindIcon(BenefitKind kind) => switch (kind) {
    BenefitKind.loungeDomestic || BenefitKind.loungeInternational => Icons.airline_seat_flat_rounded,
    BenefitKind.golf => Icons.sports_golf_rounded,
    BenefitKind.concierge => Icons.support_agent_rounded,
    BenefitKind.insuranceTravel || BenefitKind.insurancePurchase => Icons.shield_outlined,
    BenefitKind.extendedWarranty => Icons.verified_outlined,
    BenefitKind.diningProgram => Icons.restaurant_outlined,
    BenefitKind.movie => Icons.movie_outlined,
    BenefitKind.fuelSurcharge => Icons.local_gas_station_outlined,
    BenefitKind.roadsideAssistance => Icons.car_repair_outlined,
    BenefitKind.other => Icons.card_giftcard_outlined,
  };
}

class _BenefitTile extends StatelessWidget {
  final CardBenefit benefit;
  final String cardLabel;
  const _BenefitTile({required this.benefit, required this.cardLabel});

  @override
  Widget build(BuildContext context) {
    final quotaParts = <String>[
      if (benefit.quotaCount != null) '${benefit.quotaCount} / ${_periodLabel(benefit.quotaPeriod)}',
      if (benefit.networkProgram != null) benefit.networkProgram!,
    ];

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: BambooInk.slate,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(BenefitsCheatSheetScreen._kindIcon(benefit.kind), color: BambooInk.lime, size: 20),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(benefit.label, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: 2),
                Text(cardLabel, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                if (benefit.description != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Text(benefit.description!, style: BambooFonts.ui(13.5, color: BambooInk.ink900)),
                ],
                if (quotaParts.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.xs),
                  Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    children: [
                      for (final part in quotaParts)
                        StatusPill(
                          label: part,
                          foreground: BambooInk.ink900,
                          background: BambooInk.paperMuted,
                        ),
                    ],
                  ),
                ],
                if (benefit.valueEstimate != null) ...[
                  const SizedBox(height: AppSpace.xs),
                  Row(
                    children: [
                      Text('Est. value: ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                      MoneyText(
                        benefit.valueEstimate!,
                        confidence: Confidence.estimated,
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _periodLabel(CapPeriod? period) => switch (period) {
    CapPeriod.statementCycle => 'cycle',
    CapPeriod.calendarMonth => 'month',
    CapPeriod.quarter => 'quarter',
    CapPeriod.halfYear => 'half-year',
    CapPeriod.annual => 'year',
    CapPeriod.lifetime => 'lifetime',
    null => 'period',
  };
}
