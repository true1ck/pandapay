import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../insights/lounge_access_screen.dart' show isInCurrentLoungeWindow;

/// ui-spec.md G1 Travel Mode. The toggle itself flips `travelModeProvider`
/// (app/providers.dart), which `rankedRecommendationsProvider` already
/// reads into `RecommendationContext.travelMode` — Home's top card
/// re-ranks live the moment this switch flips, with no extra fetch (the
/// engine already had this wired, per the plan's audit; this screen is the
/// missing UI, not new ranking logic).
///
/// Offline behaviour: same as every other Insights-adjacent screen —
/// requires the already-fetched catalogue/wallet, degrades to ErrorState
/// with retry when that fetch fails. Only G4 has the zero-network mandate.
class TravelModeScreen extends ConsumerWidget {
  const TravelModeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final travelMode = ref.watch(travelModeProvider);
    final pairs = ref.watch(ownedCardsWithProductProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Travel Mode')),
      body: pairs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(ownedCardsWithProductProvider),
        ),
        data: (owned) {
          return ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              _TravelModeToggle(
                enabled: travelMode,
                onChanged: (v) =>
                    ref.read(travelModeProvider.notifier).state = v,
              ),
              const SizedBox(height: AppSpace.xxl),
              Text(
                'Forex markup by card',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'What each card actually charges on a foreign-currency swipe, including GST on the '
                'markup — lower is better. Cards ranked here are the ones you own.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpace.md),
              _MarkupComparison(owned: owned),
              const SizedBox(height: AppSpace.xxl),
              Text(
                'Lounge access abroad',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.sm),
              _LoungeAbroadSection(owned: owned),
              const SizedBox(height: AppSpace.xxl),
              Text(
                'Travel insurance',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.sm),
              _TravelInsuranceSection(owned: owned),
              const SizedBox(height: AppSpace.xxl),
              const _DccExplainer(),
              const SizedBox(height: AppSpace.xxl),
              const _DestinationAcceptanceNotes(),
            ],
          );
        },
      ),
    );
  }
}

class _TravelModeToggle extends StatelessWidget {
  final bool enabled;
  final ValueChanged<bool> onChanged;
  const _TravelModeToggle({required this.enabled, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: enabled ? AppColors.navy900 : AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          Icon(
            Icons.flight_takeoff_rounded,
            color: enabled ? Colors.white : AppColors.navy800,
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Travel Mode',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: enabled ? Colors.white : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'On — Home now ranks cards with forex markup factored in.'
                      : 'Off — turn on when you\'re spending abroad.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: enabled ? Colors.white70 : null,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: onChanged,
            activeTrackColor: AppColors.teal500,
          ),
        ],
      ),
    );
  }
}

class _MarkupComparison extends StatelessWidget {
  final List<(UserCard, CardProduct)> owned;
  const _MarkupComparison({required this.owned});

  @override
  Widget build(BuildContext context) {
    if (owned.isEmpty) {
      return const EmptyState(
        icon: Icons.public_off_rounded,
        title: 'No cards yet',
        message: 'Add a card to compare forex markups.',
      );
    }
    final withForex = <(UserCard, CardProduct, double)>[
      for (final (uc, p) in owned)
        if (p.forexRule != null)
          (uc, p, p.forexRule!.effectiveMarkupFraction()),
    ]..sort((a, b) => a.$3.compareTo(b.$3));
    final withoutForex = owned.where((p) => p.$2.forexRule == null).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (userCard, product, markup) in withForex)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.ink100),
              ),
              padding: const EdgeInsets.all(AppSpace.md),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      userCard.nickname?.isNotEmpty == true
                          ? userCard.nickname!
                          : product.name,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    '${(markup * 100).toStringAsFixed(2)}% incl. GST',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: markup <= 0.02
                          ? AppColors.success
                          : AppColors.error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (withoutForex.isNotEmpty) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            'No forex data on file',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: AppSpace.xs),
          for (final (userCard, product) in withoutForex)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name} — markup unknown, '
                'treat as domestic-only until confirmed',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }
}

