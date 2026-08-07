import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/tutorial_keys.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';
import '../overrides/manual_overrides_screen.dart';

/// B1 Home, cut down to what's real today: category chips + ranked list
/// with reason lines, backed by the actual engine and a live API fetch.
/// Deliberately usable signed-out (rankedRecommendationsProvider falls
/// back to the whole catalogue) — see the sign-in banner below for how a
/// signed-out visitor finds their way to an account.
/// Missing vs the full ui-spec B1: alerts strip, geofence-driven context
/// line, offline bundling — all noted as not-yet-done rather than faked.
/// Hero-card treatment and the backup-card row (see _BackupCardRow) are
/// done.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _categories = [
    ('groceries', 'Groceries', Icons.local_grocery_store_rounded),
    ('fuel', 'Fuel', Icons.local_gas_station_rounded),
    ('dining', 'Dining', Icons.restaurant_rounded),
    ('online', 'Online', Icons.shopping_bag_rounded),
    ('travel', 'Travel', Icons.flight_takeoff_rounded),
    ('bills', 'Bills', Icons.receipt_long_rounded),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final ranked = ref.watch(rankedRecommendationsProvider);
    final signedIn = ref.watch(accessTokenProvider) != null;
    final tutorialKeys = ref.watch(tutorialKeysProvider);

    return Column(
      children: [
        if (!signedIn) const _SignInBanner(),
        Padding(
          key: tutorialKeys.amountField,
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
          child: _AmountField(),
        ),
        const SizedBox(height: AppSpace.lg),
        SizedBox(
          key: tutorialKeys.categoryChips,
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            children: [
              for (final (slug, label, icon) in _categories)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpace.sm),
                  child: ChoiceChip(
                    avatar: Icon(
                      icon,
                      size: 16,
                      color: selectedCategory == slug ? AppColors.teal600 : AppColors.ink500,
                    ),
                    label: Text(label),
                    selected: selectedCategory == slug,
                    onSelected: (_) => ref.read(selectedCategoryProvider.notifier).state = slug,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Expanded(child: _RankedList(ranked: ranked)),
      ],
    );
  }
}

class _SignInBanner extends StatelessWidget {
  const _SignInBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.lg, AppSpace.lg, 0),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.navy900,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: const Icon(Icons.person_outline_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "You're browsing as a guest",
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sign in to track your own cards & spend',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: AppColors.navy900,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            ),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const Scaffold(body: LoginScreen())),
            ),
            child: const Text('Sign in'),
          ),
        ],
      ),
    );
  }
}

/// Chunk 19: the real amount-entry field — everything downstream (ranking
/// here, and Cards' "log spend" button via the same enteredAmountProvider)
/// was already correct, it was just fed a hardcoded ₹1,000 placeholder.
class _AmountField extends ConsumerStatefulWidget {
  const _AmountField();
  @override
  ConsumerState<_AmountField> createState() => _AmountFieldState();
}

class _AmountFieldState extends ConsumerState<_AmountField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    final initial = ref.read(enteredAmountProvider);
    _controller = TextEditingController(text: initial.rupees.toStringAsFixed(0));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("How much are you spending?", style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: AppSpace.sm),
        TextField(
          controller: _controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          decoration: const InputDecoration(
            prefixText: '₹  ',
          ),
          onChanged: (value) {
            final parsed = double.tryParse(value);
            if (parsed != null && parsed >= 0) {
              ref.read(enteredAmountProvider.notifier).state = Money.fromRupees(parsed);
            }
          },
        ),
      ],
    );
  }
}

class _RankedList extends ConsumerWidget {
  final AsyncValue<List<Recommendation>> ranked;
  const _RankedList({required this.ranked});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    return ranked.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(message: userFacingErrorMessage(err)),
      data: (recommendations) {
        if (recommendations.isEmpty) {
          return const EmptyState(
            icon: Icons.credit_card_off_rounded,
            title: 'No cards yet',
            message: 'Add a card to see personalized reward recommendations here.',
          );
        }
        // ui-spec B1.4: the first non-excluded runner-up after the hero
        // (index 0), if one exists — see _BackupCardRow's doc comment for
        // why this is "next-best ranked card" rather than real
        // crowdsourced acceptance data.
        final backup = recommendations.skip(1).firstWhereOrNull((r) => !r.isExcluded);
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.xxl),
          itemCount: recommendations.length + (backup != null ? 1 : 0),
          itemBuilder: (context, index) {
            if (backup != null && index == 1) {
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: _BackupCardRow(backup),
              );
            }
            final recIndex = (backup != null && index > 1) ? index - 1 : index;
            return Padding(
              key: recIndex == 0 ? tutorialKeys.firstRecommendationCard : null,
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              // Keyed by card identity, not just position: _RecommendationCard
              // is a StatefulWidget holding its own "Why this card?" expand
              // state, and ranked can reorder (category chip, amount edit).
              // Without a stable key, ListView.builder reuses the Element at
              // an index and the wrong card inherits the previous occupant's
              // expanded/collapsed state.
              child: _RecommendationCard(
                recommendations[recIndex],
                rank: recIndex,
                key: ValueKey(recommendations[recIndex].card.id),
              ),
            );
          },
        );
      },
    );
  }
}

