import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// D6 Missed Opportunities (ui-spec Group D). Sub-optimal transactions
/// only: used vs. better card, ₹ lost, running 90-day total. Built entirely
/// on the shared [compareToOwnedCards] calculator (Task D-13) — see that
/// function's own doc-comment for exactly what this can and can't detect
/// (base-rate-only, no historical cap/milestone/forex state). Filter by
/// card/category, per spec.
class MissedOpportunitiesScreen extends ConsumerWidget {
  const MissedOpportunitiesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filterCardId = ref.watch(_missedOppCardFilterProvider);
    final missed = ref.watch(_missedOpportunitiesProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Missed opportunities', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.9, -0.5),
            radius: 1.3,
            colors: [BambooInk.wash, BambooInk.paper],
            stops: [0.0, 0.6],
          ),
        ),
        child: missed.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => ErrorState(
            message: userFacingErrorMessage(err),
            onRetry: () => ref.invalidate(_missedOpportunitiesProvider),
          ),
          data: (all) {
            final cardsInvolved = {for (final m in all) m.entry.userCardId: m.entry.cardDisplayName};
            final filtered = filterCardId == null ? all : all.where((m) => m.entry.userCardId == filterCardId).toList();
            final runningTotal = filtered.fold<Money>(const Money.zero(), (a, m) => a + m.comparison.missedValue);

            return Column(
              children: [
                if (cardsInvolved.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
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
                              color: filterCardId == null ? BambooInk.onSlate : BambooInk.ink900,
                            ),
                            selected: filterCardId == null,
                            selectedColor: BambooInk.slate,
                            backgroundColor: BambooInk.paperMuted,
                            side: BorderSide.none,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                            onSelected: (_) => ref.read(_missedOppCardFilterProvider.notifier).state = null,
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
                                  color: filterCardId == entry.key ? BambooInk.onSlate : BambooInk.ink900,
                                ),
                                selected: filterCardId == entry.key,
                                selectedColor: BambooInk.slate,
                                backgroundColor: BambooInk.paperMuted,
                                side: BorderSide.none,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                onSelected: (_) => ref.read(_missedOppCardFilterProvider.notifier).state = entry.key,
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
                          message: 'Every transaction we can compare used one of your best-rated cards for its category.',
                        )
                      : ListView(
                          padding: const EdgeInsets.all(AppSpace.lg),
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [BambooInk.slateRaised, BambooInk.slate],
                                ),
                                borderRadius: BorderRadius.circular(AppRadius.lg),
                              ),
                              padding: const EdgeInsets.all(AppSpace.lg),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Last 90 days', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
                                  MoneyText(runningTotal, confidence: Confidence.estimated, style: BambooFonts.money(22, color: BambooInk.lime)),
                                ],
                              ),
                            ),
                            const SizedBox(height: AppSpace.lg),
                            for (final m in filtered)
                              Padding(
                                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                                child: _MissedOpportunityTile(m),
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
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

final _missedOpportunitiesProvider = FutureProvider<List<_MissedOpportunity>>((ref) async {
  final repo = ref.watch(userCardsRepositoryProvider);
  if (repo == null) return const [];
  final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
  if (pairs.length < 2) return const []; // nothing to have chosen instead of

  final productsByUserCardId = {for (final (uc, p) in pairs) uc.id: p};
  final allProducts = [for (final (_, p) in pairs) p];

  final since = DateTime.now().subtract(const Duration(days: 90));
  final transactions = await repo.fetchTransactions(from: since);

  final results = <_MissedOpportunity>[];
  for (final txn in transactions) {
    if (txn.status != 'active') continue;
    final usedProduct = productsByUserCardId[txn.userCardId];
    if (usedProduct == null) continue; // card since archived/removed — nothing to compare
    final comparison = compareToOwnedCards(
      usedCard: usedProduct,
      ownedCards: allProducts,
      amount: txn.amount,
      categoryId: txn.categoryId,
    );
    if (comparison.hadBetterOption) results.add(_MissedOpportunity(txn, comparison));
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
          Row(
            children: [
              Expanded(
                child: Text(entry.merchantName ?? 'Spend', style: BambooFonts.heading(14.5, color: BambooInk.ink900), overflow: TextOverflow.ellipsis),
              ),
              MoneyText(entry.amount, confidence: Confidence.estimated, style: BambooFonts.money(14, color: BambooInk.ink900)),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text('Used ${entry.cardDisplayName ?? comparison.usedCard.name}', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
          Row(
            children: [
              const Icon(Icons.trending_up_rounded, size: 14, color: BambooInk.amber),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${comparison.betterCard!.name} would have earned ${comparison.missedValue.format()} more',
                  style: BambooFonts.ui(12.5, color: BambooInk.amber),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
