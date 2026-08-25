import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/offline_banner.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/tutorial_keys.dart';
import '../../data/api_exception.dart';
import '../../data/user_cards_repository.dart' show UserCard;
import '../../main.dart' show MoneyText;
import '../auth/login_screen.dart';
import '../comparison/comparison_view_screen.dart';
import '../insights/credit_utilization_screen.dart';
import '../overrides/manual_overrides_screen.dart';
import '../quickadd/quick_add_screen.dart';
import 'home_alerts.dart';
import 'home_context_line.dart';

/// B1 Home — design 01 "Home · the verdict". Section order, gutters, type
/// sizes and the header composition are transcribed from that mockup; the
/// functionality underneath is the real B1 feature set, nothing mocked:
///
/// - Amount entry, category chips, offline banner, alerts strip, the ranked
///   list (hero + backup + rest), "Why this card?"/"Compare all cards", and
///   the override pill are unchanged in behaviour — only their order and
///   visuals moved.
/// - The header's three figures ("₹1,842 earned", "₹24,180 all-time", a
///   "14-day streak" pill) are hardcoded in the mockup. Here they come from
///   `homeSummaryProvider` / `GET /home-summary`, which aggregates the
///   user's own transactions — and the whole line collapses to a bare
///   greeting when there's nothing real to aggregate (signed out, or no
///   transactions logged yet). Same rule the rest of the app follows: never
///   display a number the app can't point at a row for.
/// - The mockup's `MonthlyReport.extraEarned`-based "saved vs a single
///   card" figure is still not shown anywhere: `GET /monthly-reports`
///   returns it hardcoded to 0 (see that route's doc-comment) so it would
///   read as "you saved ₹0" forever.
/// - The mockup's three Home action icons (search / quick-add /
///   calculator) aren't on design 01 at all — the deck files those under
///   You → Tools (design 05), which is where they now live. Nothing became
///   unreachable.
/// - The greeting is time-of-day only, via `clockProvider`, never
///   `DateTime.now()` directly (see `no_datetime_now_outside_clock` in
///   packages/pandapay_lints). The mockup's "Evening, Aarav" needs a name
///   the profile API doesn't carry.
///
/// The shell (app/router.dart's `_AppShell`) deliberately draws no AppBar,
/// so this screen's own scroll padding covers the status bar — see that
/// file for why.
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

  /// Display label for a category slug, or null if it isn't one of Home's
  /// own chips (nothing selected, or a slug that came from elsewhere).
  static String? categoryLabelFor(String? slug) {
    for (final (s, label, _) in _categories) {
      if (s == slug) return label;
    }
    return null;
  }

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

    // Section order is design 01's, top to bottom: header, "What are you
    // paying for?", category chips, amount, "Panda says use" + the verdict,
    // backups, utilisation warning. It used to run header → action icons →
    // rewards strip → amount → chips, which buried the question the screen
    // exists to answer under two strips of chrome.
    return AppBackground(
      child: SingleChildScrollView(
        // 58pt top / 128pt bottom, the mockup's own scroll padding — the
        // top inset stands in for the status bar now that the shell has no
        // AppBar, and the shell reserves the bottom 128 for the nav pill.
        padding: EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top + AppSpace.sm,
          bottom: AppShell.navClearance,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(_gutter, 6, _gutter, 0),
              child: _BrandHeader(greeting: _greetingFor(now)),
            ),
            if (!signedIn)
              const Padding(
                padding: EdgeInsets.fromLTRB(_gutter, AppSpace.lg, _gutter, 0),
                child: _SignInBanner(),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(_gutter, 18, _gutter, 0),
              child: Text(
                'What are you paying for?',
                style: BambooFonts.heading(24, color: BambooInk.ink900, height: 1.15),
              ),
            ),
            // B5's geofence context ("you look like you're at X") reads as
            // the answer-in-progress to the heading above it, so it sits
            // directly under the question rather than in its own strip.
            const Padding(
              padding: EdgeInsets.fromLTRB(_gutter, AppSpace.xs, _gutter, 0),
              child: HomeContextLine(),
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
            Padding(
              key: tutorialKeys.amountField,
              padding: const EdgeInsets.fromLTRB(_gutter, AppSpace.lg, _gutter, 0),
              child: const _AmountCard(),
            ),
            const SizedBox(height: AppSpace.sm),
            OfflineBanner(
              gutter: _gutter,
              onRetry: () {
                ref.invalidate(catalogueProvider);
                ref.invalidate(userCardsProvider);
                ref.invalidate(cardOverridesProvider);
              },
            ),
            const _AlertsStrip(),
            const SizedBox(height: AppSpace.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _gutter),
              child: _RankedSection(ranked: ranked, tutorialKeys: tutorialKeys),
            ),
            const _UtilizationWarningBanner(),
            const SizedBox(height: AppSpace.lg),
          ],
        ),
      ),
    );
  }
}

