import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/api_exception.dart';
import '../data/app_status_repository.dart' show isVersionOlderThan;
import '../features/account/account_screen.dart';
import '../features/activity/activity_screen.dart';
import '../features/activity/duplicate_review_screen.dart';
import '../features/activity/edit_transaction_screen.dart';
import '../features/activity/needs_review_screen.dart';
import '../features/activity/transaction_detail_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/cards/benefits_cheat_sheet_screen.dart';
import '../features/cards/card_detail_screen.dart';
import '../features/cards/edit_card_screen.dart';
import '../features/cards/my_cards_screen.dart';
import '../features/cards/points_expiry_screen.dart';
import '../features/cards/report_wrong_data_screen.dart';
import '../features/cards/request_new_card_screen.dart';
import '../features/home/home_screen.dart';
import '../features/import/import_hub_screen.dart';
import '../features/insights/billing_float_screen.dart';
import '../features/insights/caps_screen.dart';
import '../features/insights/credit_utilization_screen.dart';
import '../features/insights/due_date_calendar_screen.dart';
import '../features/insights/fee_waivers_screen.dart';
import '../features/insights/insights_hub_screen.dart';
import '../features/insights/lounge_access_screen.dart';
import '../features/insights/milestones_screen.dart';
import '../features/insights/missed_opportunities_screen.dart';
import '../features/insights/monthly_savings_screen.dart';
import '../features/insights/my_contributions_screen.dart';
import '../features/insights/portfolio_audit_screen.dart';
import '../features/insights/spending_overview_screen.dart';
import '../features/onboarding/account_choice_screen.dart';
import '../features/onboarding/add_first_card_screen.dart';
import '../features/onboarding/card_details_setup_screen.dart';
import '../features/onboarding/splash_screen.dart';
import '../features/onboarding/tracking_setup_screen.dart';
import '../features/onboarding/tutorial_overlay.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/scan/scan_card_screen.dart';
import '../features/scan/scan_result_screen.dart';
import '../features/scan/upi_qr_scanner_screen.dart';
import '../features/system/forced_upgrade_screen.dart';
import '../features/system/maintenance_screen.dart';
import '../features/tools/emergency_card_info_screen.dart';
import '../features/tools/tools_hub_screen.dart';
import 'providers.dart';
import 'tutorial_keys.dart';

/// Route paths as constants so a typo becomes a compile-time-adjacent grep
/// hit instead of a silent 404 — every `context.go(...)` call in the app
/// should reference these rather than a literal string.
abstract final class AppRoute {
  static const splash = '/splash';
  static const welcome = '/welcome';
  static const accountChoice = '/account-choice';
  static const logIn = '/login';
  static const signUp = '/signup';
  static const home = '/home';
  static const cards = '/cards';
  static const insights = '/insights';
  static const account = '/account';

  /// Group C (Cards) net-new screens (implementation-plan-group-c-d.md).
  /// Same "plain pushed route, screen builds its own Scaffold+AppBar"
  /// pattern as importHub/toolsHub above — deep-linkable per ui-spec §1
  /// ("card detail" is explicitly named there), reached from C1 My Cards.
  static const benefitsCheatSheet = '/cards/benefits';
  static const cardDetail = '/cards/:id';
  static const editCard = '/cards/:id/edit';
  static const pointsExpiry = '/cards/points-expiry';
  static const reportWrongData = '/cards/report-wrong-data';
  static const requestNewCard = '/cards/request-new-card';

  /// Group D (Transactions) net-new screens. transactionDetail is
  /// deep-linkable per ui-spec §1 ("transaction detail" explicitly named).
  static const transactionDetail = '/activity/:id';
  static const needsReview = '/activity/needs-review';
  static const duplicateReview = '/activity/duplicates';
  static const missedOpportunities = '/insights/missed-opportunities';

  /// Task 7: no longer a bottom-nav destination — Material's 5-item ceiling
  /// meant Insights displaced it, not joined it, once a 4th non-Home/Cards/
  /// Account destination was needed. Still a real route, reached only via
  /// Insights Hub's "All Activity" tile now.
  static const activity = '/activity';
  static const caps = '/insights/caps';
  static const milestones = '/insights/milestones';
  static const billingFloat = '/insights/billing-float';

