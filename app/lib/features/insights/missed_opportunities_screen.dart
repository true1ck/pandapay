import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;
import '../cards/card_summary.dart';
import '../cards/card_visual.dart';
import 'spending_visuals.dart';

/// D6 Missed Opportunities (ui-spec Group D). Sub-optimal transactions
/// only: used vs. better card, ₹ lost, running 90-day total. Built entirely
/// on the shared [compareToOwnedCards] calculator (Task D-13) — see that
/// function's own doc-comment for exactly what this can and can't detect
/// (base-rate-only, no historical cap/milestone/forex state). Filter by
/// card/category, per spec.
class MissedOpportunitiesScreen extends ConsumerWidget {
  /// When false, the screen renders only its body — no Scaffold, no AppBar.
  ///
  /// Needed because this is the one insight screen that carried its own
  /// chrome; every sibling was a plain body the router wrapped. It now also
  /// appears as a tab inside the grouped "Rewards" insight, where a nested
  /// Scaffold would stack a second app bar under the first.
  final bool showChrome;

  const MissedOpportunitiesScreen({super.key, this.showChrome = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filterCardId = ref.watch(_missedOppCardFilterProvider);
    final missed = ref.watch(_missedOpportunitiesProvider);

    if (!showChrome) return _body(context, ref, filterCardId, missed);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Missed opportunities',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: _body(context, ref, filterCardId, missed),
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    String? filterCardId,
    AsyncValue<List<_MissedOpportunity>> missed,
  ) {
    return AppBackground(
      child: missed.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorState(
          message: userFacingErrorMessage(err),
          onRetry: () => ref.invalidate(_missedOpportunitiesProvider),
        ),
        data: (all) {
          final cardsInvolved = {
            for (final m in all) m.entry.userCardId: m.entry.cardDisplayName,
          };
          final filtered = filterCardId == null
              ? all
              : all.where((m) => m.entry.userCardId == filterCardId).toList();
          final runningTotal = filtered.fold<Money>(
            const Money.zero(),
            (a, m) => a + m.comparison.missedValue,
          );

          return Column(
            children: [
              if (cardsInvolved.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    0,
                  ),
                  child: SizedBox(
                    height: 36,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        ChoiceChip(
                          label: const Text('All cards'),
                          labelStyle: BambooFonts.ui(
                            13,
                            weight: FontWeight.w600,
                            color: filterCardId == null
                                ? BambooInk.onSlate
                                : BambooInk.ink900,
                          ),
                          selected: filterCardId == null,
                          selectedColor: BambooInk.slate,
                          backgroundColor: BambooInk.paperMuted,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          onSelected: (_) =>
                              ref
                                      .read(
                                        _missedOppCardFilterProvider.notifier,
                                      )
                                      .state =
                                  null,
                        ),
                        const SizedBox(width: AppSpace.xs),
                        for (final entry in cardsInvolved.entries)
                          Padding(
                            padding: const EdgeInsets.only(right: AppSpace.xs),
                            child: ChoiceChip(
                              label: Text(entry.value ?? 'Card'),
                              labelStyle: BambooFonts.ui(
                                13,
                                weight: FontWeight.w600,
                                color: filterCardId == entry.key
                                    ? BambooInk.onSlate
                                    : BambooInk.ink900,
                              ),
                              selected: filterCardId == entry.key,
                              selectedColor: BambooInk.slate,
                              backgroundColor: BambooInk.paperMuted,
                              side: BorderSide.none,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                              onSelected: (_) =>
                                  ref
                                      .read(
                                        _missedOppCardFilterProvider.notifier,
                                      )
                                      .state = entry
                                      .key,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              Expanded(
                child: filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.check_circle_outline_rounded,
                        title: 'No missed opportunities in the last 90 days',
                        message:
                            'Every transaction we can compare used one of your best-rated cards for its category.',
                      )
                    : ListView(
                        padding: const EdgeInsets.all(AppSpace.lg),
                        children: [
                          _MissedTotalCard(runningTotal: runningTotal),
                          const SizedBox(height: AppSpace.lg),
                          for (final m in filtered)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: AppSpace.sm,
                              ),
                              child: _MissedOpportunityTile(m),
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MissedOpportunity {
  final TransactionEntry entry;
  final HistoricalCardComparison comparison;
  const _MissedOpportunity(this.entry, this.comparison);
}

final _missedOppCardFilterProvider = StateProvider<String?>((ref) => null);

final _missedOpportunitiesProvider = FutureProvider<List<_MissedOpportunity>>((
  ref,
) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final pairs =
      ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (pairs.length < 2) return const []; // nothing to have chosen instead of

  final productsByUserCardId = {for (final (uc, p) in pairs) uc.id: p};
  final allProducts = [for (final (_, p) in pairs) p];

  final since = DateTime.now().subtract(const Duration(days: 90));
  final transactions = await loadTransactionsWithOfflineCache(
    ref,
    repo: repo,
    cacheKey: 'transactions:missed_opportunities',
    from: since,
    preferCached: true,
    useReportSnapshots: true,
  );

  final results = <_MissedOpportunity>[];
  for (final txn in transactions) {
    if (txn.status != 'active') continue;
    if (txn.userCardId == null) continue;
    final usedProduct = productsByUserCardId[txn.userCardId!];
    if (usedProduct == null) {
      continue; // card since archived/removed — nothing to compare
    }
    final comparison = compareToOwnedCards(
      usedCard: usedProduct,
      ownedCards: allProducts,
      amount: txn.amount,
      categoryId: txn.categoryId,
    );
    if (comparison.hadBetterOption) {
      results.add(_MissedOpportunity(txn, comparison));
    }
  }
  results.sort((a, b) => b.entry.occurredAt.compareTo(a.entry.occurredAt));
  return results;
});

class _MissedOpportunityTile extends StatelessWidget {
  final _MissedOpportunity missed;
  const _MissedOpportunityTile(this.missed);

  @override
  Widget build(BuildContext context) {
    final entry = missed.entry;
    final comparison = missed.comparison;
    final category = spendingCategoryVisual(entry.categoryName ?? 'Other');
    return CardSummaryPanel(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _MissedIconBadge(icon: category.icon, accent: category.accent),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.merchantName ?? entry.categoryName ?? 'Spend',
                      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      entry.categoryName ?? 'Other',
                      style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              MoneyText(
                entry.amount,
                confidence: Confidence.estimated,
                style: BambooFonts.money(14, color: BambooInk.ink900),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          _CardSwapRow(
            usedCard: comparison.usedCard,
            usedLabel: entry.cardDisplayName ?? comparison.usedCard.name,
            betterCard: comparison.betterCard!,
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              const Icon(
                Icons.trending_up_rounded,
                size: 16,
                color: BambooInk.amber,
              ),
              const SizedBox(width: AppSpace.xs),
              Expanded(
                child: Text(
                  '${comparison.betterCard!.name} would have earned ${comparison.missedValue.format()} more',
                  style: BambooFonts.ui(12, color: BambooInk.amber),
                ),
              ),
              CardSummaryPill(
                label: '+${comparison.missedValue.format(hidePaise: true)}',
                foreground: BambooInk.clay,
                background: BambooInk.clay.withValues(alpha: 0.11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MissedTotalCard extends StatelessWidget {
  final Money runningTotal;

  const _MissedTotalCard({required this.runningTotal});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slate],
        ),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: BambooInk.lime.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.trending_down_rounded,
              color: BambooInk.lime,
              size: 20,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last 90 days',
                  style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  'Missed reward value',
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w600,
                    color: BambooInk.onSlate,
                  ),
                ),
              ],
            ),
          ),
          MoneyText(
            runningTotal,
            confidence: Confidence.estimated,
            style: BambooFonts.money(22, color: BambooInk.lime),
            hidePaise: true,
          ),
        ],
      ),
    );
  }
}

class _CardSwapRow extends StatelessWidget {
  final CardProduct usedCard;
  final String usedLabel;
  final CardProduct betterCard;

  const _CardSwapRow({
    required this.usedCard,
    required this.usedLabel,
    required this.betterCard,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _CardMini(product: usedCard, label: usedLabel, muted: true),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
          child: Icon(
            Icons.arrow_forward_rounded,
            size: 17,
            color: BambooInk.amber,
          ),
        ),
        _CardMini(product: betterCard, label: 'Better card', muted: false),
      ],
    );
  }
}

class _CardMini extends StatelessWidget {
  final CardProduct product;
  final String label;
  final bool muted;

  const _CardMini({
    required this.product,
    required this.label,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        children: [
          Opacity(
            opacity: muted ? 0.58 : 1,
            child: CardVisual(
              product: product,
              showProductName: false,
              width: 54,
              height: 34,
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(
                10.5,
                weight: muted ? FontWeight.w500 : FontWeight.w700,
                color: muted ? BambooInk.ink500 : BambooInk.ink900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissedIconBadge extends StatelessWidget {
  final IconData icon;
  final Color accent;

  const _MissedIconBadge({required this.icon, required this.accent});

  @override
  Widget build(BuildContext context) => Container(
    width: 36,
    height: 36,
    decoration: BoxDecoration(
      color: accent.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Icon(icon, color: accent, size: 19),
  );
}