/// Design 01's header row, transcribed from the mockup: a bare 42pt panda
/// mark (no bordered tile), then greeting-over-earnings, then a slate
/// streak pill. Tapping the earnings line opens the monthly recap, exactly
/// as the mockup's `<a href="#screen-recap">` does.
///
/// Every figure here comes from `homeSummaryProvider` (GET /home-summary).
/// Where the mockup hardcodes "₹1,842 earned · ₹24,180 all-time" and a
/// "14-day streak", this collapses to just the greeting when there's
/// nothing real to show — signed out, or signed in with no transactions
/// logged yet.
class _BrandHeader extends ConsumerWidget {
  final String greeting;
  const _BrandHeader({required this.greeting});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(homeSummaryProvider).valueOrNull;
    final hasEarnings = summary != null && summary.transactionCount > 0;

    return Row(
      children: [
        const PandaMark(size: 42),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(greeting, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              if (hasEarnings)
                GestureDetector(
                  onTap: () => context.push(AppRoute.monthlySavings),
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Flexible(
                        child: MoneyText(
                          summary.rewardsThisMonth,
                          confidence: Confidence.estimated,
                          style: BambooFonts.heading(17, color: BambooInk.ink900),
                          suffix: ' earned',
                          hidePaise: true,
                          // One confidence marker for the pair, on the
                          // all-time figure — not two on one 42pt row.
                          showConfidenceIcon: false,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: MoneyText(
                          summary.rewardsAllTime,
                          confidence: Confidence.estimated,
                          style: BambooFonts.ui(11.5, color: BambooInk.ink500),
                          suffix: ' all-time ›',
                          hidePaise: true,
                          showConfidenceIcon: false,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (summary != null && summary.streakDays > 0) ...[
          const SizedBox(width: AppSpace.sm),
          _StreakPill(days: summary.streakDays),
        ],
      ],
    );
  }
}

/// The slate "14-day streak" pill from design 01 — lime dot, lime label.
/// Shown only on a live streak (see GET /home-summary: a run that already
/// lapsed returns 0), so this never congratulates a user for a streak they
/// broke last week.
class _StreakPill extends StatelessWidget {
  final int days;
  const _StreakPill({required this.days});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(color: BambooInk.slate, borderRadius: BorderRadius.circular(AppRadius.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(color: BambooInk.lime, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            '$days-day streak',
            style: BambooFonts.ui(12, weight: FontWeight.w600, color: BambooInk.lime),
          ),
        ],
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
                Text(
                  "You're browsing as a guest",
                  style: BambooFonts.ui(14, weight: FontWeight.w600, color: BambooInk.onSlate),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sign in to track your own cards & spend',
                  style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted),
                ),
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
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const Scaffold(body: LoginScreen()))),
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
              style: BambooFonts.ui(
                13.5,
                weight: FontWeight.w600,
                color: selected ? BambooInk.onSlate : BambooInk.ink900,
              ),
            ),
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
    final alerts = computeHomeAlerts(
      wallet: userCards.requireValue,
      catalogue: catalogue.requireValue,
      now: now,
    ).take(2).toList();
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
                  Expanded(
                    child: Text(alert.message, style: BambooFonts.ui(13, color: BambooInk.ink900)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Design 01's clay utilisation banner ("SBI Cashback is 78% utilised —
/// paying before the due date protects your score"). E3 Credit Utilization
/// already computes this for real (creditUtilizationProvider, 30%-of-limit
/// bureau-guideline threshold) — this surfaces the single worst-utilised
/// card right on Home instead of leaving it a screen away. Same estimate
/// caveat as E3 itself (see creditUtilizationProvider's own doc comment):
/// "current balance" is a spend-proxy, not a real statement balance, so
/// this only fires once a card is actually over the 30% guideline, never a
/// fabricated number. Silent (no banner) for guest mode / cards with no
/// credit limit entered, same as E3.
class _UtilizationWarningBanner extends ConsumerWidget {
  const _UtilizationWarningBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
    final utilization = ref.watch(creditUtilizationProvider);
    if (pairs.isEmpty || utilization.isEmpty) return const SizedBox.shrink();

    (UserCard, CardProduct)? worst;
    UtilizationResult? worstResult;
    for (final pair in pairs) {
      final result = utilization[pair.$1.id];
      if (result == null || !result.overThreshold) continue;
      if (worstResult == null || result.ratio > worstResult.ratio) {
        worst = pair;
        worstResult = result;
      }
    }
    if (worst == null || worstResult == null) return const SizedBox.shrink();

    final (userCard, product) = worst;
    final name = userCard.nickname?.isNotEmpty == true ? userCard.nickname! : product.name;
    final pct = (worstResult.ratio * 100).toStringAsFixed(0);
    final now = ref.watch(clockProvider).now();
    final due = userCard.dueDay == null ? null : _nextOccurrence(userCard.dueDay!, now);
    final dueClause = due == null ? 'Paying it down' : 'Paying it down before ${due.day}/${due.month}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(HomeScreen._gutter, AppSpace.md, HomeScreen._gutter, 0),
      child: GestureDetector(
        onTap: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreditUtilizationScreen())),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
          decoration: BoxDecoration(
            color: BambooInk.warningBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BambooInk.warningBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 18, color: BambooInk.clay),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name is $pct% utilised',
                      style: BambooFonts.ui(13, weight: FontWeight.w700, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$dueClause protects your score.',
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static DateTime _nextOccurrence(int day, DateTime now) {
    var next = DateTime(now.year, now.month, day);
    if (!next.isAfter(now)) next = DateTime(now.year, now.month + 1, day);
    return next;
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
          BoxShadow(
            color: BambooInk.ink900.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'How much are you spending?',
                style: BambooFonts.ui(12.5, weight: FontWeight.w500, color: BambooInk.ink500),
              ),
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
        child: Text(
          label,
          style: BambooFonts.ui(13, weight: FontWeight.w600, color: BambooInk.ink900),
        ),
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
                  TextSpan(
                    text: backup.card.name,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: BambooInk.ink900),
                  ),
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

class _RecommendationCard extends ConsumerStatefulWidget {
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
  ConsumerState<_RecommendationCard> createState() => _RecommendationCardState();
}

class _RecommendationCardState extends ConsumerState<_RecommendationCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final recommendation = widget.recommendation;
    final excluded = recommendation.isExcluded;
    final isHero = widget.rank == 0 && !excluded;

    final card = Container(
      key: widget.cardAnchorKey,
      clipBehavior: isHero ? Clip.antiAlias : Clip.none,
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
            ? [
                BoxShadow(
                  color: BambooInk.slate.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
              ]
            : null,
      ),
      padding: EdgeInsets.all(isHero ? 22 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: isHero
                    // Design 01 stacks the verdict card's header: a
                    // "BEST PICK" badge and the rate it won at on one row,
                    // then the card name on its own line beneath. Inlining
                    // the name beside the badge (as this did) squeezed both
                    // and lost the rate line entirely.
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                                decoration: BoxDecoration(
                                  color: BambooInk.lime,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'BEST PICK',
                                  style: BambooFonts.ui(
                                    11,
                                    weight: FontWeight.w700,
                                    color: BambooInk.slate,
                                  ).copyWith(letterSpacing: 0.9),
                                ),
                              ),
                              if (_rateLabel(recommendation) != null) ...[
                                const SizedBox(width: 10),
                                Flexible(
                                  child: Text(
                                    _rateLabel(recommendation)!,
                                    style: BambooFonts.ui(12, color: BambooInk.onSlateMuted),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            recommendation.card.name,
                            style: BambooFonts.heading(20, color: BambooInk.onSlate),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (recommendation.breakdown != null)
                            _CapBadge(breakdown: recommendation.breakdown!, onDarkSurface: true),
                        ],
                      )
                    : Text(
                        recommendation.card.name,
                        style: BambooFonts.heading(17, color: excluded ? BambooInk.ink500 : BambooInk.ink900),
                        overflow: TextOverflow.ellipsis,
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
                      onTap: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (_) => const ManualOverridesScreen())),
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
                              Icon(
                                Icons.push_pin_rounded,
                                size: 12,
                                color: isHero ? BambooInk.onSlate : BambooInk.ink900,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Override active',
                                style: BambooFonts.ui(
                                  11,
                                  weight: FontWeight.w600,
                                  color: isHero ? BambooInk.onSlate : BambooInk.ink900,
                                ),
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
                Expanded(
                  child: Text(
                    recommendation.exclusionReason!,
                    style: BambooFonts.ui(13, color: BambooInk.ink500),
                  ),
                ),
              ],
            )
          else ...[
            if (isHero)
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  MoneyText(
                    recommendation.expectedValue,
                    confidence: recommendation.confidence,
                    style: BambooFonts.money(44, color: BambooInk.lime),
                    hidePaise: true,
                    // The confidence marker belongs after the whole phrase,
                    // not wedged between "₹125" and "back".
                    showConfidenceIcon: false,
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: Row(
                      children: [
                        Text('back', style: BambooFonts.ui(13, color: BambooInk.onSlateMuted)),
                        const SizedBox(width: 6),
                        Icon(
                          recommendation.confidence.isConfirmed
                              ? Icons.check_circle_rounded
                              : Icons.hourglass_top_rounded,
                          size: 13,
                          color: recommendation.confidence.isConfirmed
                              ? BambooInk.lime
                              : BambooInk.onSlateMuted,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            else
              MoneyText(
                recommendation.expectedValue,
                confidence: recommendation.confidence,
                style: BambooFonts.money(22, color: BambooInk.ink900),
                hidePaise: true,
              ),
            const SizedBox(height: 8),
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
                              style: BambooFonts.ui(
                                13,
                                weight: FontWeight.w600,
                                color: isHero ? BambooInk.lime : BambooInk.jade,
                              ),
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
                              style: BambooFonts.ui(
                                13,
                                color: isHero ? BambooInk.onSlateSubtle : BambooInk.ink500,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ],
          ],
          // Design 01's verdict card action row: a bamboo "Pay with this
          // card" primary CTA plus a "See the math" link to 09 Compare.
          // Home has no scanned merchant/VPA to hand off to a UPI intent
          // (that's ScanResultScreen's real "Pay with [card]", which DOES
          // launch one) — so "paying" here means what Home's own manual
          // amount+category entry can honestly mean: log this spend
          // against the winning card. Routes into QuickAddScreen prefilled
          // with the amount/category/card Home already resolved, which is
          // the app's real (tested) spend-logging path, not a fabricated
          // confirmation screen.
          if (isHero) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: BambooInk.slateHairline),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.lime,
                      foregroundColor: BambooInk.slate,
                      minimumSize: const Size(0, 44),
                      padding: EdgeInsets.zero,
                      textStyle: BambooFonts.ui(14, weight: FontWeight.w700),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      final wallet = ref.read(userCardsProvider).valueOrNull ?? const [];
                      final owned = wallet.firstWhereOrNull(
                        (w) => w.cardProductId == widget.recommendation.card.id,
                      );
                      // selectedCategoryProvider holds a slug ('online'), not
                      // the reward_rules.category_id UUID QuickAddScreen's
                      // dropdown is keyed by — same slug/UUID split
                      // rankedRecommendationsProvider itself resolves via
                      // categoriesProvider (see that provider's doc comment).
                      // Passing the slug straight through crashes
                      // DropdownButton's "exactly one matching item" assert.
                      primaryActionHaptic();
                      final categories = ref.read(categoriesProvider).valueOrNull ?? const [];
                      final selectedSlug = ref.read(selectedCategoryProvider);
                      final categoryId = categories.firstWhereOrNull((c) => c.slug == selectedSlug)?.id;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => QuickAddScreen(
                            initialAmount: ref.read(enteredAmountProvider),
                            initialCategoryId: categoryId,
                            initialUserCardId: owned?.id,
                          ),
                        ),
                      );
                    },
                    child: const Text('Pay with this card'),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const ComparisonViewScreen())),
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slateRaised,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size(0, 52),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    textStyle: BambooFonts.ui(13.5, weight: FontWeight.w700),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('See the math'),
                ),
              ],
            ),
          ],
        ],
      ),
    );

    if (!isHero) return card;
    // Design 01 bleeds a soft lime bloom out of the verdict card's
    // top-right corner (a 180pt circle at 10% lime, clipped by the card's
    // own 28pt radius) — it's what keeps the slate block from reading as a
    // flat rectangle. Painted behind the content, never over it.
    return Stack(
      children: [
        // The card sizes the stack; the bloom fills whatever it measures.
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              children: [
                Positioned(
                  top: -60,
                  right: -50,
                  child: Container(
                    width: 180,
                    height: 180,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: BambooInk.lime.withValues(alpha: 0.10),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        card,
      ],
    );
  }

  /// Design 01's rate line beside the BEST PICK badge — "5% on Online".
  /// Null when the engine couldn't attribute a per-rupee rate, so the badge
  /// stands alone rather than claiming a rate that wasn't computed.
  ///
  /// Shows the rate this spend WOULD ACTUALLY EARN, not the rate the card
  /// advertises. The two are the same until a cap runs out, at which point
  /// the headline becomes a promise the card won't keep: a "10% on Online"
  /// card whose ₹3,000 monthly cap is spent pays its 1% base rate, and
  /// printing "10% on Online" beside it is the exact over-promise the cap
  /// work exists to stop. [_CapBadge] explains why the number dropped.
  String? _rateLabel(Recommendation recommendation) {
    final headline = recommendation.effectiveRatePerRupee;
    if (headline == null || headline <= 0) return null;
    final breakdown = recommendation.breakdown;
    final rate = breakdown != null && breakdown.capStatus != CapStatus.none
        ? breakdown.effectiveRatePerRupee
        : headline;
    if (rate <= 0) return null;
    final pct = rate * 100;
    final formatted = pct >= 10 || pct == pct.roundToDouble()
        ? pct.toStringAsFixed(0)
        : pct.toStringAsFixed(1);
    final slug = ref.read(selectedCategoryProvider);
    final label = HomeScreen.categoryLabelFor(slug);
    return label == null ? '$formatted% back' : '$formatted% on $label';
  }
}

/// The one-line explanation for why a card's rate isn't its headline rate.
///
/// Home is where the app makes its promise, so it's where a spent cap has
/// to be visible — the information already existed in the breakdown and
/// simply wasn't shown, which meant a user could follow a "BEST PICK" and
/// earn a fifth of what the badge implied with nothing on screen having
/// warned them.
class _CapBadge extends StatelessWidget {
  final RecommendationBreakdown breakdown;
  final bool onDarkSurface;

  const _CapBadge({required this.breakdown, required this.onDarkSurface});

  /// BambooInk.amber is tuned for the light paper surfaces the Insights
  /// screens use; on the hero card's dark slate it falls below a
  /// comfortable contrast ratio, so the dark variant is one step brighter.
  static const _amberOnDark = Color(0xFFF6B23C);

  @override
  Widget build(BuildContext context) {
    final amber = onDarkSurface ? _amberOnDark : BambooInk.amber;
    final (label, tone) = switch (breakdown.capStatus) {
      CapStatus.reached => ('Cap spent — earning base rate', amber),
      CapStatus.partiallyConsumed => (breakdown.capNote ?? 'Cap nearly spent', amber),
      _ => (null, BambooInk.jade),
    };
    if (label == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.info_outline_rounded, size: 13, color: tone),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              style: BambooFonts.ui(11.5, weight: FontWeight.w600, color: tone),
              overflow: TextOverflow.ellipsis,
            ),
          ),
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