  /// Group E (Trackers & Insights) net-new screens (E3, E5, E6, E8, E9,
  /// E10, E11, E12) — implementation-plan-group-e-f-g.md. Same pushed-route
  /// pattern as caps/milestones/billingFloat above (AppBar + back), all
  /// reached from Insights Hub (E1)'s tile grid.
  static const creditUtilization = '/insights/credit-utilization';
  static const feeWaivers = '/insights/fee-waivers';
  static const loungeAccess = '/insights/lounge-access';
  static const dueDateCalendar = '/insights/due-dates';
  static const monthlySavings = '/insights/savings-report';
  static const portfolioAudit = '/insights/portfolio-audit';
  static const spendingOverview = '/insights/spending-overview';
  static const myContributions = '/insights/my-contributions';

  /// Group F (Data Import & Sync) — implementation-plan-group-e-f-g.md §3.
  /// F1 Import Hub is the one entry point reached from Account's Tools
  /// section (F3's per-plan navigation finding); F2-F7 are all reached from
  /// F1's tiles via plain Navigator.push, not separate registered routes —
  /// same "go look at one thing and come back" reasoning the caps/
  /// milestones/billingFloat routes above already follow, and F1's own
  /// children are one level deeper still (a hub-of-a-hub), so a second tier
  /// of go_router routes would add ceremony with no real navigation need.
  static const importHub = '/account/import';

  /// Group G (Tools & Modes) — implementation-plan-group-e-f-g.md §4. Same
  /// hub-of-a-hub pattern as importHub above: G1-G3 are reached from
  /// [toolsHub] via plain Navigator.push, not separate registered routes.
  static const toolsHub = '/account/tools';

  /// G4 Emergency Card Info is deliberately its OWN top-level route,
  /// registered outside the ShellRoute and outside toolsHub's push chain —
  /// per the plan's "zero network and zero login" mandate, it must be
  /// reachable without going through Account's sign-in gate. See
  /// LoginScreen's own entry point and this route's doc-comment in
  /// tools_hub_screen.dart for how both paths land on the same screen.
  static const emergencyCardInfo = '/emergency-card-info';

  /// S5/S6 (ui-spec System Surfaces, GAP_ANALYSIS.md §3) — forced upgrade /
  /// maintenance mode. Both are unbypassable full-screen blocks, checked
  /// ahead of the onboarding guard below (a maintenance window or a
  /// too-old install blocks the app regardless of onboarding state) and
  /// deliberately NOT members of [preOnboarding] — that set means "only
  /// reachable before onboarding completes," which doesn't apply here.
  static const maintenance = '/maintenance';
  static const forceUpgrade = '/force-upgrade';

  /// A7/A9/A10 (implementation-plan's Group A completion): the rest of the
  /// onboarding chain after Account Choice, per ui-spec's real screen order
  /// A3 -> A7 -> A9 -> A10 -> A11 -> Home. A8 (Request Unsupported Card) is
  /// deliberately NOT a registered route here — same "go look at one thing
  /// and come back" reasoning as importHub/toolsHub's own children above:
  /// it's reached by a plain `Navigator.push` from A7 (and, unchanged, from
  /// C8 elsewhere), not a forward step in this linear flow.
  static const addFirstCard = '/onboarding/add-card';
  static const cardDetailsSetup = '/onboarding/card-details';
  static const trackingSetup = '/onboarding/tracking-setup';

  /// Screens shown before onboarding is complete — the redirect guard below
  /// treats this set as its whole "am I in the pre-onboarding flow" check.
  static const preOnboarding = {
    splash,
    welcome,
    accountChoice,
    logIn,
    signUp,
    addFirstCard,
    cardDetailsSetup,
    trackingSetup,
  };
}

