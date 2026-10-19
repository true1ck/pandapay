import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/category_picker.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart' show CardOverride;
import '../../data/catalogue_repository.dart'
    show SpendCategory, categoryIdForServer;
import '../../data/override_resolver.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../cards/card_visual.dart';
import '../tools/emi_advisor_screen.dart';
import '../tools/split_planner_screen.dart';

/// ui-spec B7. "Split suggestion" pushes G2 Split Planner and "EMI
/// comparison" pushes G3 EMI Advisor. The split planner starts with this
/// screen's purchase amount and keeps its own editable input. Originally shipped disabled with a
/// "Coming soon" snackbar before G2/G3 existed in this codebase — wired for
/// real once they landed.
///
/// Amount/category here are this screen's own local state, deliberately
/// independent of Home's `selectedCategoryProvider`/`enteredAmountProvider`
/// — a one-off "what if I spent this much on X" computation, same reasoning
/// ScanResultScreen (B3, Task 12) gives for its own local context in that
/// screen's header comment.
class BigPurchaseCalculatorScreen extends ConsumerStatefulWidget {
  const BigPurchaseCalculatorScreen({super.key});

  @override
  ConsumerState<BigPurchaseCalculatorScreen> createState() =>
      _BigPurchaseCalculatorScreenState();
}