class _LoungeAbroadSection extends ConsumerWidget {
  final List<(UserCard, CardProduct)> owned;
  const _LoungeAbroadSection({required this.owned});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visits = ref.watch(loungeUsageProvider);
    final rows = <(UserCard, CardProduct, CardBenefit)>[
      for (final (uc, p) in owned)
        for (final b in p.benefits)
          if (b.kind == BenefitKind.loungeInternational) (uc, p, b),
    ];
    if (rows.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Text(
          'None of your cards carry an international-lounge benefit — or you haven\'t added a card '
          'yet. This section only shows what your own cards\' catalogue data actually lists.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return visits.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpace.md),
        child: LinearProgressIndicator(),
      ),
      error: (err, _) => Text(
        userFacingErrorMessage(err),
        style: Theme.of(context).textTheme.bodySmall,
      ),
      data: (visitList) => Column(
        children: [
          for (final (userCard, product, benefit) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: _LoungeAbroadTile(
                userCard: userCard,
                product: product,
                benefit: benefit,
                usedThisWindow: visitList
                    .where(
                      (v) =>
                          v.userCardId == userCard.id &&
                          v.benefitId == benefit.id,
                    )
                    .where(
                      (v) => isInCurrentLoungeWindow(
                        v.usedOn,
                        benefit.quotaPeriod,
                      ),
                    )
                    .length,
              ),
            ),
        ],
      ),
    );
  }
}

class _LoungeAbroadTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final CardBenefit benefit;
  final int usedThisWindow;
  const _LoungeAbroadTile({
    required this.userCard,
    required this.product,
    required this.benefit,
    required this.usedThisWindow,
  });

  @override
  Widget build(BuildContext context) {
    // Same fix as lounge_access_screen.dart's own _LoungeTile (PROGRESS.md
    // Chunk 36 flagged this exact bug): `quota` must be a non-null int
    // BEFORE the ternary below, not left nullable — Dart doesn't promote
    // it to non-null in the false branch just because a separately-named
    // `unlimited` bool happens to be false there.
    final quotaValue = benefit.quotaCount;
    final unlimited = quotaValue == null;
    final quota = quotaValue ?? 0;
    final remaining = unlimited
        ? null
        : (quota - usedThisWindow).clamp(0, quota);
    final eligible = unlimited || (remaining ?? 0) > 0;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          Icon(
            eligible ? Icons.check_circle_outline_rounded : Icons.block_rounded,
            size: 18,
            color: eligible ? AppColors.success : AppColors.error,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name} — ${benefit.label}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  unlimited
                      ? 'Unlimited this period'
                      : '${remaining ?? 0} of $quota visits left this period',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TravelInsuranceSection extends StatelessWidget {
  final List<(UserCard, CardProduct)> owned;
  const _TravelInsuranceSection({required this.owned});

  @override
  Widget build(BuildContext context) {
    final rows = <(UserCard, CardProduct, CardBenefit)>[
      for (final (uc, p) in owned)
        for (final b in p.benefits)
          if (b.kind == BenefitKind.insuranceTravel) (uc, p, b),
    ];
    if (rows.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.all(AppSpace.md),
        child: Text(
          'None of your cards list a travel-insurance benefit in the catalogue. That may mean your '
          'card genuinely doesn\'t carry one, or that PandaPay\'s catalogue data for it is '
          'incomplete — check your card\'s own terms before travelling on the assumption you\'re '
          'covered.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    return Column(
      children: [
        for (final (userCard, product, benefit) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.ink100),
              ),
              padding: const EdgeInsets.all(AppSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name} — ${benefit.label}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (benefit.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      benefit.description!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (benefit.valueEstimate != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          'Estimated cover ',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        MoneyText(
                          benefit.valueEstimate!,
                          confidence: Confidence.estimated,
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Static, content-only — no data dependency by design (per the plan's own
/// "content task, not a data task; don't over-engineer this" note).
class _DccExplainer extends StatelessWidget {
  const _DccExplainer();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: AppColors.error,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Text(
                  'Watch out for DCC',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'At a foreign card machine or ATM you\'ll sometimes be asked "Charge in ₹ (INR) or in the '
            'local currency?" — that prompt is Dynamic Currency Conversion (DCC).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'Always choose the LOCAL currency, not INR. DCC lets the merchant\'s bank set its own '
            'exchange rate on the spot — it\'s almost always worse than your card network\'s real '
            'rate, on top of whatever forex markup your card already charges. Choosing local '
            'currency lets your card issuer do the conversion instead, at the real rate.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Judgment call, flagged per the plan's own explicit narrowing: no table in
/// this app's schema models per-destination network acceptance, so this is
/// a static, honest note rather than fabricated per-country data.
class _DestinationAcceptanceNotes extends StatelessWidget {
  const _DestinationAcceptanceNotes();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: AppColors.ink100),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Card acceptance abroad',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'PandaPay doesn\'t have per-destination acceptance data (no country/merchant coverage '
            'is modelled anywhere in this app today) — this is general guidance, not a country-by-'
            'country breakdown.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'RuPay has limited acceptance outside India. If your only card is RuPay, carry a Visa '
            'or Mastercard as a backup when travelling internationally.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