/// Bridges Riverpod state into go_router's redirect re-evaluation.
/// GoRouter only re-runs `redirect` when its `refreshListenable` fires (or
/// on navigation) — without this, completing onboarding or finishing
/// sessionInitProvider would sit inert until the next manual navigation.
class _RouterRefreshNotifier extends ChangeNotifier {
  _RouterRefreshNotifier(Ref ref) {
    ref.listen(sessionInitProvider, (_, _) => notifyListeners());
    ref.listen(accessTokenProvider, (_, _) => notifyListeners());
    ref.listen(onboardingCompleteProvider, (_, _) => notifyListeners());
    // S5/S6 — re-evaluate redirect once the status/version checks resolve,
    // and again any time appStatusProvider is invalidated (e.g.
    // MaintenanceScreen's "Try again" button).
    ref.listen(appStatusProvider, (_, _) => notifyListeners());
    ref.listen(appVersionProvider, (_, _) => notifyListeners());
  }
}

/// Task 3 shipped the navigation-shell swap alone, deferring the
/// auth/onboarding redirect guard until its target screens (Welcome,
/// Account Choice — Tasks 4-6) existed. They do now, so this wires the real
/// guard:
///   1. While session resume or the onboarding flag is still loading, sit on
///      /splash — never flash Welcome or Home first and then jump.
///   2. Once resolved, onboarding NOT complete -> only [AppRoute.preOnboarding]
///      screens are reachable; anything else bounces to /welcome.
///   3. Onboarding complete -> preOnboarding screens are UNREACHABLE, even by
///      direct navigation (ui-spec.md A3: "no nagging later" — completing
///      onboarding once must never resurface it, not even via a stale deep
///      link). This is deliberately NOT gated on sign-in status: browsing
///      without an account remains fully supported after onboarding, same
///      as Home's existing guest-browse behaviour.
final goRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefreshNotifier(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: AppRoute.splash,
    refreshListenable: refresh,
    redirect: (context, state) {
      final path = state.uri.path;

      // S5/S6 — checked first, ahead of the onboarding guard below: a
      // maintenance window or a too-old install blocks the app regardless
      // of onboarding state. Only acts once appStatusProvider has actually
      // resolved to a non-null value — it fails open on its own fetch
      // error (returns null, see providers.dart), so a status-check outage
      // never itself blocks anyone; and the forced-upgrade branch only
      // acts once appVersionProvider has resolved too, so "haven't loaded
      // the version yet" is never mistaken for "too old."
      final status = ref.read(appStatusProvider).valueOrNull;
      if (status != null) {
        if (status.maintenanceMode) {
          return path == AppRoute.maintenance ? null : AppRoute.maintenance;
        }
        if (path == AppRoute.maintenance) return AppRoute.home; // recovered mid-session
        final version = ref.read(appVersionProvider).valueOrNull;
        if (version != null && isVersionOlderThan(version, status.minSupportedVersion)) {
          return path == AppRoute.forceUpgrade ? null : AppRoute.forceUpgrade;
        }
        if (path == AppRoute.forceUpgrade) return AppRoute.home;
      }

      final sessionInit = ref.read(sessionInitProvider);
      final onboarding = ref.read(onboardingCompleteProvider);

      if (sessionInit.isLoading || onboarding.isLoading) {
        return path == AppRoute.splash ? null : AppRoute.splash;
      }

      final complete = onboarding.valueOrNull ?? false;

      // Loading just finished. Splash must always hand off to a real
      // destination here — it's never itself a valid resting page once
      // resolved, even though it's a member of preOnboarding below (that
      // membership exists so /splash redirects to /splash, i.e. a no-op,
      // while still loading; it must NOT also mean "stay on splash forever"
      // once loading is done).
      if (path == AppRoute.splash) {
        return complete ? AppRoute.home : AppRoute.welcome;
      }

      if (!complete) {
        return AppRoute.preOnboarding.contains(path) ? null : AppRoute.welcome;
      }
      return AppRoute.preOnboarding.contains(path) ? AppRoute.home : null;
    },
    routes: [
      GoRoute(
        path: AppRoute.splash,
        pageBuilder: (context, state) => const NoTransitionPage(child: SplashScreen()),
      ),
      GoRoute(
        path: AppRoute.welcome,
        pageBuilder: (context, state) => const NoTransitionPage(child: WelcomeScreen()),
      ),
      GoRoute(
        path: AppRoute.accountChoice,
        pageBuilder: (context, state) => const NoTransitionPage(child: AccountChoiceScreen()),
      ),
      GoRoute(
        path: AppRoute.logIn,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: Scaffold(body: LoginScreen(mode: AuthMode.logIn))),
      ),
      GoRoute(
        path: AppRoute.signUp,
        pageBuilder: (context, state) =>
            const NoTransitionPage(child: Scaffold(body: LoginScreen(mode: AuthMode.signUp))),
      ),
      // A7/A9/A10: the rest of the onboarding chain, reached via
      // context.go(...) as forward linear steps (not pushed-and-returned
      // like A8) — see AppRoute's own doc-comment above for the push-vs-
      // route reasoning this follows.
      GoRoute(
        path: AppRoute.addFirstCard,
        pageBuilder: (context, state) => const NoTransitionPage(child: AddFirstCardScreen()),
      ),
      GoRoute(
        path: AppRoute.cardDetailsSetup,
        pageBuilder: (context, state) => NoTransitionPage(
          child: CardDetailsSetupScreen(userCardIds: state.extra! as List<String>),
        ),
      ),
      GoRoute(
        path: AppRoute.trackingSetup,
        pageBuilder: (context, state) => const NoTransitionPage(child: TrackingSetupScreen()),
      ),
      // Task 7-11: Insights Hub's drill-down screens. Plain pushed routes
      // (AppBar + back button), not part of the ShellRoute below — these are
      // "go look at one thing and come back", not top-level destinations a
      // user switches between, so a bottom-nav-persistent shell would be the
      // wrong pattern for them.
      GoRoute(
        path: AppRoute.caps,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Caps & Limits')),
          body: const CapsScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.milestones,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Milestones')),
          body: const MilestonesScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.billingFloat,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Billing Cycle Float')),
          body: const BillingFloatScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.activity,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Activity')),
          body: const ActivityScreen(),
        ),
      ),
      // D2/D3 — deep-linkable per ui-spec §1 ("transaction detail" named
      // explicitly). Static siblings (needsReview, duplicateReview) are
      // registered separately below, same "static beats param at the same
      // depth" reasoning as cardDetail's own doc-comment.
      GoRoute(
        path: AppRoute.transactionDetail,
        builder: (context, state) => TransactionDetailScreen(transactionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/activity/:id/edit',
        builder: (context, state) => EditTransactionScreen(transactionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoute.needsReview,
        builder: (context, state) => const NeedsReviewScreen(),
      ),
      GoRoute(
        path: AppRoute.duplicateReview,
        builder: (context, state) => const DuplicateReviewScreen(),
      ),
      GoRoute(
        path: AppRoute.creditUtilization,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Credit Utilization')),
          body: const CreditUtilizationScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.feeWaivers,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Annual Fee Waivers')),
          body: const FeeWaiversScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.loungeAccess,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Lounge Access')),
          body: const LoungeAccessScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.dueDateCalendar,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Due Date Calendar')),
          body: const DueDateCalendarScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.monthlySavings,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Monthly Savings Report')),
          body: const MonthlySavingsScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.portfolioAudit,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Portfolio Audit')),
          body: const PortfolioAuditScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.spendingOverview,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('Spending Overview')),
          body: const SpendingOverviewScreen(),
        ),
      ),
      GoRoute(
        path: AppRoute.myContributions,
        builder: (context, state) => Scaffold(
          appBar: AppBar(title: const Text('My Contributions')),
          body: const MyContributionsScreen(),
        ),
      ),
      // D6 — already builds its own Scaffold+AppBar, same shape as
      // importHub/toolsHub below.
      GoRoute(
        path: AppRoute.missedOpportunities,
        builder: (context, state) => const MissedOpportunitiesScreen(),
      ),
      // C5 Benefits Cheat Sheet already builds its own Scaffold+AppBar, same
      // shape as importHub/toolsHub below.
      GoRoute(
        path: AppRoute.benefitsCheatSheet,
        builder: (context, state) => const BenefitsCheatSheetScreen(),
      ),
      // C2 Card Detail — deep-linkable (ui-spec §1 names "card detail"
      // explicitly). go_router matches the static benefitsCheatSheet route
      // above in preference to this param route for the literal path
      // '/cards/benefits', so declaration order here doesn't create an
      // ambiguity between the two.
      GoRoute(
        path: AppRoute.cardDetail,
        builder: (context, state) => CardDetailScreen(userCardId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoute.editCard,
        builder: (context, state) => EditCardScreen(userCardId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoute.pointsExpiry,
        builder: (context, state) => const PointsExpiryScreen(),
      ),
      GoRoute(
        path: AppRoute.reportWrongData,
        builder: (context, state) => ReportWrongDataScreen(
          cardProductId: state.uri.queryParameters['cardProductId']!,
        ),
      ),
      GoRoute(
        path: AppRoute.requestNewCard,
        builder: (context, state) => const RequestNewCardScreen(),
      ),
      // F1 Import Hub already builds its own Scaffold+AppBar (its F2-F7
      // children are reached via plain pushed routes from inside it, not
      // more go_router entries — see AppRoute.importHub's doc-comment).
      GoRoute(
        path: AppRoute.importHub,
        builder: (context, state) => const ImportHubScreen(),
      ),
      // Group G — same "already builds its own Scaffold+AppBar" shape as
      // importHub above.
      GoRoute(
        path: AppRoute.toolsHub,
        builder: (context, state) => const ToolsHubScreen(),
      ),
      // G4: reachable with or without a session — see AppRoute.
      // emergencyCardInfo's own doc-comment for why this is a top-level
      // route rather than nested under toolsHub's push chain.
      GoRoute(
        path: AppRoute.emergencyCardInfo,
        builder: (context, state) => const EmergencyCardInfoScreen(),
      ),
      // S5/S6: unbypassable full-screen blocks — see the redirect guard
      // above and both AppRoute constants' doc-comments.
      GoRoute(
        path: AppRoute.maintenance,
        pageBuilder: (context, state) => const NoTransitionPage(child: MaintenanceScreen()),
      ),
      GoRoute(
        path: AppRoute.forceUpgrade,
        pageBuilder: (context, state) => const NoTransitionPage(child: ForcedUpgradeScreen()),
      ),
      ShellRoute(
        builder: (context, state, child) => _AppShell(
          location: state.uri.path,
          child: child,
        ),
        routes: [
          // NoTransitionPage on every tab: a bottom-nav switch should feel
          // instant, the same as the setState-based int-index switch this
          // replaced — not a page-push slide transition, which briefly
          // leaves the incoming screen's tappable content off its resting
          // position mid-animation (the router tests caught this directly:
          // a tap landed at x=949 in an 800px-wide viewport because the
          // default transition hadn't settled).
          GoRoute(
            path: AppRoute.home,
            pageBuilder: (context, state) => const NoTransitionPage(child: HomeScreen()),
          ),
          GoRoute(
            path: AppRoute.cards,
            pageBuilder: (context, state) => const NoTransitionPage(child: MyCardsScreen()),
          ),
          GoRoute(
            path: AppRoute.insights,
            pageBuilder: (context, state) => const NoTransitionPage(child: InsightsHubScreen()),
          ),
          GoRoute(
            path: AppRoute.account,
            pageBuilder: (context, state) => const NoTransitionPage(child: AccountScreen()),
          ),
        ],
      ),
    ],
  );
});