class _BigPurchaseCalculatorScreenState
    extends ConsumerState<BigPurchaseCalculatorScreen> {
  late final TextEditingController _amountController;
  Money _amount = Money.fromRupees(50000);
  String? _categoryId;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: _amount.rupees.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalogue = ref.watch(catalogueProvider);
    final userCards = ref.watch(userCardsProvider);
    final categories = ref.watch(categoriesProvider);
    final engine = ref.watch(recommendationEngineProvider);
    final overrides = ref.watch(cardOverridesProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Big-purchase calculator',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Amount',
                style: BambooFonts.ui(
                  13,
                  weight: FontWeight.w600,
                  color: BambooInk.ink500,
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: BambooFonts.money(24, color: BambooInk.ink900),
                decoration: InputDecoration(
                  prefixText: '₹ ',
                  prefixStyle: BambooFonts.money(24, color: BambooInk.ink500),
                  filled: true,
                  fillColor: BambooInk.glassFillOnPaper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: BambooInk.hairlineOnPaper,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(
                      color: BambooInk.slate,
                      width: 1.5,
                    ),
                  ),
                ),
                controller: _amountController,
                onChanged: (v) {
                  final parsed = double.tryParse(v);
                  if (parsed != null && parsed >= 0)
                    setState(() => _amount = Money.fromRupees(parsed));
                },
              ),
              const SizedBox(height: AppSpace.md),
              categories.when(
                loading: () => const LinearProgressIndicator(),
                error: (err, _) => Text(userFacingErrorMessage(err)),
                data: (list) => _CategoryPicker(
                  categories: list,
                  selectedId: _categoryId,
                  onSelected: (value) => setState(() => _categoryId = value),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BambooInk.ink900,
                        minimumSize: const Size.fromHeight(48),
                        side: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SplitPlannerScreen(initialAmount: _amount),
                        ),
                      ),
                      child: const Text('Split suggestion'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BambooInk.ink900,
                        minimumSize: const Size.fromHeight(48),
                        side: const BorderSide(
                          color: BambooInk.hairlineOnPaper,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EmiAdvisorScreen(),
                        ),
                      ),
                      child: const Text('EMI comparison'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              Expanded(
                child: _buildResults(
                  catalogue,
                  userCards,
                  categories,
                  engine,
                  overrides,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<UserCard>> userCards,
    AsyncValue<List<SpendCategory>> categories,
    RecommendationEngine engine,
    AsyncValue<List<CardOverride>> overrides,
  ) {
    if (catalogue.isLoading || userCards.isLoading || overrides.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final combinedError = catalogue.error ?? userCards.error ?? overrides.error;
    if (combinedError != null)
      return ErrorState(message: userFacingErrorMessage(combinedError));

    final allCards = catalogue.requireValue;
    final wallet = userCards.requireValue;
    if (wallet.isEmpty) {
      return const EmptyState(
        icon: Icons.credit_card_off_rounded,
        title: 'No cards yet',
        message: 'Add a card to compare a big purchase across your wallet.',
      );
    }
    final owned = allCards
        .where((c) => wallet.any((w) => w.cardProductId == c.id))
        .toList();

    final effectiveCategoryId = categoryIdForServer(_categoryId);
    final categorySlug = effectiveCategoryId == null
        ? null
        : categories.valueOrNull
              ?.where((c) => c.id == effectiveCategoryId)
              .firstOrNull
              ?.slug;
    final context = RecommendationContext(
      amount: _amount,
      categoryId: effectiveCategoryId,
      categorySlug: categorySlug,
      rail: TxnRail.swipe,
      now: DateTime.now(),
    );
    // Same B8 wiring as rankedRecommendationsProvider (app/providers.dart):
    // this screen only carries category context (no merchant/vpa), so an
    // active category override must be honored here too — otherwise Home
    // and the calculator can silently recommend different cards for the
    // same category, contradicting each other with no explanation.
    final overrideProductId = resolveActiveOverrideCardProductId(
      overrides: overrides.requireValue,
      wallet: wallet,
      categoryId: effectiveCategoryId,
    );
    final snapshots = owned.map((c) {
      final uc = wallet.where((w) => w.cardProductId == c.id).first;
      final capRemaining = {
        for (final cap in uniqueCapRules(c.capRules))
          if (uc.capConsumed.containsKey(cap.id))
            cap.id: cap.capValue - uc.capConsumed[cap.id]!,
      };
      return CardSnapshot(
        product: c,
        capRemaining: capRemaining,
        milestoneProgress: uc.milestoneQualifiedSpend,
        forcedOverrideCardId: overrideProductId,
      );
    }).toList();

    final ranked = engine.rank(context, snapshots);
    final bestIndex = ranked.indexWhere(
      (recommendation) => !recommendation.isExcluded,
    );
    return ListView.builder(
      itemCount: ranked.length,
      itemBuilder: (context, index) {
        final rec = ranked[index];
        final isBest = index == bestIndex;
        // ui-spec B7.5: flag a milestone-completing purchase — the engine
        // already phrases this exactly in reasonLines ("completes ...
        // milestone"), so this reuses that text rather than reinventing
        // milestone-completion detection here.
        final completesMilestone = rec.reasonLines.any(
          (l) => l.contains('completes') && l.contains('milestone'),
        );
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Container(
            key: ValueKey(rec.card.id),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              color: isBest
                  ? BambooInk.lime
                  : (completesMilestone
                        ? const Color(0xFFE3F3EA)
                        : BambooInk.glassFillOnPaper),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: isBest
                    ? BambooInk.lime
                    : (completesMilestone
                          ? BambooInk.jade.withValues(alpha: 0.45)
                          : BambooInk.hairlineOnPaper),
                width: isBest ? 2 : 1,
              ),
              boxShadow: isBest
                  ? [
                      BoxShadow(
                        color: BambooInk.lime.withValues(alpha: 0.32),
                        blurRadius: 16,
                        offset: const Offset(0, 7),
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CardVisual(
                  product: rec.card,
                  height: isBest ? 136 : 112,
                  showProductName: false,
                ),
                const SizedBox(height: AppSpace.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isBest) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: BambooInk.slate,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'BEST PICK',
                          style: BambooFonts.ui(
                            10.5,
                            weight: FontWeight.w700,
                            color: BambooInk.lime,
                          ).copyWith(letterSpacing: 0.5),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                    ],
                    Expanded(
                      child: Text(
                        rec.card.name,
                        style: BambooFonts.heading(
                          16,
                          color: rec.isExcluded
                              ? BambooInk.ink500
                              : BambooInk.ink900,
                        ),
                      ),
                    ),
                    if (rec.isOverride)
                      StatusPill(
                        label: 'Override',
                        foreground: isBest ? BambooInk.slate : BambooInk.ink900,
                        background: isBest
                            ? Colors.white.withValues(alpha: 0.5)
                            : BambooInk.paperMuted,
                        icon: Icons.push_pin_rounded,
                      ),
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                if (rec.isExcluded)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.block_rounded,
                        size: 16,
                        color: BambooInk.ink500,
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Expanded(
                        child: Text(
                          rec.exclusionReason!,
                          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final line in rec.reasonLines.take(2))
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  line,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: BambooFonts.ui(
                                    12.5,
                                    color: isBest
                                        ? BambooInk.slate
                                        : BambooInk.ink500,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      MoneyText(
                        rec.expectedValue,
                        confidence: rec.confidence,
                        style: BambooFonts.money(
                          isBest ? 24 : 20,
                          color: BambooInk.ink900,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.hourglass_bottom_rounded,
                        size: 16,
                        color: BambooInk.clay,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CategoryPicker extends ConsumerWidget {
  final List<SpendCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelected;

  const _CategoryPicker({
    required this.categories,
    required this.selectedId,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CategoryPickerField(
      categories: categories,
      selectedId: selectedId,
      onSelected: onSelected,
      label: 'Purchase category',
    );
  }
}
