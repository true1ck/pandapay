import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show LoungeVisit, UserCard;
import '../insights/lounge_access_screen.dart' show isInCurrentLoungeWindow;
import 'benefit_detail_screen.dart';
import 'card_summary.dart';

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
        title: Text(
          'Benefits cheat sheet',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: owned.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(userCardsProvider),
          ),
          data: (pairs) {
            // One (UserCard, CardProduct, CardBenefit) tuple per benefit,
            // across every owned card — a card with two benefits of the
            // same kind (e.g. domestic + international lounge) shows both,
            // not a collapsed one, since their quotas/programs may differ.
            final entries = <(UserCard, CardProduct, CardBenefit)>[
              for (final (userCard, product) in pairs) ...[
                for (final benefit in uniqueCardBenefits(product.benefits))
                  (userCard, product, benefit),
                if (product.fuelRule != null &&
                    !uniqueCardBenefits(product.benefits).any(
                      (b) => b.kind == BenefitKind.fuelSurcharge,
                    ))
                  (
                    userCard,
                    product,
                    CardBenefit(
                      id: 'fuel-${product.id}',
                      kind: BenefitKind.fuelSurcharge,
                      label:
                          '${product.fuelRule!.waiverPercent == product.fuelRule!.waiverPercent.roundToDouble() ? product.fuelRule!.waiverPercent.toStringAsFixed(0) : product.fuelRule!.waiverPercent.toStringAsFixed(2)}% fuel surcharge waiver',
                      description:
                          'Fuel surcharge waived'
                          '${product.fuelRule!.minTxn != null ? " on transactions above ${product.fuelRule!.minTxn!.format()}" : ""}'
                          '${product.fuelRule!.maxTxn != null ? " up to ${product.fuelRule!.maxTxn!.format()}" : ""}.',
                    ),
                  ),
              ],
            ];

            if (entries.isEmpty) {
              return const EmptyState(
                icon: Icons.workspace_premium_outlined,
                title: 'No benefits to show yet',
                message:
                    'Add a card to see its lounge access, insurance, warranty, and other benefits here.',
              );
            }

            final grouped =
                <BenefitKind, List<(UserCard, CardProduct, CardBenefit)>>{};
            for (final entry in entries) {
              grouped.putIfAbsent(entry.$3.kind, () => []).add(entry);
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
                  if (grouped[kind] case final items?
                      when items.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.only(
                        top: AppSpace.lg,
                        bottom: AppSpace.sm,
                      ),
                      child: Text(
                        kindLabel(kind),
                        style: BambooFonts.heading(16, color: BambooInk.ink900),
                      ),
                    ),
                    for (final (userCard, product, benefit) in items)
                      Padding(
                        padding: const EdgeInsets.only(bottom: AppSpace.sm),
                        child: _BenefitTile(
                          userCard: userCard,
                          product: product,
                          benefit: benefit,
                        ),
                      ),
                  ],
              ],
            );
          },
        ),
      ),
    );
  }

  static String kindLabel(BenefitKind kind) => switch (kind) {
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

  static IconData kindIcon(BenefitKind kind) => switch (kind) {
    BenefitKind.loungeDomestic ||
    BenefitKind.loungeInternational => Icons.airline_seat_flat_rounded,
    BenefitKind.golf => Icons.sports_golf_rounded,
    BenefitKind.concierge => Icons.support_agent_rounded,
    BenefitKind.insuranceTravel ||
    BenefitKind.insurancePurchase => Icons.shield_outlined,
    BenefitKind.extendedWarranty => Icons.verified_outlined,
    BenefitKind.diningProgram => Icons.restaurant_outlined,
    BenefitKind.movie => Icons.movie_outlined,
    BenefitKind.fuelSurcharge => Icons.local_gas_station_outlined,
    BenefitKind.roadsideAssistance => Icons.car_repair_outlined,
    BenefitKind.other => Icons.card_giftcard_outlined,
  };

  static String periodLabel(CapPeriod? period) => switch (period) {
    CapPeriod.statementCycle => 'cycle',
    CapPeriod.calendarMonth => 'month',
    CapPeriod.quarter => 'quarter',
    CapPeriod.halfYear => 'half-year',
    CapPeriod.annual => 'year',
    CapPeriod.lifetime => 'lifetime',
    null => 'period',
  };
}

class _BenefitTile extends ConsumerStatefulWidget {
  final UserCard userCard;
  final CardProduct product;
  final CardBenefit benefit;

  const _BenefitTile({
    required this.userCard,
    required this.product,
    required this.benefit,
  });

  @override
  ConsumerState<_BenefitTile> createState() => _BenefitTileState();
}

class _BenefitTileState extends ConsumerState<_BenefitTile> {
  bool _expanded = false;

  String get cardLabel => widget.userCard.nickname?.isNotEmpty == true
      ? widget.userCard.nickname!
      : widget.userCard.cardName;

  bool get _isLounge =>
      widget.benefit.kind == BenefitKind.loungeDomestic ||
      widget.benefit.kind == BenefitKind.loungeInternational;

