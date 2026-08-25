import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../main.dart' show MoneyText;

/// Design 31 "You're all set" — the final onboarding screen, reached from
/// Tracking Setup once onboarding is already marked complete. Pushed
/// imperatively (`Navigator.push`), not a go_router route: same "one-off,
/// looked-at-then-returns(-Home)" shape as A8/other single-destination
/// screens noted in router.dart's own AppRoute doc-comment, so it doesn't
/// need to fight the preOnboarding redirect guard (which would otherwise
/// bounce it straight back to Home the instant onboarding.complete flips
/// true, before the user ever sees it).
class AllSetScreen extends ConsumerWidget {
  const AllSetScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
    final cardNames = [for (final (uc, p) in owned) uc.nickname?.isNotEmpty == true ? uc.nickname! : p.name];

    return PopScope(
      canPop: false,
      child: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: AppSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: const LinearProgressIndicator(
                          value: 1,
                          minHeight: 6,
                          backgroundColor: BambooInk.paperMuted,
                          color: BambooInk.slate,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Text(
                      'Step 3 of 3',
                      style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.ink500),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: 72,
                            height: 72,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: BambooInk.paper,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: const PandaMark(size: 52),
                          ),
                          const SizedBox(height: AppSpace.lg),
                          Text(
                            cardNames.isEmpty
                                ? "You're all set"
                                : '${cardNames.length} card${cardNames.length == 1 ? '' : 's'} ready',
                            style: BambooFonts.heading(26, color: BambooInk.ink900),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            // The skip path ("I'll do this later") reaches
                            // this screen with an empty wallet — say what
                            // actually happens next instead of leaving the
                            // no-cards case with a bare title and a gap.
                            cardNames.isEmpty
                                ? "Add a card any time from Wallet and we'll start ranking for you."
                                : cardNames.join(' · '),
                            style: BambooFonts.ui(14, color: BambooInk.ink500),
                          ),
                          if (cardNames.isNotEmpty) ...[
                            const SizedBox(height: AppSpace.xl),
                            const _TryItNowPreview(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slate,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                  ),
                  onPressed: () async {
                    // Onboarding completes HERE, not before this screen —
                    // see TrackingSetupScreen._finish()'s doc comment for
                    // the redirect-guard race this ordering avoids.
                    await ref.read(onboardingCompleteProvider.notifier).complete();
                    if (!context.mounted) return;
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    context.go(AppRoute.home);
                  },
                  child: const Text('Take me Home'),
                ),
                const SizedBox(height: AppSpace.sm),
                Center(
                  child: Text(
                    'This tour replays any time from You → Help.',
                    style: BambooFonts.ui(12, color: BambooInk.ink500),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Design 31's "Try it now" card, previewing a real answer rather than a
/// hardcoded ₹125 — runs the actual RecommendationEngine against the cards
/// just added for a representative ₹2,500 groceries scenario (the same
/// example the Tour used), so what's shown here is honest for whichever
/// cards this specific user has, not a copy-pasted demo number.
class _TryItNowPreview extends ConsumerWidget {
  const _TryItNowPreview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owned = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
    final categories = ref.watch(categoriesProvider).valueOrNull ?? const [];
    if (owned.isEmpty) return const SizedBox.shrink();

    final groceriesId = categories.where((c) => c.slug == 'groceries').firstOrNull?.id;
    final engine = ref.watch(recommendationEngineProvider);
    final snapshots = [
      for (final (_, product) in owned)
        CardSnapshot(product: product, capRemaining: const {}, milestoneProgress: const {}),
    ];
    final recContext = RecommendationContext(
      amount: Money.fromRupees(2500),
      categoryId: groceriesId,
      rail: TxnRail.swipe,
      now: DateTime.now(),
    );
    final ranked = engine.rank(recContext, snapshots).where((r) => !r.isExcluded).toList();
    if (ranked.isEmpty) return const SizedBox.shrink();
    final winner = ranked.first;

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TRY IT NOW · ₹2,500 GROCERIES',
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w600,
              color: BambooInk.onSlateMuted,
            ).copyWith(letterSpacing: 1),
          ),
          const SizedBox(height: AppSpace.sm),
          MoneyText(
            winner.expectedValue,
            confidence: winner.confidence,
            style: BambooFonts.money(32, color: BambooInk.lime),
          ),
          const SizedBox(height: 2),
          Text('with ${winner.card.name}', style: BambooFonts.ui(13.5, color: BambooInk.onSlateSubtle)),
        ],
      ),
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
