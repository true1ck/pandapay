import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../app/tutorial_keys.dart';
import '../../data/api_exception.dart';
import '../../data/spend_by_category_repository.dart' show CategorySpend;
import '../../data/spend_reports_repository.dart'
    show SpendBreakdownRow, SpendPeriod, SpendReportQuery;
import '../../data/user_cards_repository.dart'
    show BankAccountSummary, TransactionEntry, TxnEntryKind, UserCard;
import '../../main.dart' show MoneyText;
import '../comparison/comparison_view_screen.dart';
import '../insights/credit_utilization_screen.dart';
import '../insights/credit_utilization_ui.dart';
import '../insights/payments_due_screen.dart'
    show DuePayment, paymentsDueProvider;
import '../../data/card_bill_ledger.dart' show CardBill;
import '../insights/spend_trends_screen.dart' show SpendingDonut;
import '../insights/spending_visuals.dart' show spendingCategoryVisual;
import '../import/import_hub_screen.dart';
import '../overrides/manual_overrides_screen.dart';
import '../quickadd/quick_add_screen.dart';
import '../scan/scan_result_screen.dart';
import '../scan/upi_qr_scanner_screen.dart';
import '../cards/card_visual.dart';
import '../../domain/cycle_engine.dart';
import 'home_alerts.dart';
import 'home_context_line.dart';

/// B1 Home — design 01 "Home · the verdict". Section order, gutters, type
/// sizes and the header composition are transcribed from that mockup; the
/// functionality underneath is the real B1 feature set, nothing mocked:
///
/// - Amount entry, purchase selector, alerts strip, the ranked
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
/// - Quick actions below the spending summary link to transaction entry,
///   imports, the UPI scanner and Wallet. The full Tools hub remains
///   available through "See all" and You → Tools.
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
    ('rent', 'Rent', Icons.home_work_rounded),
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
    // Start the server refresh in the background. The recommendation inputs
    // are cache-first, so this does not delay the first Home frame.
    ref.watch(homeDataRefreshProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final ranked = ref.watch(rankedRecommendationsProvider);
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    final now = ref.watch(clockProvider).now();
    // A signed engagement receipt is issued only after a live Home-summary
    // request, so cached/offline data can never manufacture streak activity.
    ref.watch(
      homeEngagementCheckInProvider(DateFormat('yyyy-MM-dd').format(now)),
    );

    // Keep the page hierarchy clear: greeting, spending summary, quick actions,
    // then the purchase controls and the recommendation they drive.
    // Context, warnings, category detail, dues and account data continue below.
    return AppBackground(
      child: Column(
        children: [
          const _HomeWidgetSync(),
          Expanded(
            child: CustomScrollView(
              slivers: [
                // Build Home sections lazily as they approach the viewport. The
                // former SingleChildScrollView/Column laid out the whole dashboard
                // on each refresh, even when only its first cards were visible.
                SliverPadding(
                  // 58pt top / 128pt bottom, the mockup's own scroll padding — the
                  // top inset stands in for the status bar now that the shell has no
                  // AppBar, and the shell reserves the bottom 128 for the nav pill.
                  padding: EdgeInsets.only(
                    top: MediaQuery.paddingOf(context).top + AppSpace.sm,
                    bottom: AppShell.navClearance,
                  ),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _gutter,
                          0,
                          _gutter,
                          0,
                        ),
                        child: _BrandHeader(greeting: _greetingFor(now)),
                      ),
                      const _HomeSpendHeadline(),
                      const _HomeQuickActions(),
                      const _HomeSectionDivider(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          _gutter,
                          0,
                          _gutter,
                          0,
                        ),
                        child: Text(
                          'What are you paying for?',
                          style: BambooFonts.heading(
                            18,
                            color: BambooInk.ink900,
                            height: 1.15,
                          ),
                        ),
                      ),
                      // B5's geofence context ("you look like you're at X") reads as
                      // the answer-in-progress to the heading above it, so it sits
                      // directly under the question rather than in its own strip.
                      const Padding(
                        padding: EdgeInsets.fromLTRB(
                          _gutter,
                          AppSpace.xs,
                          _gutter,
                          0,
                        ),
                        child: HomeContextLine(),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Padding(
                        key: tutorialKeys.categoryChips,
                        padding: const EdgeInsets.symmetric(
                          horizontal: _gutter,
                        ),
                        child: _PurchaseTypeSelector(
                          selectedCategory: selectedCategory,
                          onChanged: (slug) =>
                              ref
                                      .read(selectedCategoryProvider.notifier)
                                      .state =
                                  slug,
                        ),
                      ),
                      Padding(
                        key: tutorialKeys.amountField,
                        padding: const EdgeInsets.fromLTRB(
                          _gutter,
                          AppSpace.md,
                          _gutter,
                          0,
                        ),
                        child: const _AmountCard(),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: _gutter,
                        ),
                        child: _RankedSection(
                          ranked: ranked,
                          tutorialKeys: tutorialKeys,
                        ),
                      ),
                      const _AlertsStrip(),
                      const _UtilizationWarningBanner(),
                      const _HomeCategories(),
                      const _HomeDuesAndReminders(),
                      const _HomeAccountSnapshot(),
                      const SizedBox(height: AppSpace.lg),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeQuickActions extends StatefulWidget {
  const _HomeQuickActions();

  @override
  State<_HomeQuickActions> createState() => _HomeQuickActionsState();
}

class _HomeQuickActionsState extends State<_HomeQuickActions> {
  bool _scanning = false;

  Future<void> _scanToPay() async {
    setState(() => _scanning = true);
    try {
      final parsed = await Navigator.of(context).push<ParsedUpiQr>(
        MaterialPageRoute(builder: (_) => const UpiQrScannerScreen()),
      );
      if (parsed != null && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ScanResultScreen(parsed: parsed)),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not start the scanner. ${userFacingErrorMessage(error)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('home-quick-actions-layout'),
    padding: const EdgeInsets.fromLTRB(
      HomeScreen._gutter,
      AppSpace.xs,
      HomeScreen._gutter,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Quick actions',
                style: BambooFonts.heading(18, color: BambooInk.ink900),
              ),
            ),
            Pressable(
              semanticLabel: 'See all quick actions',
              onTap: () => context.push(AppRoute.toolsHub),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'See all',
                    style: BambooFonts.ui(
                      12,
                      weight: FontWeight.w600,
                      color: BambooInk.ink700,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: BambooInk.ink700,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpace.sm,
          children: [
            Expanded(
              child: _HomeQuickActionTile(
                label: 'Quick add',
                icon: Icons.add_rounded,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const QuickAddScreen()),
                ),
              ),
            ),
            Expanded(
              child: _HomeQuickActionTile(
                label: 'Import',
                icon: Icons.file_download_outlined,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ImportHubScreen()),
                ),
              ),
            ),
            Expanded(
              child: _HomeQuickActionTile(
                label: 'Scan & pay',
                icon: Icons.qr_code_scanner_rounded,
                onTap: _scanning ? null : _scanToPay,
              ),
            ),
            Expanded(
              child: _HomeQuickActionTile(
                label: 'View cards',
                icon: Icons.credit_card_rounded,
                onTap: () => context.go(AppRoute.cards),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _HomeSectionDivider extends StatelessWidget {
  const _HomeSectionDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      HomeScreen._gutter,
      AppSpace.xl,
      HomeScreen._gutter,
      AppSpace.lg,
    ),
    child: Container(
      key: const ValueKey('home-quick-actions-divider'),
      height: 1,
      color: BambooInk.hairlineOnPaper.withValues(alpha: .10),
    ),
  );
}

class _HomeQuickActionTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  const _HomeQuickActionTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Pressable(
    semanticLabel: label,
    onTap: onTap,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 3),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: BambooInk.wash.withValues(alpha: .65),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 18, color: BambooInk.slate),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            style: BambooFonts.ui(
              9.5,
              weight: FontWeight.w500,
              color: BambooInk.ink700,
            ),
          ),
        ],
      ),
    ),
  );
}