class _AppShell extends ConsumerStatefulWidget {
  final String location;
  final Widget child;
  const _AppShell({required this.location, required this.child});

  @override
  ConsumerState<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<_AppShell> {
  bool _scanning = false;

  static const _destinations = [
    (AppRoute.home, 'Home', Icons.home_rounded),
    (AppRoute.cards, 'Cards', Icons.credit_card_rounded),
    (AppRoute.insights, 'Insights', Icons.insights_rounded),
    (AppRoute.account, 'Account', Icons.person_rounded),
  ];

  String get _currentLabel =>
      _destinations.firstWhere((d) => d.$1 == widget.location, orElse: () => _destinations[0]).$2;

  /// UA-4: pushes the scanner as an imperative overlay on top of whichever
  /// tab is current — a one-off flow, not a bottom-nav destination, so it
  /// stays a plain Navigator.push rather than a registered go_router route.
  /// On a pick, hands the result to Cards via pendingScannedCardIdProvider
  /// (same handoff as before the router migration) and navigates there.
  Future<void> _scanFromFab() async {
    setState(() => _scanning = true);
    try {
      final catalogue = await ref.read(catalogueProvider.future);
      if (!mounted) return;
      final picked = await Navigator.of(context).push<CardProduct>(
        MaterialPageRoute(builder: (_) => ScanCardScreen(catalogue: catalogue)),
      );
      if (picked != null && mounted) {
        ref.read(pendingScannedCardIdProvider.notifier).state = picked.id;
        context.go(AppRoute.cards);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not start the scanner. ${userFacingErrorMessage(e)}')));
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// B2/B3: "scan a merchant's UPI QR to pay" — a second, separate scan
  /// entry point from the existing FAB's "scan to add a card" flow. Reachable
  /// from a new IconButton next to the FAB rather than repurposing the FAB
  /// itself, since the FAB's tooltip/semantics ("Scan a card") is already
  /// load-bearing for the add-card flow tested in
  /// app/test/app/router_test.dart.
  Future<void> _scanToPay() async {
    final parsed = await Navigator.of(context).push<ParsedUpiQr>(
      MaterialPageRoute(builder: (_) => const UpiQrScannerScreen()),
    );
    if (parsed != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ScanResultScreen(parsed: parsed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Runs sessionKeepAliveProvider for the app's whole lifetime — the shell
    // is the one widget guaranteed to stay mounted across every tab.
    ref.watch(sessionKeepAliveProvider);
    // UA-0.3 offline cache lifecycle — clears the per-user cache on
    // sign-out, and flushes the B6 offline outbox the moment connectivity
    // returns. Same "read once from the shell" reasoning as
    // sessionKeepAliveProvider above.
    ref.watch(cacheLifecycleProvider);
    ref.watch(outboxFlushProvider);
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    // Task 5: the coach-mark tour only makes sense over Home (that's where
    // every one of its four targets lives) — a user who backs out to
    // another tab mid-tour simply doesn't see it there rather than the
    // overlay trying to follow them to a screen with nothing to point at.
    final showTutorial =
        widget.location == AppRoute.home && !(ref.watch(tutorialSeenProvider).valueOrNull ?? true);
    return Scaffold(
      appBar: AppBar(title: Text('PandaPay — $_currentLabel')),
      body: showTutorial
          ? Stack(children: [widget.child, const TutorialOverlay()])
          : widget.child,
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'scanToPayFab',
            onPressed: _scanToPay,
            tooltip: 'Scan a UPI QR to pay',
            child: const Icon(Icons.qr_code_2_rounded),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.large(
            heroTag: 'scanFab',
            key: tutorialKeys.scanFab,
            onPressed: _scanning ? null : _scanFromFab,
            tooltip: 'Scan a card',
            child: _scanning
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.qr_code_scanner_rounded),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 8,
        padding: EdgeInsets.zero,
        child: SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navButton(_destinations[0]),
              _navButton(_destinations[1]),
              const SizedBox(width: 56),
              _navButton(_destinations[2]),
              _navButton(_destinations[3]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navButton((String, String, IconData) destination) {
    final (path, label, icon) = destination;
    final selected = widget.location == path;
    final color = selected ? Theme.of(context).colorScheme.primary : const Color(0xFF6B7684);
    return Expanded(
      child: InkWell(
        onTap: () => context.go(path),
        child: Semantics(
          label: label,
          selected: selected,
          button: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 2),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: color,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
