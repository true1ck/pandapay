import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/tutorial_keys.dart';
import '../../data/api_exception.dart';
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';
import '../calculator/big_purchase_calculator_screen.dart';
import '../comparison/comparison_view_screen.dart';
import '../overrides/manual_overrides_screen.dart';
import '../quickadd/quick_add_screen.dart';
import '../search/merchant_search_screen.dart';
import 'home_alerts.dart';
import 'home_context_line.dart';

/// B1 Home, restyled onto the "Bamboo Ink" design system from the Claude
/// Design handoff (`PandaPay Redesign.dc.html` — see that bundle's
/// `chats/chat1.md`/`chat2.md` for how the system was arrived at, and
/// [BambooInk]'s own doc-comment in app_theme.dart for why it's landed
/// additively rather than as a global theme swap). This is a VISUAL
/// restyle on top of the real functionality B1 already had — every
/// provider wired here is the same real one, nothing is mocked to look
/// good:
///
/// - Amount entry, category chips, offline banner, alerts strip, the
///   ranked list (hero + backup + rest), "Why this card?"/"Compare all
///   cards", and the override pill are unchanged in behaviour from
///   before this pass — only their visuals moved.
/// - The mockup's greeting line personalizes with a name and a login
///   streak ("Evening, Aarav" / "14-day streak") — neither exists as
///   real data anywhere in this codebase (no `name` field on the
///   profile API, no streak tracking at all), so neither is faked here;
///   the header shows a real time-of-day greeting only (via
///   `clockProvider`, never `DateTime.now()` directly — see
///   `no_datetime_now_outside_clock` in packages/pandapay_lints).
/// - The mockup's "Saved with PandaPay — ₹24,180 since Mar 2024" strip
///   is backed by `MonthlyReport.extraEarned`, which `GET
///   /monthly-reports` always returns as a hardcoded 0 (see that
///   route's own doc-comment in api/src/index.js — the historical
///   recompute it needs doesn't exist yet). Showing it would mean
///   showing ₹0 forever, which is exactly the "never display a number
///   the app can't justify" rule this codebase applies everywhere else
///   (see MonthlySavingsScreen). [_MonthlyRewardsStrip] shows the one
///   figure that IS real instead — this month's actual rewards earned —
///   and taps through to the real Monthly Savings Report screen.
/// - The mockup's hero-card "Pay with this card" primary button has no
///   real destination on Home: there's no merchant/payee bound at this
///   point in the flow (that only exists after a UPI QR scan — see
///   ScanResultScreen's real "Pay with [card]" button, reachable from
///   the shell's own "Scan a UPI QR to pay" entry point). Adding a
///   same-looking button here with nothing real behind it would be
///   exactly the kind of decorative dead end this pass is trying not to
///   ship, so it's left out; "Compare all cards" (real, tested, unchanged)
///   is the hero card's one action.
/// - AppBar/BottomAppBar (app/router.dart's `_AppShell`) are NOT
///   restyled this pass — they're shared chrome across all four tabs
///   and covered by shell-level tests (router_test.dart,
///   router_onboarding_test.dart, tutorial_overlay_test.dart) that
///   assert on their exact structure/copy. Confirmed with the user as
///   next-phase scope, not silently skipped.
///
/// Missing vs the full ui-spec B1 (unchanged from before this pass):
/// offline bundling. Hero-card treatment, the backup-card row, the
/// alerts strip, and the geofence-driven context line (HomeContextLine
/// in home_context_line.dart, untouched by this pass) are done.
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

  static const _gutter = 20.0;

  static String _greetingFor(DateTime now) {
    if (now.hour < 12) return 'Good morning';
    if (now.hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final ranked = ref.watch(rankedRecommendationsProvider);
    final signedIn = ref.watch(accessTokenProvider) != null;
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    final now = ref.watch(clockProvider).now();

    return DecoratedBox(
      // The mockup's screens sit on white under a faint bamboo wash
      // falling from the top-right, not a flat fill.
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0.9, -0.7),
          radius: 1.3,
          colors: [BambooInk.wash, BambooInk.paper],
          stops: [0.0, 0.6],
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: AppSpace.xxxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpace.sm),
            Padding(
              padding: const EdgeInsets.fromLTRB(_gutter, 0, _gutter, 0),
              child: _BrandHeader(greeting: _greetingFor(now)),
            ),
            const SizedBox(height: AppSpace.md),
            // B5 entry point (unchanged from before this pass): a search
            // icon, quick-add, and calculator alongside the geofence-driven
            // context line — HomeScreen has no AppBar of its own (that
            // lives in _AppShell in router.dart), so this Row is where
            // those three actions live.
            Padding(
              padding: const EdgeInsets.fromLTRB(_gutter, 0, 8, 0),
              child: Row(
                children: [
                  const Expanded(child: HomeContextLine()),
                  IconButton(
                    tooltip: 'Search merchants',
                    icon: const Icon(Icons.search_rounded, size: 20, color: BambooInk.ink500),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MerchantSearchScreen())),
                  ),
                  IconButton(
                    tooltip: 'Quick add a transaction',
                    icon: const Icon(Icons.add_circle_outline_rounded, size: 20, color: BambooInk.ink500),
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickAddScreen())),
                  ),
                  IconButton(
                    tooltip: 'Big-purchase calculator',
                    icon: const Icon(Icons.calculate_outlined, size: 20, color: BambooInk.ink500),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => const BigPurchaseCalculatorScreen())),
                  ),
                ],
              ),
            ),
            if (!signedIn)
              const Padding(
                padding: EdgeInsets.fromLTRB(_gutter, AppSpace.md, _gutter, 0),
                child: _SignInBanner(),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(_gutter, AppSpace.md, _gutter, 0),
              child: _MonthlyRewardsStrip(),
            ),
            Padding(
              key: tutorialKeys.amountField,
              padding: const EdgeInsets.fromLTRB(_gutter, AppSpace.md, _gutter, 0),
              child: const _AmountCard(),
            ),
            const SizedBox(height: AppSpace.lg),
            SizedBox(
              key: tutorialKeys.categoryChips,
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: _gutter),
                children: [
                  for (final (slug, label, icon) in _categories)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpace.sm),
                      child: _CategoryChip(
                        label: label,
                        icon: icon,
                        selected: selectedCategory == slug,
                        onTap: () => ref.read(selectedCategoryProvider.notifier).state = slug,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            const _OfflineBanner(),
            const _AlertsStrip(),
            const SizedBox(height: AppSpace.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _gutter),
              child: _RankedSection(ranked: ranked, tutorialKeys: tutorialKeys),
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  final String greeting;
  const _BrandHeader({required this.greeting});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: BambooInk.paper,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          child: const PandaMark(size: 36),
        ),
        const SizedBox(width: AppSpace.md),
        Expanded(child: Text(greeting, style: BambooFonts.heading(19))),
      ],
    );
  }
}