  String get _compactTitle => switch (widget.benefit.kind) {
    BenefitKind.loungeDomestic => 'Domestic lounge',
    BenefitKind.loungeInternational => 'International lounge',
    BenefitKind.golf => 'Golf access',
    BenefitKind.concierge => 'Concierge',
    BenefitKind.insuranceTravel => 'Travel insurance',
    BenefitKind.insurancePurchase => 'Purchase protection',
    BenefitKind.extendedWarranty => 'Extended warranty',
    BenefitKind.diningProgram => 'Dining',
    BenefitKind.movie => 'Movie benefit',
    BenefitKind.fuelSurcharge => 'Fuel waiver',
    BenefitKind.roadsideAssistance => 'Roadside assistance',
    BenefitKind.other => _otherCompactTitle,
  };

  String get _otherCompactTitle {
    final label = widget.benefit.label.toLowerCase();
    final description = widget.benefit.description?.toLowerCase() ?? '';
    final text = '$label $description';
    if (text.contains('liability') || text.contains('fraud')) {
      return 'Fraud protection';
    }
    if (text.contains('voucher') || text.contains('discount')) {
      return 'Shopping voucher';
    }
    if (text.contains('insurance')) return 'Insurance';
    return 'Other benefit';
  }

  IconData get _benefitIcon {
    if (widget.benefit.kind == BenefitKind.other) {
      final label = widget.benefit.label.toLowerCase();
      final description = widget.benefit.description?.toLowerCase() ?? '';
      final text = '$label $description';
      if (text.contains('liability') || text.contains('fraud')) {
        return Icons.security_outlined;
      }
      if (text.contains('voucher') || text.contains('discount')) {
        return Icons.local_offer_outlined;
      }
      if (text.contains('insurance')) return Icons.shield_outlined;
    }
    return BenefitsCheatSheetScreen.kindIcon(widget.benefit.kind);
  }

  int? _usedThisWindow(List<LoungeVisit>? visits) {
    if (!_isLounge || visits == null) return null;
    return visits
        .where(
          (visit) =>
              visit.userCardId == widget.userCard.id &&
              visit.benefitId == widget.benefit.id,
        )
        .where(
          (visit) =>
              isInCurrentLoungeWindow(visit.usedOn, widget.benefit.quotaPeriod),
        )
        .length;
  }

  @override
  Widget build(BuildContext context) {
    final visits = _isLounge
        ? ref.watch(loungeUsageProvider).valueOrNull
        : null;
    final used = _usedThisWindow(visits);
    final quota = widget.benefit.quotaCount;
    final period = BenefitsCheatSheetScreen.periodLabel(
      widget.benefit.quotaPeriod,
    );
    final remaining = quota == null || used == null
        ? null
        : (quota - used).clamp(0, quota);
    final availabilityLabel = !_isLounge
        ? 'Details inside'
        : used == null
        ? 'Usage not synced'
        : remaining == 0
        ? 'No visits left'
        : '$remaining left this $period';
    final availabilityColor = remaining == 0
        ? BambooInk.clay
        : used == null
        ? BambooInk.ink500
        : BambooInk.jade;

    return CardSummaryPanel(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: CardSummaryHeader(
                  product: widget.product,
                  title: _compactTitle,
                  subtitle: cardLabel,
                  visualWidth: 62,
                  badgeIcon: _benefitIcon,
                  footer: Wrap(
                    spacing: AppSpace.xs,
                    runSpacing: AppSpace.xs,
                    children: [
                      CardSummaryPill(
                        label: quota == null ? 'Included' : '$quota / $period',
                      ),
                      CardSummaryPill(
                        label: availabilityLabel,
                        foreground: availabilityColor,
                        background: availabilityColor.withValues(alpha: 0.10),
                      ),
                    ],
                  ),
                  trailing: Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: BambooInk.ink500,
                    size: 22,
                  ),
                ),
              ),
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.md,
                    0,
                    AppSpace.md,
                    AppSpace.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(height: 1),
                      const SizedBox(height: AppSpace.md),
                      Text(
                        widget.benefit.description ??
                            'Included with this card. Check the issuer terms before using the benefit.',
                        style: BambooFonts.ui(
                          13,
                          color: BambooInk.ink900,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      if (widget.benefit.networkProgram != null)
                        _BenefitMetaRow(
                          label: 'Program',
                          value: widget.benefit.networkProgram!,
                        ),
                      if (widget.product.issuerName?.trim().isNotEmpty == true)
                        _BenefitMetaRow(
                          label: 'Issuer',
                          value: widget.product.issuerName!,
                        ),
                      if (widget.benefit.valueEstimate != null)
                        _BenefitMetaRow(
                          label: 'Estimated value',
                          value: widget.benefit.valueEstimate!.format(),
                        ),
                      if (_isLounge && used != null && quota != null)
                        _BenefitMetaRow(
                          label: 'This $period',
                          value: '$used of $quota used · $remaining remaining',
                        ),
                      if (_isLounge && used == null)
                        Text(
                          'Usage has not synced yet, so availability cannot be confirmed here.',
                          style: BambooFonts.ui(12, color: BambooInk.ink500),
                        ),
                      const SizedBox(height: AppSpace.xs),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => BenefitDetailScreen(
                                userCard: widget.userCard,
                                product: widget.product,
                                benefit: widget.benefit,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.open_in_new_rounded, size: 16),
                          label: const Text('View full details'),
                          style: TextButton.styleFrom(
                            foregroundColor: BambooInk.jade,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BenefitMetaRow extends StatelessWidget {
  final String label;
  final String value;

  const _BenefitMetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpace.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: BambooFonts.ui(12, color: BambooInk.ink500),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w600,
              color: BambooInk.ink900,
            ),
          ),
        ),
      ],
    ),
  );
}