/// Keeps launcher widgets aligned with the same month report and card ranking
/// that Home is currently showing. Rebuilds are fingerprinted so an ordinary
/// Home animation or scroll never re-renders the widget images.
class _HomeWidgetSync extends ConsumerStatefulWidget {
  const _HomeWidgetSync();

  @override
  ConsumerState<_HomeWidgetSync> createState() => _HomeWidgetSyncState();
}

class _HomeWidgetSyncState extends ConsumerState<_HomeWidgetSync> {
  String? _lastScheduledFingerprint;
  Future<void> _syncQueue = Future<void>.value();

  @override
  Widget build(BuildContext context) {
    final reportState = ref.watch(
      spendReportProvider(const SpendReportQuery.preset(SpendPeriod.month)),
    );
    final recommendationState = ref.watch(rankedRecommendationsProvider);
    if (!reportState.hasValue || !recommendationState.hasValue) {
      return const SizedBox.shrink();
    }

    final report = reportState.valueOrNull;
    final recommendations = recommendationState.valueOrNull ?? const [];
    Recommendation? recommendation;
    for (final candidate in recommendations) {
      if (!candidate.isExcluded) {
        recommendation = candidate;
        break;
      }
    }
    final fingerprint = [
      report?.spend.total.paise ?? 0,
      report?.spend.rewards.paise ?? 0,
      for (final row in report?.byCategory ?? const <SpendBreakdownRow>[]) ...[
        row.label,
        row.total.paise,
      ],
      recommendation?.card.id ?? '',
      recommendation?.expectedValue.paise ?? 0,
      recommendation == null || recommendation.reasonLines.isEmpty
          ? ''
          : recommendation.reasonLines.first,
    ].join('|');
    if (fingerprint != _lastScheduledFingerprint) {
      _lastScheduledFingerprint = fingerprint;
      final clock = ref.read(clockProvider);
      final service = ref.read(homeWidgetServiceProvider);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncQueue = _syncQueue
            .then(
              (_) => service.updateHomeWidgets(
                report: report,
                recommendation: recommendation,
                nowIso: clock.now().toIso8601String(),
              ),
            )
            .catchError((Object error, StackTrace stackTrace) {
              debugPrint('Could not refresh PandaPay home widgets: $error');
            });
      });
    }
    return const SizedBox.shrink();
  }
}

class _HomeSpendHeadline extends ConsumerStatefulWidget {
  const _HomeSpendHeadline();

  @override
  ConsumerState<_HomeSpendHeadline> createState() => _HomeSpendHeadlineState();
}

class _HomeSpendHeadlineState extends ConsumerState<_HomeSpendHeadline> {
  int? _selectedCategoryIndex;

  void _selectCategory(int? index) => setState(() {
    _selectedCategoryIndex = index;
  });

  @override
  Widget build(BuildContext context) {
    final report = ref
        .watch(
          spendReportProvider(const SpendReportQuery.preset(SpendPeriod.month)),
        )
        .valueOrNull;
    if (report == null || report.spend.total.isZero) {
      return const SizedBox.shrink();
    }
    final change = report.changeVsPrevious;
    final projected = report.projectedSpend;
    final categories = report.byCategory
        .where((row) => !row.total.isZero)
        .toList();
    final selectedCategoryIndex =
        _selectedCategoryIndex != null &&
            _selectedCategoryIndex! < categories.length
        ? _selectedCategoryIndex
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeScreen._gutter,
        AppSpace.xs,
        HomeScreen._gutter,
        0,
      ),
      child: InkWell(
        key: const Key('home_spend_summary'),
        onTap: () => context.push(AppRoute.spendTrends),
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            color: BambooInk.paper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BambooInk.hairlineOnPaper),
            boxShadow: [
              BoxShadow(
                color: BambooInk.ink900.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'TOTAL SPENT',
                        style: BambooFonts.ui(
                          10.5,
                          weight: FontWeight.w700,
                          color: BambooInk.ink500,
                        ).copyWith(letterSpacing: .7),
                      ),
                    ),
                    if (change != null) _HomeSpendChangePill(change: change),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          SpendingDonut(
                            rows: categories,
                            total: report.spend.total,
                            size: 124,
                            compact: true,
                            totalLabel: 'spent',
                            selectedIndex: selectedCategoryIndex,
                            onSelected: _selectCategory,
                            onCenterTap: () =>
                                context.push(AppRoute.spendTrends),
                          ),
                          if (projected != null &&
                              report.elapsedFraction < .95) ...[
                            const SizedBox(height: 3),
                            SizedBox(
                              width: 150,
                              child: Text(
                                'On track for ${projected.format(compact: true)} this month',
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: BambooFonts.ui(
                                  9.5,
                                  color: BambooInk.ink500,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 1,
                      height: 138,
                      color: BambooInk.hairlineOnPaper,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HomeSpendMetric(
                            label: 'Money in',
                            amount: report.income.total,
                          ),
                          const _HomeSpendMetricDivider(),
                          _HomeSpendMetric(
                            label: 'Total spent',
                            amount: report.spend.total,
                          ),
                          const _HomeSpendMetricDivider(),
                          _HomeSpendMetric(
                            label: 'Rewards earned',
                            amount: report.spend.rewards,
                            reward: true,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeSpendMetric extends StatelessWidget {
  final String label;
  final Money amount;
  final bool reward;

  const _HomeSpendMetric({
    required this.label,
    required this.amount,
    this.reward = false,
  });

  @override
  Widget build(BuildContext context) {
    final icon = reward
        ? Icons.card_giftcard_rounded
        : label == 'Money in'
        ? Icons.south_rounded
        : Icons.north_rounded;
    final accent = reward ? BambooInk.amber : BambooInk.jade;
    final tint = reward
        ? const Color(0xFFFFF4E3)
        : label == 'Money in'
        ? const Color(0xFFE8F5EF)
        : const Color(0xFFFFEFED);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            child: Icon(icon, size: 15, color: accent),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BambooFonts.ui(9, color: BambooInk.ink500),
                ),
                const SizedBox(height: 1),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: MoneyText(
                    amount,
                    confidence: Confidence.estimated,
                    showConfidenceIcon: false,
                    style: BambooFonts.ui(
                      11.5,
                      weight: FontWeight.w700,
                      color: reward ? BambooInk.jade : BambooInk.ink900,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeSpendMetricDivider extends StatelessWidget {
  const _HomeSpendMetricDivider();

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: BambooInk.hairlineOnPaper);
}

class _HomeSpendChangePill extends StatelessWidget {
  final double change;
  const _HomeSpendChangePill({required this.change});

  @override
  Widget build(BuildContext context) {
    final up = change >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFE7F8D8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${up ? '↑' : '↓'} ${(change.abs() * 100).round()}%',
            style: BambooFonts.ui(
              11,
              weight: FontWeight.w800,
              color: const Color(0xFF1C7B35),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'vs last month',
            style: BambooFonts.ui(10, color: BambooInk.ink700),
          ),
        ],
      ),
    );
  }
}

/// Compact Home header: panda mark, greeting, all-time rewards and streak.
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
    final streakDays = summary?.streakDays ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const PandaMark(size: 38),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      greeting,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(13, color: BambooInk.ink500),
                    ),
                  ),
                  if (streakDays > 0) ...[
                    const SizedBox(width: AppSpace.xs),
                    _StreakPill(days: streakDays),
                  ],
                ],
              ),
              if (summary != null)
                GestureDetector(
                  onTap: () => context.push(AppRoute.monthlySavings),
                  behavior: HitTestBehavior.opaque,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: MoneyText(
                      key: const ValueKey('home-all-time-rewards'),
                      summary.rewardsAllTime,
                      confidence: Confidence.estimated,
                      style: BambooFonts.ui(10.5, color: BambooInk.ink500),
                      suffix: ' earned all-time ›',
                      hidePaise: true,
                      showConfidenceIcon: false,
                    ),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Add transaction',
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const QuickAddScreen())),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          iconSize: 21,
          icon: const Icon(Icons.add_rounded, color: BambooInk.jade),
        ),
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
      decoration: BoxDecoration(
        color: BambooInk.slate,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: BambooInk.lime,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$days-day streak',
            style: BambooFonts.ui(
              12,
              weight: FontWeight.w600,
              color: BambooInk.lime,
            ),
          ),
        ],
      ),
    );
  }
}