/// See [HomeScreen]'s doc-comment: this shows the one real figure the
/// backend actually computes (this month's rewards earned,
/// `MonthlyReport.rewardsEarned` from the real `GET /monthly-reports`),
/// not the mockup's `extraEarned`-based "saved vs. a single card" figure
/// — that field is hardcoded to 0 server-side today. Hidden entirely
/// while there's no real report yet, same "no data yet reads as nothing
/// to show, not a fabricated ₹0" rule MonthlySavingsScreen already
/// follows for the exact same field.
class _MonthlyRewardsStrip extends ConsumerWidget {
  const _MonthlyRewardsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(currentMonthlyReportProvider).valueOrNull;
    if (report == null || report.totalSpend.isZero) return const SizedBox.shrink();

    return GestureDetector(
      onTap: () => context.push(AppRoute.monthlySavings),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'REWARDS THIS MONTH',
                    style: BambooFonts.ui(11, weight: FontWeight.w600, color: BambooInk.onSlateMuted)
                        .copyWith(letterSpacing: 1.1),
                  ),
                  const SizedBox(height: 4),
                  MoneyText(
                    report.rewardsEarned,
                    confidence: Confidence.estimated,
                    style: BambooFonts.money(24, color: BambooInk.lime),
                  ),
                ],
              ),
            ),
            Text('Details ›', style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.lime)),
          ],
        ),
      ),
    );
  }
}

class _SignInBanner extends StatelessWidget {
  const _SignInBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [BambooInk.slateRaised, BambooInk.slate],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: const Icon(Icons.person_outline_rounded, color: BambooInk.onSlate, size: 20),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("You're browsing as a guest", style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.onSlate)),
                const SizedBox(height: 2),
                Text('Sign in to track your own cards & spend', style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: BambooInk.lime,
              foregroundColor: BambooInk.slate,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
              textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
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

class _CategoryChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? BambooInk.slate : BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(999),
          border: selected ? null : Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? BambooInk.lime : BambooInk.ink500),
            const SizedBox(width: 6),
            Text(
              label,
              style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: selected ? BambooInk.onSlate : BambooInk.ink900),
            ),
          ],
        ),
      ),
    );
  }
}

