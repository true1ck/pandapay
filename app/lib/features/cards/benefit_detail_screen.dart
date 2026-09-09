import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../insights/lounge_access_screen.dart' show isInCurrentLoungeWindow;
import 'benefits_cheat_sheet_screen.dart';

/// Screen showing in-depth details of a specific [CardBenefit], the card providing it,
/// its quota/terms, and integrated tracking (e.g. for lounge visits).
class BenefitDetailScreen extends ConsumerWidget {
  final UserCard? userCard;
  final CardProduct? product;
  final CardBenefit? benefit;
  final String? benefitId;
  final String? userCardId;

  const BenefitDetailScreen({
    super.key,
    this.userCard,
    this.product,
    this.benefit,
    this.benefitId,
    this.userCardId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (userCard != null && product != null && benefit != null) {
      return _BenefitDetailBody(
        userCard: userCard!,
        product: product!,
        benefit: benefit!,
      );
    }

    final owned = ref.watch(ownedCardsWithProductProvider);
    return owned.when(
      loading: () => Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          elevation: 0,
          title: Text('Benefit details', style: BambooFonts.heading(17, color: BambooInk.ink900)),
        ),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => Scaffold(
        backgroundColor: BambooInk.paper,
        appBar: AppBar(
          backgroundColor: BambooInk.paper,
          foregroundColor: BambooInk.ink900,
          elevation: 0,
          title: Text('Benefit details', style: BambooFonts.heading(17, color: BambooInk.ink900)),
        ),
        body: ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(userCardsProvider),
        ),
      ),
      data: (pairs) {
        for (final (card, prod) in pairs) {
          if (userCardId != null && card.id != userCardId) continue;
          for (final b in prod.benefits) {
            if (b.id == benefitId) {
              return _BenefitDetailBody(
                userCard: card,
                product: prod,
                benefit: b,
              );
            }
          }
          if (prod.fuelRule != null && benefitId == 'fuel-${prod.id}') {
            return _BenefitDetailBody(
              userCard: card,
              product: prod,
              benefit: CardBenefit(
                id: 'fuel-${prod.id}',
                kind: BenefitKind.fuelSurcharge,
                label:
                    '${prod.fuelRule!.waiverPercent == prod.fuelRule!.waiverPercent.roundToDouble() ? prod.fuelRule!.waiverPercent.toStringAsFixed(0) : prod.fuelRule!.waiverPercent.toStringAsFixed(2)}% fuel surcharge waiver',
                description: 'Fuel surcharge waived'
                    '${prod.fuelRule!.minTxn != null ? " on transactions above ${prod.fuelRule!.minTxn!.format()}" : ""}'
                    '${prod.fuelRule!.maxTxn != null ? " up to ${prod.fuelRule!.maxTxn!.format()}" : ""}.',
              ),
            );
          }
        }
        return Scaffold(
          backgroundColor: BambooInk.paper,
          appBar: AppBar(
            backgroundColor: BambooInk.paper,
            foregroundColor: BambooInk.ink900,
            elevation: 0,
            title: Text('Benefit details', style: BambooFonts.heading(17, color: BambooInk.ink900)),
          ),
          body: const ErrorState(
            message: 'This benefit could not be found.',
          ),
        );
      },
    );
  }
}

class _BenefitDetailBody extends ConsumerWidget {
  final UserCard userCard;
  final CardProduct product;
  final CardBenefit benefit;

  const _BenefitDetailBody({
    required this.userCard,
    required this.product,
    required this.benefit,
  });