/// ui-spec B1.4 backup card row, rendered once directly below the hero
/// card. Scope reduction, stated explicitly here: this shows the next-best
/// non-excluded card from the same already-ranked `rankedRecommendationsProvider`
/// list (the runner-up), not real crowdsourced acceptance data — the only
/// acceptance-data surface in this codebase today is the admin-gated
/// `GET /admin/acceptance-summary`, and building a public equivalent is a
/// whole crowdsourcing-pipeline surface out of scope for this delta.
class _BackupCardRow extends StatelessWidget {
  final Recommendation backup;
  const _BackupCardRow(this.backup);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz_rounded, size: 16, color: AppColors.ink500),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: Theme.of(context).textTheme.bodySmall,
                children: [
                  const TextSpan(text: 'If not accepted: '),
                  TextSpan(
                    text: backup.card.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          MoneyText(backup.expectedValue, confidence: backup.confidence, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _RecommendationCard extends StatefulWidget {
  final Recommendation recommendation;
  final int rank;
  const _RecommendationCard(this.recommendation, {required this.rank, super.key});

  @override
  State<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends State<_RecommendationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final recommendation = widget.recommendation;
    final excluded = recommendation.isExcluded;
    final isHero = widget.rank == 0 && !excluded;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      decoration: BoxDecoration(
        // ui-spec B1.2: the hero card gets its own art/color treatment,
        // not just a thin border like every other ranked-list row —
        // filled navy so it reads as "the answer" at a glance, matching
        // B1's "answer 'which card?' in under 500ms" purpose statement.
        color: isHero ? AppColors.navy900 : (excluded ? AppColors.surfaceMuted : AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: isHero ? null : Border.all(color: AppColors.ink100),
        boxShadow: isHero
            ? [BoxShadow(color: AppColors.navy900.withValues(alpha: 0.24), blurRadius: 16, offset: const Offset(0, 6))]
            : null,
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (isHero) ...[
                      const StatusPill(
                        label: 'BEST',
                        foreground: AppColors.navy900,
                        background: Colors.white,
                        icon: Icons.star_rounded,
                      ),
                      const SizedBox(width: AppSpace.sm),
                    ],
                    Flexible(
                      child: Text(
                        recommendation.card.name,
                        style: textTheme.titleMedium?.copyWith(
                          color: isHero ? Colors.white : (excluded ? AppColors.ink500 : AppColors.ink900),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (recommendation.isOverride)
                Padding(
                  padding: const EdgeInsets.only(left: AppSpace.xs),
                  child: ConstrainedBox(
                    // The pill itself stays small (StatusPill's own padding),
                    // but the tappable region is padded out to the 48x48dp
                    // minimum touch target so it's usable, not just visible.
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    child: GestureDetector(
                      // B8 chip requirement: tapping the "override active" pill
                      // takes the user straight to where they can see/undo it —
                      // an override silently steering advice with no visible
                      // way back is exactly the trust bug B8 exists to prevent.
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ManualOverridesScreen()),
                      ),
                      child: Center(
                        child: StatusPill(
                          label: 'Override active',
                          foreground: isHero ? Colors.white : AppColors.navy800,
                          background: isHero ? Colors.white.withValues(alpha: 0.16) : AppColors.surfaceMuted,
                          icon: Icons.push_pin_rounded,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (excluded)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.block_rounded, size: 16, color: AppColors.ink500),
                const SizedBox(width: AppSpace.xs),
                Expanded(
                  child: Text(recommendation.exclusionReason!, style: textTheme.bodySmall),
                ),
              ],
            )
          else ...[
            MoneyText(
              recommendation.expectedValue,
              confidence: recommendation.confidence,
              style: isHero ? textTheme.headlineMedium?.copyWith(color: Colors.white) : textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpace.xs),
            // ui-spec B1.3 "Why this card?" — collapsed to the first reason
            // line by default (short, scannable), full arithmetic behind an
            // explicit tap so the ranked list doesn't turn into a wall of
            // text for every card.
            if (recommendation.reasonLines.isNotEmpty) ...[
              Text(
                '•  ${recommendation.reasonLines.first}',
                style: textTheme.bodySmall?.copyWith(color: isHero ? Colors.white70 : null),
              ),
              if (recommendation.reasonLines.length > 1) ...[
                // Visual row stays compact; the InkWell's own min-size
                // constraint pads the tappable region out to 48x48dp
                // without inflating the pill/text's on-screen footprint.
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _expanded ? 'Hide the full breakdown' : 'Why this card?',
                              style: textTheme.labelMedium?.copyWith(
                                color: isHero ? AppColors.teal400 : AppColors.teal600,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Icon(
                              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                              size: 18,
                              color: isHero ? AppColors.teal400 : AppColors.teal600,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (_expanded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in recommendation.reasonLines.skip(1))
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '•  $line',
                              style: textTheme.bodySmall?.copyWith(color: isHero ? Colors.white70 : null),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
        ],
      ),
    );
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