/// UA-0.3 offline cache (GAP_ANALYSIS.md §2): visible only when the device
/// currently reads as offline — catalogueProvider/userCardsProvider/
/// cardOverridesProvider fall back to last-cached data silently underneath
/// this, so without this banner a user has no way to tell the ranked list
/// they're looking at might be stale. Pending-outbox count only shown when
/// non-zero, matching this screen's "don't show an empty state as if it
/// were content" pattern elsewhere. Unchanged in behaviour from before
/// this pass — only restyled.
class _OfflineBanner extends ConsumerWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOnline = ref.watch(isOnlineProvider).valueOrNull ?? true;
    if (isOnline) return const SizedBox.shrink();

    final pendingCount = ref.watch(pendingOutboxCountProvider).valueOrNull ?? 0;
    final message = pendingCount > 0
        ? "You're offline — showing your last synced cards. "
            '$pendingCount transaction${pendingCount == 1 ? '' : 's'} will sync when you\'re back.'
        : "You're offline — showing your last synced cards.";

    return Padding(
      padding: const EdgeInsets.fromLTRB(HomeScreen._gutter, AppSpace.md, HomeScreen._gutter, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.sm),
        decoration: BoxDecoration(
          color: BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 16, color: BambooInk.ink500),
            const SizedBox(width: AppSpace.sm),
            Expanded(child: Text(message, style: BambooFonts.ui(12.5, color: BambooInk.ink500))),
          ],
        ),
      ),
    );
  }
}

/// ui-spec B1.6 alerts strip. Unchanged in behaviour from before this
/// pass (same computeHomeAlerts, same "max 2 at once" cap) — only
/// restyled to the mockup's warning-card look.
class _AlertsStrip extends ConsumerWidget {
  const _AlertsStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userCards = ref.watch(userCardsProvider);
    final catalogue = ref.watch(catalogueProvider);
    if (!userCards.hasValue || !catalogue.hasValue) return const SizedBox.shrink();

