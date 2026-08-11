import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart';
import '../../main.dart' show MoneyText;

/// ui-spec.md E2 Caps & Limits ⭐. `CapRule` (the definition — value,
/// measure, period) and `UserCard.capConsumed` (this period's consumption,
/// already fetched by GET /user-cards — Chunk 17) were both fully wired
/// before this screen; nothing here was previously displayed anywhere.
///
/// Task E-0b finding: `FuelSurchargeRule` is a SEPARATE type from `CapRule`
/// (confirmed by reading card_rules.dart directly, not assumed from type
/// names) — a fuel-surcharge waiver never appears in `product.capRules`,
/// so the plain iteration below would silently omit it. Folded in as a
/// second, explicitly-labelled section rather than a `CapRule` row (it has
/// no id/period/consumed-state to sort/display the same way).
///
/// Task E-0c: rows sort closest-to-cap first via the shared urgency
/// scorer, matching E1's ordering approach.
///
/// Bamboo Ink's token set defines only a two-tier clay/jade severity
/// pairing (no separate mid-severity "warning" hue) — this screen's real
/// three-tier traffic light (>=90% / >=50% / under) is a genuine part of
/// its function (it's how a user tells "fine" from "watch this" from
/// "about to hit the cap"), so a distinct amber is kept here rather than
/// collapsing to two colors and losing that signal.
const _amber = Color(0xFFD97706);

class CapsScreen extends ConsumerWidget {
  const CapsScreen({super.key});

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
        final rows = <(UserCard, CardProduct, CapRule)>[
          for (final (userCard, product) in owned)
            for (final cap in product.capRules) (userCard, product, cap),
        ];
        rows.sort((a, b) {
          final consumedA = a.$1.capConsumed[a.$3.id] ?? const Money.zero();
          final consumedB = b.$1.capConsumed[b.$3.id] ?? const Money.zero();
          final scoreA = UrgencyScore(ratioConsumed: capRatio(consumedA, a.$3.capValue));
          final scoreB = UrgencyScore(ratioConsumed: capRatio(consumedB, b.$3.capValue));
          return scoreA.compareTo(scoreB);
        });

        final fuelRows = <(UserCard, CardProduct, FuelSurchargeRule)>[
          for (final (userCard, product) in owned)
            if (product.fuelRule != null) (userCard, product, product.fuelRule!),
        ];

        if (rows.isEmpty && fuelRows.isEmpty) {
          return const EmptyState(
            icon: Icons.speed_rounded,
            title: 'No caps to track',
            message: 'None of your cards have spend or reward caps — or you haven\'t added a card yet.',
          );
        }
        return ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            for (final (userCard, product, cap) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: _CapTile(userCard: userCard, product: product, cap: cap, allOwned: owned),
              ),
            if (fuelRows.isNotEmpty) ...[
              Text(
                'Fuel surcharge waivers',
                style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
              ),
              const SizedBox(height: AppSpace.sm),
              for (final (userCard, product, fuel) in fuelRows)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _FuelSurchargeTile(userCard: userCard, product: product, fuel: fuel),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _CapTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final CapRule cap;
  final List<(UserCard, CardProduct)> allOwned;
  const _CapTile({required this.userCard, required this.product, required this.cap, required this.allOwned});

  @override
  Widget build(BuildContext context) {
    final consumed = userCard.capConsumed[cap.id] ?? const Money.zero();
    final remainingPaise = (cap.capValue.paise - consumed.paise).clamp(0, cap.capValue.paise);
    final remaining = Money.fromPaise(remainingPaise);
    final ratio = cap.capValue.isZero ? 0.0 : (consumed.paise / cap.capValue.paise).clamp(0.0, 1.0);

    final Color barColor;
    final String headline;
    if (ratio >= 0.9) {
      barColor = BambooInk.clay;
      headline = cap.measure == CapMeasure.txnCount
          ? '${remaining.rupees.toInt()} transactions left'
          : '${remaining.format()} left';
    } else if (ratio >= 0.5) {
      barColor = _amber;
      headline = cap.measure == CapMeasure.txnCount
          ? '${remaining.rupees.toInt()} transactions left'
          : '${remaining.format()} left';
    } else {
      barColor = BambooInk.jade;
      headline = cap.measure == CapMeasure.txnCount
          ? '${remaining.rupees.toInt()} transactions left'
          : '${remaining.format()} left';
    }

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cap.label, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                    const SizedBox(height: 2),
                    Text(
                      userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
              if (ratio >= 0.9)
                const Icon(Icons.warning_amber_rounded, size: 16, color: BambooInk.clay)
              else if (ratio >= 0.5)
                const Icon(Icons.info_outline_rounded, size: 16, color: _amber),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: BambooInk.paperMuted,
              color: barColor,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                headline,
                style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: barColor),
              ),
              if (cap.measure != CapMeasure.txnCount)
                MoneyText(
                  consumed,
                  confidence: Confidence.estimated,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                )
              else
                Text(
                  '${consumed.rupees.toInt()} / ${cap.capValue.rupees.toInt()}',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
            ],
          ),
          if (ratio >= 0.9) ...[
            const SizedBox(height: AppSpace.sm),
            _SwitchToSuggestion(currentCard: userCard, cap: cap, allOwned: allOwned),
          ],
        ],
      ),
    );
  }
}

/// "₹300 left on X — switch to Y after that" — reuses
/// `RecommendationEngine.rank()` filtered to the cap's own category,
/// excluding the current card, rather than a second ranking path (E2's own
/// task note in the plan). Renders nothing when the cap has no category
/// (a whole-card cap) or no other owned card is eligible in it — silence,
/// not a misleading suggestion.
class _SwitchToSuggestion extends StatelessWidget {
  final UserCard currentCard;
  final CapRule cap;
  final List<(UserCard, CardProduct)> allOwned;
  const _SwitchToSuggestion({required this.currentCard, required this.cap, required this.allOwned});

  @override
  Widget build(BuildContext context) {
    if (cap.categoryId == null) return const SizedBox.shrink();
    final others = allOwned.where((p) => p.$1.id != currentCard.id).toList();
    if (others.isEmpty) return const SizedBox.shrink();

    const engine = RecommendationEngine();
    final snapshots = [for (final (_, product) in others) CardSnapshot(product: product)];
    final ranked = engine.rank(
      RecommendationContext(
        amount: const Money.fromPaise(100000), // nominal ₹1,000 — ranking only cares about relative rate
        categoryId: cap.categoryId,
        rail: TxnRail.swipe,
      ),
      snapshots,
    );
    final best = ranked.where((r) => !r.isExcluded).firstOrNull;
    if (best == null) return const SizedBox.shrink();

    final bestOwned = others.firstWhere((p) => p.$2.id == best.card.id);
    final label = bestOwned.$1.nickname?.isNotEmpty == true ? bestOwned.$1.nickname! : best.card.name;
    return Text(
      'Switch to $label after this cap',
      style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.jade),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _FuelSurchargeTile extends StatelessWidget {
  final UserCard userCard;
  final CardProduct product;
  final FuelSurchargeRule fuel;
  const _FuelSurchargeTile({required this.userCard, required this.product, required this.fuel});

  @override
  Widget build(BuildContext context) {
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
          Text(
            userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name,
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: 4),
          Text(
            '${fuel.waiverPercent.toStringAsFixed(2)}% surcharge waived'
            '${fuel.minTxn != null ? " on spends above ${fuel.minTxn!.format()}" : ""}'
            '${fuel.maxTxn != null ? " up to ${fuel.maxTxn!.format()}" : ""}',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500),
          ),
        ],
      ),
    );
  }
}