  bool get _isLoungeBenefit =>
      benefit.kind == BenefitKind.loungeDomestic || benefit.kind == BenefitKind.loungeInternational;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardDisplayName =
        userCard.nickname?.isNotEmpty == true ? userCard.nickname! : userCard.cardName;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Benefit details', style: BambooFonts.heading(17, color: BambooInk.ink900)),
        actions: [
          IconButton(
            tooltip: 'Report wrong data',
            icon: const Icon(Icons.flag_outlined),
            onPressed: () => context.push('${AppRoute.reportWrongData}?cardProductId=${product.id}'),
          ),
        ],
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            // Top category pill
            Row(
              children: [
                StatusPill(
                  icon: BenefitsCheatSheetScreen.kindIcon(benefit.kind),
                  label: BenefitsCheatSheetScreen.kindLabel(benefit.kind),
                  foreground: BambooInk.ink900,
                  background: BambooInk.paperMuted,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.md),

            // Benefit headline
            Text(
              benefit.label,
              style: BambooFonts.heading(20, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),

            // Estimated value banner if present
            if (benefit.valueEstimate != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
                decoration: BoxDecoration(
                  color: BambooInk.jade.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: BambooInk.jade.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.savings_outlined, color: BambooInk.jade, size: 20),
                    const SizedBox(width: AppSpace.sm),
                    Text(
                      'Estimated value: ',
                      style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
                    ),
                    MoneyText(
                      benefit.valueEstimate!,
                      confidence: Confidence.estimated,
                      style: BambooFonts.heading(15, color: BambooInk.jade),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.md),
            ],

            // Associated card card
            _buildCardInfoCard(context, cardDisplayName),
            const SizedBox(height: AppSpace.md),

            // Quota and Program Highlights
            _buildQuotaAndProgramCard(),
            const SizedBox(height: AppSpace.md),

            // Live lounge tracker section if this is a lounge perk
            if (_isLoungeBenefit) ...[
              _buildLoungeUsageSection(context, ref),
              const SizedBox(height: AppSpace.md),
              _buildLoungeAccessGuide(),
              const SizedBox(height: AppSpace.md),
              _buildLoungeCoverageAndRules(),
              const SizedBox(height: AppSpace.md),
            ],

            // Full terms and description
            _buildTermsAndDescriptionCard(),
            const SizedBox(height: AppSpace.lg),

            // Report wrong data footer link
            Center(
              child: TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: BambooInk.ink500),
                icon: const Icon(Icons.flag_outlined, size: 16),
                label: const Text('Report incorrect details for this benefit'),
                onPressed: () =>
                    context.push('${AppRoute.reportWrongData}?cardProductId=${product.id}'),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
          ],
        ),
      ),
    );
  }

  Widget _buildCardInfoCard(BuildContext context, String cardDisplayName) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: () => context.push('/cards/${userCard.id}'),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PROVIDED BY',
              style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: BambooInk.slate,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: const Icon(Icons.credit_card_rounded, color: BambooInk.lime, size: 22),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        cardDisplayName,
                        style: BambooFonts.heading(15, color: BambooInk.ink900),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${product.issuerName != null ? "${product.issuerName} · " : ""}${product.network.name.toUpperCase()}',
                        style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500, size: 22),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuotaAndProgramCard() {
    final quotaText = benefit.quotaCount != null
        ? '${benefit.quotaCount} per ${BenefitsCheatSheetScreen.periodLabel(benefit.quotaPeriod)}'
        : 'Unlimited';
    final programText = benefit.networkProgram ?? 'Standard card benefit';

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BENEFIT PARAMETERS',
            style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: _buildParamItem(
                  icon: Icons.repeat_rounded,
                  label: 'Quota',
                  value: quotaText,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _buildParamItem(
                  icon: Icons.hub_outlined,
                  label: 'Program',
                  value: programText,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildParamItem({required IconData icon, required String label, required String value}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: BambooInk.ink500),
            const SizedBox(width: 4),
            Text(label, style: BambooFonts.ui(12, color: BambooInk.ink500)),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildLoungeUsageSection(BuildContext context, WidgetRef ref) {
    final visitsAsync = ref.watch(loungeUsageProvider);

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: visitsAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.md),
            child: CircularProgressIndicator(),
          ),
        ),
        error: (err, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Lounge Usage Tracker', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.xs),
            Text('Could not load usage data.', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          ],
        ),
        data: (visitList) {
          final windowVisits = visitList
              .where((v) => v.userCardId == userCard.id && v.benefitId == benefit.id)
              .where((v) => isInCurrentLoungeWindow(v.usedOn, benefit.quotaPeriod))
              .length;

          final quotaValue = benefit.quotaCount;
          final unlimited = quotaValue == null;
          final quota = quotaValue ?? 0;
          final remaining = unlimited ? null : (quota - windowVisits).clamp(0, quota);
          final ratio = unlimited ? 0.0 : (quota == 0 ? 0.0 : (windowVisits / quota).clamp(0.0, 1.0));

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'LOUNGE TRACKING',
                    style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: BambooInk.jade,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Log visit'),
                    onPressed: () => _showLogVisitSheet(context, ref),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              if (unlimited)
                Text(
                  '$windowVisits visits logged this period · unlimited quota',
                  style: BambooFonts.ui(13, color: BambooInk.ink900),
                )
              else ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 8,
                    backgroundColor: BambooInk.paperMuted,
                    color: ratio >= 1.0 ? BambooInk.clay : BambooInk.jade,
                  ),
                ),
                const SizedBox(height: AppSpace.sm),
                Row(
                  children: [
                    if (ratio >= 1.0)
                      const Icon(Icons.block_rounded, size: 14, color: BambooInk.clay),
                    if (ratio >= 1.0) const SizedBox(width: 4),
                    Text(
                      '$windowVisits of $quota visits used this period ($remaining left)',
                      style: BambooFonts.ui(
                        12.5,
                        weight: FontWeight.w500,
                        color: ratio >= 1.0 ? BambooInk.clay : BambooInk.ink900,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: AppSpace.md),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: BambooInk.ink900,
                  side: const BorderSide(color: BambooInk.hairlineOnPaper),
                  minimumSize: const Size.fromHeight(40),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.md)),
                ),
                icon: const Icon(Icons.airline_seat_flat_angled_rounded, size: 16),
                label: const Text('View All Lounge Access'),
                onPressed: () => context.push(AppRoute.loungeAccess),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLoungeAccessGuide() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'HOW TO ACCESS THE LOUNGE',
            style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          _buildStepRow(
            stepNumber: '1',
            title: 'Present physical or digital card',
            description: 'Show your eligible card at the airport lounge reception counter.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildStepRow(
            stepNumber: '2',
            title: 'Boarding pass verification',
            description: 'Provide a valid same-day boarding pass matching the cardholder name.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildStepRow(
            stepNumber: '3',
            title: 'Nominal swipe verification',
            description:
                'A standard validation charge (₹2 on Visa/RuPay, ₹25 on Mastercard) is processed and refunded automatically.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildStepRow(
            stepNumber: '4',
            title: 'Enjoy complimentary amenities',
            description:
                'Access complimentary buffet meals, refreshments, Wi-Fi, comfortable seating, and flight information displays.',
          ),
        ],
      ),
    );
  }

  Widget _buildLoungeCoverageAndRules() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ELIGIBILITY & LOUNGE NETWORK',
            style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.md),
          _buildRuleItem(
            icon: Icons.currency_rupee_rounded,
            title: 'Spend Criteria (Where Applicable)',
            description:
                'Some issuers require qualifying spends (e.g. ₹10,000–₹50,000) in the previous calendar quarter to unlock complimentary visits in the following quarter.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildRuleItem(
            icon: Icons.people_outline_rounded,
            title: 'Guest & Child Policy',
            description:
                'Complimentary quota is reserved for the primary cardholder. Accompanying guests and children are charged at standard lounge entry rates.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildRuleItem(
            icon: Icons.schedule_rounded,
            title: 'Duration of Stay',
            description:
                'Standard complimentary entry is permitted up to 2–3 hours prior to your scheduled flight departure time.',
          ),
          const SizedBox(height: AppSpace.sm),
          _buildRuleItem(
            icon: Icons.flight_takeoff_rounded,
            title: 'Major Participating Hubs',
            description:
                'Delhi (DEL T1, T2, T3), Mumbai (BOM T1, T2), Bengaluru (BLR T1, T2), Hyderabad (HYD), Chennai (MAA), Kolkata (CCU), Ahmedabad, Pune, Kochi, Goa, and 30+ domestic airports.',
          ),
        ],
      ),
    );
  }

  Widget _buildStepRow({
    required String stepNumber,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: BambooInk.slate,
            shape: BoxShape.circle,
          ),
          child: Text(
            stepNumber,
            style: BambooFonts.ui(12, weight: FontWeight.w700, color: BambooInk.lime),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRuleItem({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: BambooInk.ink500),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: BambooFonts.ui(12, color: BambooInk.ink500),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTermsAndDescriptionCard() {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TERMS & DETAILS',
            style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.ink500),
          ),
          const SizedBox(height: AppSpace.sm),
          if (benefit.description != null && benefit.description!.isNotEmpty) ...[
            Text(
              benefit.description!,
              style: BambooFonts.ui(14, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.md),
          ],
          _buildKindSpecificGuidelines(benefit.kind),
        ],
      ),
    );
  }

  Widget _buildKindSpecificGuidelines(BenefitKind kind) {
    final note = switch (kind) {
      BenefitKind.loungeDomestic || BenefitKind.loungeInternational =>
        'Access is subject to lounge availability, valid boarding pass, and primary/add-on card eligibility rules. A nominal authorization charge may apply.',
      BenefitKind.diningProgram =>
        'Discounts and dining offers generally apply to participating partner restaurants and must be settled using this card. Advance reservations may be required.',
      BenefitKind.insuranceTravel || BenefitKind.insurancePurchase =>
        'Insurance coverage is subject to underwriter policy terms, deductibles, and submission of relevant proof (e.g. flight tickets or purchase invoices).',
      BenefitKind.extendedWarranty =>
        'Warranty protection extends original manufacturer warranty. Retain invoices and warranty cards for claim verification.',
      BenefitKind.fuelSurcharge =>
        'Fuel surcharge waivers typically apply to transactions between ₹400 and ₹5,000, excluding GST on fuel transactions.',
      BenefitKind.golf =>
        'Golf bookings are subject to course availability, booking lead times, and handicap requirements where applicable.',
      BenefitKind.concierge =>
        '24/7 concierge assistance is available for travel bookings, dining recommendations, and emergency coordination.',
      BenefitKind.movie =>
        'Ticket discounts/vouchers are subject to monthly quotas, partner booking platforms (e.g. BookMyShow), and availability.',
      BenefitKind.roadsideAssistance =>
        'Emergency roadside assistance services are available on registered vehicles and subject to geographical coverage.',
      BenefitKind.other =>
        'Refer to card terms and conditions or issuer documentation for specific eligibility criteria.',
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline_rounded, size: 16, color: BambooInk.ink500),
        const SizedBox(width: AppSpace.xs),
        Expanded(
          child: Text(
            note,
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ),
      ],
    );
  }

  void _showLogVisitSheet(BuildContext context, WidgetRef ref) {
    final airportController = TextEditingController();
    final pickedDate = DateTime.now();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: BambooInk.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          left: AppSpace.lg,
          right: AppSpace.lg,
          top: AppSpace.lg,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Log a lounge visit', style: BambooFonts.heading(17, color: BambooInk.ink900)),
            const SizedBox(height: AppSpace.md),
            TextField(
              controller: airportController,
              style: BambooFonts.ui(14.5, color: BambooInk.ink900),
              decoration: InputDecoration(
                labelText: 'Airport (optional)',
                labelStyle: BambooFonts.ui(13.5, color: BambooInk.ink500),
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
            ),
            const SizedBox(height: AppSpace.lg),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.slate,
                foregroundColor: BambooInk.lime,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
              ),
              onPressed: () async {
                final repo = ref.read(userCardsRepositoryProvider);
                if (repo == null) return;
                try {
                  await repo.logLoungeVisit(
                    userCardId: userCard.id,
                    benefitId: benefit.id,
                    usedOn: pickedDate,
                    airport: airportController.text.trim().isEmpty ? null : airportController.text.trim(),
                  );
                  ref.invalidate(loungeUsageProvider);
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                } catch (e) {
                  if (sheetContext.mounted) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      SnackBar(content: Text(userFacingErrorMessage(e))),
                    );
                  }
                }
              },
              child: const Text('Log visit'),
            ),
          ],
        ),
      ),
    );
  }
}