    final now = ref.watch(clockProvider).now();
    final alerts = computeHomeAlerts(wallet: userCards.requireValue, catalogue: catalogue.requireValue, now: now)
        .take(2)
        .toList();
    if (alerts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(HomeScreen._gutter, AppSpace.md, HomeScreen._gutter, 0),
      child: Column(
        children: [
          for (final alert in alerts)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.xs),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
              decoration: BoxDecoration(
                color: BambooInk.warningBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: BambooInk.warningBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    margin: const EdgeInsets.only(top: 1),
                    decoration: const BoxDecoration(color: BambooInk.clay, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // Icon + text label together, not color alone, carry the
                  // "this needs attention" signal — a clay-only box would
                  // fail for colorblind users.
                  Expanded(child: Text(alert.message, style: BambooFonts.ui(13, color: BambooInk.ink900))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Chunk 19: the real amount-entry field — everything downstream (ranking
/// here, and Cards' "log spend" button via the same enteredAmountProvider)
/// reads this same provider. Unchanged in behaviour from before this pass
/// (still a single real `TextField` bound to `enteredAmountProvider`,
/// still the first `TextField` on this screen — see
/// test/widget_test.dart's `find.byType(TextField).first`) — restyled
/// into a glass card, with quick-preset chips added as a second, real way
/// to set the same provider (not a second source of truth).
class _AmountCard extends ConsumerStatefulWidget {
  const _AmountCard();
  @override
  ConsumerState<_AmountCard> createState() => _AmountCardState();
}

class _AmountCardState extends ConsumerState<_AmountCard> {
  late final TextEditingController _controller;

  static const _quickAmounts = [500.0, 1000.0, 2000.0, 5000.0];

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

  void _setAmount(double rupees) {
    setState(() => _controller.text = rupees.toStringAsFixed(0));
    ref.read(enteredAmountProvider.notifier).state = Money.fromRupees(rupees);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: [
          BoxShadow(color: BambooInk.ink900.withValues(alpha: 0.06), blurRadius: 10, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('How much are you spending?', style: BambooFonts.ui(12.5, weight: FontWeight.w500, color: BambooInk.ink500)),
              Text('Tap to change', style: BambooFonts.ui(12, color: BambooInk.ink300)),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
            style: BambooFonts.money(40),
            decoration: InputDecoration(
              // filled: false — without this, the ambient InputDecorationTheme
              // (app_theme.dart's AppTheme.light()/.dark(), still applied
              // globally) fills every TextField with AppColors.surfaceMuted by
              // default, which would paint a mismatched grey box inside this
              // widget's own glass Container.
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              prefixText: '₹ ',
              prefixStyle: BambooFonts.money(28, color: BambooInk.ink500),
            ),
            onChanged: (value) {
              final parsed = double.tryParse(value);
              if (parsed != null && parsed >= 0) {
                ref.read(enteredAmountProvider.notifier).state = Money.fromRupees(parsed);
              }
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (var i = 0; i < _quickAmounts.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: i == _quickAmounts.length - 1 ? 0 : 8),
                    child: _QuickAmountChip(
                      label: '₹${_quickAmounts[i].toStringAsFixed(0)}',
                      onTap: () => _setAmount(_quickAmounts[i]),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuickAmountChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickAmountChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(14)),
        child: Text(label, style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900)),
      ),
    );
  }
}

/// The ranked list (hero + backup + rest), lifted out of its own
/// `ListView.builder`/`Expanded` (before this pass, Home's header was
/// fixed and only the list scrolled) into a plain `Column` inside the
/// whole-screen scroll, matching the mockup's single continuous scroll.
/// A plain `Column` diffs children by `Key` the same way
/// `SliverChildBuilderDelegate` does when it can find one — the
/// `findChildIndexCallback` the old `ListView.builder` needed specifically
/// to make that work for lazily-built children isn't needed here, but the
/// underlying reason for it (a reorder must move each card's `Element` —
/// and its `_expanded` state — WITH it, not reset it) still applies, so
/// every card keeps its `ValueKey(card.id)` exactly as before.
class _RankedSection extends ConsumerWidget {
  final AsyncValue<List<Recommendation>> ranked;
  final TutorialKeys tutorialKeys;
  const _RankedSection({required this.ranked, required this.tutorialKeys});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ranked.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      ),
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
        // (index 0), if one exists.
        final backup = recommendations.skip(1).firstWhereOrNull((r) => !r.isExcluded);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Row(
                children: [
                  const PandaMark(size: 22),
                  const SizedBox(width: 8),
                  Text('Panda says use', style: BambooFonts.heading(15)),
                ],
              ),
            ),
            for (var i = 0; i < recommendations.length; i++) ...[
              Padding(
                key: ValueKey(recommendations[i].card.id),
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                // NOTE: the tutorial anchor GlobalKey is passed in as a
                // plain constructor field (cardAnchorKey), not attached as
                // this widget's own Key — see _RecommendationCard's
                // doc-comment for why a rank-based GlobalKey must never be
                // this widget's identity key.
                child: _RecommendationCard(
                  recommendations[i],
                  rank: i,
                  cardAnchorKey: i == 0 ? tutorialKeys.firstRecommendationCard : null,
                ),
              ),
              if (i == 0 && backup != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: _BackupCardRow(backup),
                ),
            ],
          ],
        );
      },
    );
  }
}

/// ui-spec B1.4 backup card row. Unchanged in behaviour from before this
/// pass — see the original file's doc-comment (preserved in git history)
/// for why this is the next-best ranked card, not real crowdsourced
/// acceptance data.
class _BackupCardRow extends StatelessWidget {
  final Recommendation backup;
  const _BackupCardRow(this.backup);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: BambooInk.paperMuted, borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          const Icon(Icons.swap_horiz_rounded, size: 16, color: BambooInk.ink500),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                children: [
                  const TextSpan(text: 'If not accepted: '),
                  TextSpan(text: backup.card.name, style: const TextStyle(fontWeight: FontWeight.w600, color: BambooInk.ink900)),
                ],
              ),
            ),
          ),
          MoneyText(
            backup.expectedValue,
            confidence: backup.confidence,
            style: BambooFonts.ui(12.5, weight: FontWeight.w600, color: BambooInk.ink900),
          ),
        ],
      ),
    );
  }
}

