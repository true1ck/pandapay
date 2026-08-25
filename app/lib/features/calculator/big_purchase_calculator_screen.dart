import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/card_overrides_repository.dart' show CardOverride;
import '../../data/override_resolver.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../tools/emi_advisor_screen.dart';
import '../tools/split_planner_screen.dart';

/// ui-spec B7. "Split suggestion" pushes G2 Split Planner and "EMI
/// comparison" pushes G3 EMI Advisor — both screens carry their own amount
/// input (splitPlannerAmountProvider / EmiAdvisorScreen's own principal
/// field), so this screen's local `_amount` isn't threaded through; a user
/// arriving from B7 re-enters the figure there, same as arriving at G2/G3
/// any other way (from Tools Hub). Originally shipped disabled with a
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
  ConsumerState<BigPurchaseCalculatorScreen> createState() => _BigPurchaseCalculatorScreenState();
}

class _BigPurchaseCalculatorScreenState extends ConsumerState<BigPurchaseCalculatorScreen> {
  late final TextEditingController _amountController;
  Money _amount = Money.fromRupees(50000);
  String? _categoryId;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(text: _amount.rupees.toStringAsFixed(0));
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
        title: Text('Big-purchase calculator', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Amount',
                style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink500),
              ),
              const SizedBox(height: AppSpace.sm),
              TextField(
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
                    borderSide: const BorderSide(color: BambooInk.hairlineOnPaper),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: BambooInk.slate, width: 1.5),
                  ),
                ),
                controller: _amountController,
                onChanged: (v) {
                  final parsed = double.tryParse(v);
                  if (parsed != null && parsed >= 0) setState(() => _amount = Money.fromRupees(parsed));
                },
              ),
              const SizedBox(height: AppSpace.md),
              categories.when(
                loading: () => const LinearProgressIndicator(),
                error: (err, _) => Text(userFacingErrorMessage(err)),
                data: (list) => Wrap(
                  spacing: AppSpace.xs,
                  children: [
                    for (final c in list)
                      ChoiceChip(
                        label: Text(c.name),
                        labelStyle: BambooFonts.ui(
                          13,
                          weight: FontWeight.w600,
                          color: _categoryId == c.id ? BambooInk.onSlate : BambooInk.ink900,
                        ),
                        selected: _categoryId == c.id,
                        selectedColor: BambooInk.slate,
                        backgroundColor: BambooInk.paperMuted,
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        onSelected: (_) => setState(() => _categoryId = c.id),
                      ),
                  ],
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
                        side: const BorderSide(color: BambooInk.hairlineOnPaper),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (_) => const SplitPlannerScreen())),
                      child: const Text('Split suggestion'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: BambooInk.ink900,
                        minimumSize: const Size.fromHeight(48),
                        side: const BorderSide(color: BambooInk.hairlineOnPaper),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (_) => const EmiAdvisorScreen())),
                      child: const Text('EMI comparison'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpace.lg),
              Expanded(child: _buildResults(catalogue, userCards, engine, overrides)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(
    AsyncValue<List<CardProduct>> catalogue,
    AsyncValue<List<UserCard>> userCards,
    RecommendationEngine engine,
    AsyncValue<List<CardOverride>> overrides,
  ) {
    if (catalogue.isLoading || userCards.isLoading || overrides.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final combinedError = catalogue.error ?? userCards.error ?? overrides.error;
    if (combinedError != null) return ErrorState(message: userFacingErrorMessage(combinedError));

    final allCards = catalogue.requireValue;
    final wallet = userCards.requireValue;
    if (wallet.isEmpty) {
      return const EmptyState(
        icon: Icons.credit_card_off_rounded,
        title: 'No cards yet',
        message: 'Add a card to compare a big purchase across your wallet.',
      );
    }
    final owned = allCards.where((c) => wallet.any((w) => w.cardProductId == c.id)).toList();

    final context = RecommendationContext(
      amount: _amount,
      categoryId: _categoryId,
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
      categoryId: _categoryId,
    );
    final snapshots = owned.map((c) {
      final uc = wallet.where((w) => w.cardProductId == c.id).first;
      final capRemaining = {
        for (final cap in c.capRules)
          if (uc.capConsumed.containsKey(cap.id)) cap.id: cap.capValue - uc.capConsumed[cap.id]!,
      };
      return CardSnapshot(
        product: c,
        capRemaining: capRemaining,
        milestoneProgress: uc.milestoneQualifiedSpend,
        forcedOverrideCardId: overrideProductId,
      );
    }).toList();

    final ranked = engine.rank(context, snapshots);
    return ListView.builder(
      itemCount: ranked.length,
      itemBuilder: (context, index) {
        final rec = ranked[index];
        // ui-spec B7.5: flag a milestone-completing purchase — the engine
        // already phrases this exactly in reasonLines ("completes ...
        // milestone"), so this reuses that text rather than reinventing
        // milestone-completion detection here.
        final completesMilestone = rec.reasonLines.any(
          (l) => l.contains('completes') && l.contains('milestone'),
        );
        return Card(
          key: ValueKey(rec.card.id),
          color: completesMilestone ? const Color(0xFFE3F3EA) : BambooInk.glassFillOnPaper,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
              color: completesMilestone ? BambooInk.jade.withValues(alpha: 0.4) : BambooInk.hairlineOnPaper,
            ),
          ),
          margin: const EdgeInsets.only(bottom: AppSpace.sm),
          child: ListTile(
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    rec.card.name,
                    style: BambooFonts.heading(15, color: BambooInk.ink900),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (rec.isOverride) ...[
                  const SizedBox(width: AppSpace.xs),
                  const StatusPill(
                    label: 'Override active',
                    foreground: BambooInk.ink900,
                    background: BambooInk.paperMuted,
                    icon: Icons.push_pin_rounded,
                  ),
                ],
              ],
            ),
            subtitle: Text(
              rec.isExcluded ? rec.exclusionReason! : rec.reasonLines.join(' · '),
              style: BambooFonts.ui(12.5, color: BambooInk.ink500),
            ),
            trailing: rec.isExcluded
                ? null
                : MoneyText(
                    rec.expectedValue,
                    confidence: rec.confidence,
                    style: BambooFonts.money(16, color: BambooInk.ink900),
                  ),
          ),
        );
      },
    );
  }
}