class _PurchaseTypeSelector extends StatelessWidget {
  final String? selectedCategory;
  final ValueChanged<String?> onChanged;

  const _PurchaseTypeSelector({
    required this.selectedCategory,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Keep the reference order stable: the remaining categories continue to
    // be available by horizontal scrolling without adding another row.
    final orderedCategories = [
      for (final slug in const [
        'online',
        'groceries',
        'dining',
        'fuel',
        'travel',
        'bills',
        'rent',
      ])
        for (final entry in HomeScreen._categories)
          if (entry.$1 == slug) entry,
    ];

    return SizedBox(
      key: const ValueKey('home-purchase-type'),
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: orderedCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 9),
        itemBuilder: (context, index) {
          final (slug, label, icon) = orderedCategories[index];
          return _PurchaseTypeIconButton(
            slug: slug,
            label: label,
            icon: icon,
            selected: slug == selectedCategory,
            onTap: () => onChanged(slug),
          );
        },
      ),
    );
  }
}

class _PurchaseTypeIconButton extends StatelessWidget {
  final String slug;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _PurchaseTypeIconButton({
    required this.slug,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? BambooInk.lime : BambooInk.ink500;
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey('home-category-icon-$slug'),
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: selected ? BambooInk.slate : BambooInk.paper,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? BambooInk.slate : BambooInk.hairlineOnPaper,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17, color: foreground),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: BambooFonts.ui(
                      11.5,
                      weight: FontWeight.w600,
                      color: selected ? BambooInk.onSlate : BambooInk.ink900,
                    ),
                  ),
                ],
              ),
            ),
          ),
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
    if (!userCards.hasValue || !catalogue.hasValue) {
      return const SizedBox.shrink();
    }

    final now = ref.watch(clockProvider).now();
    final alerts = computeHomeAlerts(
      wallet: userCards.requireValue,
      catalogue: catalogue.requireValue,
      now: now,
    ).take(2).toList();
    if (alerts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeScreen._gutter,
        AppSpace.md,
        HomeScreen._gutter,
        0,
      ),
      child: Column(
        children: [
          for (final alert in alerts)
            Container(
              margin: const EdgeInsets.only(bottom: AppSpace.xs),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.md,
                vertical: AppSpace.md,
              ),
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
                    decoration: const BoxDecoration(
                      color: BambooInk.clay,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // Icon + text label together, not color alone, carry the
                  // "this needs attention" signal — a clay-only box would
                  // fail for colorblind users.
                  Expanded(
                    child: Text(
                      alert.message,
                      style: BambooFonts.ui(13, color: BambooInk.ink900),
                    ),
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
/// fabricated number. Silent for cards with no credit limit entered, same as
/// E3.
class _UtilizationWarningBanner extends ConsumerWidget {
  const _UtilizationWarningBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs =
        ref.watch(ownedCardsWithProductProvider).valueOrNull ?? const [];
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
    final name = userCard.nickname?.isNotEmpty == true
        ? userCard.nickname!
        : product.name;
    final pct = (worstResult.ratio * 100).toStringAsFixed(0);
    final utilizationColor = CreditUtilizationUi.color(worstResult.ratio);
    final now = ref.watch(clockProvider).now();
    final duePayments =
        ref.watch(paymentsDueProvider).valueOrNull ?? const <DuePayment>[];
    final cardDue = duePayments
        .where((d) => d.card.id == userCard.id)
        .firstOrNull;
    final due =
        cardDue?.dueOn ??
        (userCard.dueDay == null
            ? null
            : _nextOccurrence(userCard.dueDay!, now));
    final dueClause = due == null
        ? 'Paying it down'
        : 'Paying it down before ${due.day}/${due.month}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeScreen._gutter,
        AppSpace.md,
        HomeScreen._gutter,
        0,
      ),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CreditUtilizationScreen()),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.md,
          ),
          decoration: BoxDecoration(
            color: BambooInk.warningBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BambooInk.warningBorder),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: BambooInk.clay,
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$name is $pct% utilised',
                      style: BambooFonts.ui(
                        13,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: worstResult.ratio.clamp(0.0, 1.0),
                        minHeight: 7,
                        backgroundColor: Colors.white,
                        color: utilizationColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${CreditUtilizationUi.label(worstResult.ratio)} · ${worstResult.currentBalance.format(hidePaise: true)} of ${userCard.creditLimit!.format(hidePaise: true)} tracked this cycle',
                      style: BambooFonts.ui(11.5, color: utilizationColor),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$dueClause can help keep utilization lower.',
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

  static DateTime _nextOccurrence(int day, DateTime now) =>
      CycleEngine.nextOccurrence(day, now);
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
  late final FocusNode _amountFocusNode;

  static const _quickAmounts = [500.0, 1000.0, 2000.0, 5000.0];

  String _formatAmount(double rupees) =>
      NumberFormat('#,##0.##', 'en_IN').format(rupees);

  @override
  void initState() {
    super.initState();
    final initial = ref.read(enteredAmountProvider);
    _amountFocusNode = FocusNode();
    _controller = TextEditingController(text: _formatAmount(initial.rupees));
  }

  @override
  void dispose() {
    _amountFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _setAmount(double rupees) {
    setState(() {
      _controller.text = _formatAmount(rupees);
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
    ref.read(enteredAmountProvider.notifier).state = Money.fromRupees(rupees);
  }

  @override
  Widget build(BuildContext context) {
    final currentAmount = ref.watch(enteredAmountProvider);

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 15, 18, 14),
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: Text(
                  'Spending amount',
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              ),
              IconButton(
                tooltip: 'Edit spending amount',
                icon: const Icon(Icons.edit_outlined),
                iconSize: 15,
                color: BambooInk.ink500,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: () => _amountFocusNode.requestFocus(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            focusNode: _amountFocusNode,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^[\d,]*\.?\d{0,2}')),
            ],
            style: BambooFonts.money(28),
            decoration: InputDecoration(
              // filled: false — without this, the ambient InputDecorationTheme
              // (app_theme.dart's AppTheme.light()/.dark(), still applied
              // globally) fills every TextField with AppColors.surfaceMuted by
              // default, which would paint a mismatched grey box inside this
              // widget's own glass Container.
              filled: false,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 2),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              prefixText: '₹',
              prefixStyle: BambooFonts.money(28, color: BambooInk.ink900),
            ),
            onChanged: (value) {
              final parsed = double.tryParse(value.replaceAll(',', ''));
              if (parsed != null && parsed >= 0) {
                ref.read(enteredAmountProvider.notifier).state =
                    Money.fromRupees(parsed);
              }
            },
          ),
          const SizedBox(height: 13),
          Row(
            children: [
              for (var i = 0; i < _quickAmounts.length; i++)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(
                      right: i == _quickAmounts.length - 1 ? 0 : 10,
                    ),
                    child: _QuickAmountChip(
                      label: '₹${_formatAmount(_quickAmounts[i])}',
                      selected: currentAmount.rupees == _quickAmounts[i],
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
  final bool selected;
  final VoidCallback onTap;
  const _QuickAmountChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? BambooInk.lime : BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: BambooFonts.ui(
            12,
            weight: FontWeight.w600,
            color: BambooInk.ink900,
          ),
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
class _RankedSection extends StatefulWidget {
  final AsyncValue<List<Recommendation>> ranked;
  final TutorialKeys tutorialKeys;
  const _RankedSection({required this.ranked, required this.tutorialKeys});

  @override
  State<_RankedSection> createState() => _RankedSectionState();
}

class _RankedSectionState extends State<_RankedSection> {
  final Set<String> _expandedRecommendationIds = <String>{};
  bool _alternativesExpanded = false;

  @override
  Widget build(BuildContext context) {
    return widget.ranked.when(
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
            message:
                'Add a card to see personalized reward recommendations here.',
          );
        }
        final alternatives = recommendations
            .skip(1)
            .where((recommendation) => !recommendation.isExcluded)
            .toList(growable: false);
        return _rankedCard(
          recommendations.first,
          0,
          comparedCount: recommendations.length,
          alternatives: alternatives,
          alternativesExpanded: _alternativesExpanded,
          onAlternativesToggle: () =>
              setState(() => _alternativesExpanded = !_alternativesExpanded),
        );
      },
    );
  }

  Widget _rankedCard(
    Recommendation recommendation,
    int rank, {
    required int comparedCount,
    required List<Recommendation> alternatives,
    required bool alternativesExpanded,
    required VoidCallback onAlternativesToggle,
  }) {
    return Padding(
      key: ValueKey(recommendation.card.id),
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      // NOTE: the tutorial anchor GlobalKey is passed in as a plain
      // constructor field (cardAnchorKey), not attached as this widget's own
      // Key — see _RecommendationCard's doc-comment for why a rank-based
      // GlobalKey must never be this widget's identity key.
      child: _RecommendationCard(
        recommendation,
        rank: rank,
        expanded: _expandedRecommendationIds.contains(recommendation.card.id),
        onReasonToggle: () => setState(() {
          final id = recommendation.card.id;
          if (!_expandedRecommendationIds.add(id)) {
            _expandedRecommendationIds.remove(id);
          }
        }),
        cardAnchorKey: rank == 0
            ? widget.tutorialKeys.firstRecommendationCard
            : null,
        comparedCount: comparedCount,
        alternatives: alternatives,
        alternativesExpanded: alternativesExpanded,
        onAlternativesToggle: onAlternativesToggle,
      ),
    );
  }
}

class _CardListToggle extends StatelessWidget {
  final bool expanded;
  final int hiddenCount;
  final VoidCallback onPressed;
  final bool onDarkSurface;

  const _CardListToggle({
    required this.expanded,
    required this.hiddenCount,
    required this.onPressed,
    this.onDarkSurface = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = expanded
        ? 'Hide other cards'
        : 'Show $hiddenCount more ${hiddenCount == 1 ? 'card' : 'cards'}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          decoration: BoxDecoration(
            color: onDarkSurface
                ? BambooInk.onSlate.withValues(alpha: .07)
                : BambooInk.paperMuted,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: onDarkSurface
                  ? BambooInk.onSlate.withValues(alpha: .09)
                  : BambooInk.hairlineOnPaper,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  label,
                  key: ValueKey(label),
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w600,
                    color: onDarkSurface
                        ? BambooInk.onSlateSubtle
                        : BambooInk.ink900,
                  ),
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: onDarkSurface
                      ? BambooInk.onSlateMuted
                      : BambooInk.ink500,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _issuerLabel(CardProduct product) {
  final issuer = product.issuerName?.trim();
  if (issuer != null && issuer.isNotEmpty) return issuer;
  final words = product.name.trim().split(RegExp(r'\s+'));
  return words.isEmpty ? 'Card issuer' : words.first;
}

/// Compact next-best card row, rendered on either the paper surface or
/// inside the dark recommendation hero.
class _BackupCardRow extends StatelessWidget {
  final Recommendation backup;
  final bool onDarkSurface;
  final bool showLabel;

  const _BackupCardRow(
    this.backup, {
    this.onDarkSurface = false,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
      decoration: BoxDecoration(
        color: onDarkSurface
            ? BambooInk.onSlate.withValues(alpha: .07)
            : BambooInk.paper,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: onDarkSurface
              ? BambooInk.onSlate.withValues(alpha: .09)
              : BambooInk.hairlineOnPaper,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLabel) ...[
            Text(
              'Alternative',
              style: BambooFonts.ui(
                10.5,
                color: onDarkSurface
                    ? BambooInk.onSlateMuted
                    : BambooInk.ink500,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Row(
            children: [
              SizedBox(
                width: 58,
                height: 34,
                child: CardVisual(
                  product: backup.card,
                  width: 58,
                  height: 34,
                  showProductName: false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      backup.card.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        11.5,
                        weight: FontWeight.w700,
                        color: onDarkSurface
                            ? BambooInk.onSlate
                            : BambooInk.ink900,
                      ),
                    ),
                    Text(
                      _issuerLabel(backup.card),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        10,
                        color: onDarkSurface
                            ? BambooInk.onSlateMuted
                            : BambooInk.ink500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  MoneyText(
                    backup.expectedValue,
                    confidence: backup.confidence,
                    style: BambooFonts.ui(
                      12.5,
                      weight: FontWeight.w700,
                      color: onDarkSurface ? BambooInk.lime : BambooInk.ink900,
                    ),
                    hidePaise: true,
                    showConfidenceIcon: false,
                  ),
                  Text(
                    'Est. rewards',
                    style: BambooFonts.ui(
                      9,
                      color: onDarkSurface
                          ? BambooInk.onSlateMuted
                          : BambooInk.ink500,
                    ),
                  ),
                ],
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 21,
                color: onDarkSurface
                    ? BambooInk.onSlateMuted
                    : BambooInk.ink500,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RecommendationCard extends ConsumerStatefulWidget {
  final Recommendation recommendation;
  final int rank;
  final bool expanded;
  final VoidCallback onReasonToggle;
  final int comparedCount;
  final List<Recommendation> alternatives;
  final bool alternativesExpanded;
  final VoidCallback? onAlternativesToggle;
  // Anchor GlobalKey for the onboarding tutorial overlay to measure this
  // card's position when it's the rank-0 (hero) card. Deliberately NOT
  // this widget's own `key` — this widget's identity (and thus its
  // State's _expanded flag) must be keyed only by card id (see
  // _RankedSection above), never by a rank-based GlobalKey, which would
  // silently re-introduce a per-card state leak on reorder via a
  // different mechanism.
  final Key? cardAnchorKey;
  const _RecommendationCard(
    this.recommendation, {
    required this.rank,
    required this.expanded,
    required this.onReasonToggle,
    this.cardAnchorKey,
    this.comparedCount = 1,
    this.alternatives = const [],
    this.alternativesExpanded = false,
    this.onAlternativesToggle,
  });

  @override
  ConsumerState<_RecommendationCard> createState() =>
      _RecommendationCardState();
}

class _RecommendationCardState extends ConsumerState<_RecommendationCard> {
  @override
  Widget build(BuildContext context) {
    // Keep the compact visual for the leading recommendation. Once the user
    // expands the ranked list, retain the established detail-rich card for
    // additional choices instead of presenting every alternative as another
    // "BEST PICK" hero.
    if (widget.rank > 0) return _legacyBuild(context);
    return _buildReplica(context);
  }

  // Kept as a local fallback while the compact recommendation surface is
  // refined. It is intentionally not used by the normal build path.
  Widget _legacyBuild(BuildContext context) {
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
                colors: [
                  BambooInk.slateRaised,
                  BambooInk.slate,
                  BambooInk.slateLow,
                ],
              )
            : null,
        color: isHero
            ? null
            : (excluded ? BambooInk.paperMuted : BambooInk.glassFillOnPaper),
        borderRadius: BorderRadius.circular(isHero ? 24 : 20),
        border: isHero
            ? Border.all(
                color: BambooInk.lime.withValues(alpha: 0.72),
                width: 1.5,
              )
            : Border.all(color: BambooInk.hairlineOnPaper),
        boxShadow: isHero
            ? [
                BoxShadow(
                  color: BambooInk.slate.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: BambooInk.lime.withValues(alpha: 0.14),
                  blurRadius: 20,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            height: isHero ? 92 : 82,
            child: CardVisual(
              product: recommendation.card,
              showProductName: false,
            ),
          ),
          SizedBox(height: isHero ? 10 : 12),
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
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: BambooInk.lime,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  'BEST PICK',
                                  style: BambooFonts.ui(
                                    10,
                                    weight: FontWeight.w700,
                                    color: BambooInk.slate,
                                  ).copyWith(letterSpacing: 0.9),
                                ),
                              ),
                              if (_rateLabel(recommendation) != null) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    _rateLabel(recommendation)!,
                                    style: BambooFonts.ui(
                                      11.5,
                                      color: BambooInk.onSlateMuted,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 7),
                          Text(
                            recommendation.card.name,
                            style: BambooFonts.heading(
                              18,
                              color: BambooInk.onSlate,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (recommendation.breakdown != null)
                            _CapBadge(
                              breakdown: recommendation.breakdown!,
                              onDarkSurface: true,
                            ),
                        ],
                      )
                    : Text(
                        recommendation.card.name,
                        style: BambooFonts.heading(
                          17,
                          color: excluded ? BambooInk.ink500 : BambooInk.ink900,
                        ),
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
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    child: GestureDetector(
                      // B8 chip requirement: tapping the "override active"
                      // pill takes the user straight to where they can
                      // see/undo it.
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ManualOverridesScreen(),
                        ),
                      ),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isHero
                                ? Colors.white.withValues(alpha: 0.16)
                                : BambooInk.paperMuted,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.push_pin_rounded,
                                size: 12,
                                color: isHero
                                    ? BambooInk.onSlate
                                    : BambooInk.ink900,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Override active',
                                style: BambooFonts.ui(
                                  11,
                                  weight: FontWeight.w600,
                                  color: isHero
                                      ? BambooInk.onSlate
                                      : BambooInk.ink900,
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
          const SizedBox(height: 7),
          if (excluded)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.block_rounded,
                  size: 16,
                  color: BambooInk.ink500,
                ),
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
                    style: BambooFonts.money(36, color: BambooInk.lime),
                    hidePaise: true,
                    // The confidence marker belongs after the whole phrase,
                    // not wedged between "₹125" and "back".
                    showConfidenceIcon: false,
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      children: [
                        Text(
                          'back',
                          style: BambooFonts.ui(
                            12,
                            color: BambooInk.onSlateMuted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          recommendation.confidence.isConfirmed
                              ? Icons.check_circle_rounded
                              : Icons.hourglass_top_rounded,
                          size: 12,
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
            const SizedBox(height: 6),
            // ui-spec B1.3 "Why this card?" — collapsed to the first reason
            // line by default, full arithmetic behind an explicit tap.
            if (recommendation.reasonLines.isNotEmpty) ...[
              Text(
                '•  ${recommendation.reasonLines.first}',
                style: BambooFonts.ui(
                  12,
                  color: isHero ? BambooInk.onSlateSubtle : BambooInk.ink500,
                ),
                maxLines: isHero ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (recommendation.reasonLines.length > 1) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: InkWell(
                    onTap: widget.onReasonToggle,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.expanded
                                  ? 'Hide the full breakdown'
                                  : 'Why this card?',
                              key: ValueKey('why-${recommendation.card.id}'),
                              style: BambooFonts.ui(
                                12,
                                weight: FontWeight.w600,
                                color: isHero ? BambooInk.lime : BambooInk.jade,
                              ),
                            ),
                            Icon(
                              widget.expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: isHero ? BambooInk.lime : BambooInk.jade,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.expanded)
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
                                12,
                                color: isHero
                                    ? BambooInk.onSlateSubtle
                                    : BambooInk.ink500,
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
            const SizedBox(height: 10),
            Container(height: 1, color: BambooInk.slateHairline),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: BambooInk.lime,
                      foregroundColor: BambooInk.slate,
                      minimumSize: const Size(0, 40),
                      padding: EdgeInsets.zero,
                      textStyle: BambooFonts.ui(13, weight: FontWeight.w700),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      final wallet =
                          ref.read(userCardsProvider).valueOrNull ?? const [];
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
                      final categories =
                          ref.read(categoriesProvider).valueOrNull ?? const [];
                      final selectedSlug = ref.read(selectedCategoryProvider);
                      final categoryId = categories
                          .firstWhereOrNull((c) => c.slug == selectedSlug)
                          ?.id;
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
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ComparisonViewScreen(),
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.slateRaised,
                    foregroundColor: BambooInk.lime,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: BambooFonts.ui(12.5, weight: FontWeight.w700),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
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
            borderRadius: BorderRadius.circular(24),
            child: Stack(
              children: [
                Positioned(
                  top: -52,
                  right: -44,
                  child: Container(
                    width: 150,
                    height: 150,
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

  Widget _buildReplica(BuildContext context) {
    final recommendation = widget.recommendation;
    if (recommendation.isExcluded) return _legacyBuild(context);

    final amount = ref.watch(enteredAmountProvider);
    final selectedCategory = ref.watch(selectedCategoryProvider);
    final category = HomeScreen.categoryLabelFor(selectedCategory);
    final categoryText = category == 'Online'
        ? 'Online shopping'
        : (category ?? 'Recommended spend');
    final rateLabel = _rateAmountLabel(recommendation, amount);

    final hero = Container(
      key: widget.cardAnchorKey,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [BambooInk.slateRaised, BambooInk.slateLow],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: BambooInk.slate.withValues(alpha: 0.24),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Best from your wallet',
                  style: BambooFonts.heading(16, color: BambooInk.onSlate),
                ),
              ),
              Text(
                '${widget.comparedCount} cards compared',
                style: BambooFonts.ui(10, color: BambooInk.onSlateMuted),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: BambooInk.lime,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  'BEST PICK',
                  style: BambooFonts.ui(
                    9,
                    weight: FontWeight.w800,
                    color: BambooInk.slate,
                  ).copyWith(letterSpacing: 0.7),
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.shopping_cart_outlined,
                size: 15,
                color: BambooInk.onSlateMuted,
              ),
              const SizedBox(width: 5),
              Text(
                categoryText,
                style: BambooFonts.ui(11, color: BambooInk.onSlateMuted),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              SizedBox(
                width: 82,
                height: 45,
                child: CardVisual(
                  product: recommendation.card,
                  width: 82,
                  height: 45,
                  showProductName: false,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recommendation.card.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w700,
                        color: BambooInk.onSlate,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _issuerLabel(recommendation.card),
                      style: BambooFonts.ui(
                        11.5,
                        color: BambooInk.onSlateMuted,
                      ),
                    ),
                    if (recommendation.isOverride)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Semantics(
                          button: true,
                          label: 'Override active. Manage manual overrides.',
                          child: InkWell(
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ManualOverridesScreen(),
                              ),
                            ),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 4,
                                horizontal: 2,
                              ),
                              child: Text(
                                'Override active',
                                style: BambooFonts.ui(
                                  10.5,
                                  weight: FontWeight.w700,
                                  color: BambooInk.lime,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(
                recommendation.expectedValue,
                confidence: recommendation.confidence,
                style: BambooFonts.money(26, color: BambooInk.lime),
                hidePaise: true,
                showConfidenceIcon: false,
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Text(
                      'Estimated rewards',
                      style: BambooFonts.ui(10, color: BambooInk.onSlateMuted),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 13,
                      color: BambooInk.onSlateMuted,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  rateLabel,
                  style: BambooFonts.ui(10, color: BambooInk.onSlateMuted),
                ),
              ),
            ],
          ),
          if (recommendation.breakdown != null &&
              recommendation.breakdown!.capStatus != CapStatus.none)
            _CapBadge(
              breakdown: recommendation.breakdown!,
              onDarkSurface: true,
            ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    final wallet =
                        ref.read(userCardsProvider).valueOrNull ?? const [];
                    final owned = wallet.firstWhereOrNull(
                      (w) => w.cardProductId == recommendation.card.id,
                    );
                    primaryActionHaptic();
                    final categories =
                        ref.read(categoriesProvider).valueOrNull ?? const [];
                    final categoryId = categories
                        .firstWhereOrNull((c) => c.slug == selectedCategory)
                        ?.id;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => QuickAddScreen(
                          initialAmount: amount,
                          initialCategoryId: categoryId,
                          initialUserCardId: owned?.id,
                        ),
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: BambooInk.lime,
                    foregroundColor: BambooInk.slate,
                    minimumSize: const Size(0, 34),
                    padding: EdgeInsets.zero,
                    textStyle: BambooFonts.ui(12, weight: FontWeight.w700),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(13),
                    ),
                  ),
                  child: const Text('Pay with this card'),
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ComparisonViewScreen(),
                  ),
                ),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 6,
                  ),
                  child: Text(
                    'Details ↗',
                    style: BambooFonts.ui(
                      11.5,
                      weight: FontWeight.w700,
                      color: BambooInk.lime,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (widget.alternatives.isNotEmpty) ...[
            const SizedBox(height: 9),
            Container(
              height: 1,
              color: BambooInk.onSlateMuted.withValues(alpha: .22),
            ),
            const SizedBox(height: 7),
            Text(
              'Alternative',
              style: BambooFonts.ui(10, color: BambooInk.onSlateMuted),
            ),
            const SizedBox(height: 5),
            _BackupCardRow(
              widget.alternatives.first,
              onDarkSurface: true,
              showLabel: false,
            ),
            if (widget.alternatives.length > 1) ...[
              const SizedBox(height: 5),
              _CardListToggle(
                expanded: widget.alternativesExpanded,
                hiddenCount: widget.alternatives.length - 1,
                onPressed: widget.onAlternativesToggle ?? () {},
                onDarkSurface: true,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: widget.alternativesExpanded
                    ? Padding(
                        key: const ValueKey('ranked-cards-expanded'),
                        padding: const EdgeInsets.only(top: 5),
                        child: Column(
                          children: [
                            for (final alternative in widget.alternatives.skip(
                              1,
                            )) ...[
                              _BackupCardRow(
                                alternative,
                                onDarkSurface: true,
                                showLabel: false,
                              ),
                              const SizedBox(height: 5),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ],
      ),
    );

    return hero;
  }

  String _rateAmountLabel(Recommendation recommendation, Money amount) {
    final headline = recommendation.effectiveRatePerRupee;
    if (headline == null || headline <= 0) return 'Estimated rate';
    final breakdown = recommendation.breakdown;
    final rate = breakdown != null && breakdown.capStatus != CapStatus.none
        ? breakdown.effectiveRatePerRupee
        : headline;
    final pct = rate * 100;
    final formatted = pct >= 10 || pct == pct.roundToDouble()
        ? pct.toStringAsFixed(0)
        : pct.toStringAsFixed(1);
    return '$formatted% on ${amount.format(hidePaise: true)}';
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
      CapStatus.partiallyConsumed => (
        breakdown.capNote ?? 'Cap nearly spent',
        amber,
      ),
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

/// A compact, truthful account snapshot for Home. It is deliberately at the
/// bottom of the page because it is supporting context, not the payment
/// decision. Account suffixes and issuer marks can be shown without revealing
/// money; every balance stays masked until the device biometric/PIN succeeds.
class _HomeAccountSnapshot extends ConsumerStatefulWidget {
  const _HomeAccountSnapshot();

  @override
  ConsumerState<_HomeAccountSnapshot> createState() =>
      _HomeAccountSnapshotState();
}

class _HomeAccountSnapshotState extends ConsumerState<_HomeAccountSnapshot> {
  final _localAuth = LocalAuthentication();
  bool _expanded = false;
  bool _unlocked = false;
  bool _authenticating = false;
  String? _authError;

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _authError = null;
    });
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!supported) {
        if (mounted) {
          setState(() {
            _authError =
                'Set up a fingerprint, face unlock, or device PIN to reveal balances.';
          });
        }
        return;
      }
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Reveal bank balances in PandaPay',
        biometricOnly: false,
      );
      if (!mounted) return;
      setState(() {
        _unlocked = authenticated;
        _authError = authenticated
            ? null
            : 'Authentication was cancelled. Balances remain hidden.';
      });
    } on LocalAuthException catch (error) {
      if (!mounted) return;
      final unavailable =
          error.code == LocalAuthExceptionCode.noCredentialsSet ||
          error.code == LocalAuthExceptionCode.noBiometricsEnrolled ||
          error.code == LocalAuthExceptionCode.noBiometricHardware;
      setState(() {
        _authError = unavailable
            ? 'Set up a fingerprint, face unlock, or device PIN to reveal balances.'
            : 'Could not verify. Your balances are still hidden.';
      });
    } on PlatformException {
      if (mounted) {
        setState(
          () =>
              _authError = 'Could not verify. Your balances are still hidden.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _authError = 'Could not verify. Your balances are still hidden.',
        );
      }
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  void _hideBalances() {
    setState(() {
      _unlocked = false;
      _authError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final accounts =
        ref.watch(bankAccountSummariesProvider).valueOrNull ??
        const <BankAccountSummary>[];
    // Only the account repository may establish a bank account. Report labels
    // and transaction suffixes can contain historical card misclassifications.
    final cardSuffixes = <String>{
      for (final card
          in ref.watch(userCardsProvider).valueOrNull ?? <UserCard>[])
        if (card.last4 != null) card.last4!,
      for (final transaction
          in ref.watch(transactionsProvider).valueOrNull ??
              <TransactionEntry>[])
        if (transaction.cardLast4 != null) transaction.cardLast4!,
    };
    bool isNonBankAccount(BankAccountSummary account) {
      final label = [
        account.issuerSlug,
        account.issuerShortName,
        account.issuerName,
      ].whereType<String>().join(' ').toLowerCase();
      return RegExp(
        r'\b(?:lic|licind|dhan|dhanhq|trading|demat|broker|mutual|investment|portfolio|groww|zerodha|upstox|angel|paytm\s+money)\b',
      ).hasMatch(label);
    }

    bool isVerifiedBank(BankAccountSummary account) {
      if (isNonBankAccount(account)) return false;
      final slug = (account.issuerSlug ?? '').toLowerCase().trim();
      final name = [
        account.issuerShortName,
        account.issuerName,
      ].whereType<String>().join(' ').toLowerCase().trim();
      return (slug.isNotEmpty && slug != 'unknown') ||
          (name.isNotEmpty && name != 'unknown');
    }

    // Keep the issuer in the identity. Two different banks can legitimately
    // have accounts ending in the same four digits; keying only by suffix
    // silently dropped one account and produced an incorrect total.
    final visibleAccounts =
        accounts
            .where(
              (account) =>
                  RegExp(r'^\d{4}$').hasMatch(account.accountLast4) &&
                  !isNonBankAccount(account) &&
                  (isVerifiedBank(account) ||
                      !cardSuffixes.contains(account.accountLast4)),
            )
            .toList()
          ..sort((a, b) {
            final issuer = (a.issuerShortName ?? a.issuerName ?? '').compareTo(
              b.issuerShortName ?? b.issuerName ?? '',
            );
            return issuer != 0
                ? issuer
                : a.accountLast4.compareTo(b.accountLast4);
          });
    final accountCount = visibleAccounts.length;

    var total = const Money.zero();
    var balancesFound = 0;
    for (final account in visibleAccounts) {
      final balance = account.availableBalance;
      if (balance == null) continue;
      total += balance;
      balancesFound += 1;
    }

    final hasBalances = balancesFound > 0;
    final hasManualBalances = visibleAccounts.any(
      (a) => a.isBalanceManuallySet,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HomeScreen._gutter,
        AppSpace.xl,
        HomeScreen._gutter,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.slate,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: accountCount == 0
                    ? null
                    : () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.account_balance_rounded,
                        size: 20,
                        color: BambooInk.lime,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          'Your bank accounts',
                          style: BambooFonts.heading(
                            16,
                            color: BambooInk.onSlate,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'View and edit balances',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => context.push(AppRoute.bankAccounts),
                        icon: const Icon(
                          Icons.edit_outlined,
                          size: 19,
                          color: BambooInk.lime,
                        ),
                      ),
                      Text(
                        accountCount == 0
                            ? 'No accounts yet'
                            : '$accountCount ${accountCount == 1 ? 'account' : 'accounts'}',
                        style: BambooFonts.ui(
                          12,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                      if (accountCount > 0) ...[
                        const SizedBox(width: AppSpace.xs),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 22,
                            color: BambooInk.onSlateMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        hasBalances
                            ? 'Total ${hasManualBalances ? 'account' : 'detected'} balance'
                            : 'Balance from SMS',
                        style: BambooFonts.ui(
                          11.5,
                          color: BambooInk.onSlateMuted,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (hasBalances)
                        _unlocked
                            ? MoneyText(
                                total,
                                confidence: Confidence.estimated,
                                style: BambooFonts.money(
                                  28,
                                  color: BambooInk.lime,
                                ),
                                hidePaise: true,
                                showConfidenceIcon: false,
                              )
                            : Text(
                                '₹••••',
                                style: BambooFonts.money(
                                  28,
                                  color: BambooInk.onSlate,
                                ),
                              )
                      else
                        Text(
                          accountCount == 0 ? 'Not available' : 'Not found yet',
                          style: BambooFonts.ui(
                            16,
                            weight: FontWeight.w600,
                            color: BambooInk.onSlateSubtle,
                          ),
                        ),
                    ],
                  ),
                ),
                if (hasBalances)
                  IconButton(
                    tooltip: _unlocked ? 'Hide balances' : 'Reveal balances',
                    onPressed: _authenticating
                        ? null
                        : (_unlocked ? _hideBalances : _authenticate),
                    icon: _authenticating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: BambooInk.lime,
                            ),
                          )
                        : Icon(
                            _unlocked
                                ? Icons.visibility_off_rounded
                                : Icons.visibility_rounded,
                            color: BambooInk.lime,
                          ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'Balances come from the latest bank SMS unless you updated them manually.',
              style: BambooFonts.ui(11.5, color: BambooInk.onSlateSubtle),
            ),
            const SizedBox(height: 3),
            Text(
              'Edit them anytime. Live bank balances are coming soon.',
              style: BambooFonts.ui(11.5, color: BambooInk.onSlateSubtle),
            ),
            if (hasBalances) ...[
              const SizedBox(height: 3),
              Text(
                'SMS amounts are snapshots, not live bank balances.',
                style: BambooFonts.ui(11.5, color: BambooInk.onSlateSubtle),
              ),
            ],
            if (_authError != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                _authError!,
                style: BambooFonts.ui(11.5, color: BambooInk.clay),
              ),
            ],
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: _expanded && visibleAccounts.isNotEmpty
                  ? Padding(
                      key: const ValueKey('home-bank-accounts-expanded'),
                      padding: const EdgeInsets.only(top: AppSpace.md),
                      child: Column(
                        children: [
                          Container(height: 1, color: BambooInk.slateHairline),
                          const SizedBox(height: AppSpace.sm),
                          for (final account in visibleAccounts)
                            _HomeBankAccountRow(
                              key: ValueKey(
                                '${account.issuerSlug ?? account.issuerShortName ?? account.issuerName ?? 'bank'}:${account.accountLast4}',
                              ),
                              last4: account.accountLast4,
                              summary: account,
                              revealed: _unlocked,
                            ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeBankAccountRow extends StatelessWidget {
  final String last4;
  final BankAccountSummary? summary;
  final bool revealed;

  const _HomeBankAccountRow({
    super.key,
    required this.last4,
    required this.summary,
    required this.revealed,
  });

  @override
  Widget build(BuildContext context) {
    final issuer = summary?.issuerShortName ?? summary?.issuerName;
    final balance = summary?.availableBalance;
    final balanceAt = summary?.latestBalanceSmsAt;
    final latestSmsAt = summary?.latestSmsAt;
    final logoLabel = issuer == null || issuer.trim().isEmpty ? 'Bank' : issuer;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          _HomeBankLogo(summary: summary, label: logoLabel),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  issuer ?? 'Bank account',
                  style: BambooFonts.ui(
                    13,
                    weight: FontWeight.w600,
                    color: BambooInk.onSlate,
                  ),
                ),
                Text(
                  'Account ending $last4',
                  style: BambooFonts.ui(11.5, color: BambooInk.onSlateMuted),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 132,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (balance == null)
                  Text(
                    'No balance reported',
                    style: BambooFonts.ui(11, color: BambooInk.onSlateMuted),
                    textAlign: TextAlign.end,
                  )
                else if (!revealed)
                  const Icon(
                    Icons.lock_outline_rounded,
                    size: 17,
                    color: BambooInk.onSlateMuted,
                  )
                else
                  MoneyText(
                    balance,
                    confidence: Confidence.estimated,
                    style: BambooFonts.ui(
                      13,
                      weight: FontWeight.w700,
                      color: BambooInk.lime,
                    ),
                    hidePaise: true,
                    showConfidenceIcon: false,
                  ),
                if (summary?.isBalanceManuallySet == true &&
                    summary?.manualBalanceUpdatedAt != null)
                  Text(
                    'Manually updated ${DateFormat('dd MMM, h:mm a').format(summary!.manualBalanceUpdatedAt!.toLocal())}',
                    style: BambooFonts.ui(9.5, color: BambooInk.onSlateMuted),
                    textAlign: TextAlign.end,
                  )
                else if (balanceAt != null)
                  Text(
                    'As of ${DateFormat('dd MMM, h:mm a').format(balanceAt.toLocal())}',
                    style: BambooFonts.ui(9.5, color: BambooInk.onSlateMuted),
                    textAlign: TextAlign.end,
                  )
                else if (latestSmsAt != null)
                  Text(
                    'Latest SMS ${DateFormat('dd MMM, h:mm a').format(latestSmsAt.toLocal())}',
                    style: BambooFonts.ui(9.5, color: BambooInk.onSlateMuted),
                    textAlign: TextAlign.end,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeBankLogo extends StatelessWidget {
  final BankAccountSummary? summary;
  final String label;

  const _HomeBankLogo({required this.summary, required this.label});

  @override
  Widget build(BuildContext context) {
    final logoUrl = summary?.issuerLogoUrl;
    if (logoUrl != null && logoUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          logoUrl,
          width: 36,
          height: 36,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => _fallback(),
        ),
      );
    }
    return _fallback();
  }

  Widget _fallback() {
    final short = label.trim().isEmpty
        ? 'BK'
        : label
              .trim()
              .split(RegExp(r'\s+'))
              .where((part) => part.isNotEmpty)
              .take(2)
              .map((part) => part[0].toUpperCase())
              .join();
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: BambooInk.slateRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        short,
        style: BambooFonts.ui(
          11,
          weight: FontWeight.w800,
          color: BambooInk.lime,
        ),
      ),
    );
  }
}

class _HomeCategories extends ConsumerWidget {
  const _HomeCategories();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref
        .watch(
          spendReportProvider(const SpendReportQuery.preset(SpendPeriod.month)),
        )
        .valueOrNull;
    final apiRows =
        ref.watch(categorySpendProvider).valueOrNull ?? const <CategorySpend>[];
    final transactions =
        ref.watch(transactionsProvider).valueOrNull ??
        const <TransactionEntry>[];
    final reportRows = report?.byCategory ?? const [];
    final rows = reportRows.isNotEmpty
        ? [
            for (final row in reportRows)
              CategorySpend(
                categoryId: row.categoryId,
                categorySlug: null,
                categoryName: row.label == 'Other' ? null : row.label,
                totalSpend: row.total,
                txnCount: row.txnCount,
              ),
          ]
        : (apiRows.isNotEmpty
              ? apiRows
              : _categorySpendFromTransactions(transactions));
    final sorted = [...rows]
      ..sort((a, b) => b.totalSpend.rupees.compareTo(a.totalSpend.rupees));
    final visible = sorted.take(6).toList();

    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HomeScreen._gutter),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Categories',
                    style: BambooFonts.heading(20, color: BambooInk.ink900),
                  ),
                ),
                TextButton(
                  onPressed: () => context.push(AppRoute.spendTrends),
                  child: const Text('View all'),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HomeScreen._gutter,
              ),
              child: Container(
                height: 96,
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  'Categories will appear after your first categorized spend.',
                  style: BambooFonts.ui(13, color: BambooInk.ink500),
                ),
              ),
            )
          else
            SizedBox(
              height: 132,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(
                  horizontal: HomeScreen._gutter,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: visible.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpace.sm),
                itemBuilder: (context, index) =>
                    _HomeCategoryCard(row: visible[index]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HomeScreen._gutter,
              AppSpace.xs,
              HomeScreen._gutter,
              0,
            ),
            child: Text(
              visible.isEmpty
                  ? 'Waiting for categorized spends'
                  : 'This month · tap a category for details',
              style: BambooFonts.ui(11.5, color: BambooInk.ink500),
            ),
          ),
        ],
      ),
    );
  }
}

List<CategorySpend> _categorySpendFromTransactions(
  List<TransactionEntry> transactions,
) {
  final totals = <String, Money>{};
  final counts = <String, int>{};
  for (final transaction in transactions) {
    if (transaction.status != 'active' ||
        transaction.entryKind != TxnEntryKind.spend) {
      continue;
    }
    final label = transaction.categoryLabel == 'Other'
        ? 'Other spending'
        : transaction.categoryLabel;
    totals[label] = (totals[label] ?? const Money.zero()) + transaction.amount;
    counts[label] = (counts[label] ?? 0) + 1;
  }
  return [
    for (final entry in totals.entries)
      CategorySpend(
        categoryId: null,
        categorySlug: null,
        categoryName: entry.key == 'Other spending' ? null : entry.key,
        totalSpend: entry.value,
        txnCount: counts[entry.key] ?? 0,
      ),
  ];
}

class _HomeCategoryCard extends StatelessWidget {
  final CategorySpend row;

  const _HomeCategoryCard({required this.row});

  @override
  Widget build(BuildContext context) {
    final visual = spendingCategoryVisual(row.displayName);
    return SizedBox(
      width: 232,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => context.push(
          '${AppRoute.spendTrends}?category=${Uri.encodeComponent(row.categoryId ?? row.categoryName ?? 'Other')}',
        ),
        child: Container(
          padding: const EdgeInsets.all(AppSpace.md),
          decoration: BoxDecoration(
            color: BambooInk.glassFillOnPaper,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: BambooInk.hairlineOnPaper),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: visual.surface,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(visual.icon, size: 19, color: visual.accent),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      row.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BambooFonts.ui(
                        14,
                        weight: FontWeight.w700,
                        color: BambooInk.ink900,
                      ),
                    ),
                  ),
                ],
              ),
              const Spacer(),
              MoneyText(
                row.totalSpend,
                confidence: Confidence.estimated,
                style: BambooFonts.money(20, color: BambooInk.ink900),
                hidePaise: true,
                showConfidenceIcon: false,
              ),
              const SizedBox(height: 2),
              Text(
                '${row.txnCount} ${row.txnCount == 1 ? 'spend' : 'spends'}',
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeDuesAndReminders extends ConsumerWidget {
  const _HomeDuesAndReminders();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows =
        ref.watch(paymentsDueProvider).valueOrNull ?? const <DuePayment>[];
    final catalogue = ref.watch(catalogueProvider).valueOrNull ?? const [];
    final now = ref.watch(clockProvider).now();
    var total = const Money.zero();
    for (final row in rows) {
      final bill = row.bill;
      if (bill != null && bill.amountDue != null) {
        total += bill.outstanding ?? const Money.zero();
      } else {
        total += row.loggedThisCycle;
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xl),
      child: Container(
        padding: const EdgeInsets.only(top: AppSpace.md, bottom: AppSpace.md),
        decoration: BoxDecoration(
          color: BambooInk.glassFillOnPaper,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BambooInk.hairlineOnPaper),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HomeScreen._gutter,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Dues & reminders',
                      style: BambooFonts.heading(20, color: BambooInk.ink900),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Manage due dates',
                    onPressed: () => context.push(AppRoute.dueDateCalendar),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HomeScreen._gutter,
                ),
                child: Container(
                  height: 96,
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    color: BambooInk.paperMuted,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.event_available_outlined,
                        color: BambooInk.ink500,
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Expanded(
                        child: Text(
                          'No due dates set yet. Add due dates to see upcoming payments here.',
                          style: BambooFonts.ui(13, color: BambooInk.ink500),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              SizedBox(
                height: 190,
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HomeScreen._gutter,
                  ),
                  scrollDirection: Axis.horizontal,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppSpace.sm),
                  itemBuilder: (context, index) => _HomeDueCard(
                    row: rows[index],
                    product: catalogue.firstWhereOrNull(
                      (product) => product.id == rows[index].card.cardProductId,
                    ),
                    now: now,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HomeScreen._gutter,
                  AppSpace.sm,
                  HomeScreen._gutter,
                  0,
                ),
                child: Row(
                  children: [
                    Text(
                      rows.any((row) => row.bill?.amountDue != null)
                          ? 'Outstanding on these cards'
                          : 'Tracked spend on these cards',
                      style: BambooFonts.ui(12, color: BambooInk.ink500),
                    ),
                    const Spacer(),
                    MoneyText(
                      total,
                      confidence: Confidence.estimated,
                      style: BambooFonts.money(16, color: BambooInk.ink900),
                      hidePaise: true,
                      showConfidenceIcon: false,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HomeDueCard extends StatelessWidget {
  final DuePayment row;
  final CardProduct? product;
  final DateTime now;

  const _HomeDueCard({
    required this.row,
    required this.product,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final urgent = row.daysUntilDue <= 5;
    final name = row.card.nickname?.isNotEmpty == true
        ? row.card.nickname!
        : row.card.cardName;
    final bill = row.bill;
    final outstanding = bill?.outstanding;
    final showsBill = bill != null && bill.isCurrentAsOf(now);
    return SizedBox(
      width: 236,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: urgent ? BambooInk.warningBg : BambooInk.paperMuted,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: urgent ? BambooInk.warningBorder : BambooInk.hairlineOnPaper,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (product != null) ...[
              SizedBox(
                width: double.infinity,
                height: 58,
                child: CardVisual(
                  product: product!,
                  userCard: row.card,
                  width: double.infinity,
                  height: 58,
                  showProductName: false,
                  effectiveBillingDay:
                      row.bill?.statementDate.day ?? row.card.statementDay,
                  effectiveDueDay: row.dueOn.day,
                ),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            Row(
              children: [
                Icon(
                  Icons.event_rounded,
                  size: 17,
                  color: urgent ? BambooInk.clayInk : BambooInk.ink500,
                ),
                const SizedBox(width: AppSpace.xs),
                Text(
                  row.daysUntilDue == 0
                      ? 'Due today'
                      : DateFormat('dd MMM').format(row.dueOn),
                  style: BambooFonts.ui(
                    12,
                    weight: FontWeight.w700,
                    color: urgent ? BambooInk.clayInk : BambooInk.ink500,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: BambooFonts.ui(
                14,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: 3),
            if (showsBill) ...[
              Text(
                'Bill · ${DateFormat('dd MMM').format(bill.statementDate)}',
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
              MoneyText(
                bill.isPaid
                    ? bill.amountDue!
                    : (outstanding ?? bill.paidToward),
                confidence: Confidence.estimated,
                style: BambooFonts.money(18, color: BambooInk.ink900),
                hidePaise: true,
                showConfidenceIcon: false,
              ),
              const SizedBox(height: 2),
              _BillStateChip(bill: bill),
            ] else ...[
              Text(
                'Logged spend this cycle',
                style: BambooFonts.ui(11, color: BambooInk.ink500),
              ),
              MoneyText(
                row.loggedThisCycle,
                confidence: Confidence.estimated,
                style: BambooFonts.money(18, color: BambooInk.ink900),
                hidePaise: true,
                showConfidenceIcon: false,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One line under the bill amount: full "Paid", partial progress, or the
/// requested "minimum due" nudge when the bill is only part-covered.
class _BillStateChip extends StatelessWidget {
  final CardBill bill;

  const _BillStateChip({required this.bill});

  @override
  Widget build(BuildContext context) {
    if (bill.amountDue == null) {
      return Text(
        bill.paidToward.isZero
            ? 'Amount not seen in SMS'
            : 'Payment ${bill.paidToward.format(hidePaise: true)}',
        style: BambooFonts.ui(11, color: BambooInk.ink500),
      );
    }
    if (bill.isPaid) {
      return Text(
        'Paid ✓',
        style: BambooFonts.ui(
          11.5,
          weight: FontWeight.w700,
          color: BambooInk.rankBadgeInk,
        ),
      );
    }
    if (bill.hasPayments) {
      return Text(
        '${bill.paidToward.format(hidePaise: true)} of ${bill.amountDue!.format(hidePaise: true)} paid',
        style: BambooFonts.ui(11, color: BambooInk.ink500),
      );
    }
    return Text('Unpaid', style: BambooFonts.ui(11, color: BambooInk.ink500));
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