class _RecommendationCard extends StatefulWidget {
  final Recommendation recommendation;
  final int rank;
  // Anchor GlobalKey for the onboarding tutorial overlay to measure this
  // card's position when it's the rank-0 (hero) card. Deliberately NOT
  // this widget's own `key` — this widget's identity (and thus its
  // State's _expanded flag) must be keyed only by card id (see
  // _RankedSection above), never by a rank-based GlobalKey, which would
  // silently re-introduce a per-card state leak on reorder via a
  // different mechanism.
  final Key? cardAnchorKey;
  const _RecommendationCard(this.recommendation, {required this.rank, this.cardAnchorKey});

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

    return Container(
      key: widget.cardAnchorKey,
      decoration: BoxDecoration(
        // ui-spec B1.2: the hero card gets its own art/color treatment,
        // not just a thin border like every other ranked-list row — a
        // slate gradient with a lime money figure so it reads as "the
        // answer" at a glance, matching B1's "answer 'which card?' in
        // under 500ms" purpose statement.
        gradient: isHero
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
              )
            : null,
        color: isHero ? null : (excluded ? BambooInk.paperMuted : BambooInk.glassFillOnPaper),
        borderRadius: BorderRadius.circular(isHero ? 28 : 20),
        border: isHero ? null : Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: isHero
            ? [BoxShadow(color: BambooInk.slate.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 12))]
            : null,
      ),
      padding: EdgeInsets.all(isHero ? 22 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (isHero) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                        decoration: BoxDecoration(color: BambooInk.lime, borderRadius: BorderRadius.circular(999)),
                        child: Text(
                          'BEST',
                          style: BambooFonts.ui(11, weight: FontWeight.w700, color: BambooInk.slate)
                              .copyWith(letterSpacing: 0.6),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Flexible(
                      child: Text(
                        recommendation.card.name,
                        style: BambooFonts.heading(
                          17,
                          color: isHero ? BambooInk.onSlate : (excluded ? BambooInk.ink500 : BambooInk.ink900),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (recommendation.isOverride)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ConstrainedBox(
                    // The pill itself stays small, but the tappable region
                    // is padded out to the 48x48dp minimum touch target so
                    // it's usable, not just visible.
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    child: GestureDetector(
                      // B8 chip requirement: tapping the "override active"
                      // pill takes the user straight to where they can
                      // see/undo it.
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ManualOverridesScreen()),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: isHero ? Colors.white.withValues(alpha: 0.16) : BambooInk.paperMuted,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.push_pin_rounded, size: 12, color: isHero ? BambooInk.onSlate : BambooInk.ink900),
                              const SizedBox(width: 4),
                              Text(
                                'Override active',
                                style: BambooFonts.ui(11, weight: FontWeight.w600, color: isHero ? BambooInk.onSlate : BambooInk.ink900),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (excluded)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.block_rounded, size: 16, color: BambooInk.ink500),
                const SizedBox(width: 6),
                Expanded(child: Text(recommendation.exclusionReason!, style: BambooFonts.ui(13, color: BambooInk.ink500))),
              ],
            )
          else ...[
            MoneyText(
              recommendation.expectedValue,
              confidence: recommendation.confidence,
              style: isHero ? BambooFonts.money(40, color: BambooInk.lime) : BambooFonts.money(22, color: BambooInk.ink900),
            ),
            const SizedBox(height: 6),
            // ui-spec B1.3 "Why this card?" — collapsed to the first reason
            // line by default, full arithmetic behind an explicit tap.
            if (recommendation.reasonLines.isNotEmpty) ...[
              Text(
                '•  ${recommendation.reasonLines.first}',
                style: BambooFonts.ui(13, color: isHero ? BambooInk.onSlateSubtle : BambooInk.ink500),
              ),
              if (recommendation.reasonLines.length > 1) ...[
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
                              style: BambooFonts.ui(13, weight: FontWeight.w600, color: isHero ? BambooInk.lime : BambooInk.jade),
                            ),
                            Icon(
                              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                              size: 18,
                              color: isHero ? BambooInk.lime : BambooInk.jade,
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
                              style: BambooFonts.ui(13, color: isHero ? BambooInk.onSlateSubtle : BambooInk.ink500),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
          // ui-spec B4 entry point: only the hero card gets this — see
          // HomeScreen's doc-comment for why there's no "Pay with this
          // card" button here (no real payee bound at this point in the
          // flow).
          if (isHero) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: BambooInk.slateHairline),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
                style: TextButton.styleFrom(foregroundColor: BambooInk.lime),
                child: const Text('Compare all cards'),
              ),
            ),
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
