import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/api_exception.dart';
import '../data/app_status_repository.dart' show isVersionOlderThan;
import 'design/app_theme.dart';
import 'error_handling.dart';
import '../features/account/account_screen.dart';
import '../features/activity/activity_screen.dart';
import '../features/activity/duplicate_review_screen.dart';
import '../features/activity/edit_transaction_screen.dart';
import '../features/activity/needs_review_screen.dart';
import '../features/activity/transaction_detail_screen.dart';
import '../features/auth/guest_migration.dart';
import '../features/auth/login_screen.dart';
import '../features/cards/benefits_cheat_sheet_screen.dart';
import '../features/cards/card_detail_screen.dart';
import '../features/cards/discover_new_cards_screen.dart';
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
import '../features/insights/budgets_screen.dart';
import '../features/insights/grouped_insight_screen.dart';
import '../features/insights/spend_trends_screen.dart';
import '../features/insights/subscriptions_screen.dart';
import '../features/onboarding/account_choice_screen.dart';
import '../features/onboarding/add_first_card_screen.dart';
import '../features/onboarding/card_details_setup_screen.dart';
import '../features/onboarding/permissions_screen.dart';
import '../features/onboarding/splash_screen.dart';
import '../features/onboarding/tour_screen.dart';
import '../features/onboarding/tracking_setup_screen.dart';
import '../features/onboarding/tutorial_overlay.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/scan/scan_result_screen.dart';
import '../features/scan/upi_qr_scanner_screen.dart';
import '../features/settings/settings_sync.dart';
import '../features/sync/sync_engine.dart';
import '../features/settings/account_settings_screen.dart' show biometricLockProvider;
import '../features/system/biometric_lock_screen.dart';
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
  static const discoverNewCards = '/cards/discover';

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

  /// Spend Trends — the week/month/quarter/year view with a real comparison
  /// against the previous period. Distinct from [spendingOverview], which
  /// only ever shows the current calendar month.
  static const spendTrends = '/insights/trends';

  /// Budgets — advisory limits the user sets for themselves.
  static const budgets = '/insights/budgets';

  /// Subscriptions — repeating charges found in the user's own history.
  static const subscriptions = '/insights/subscriptions';

  /// The three GROUPED insights. Each holds screens that used to be their
  /// own tile as tabs — see GroupedInsightScreen for why eighteen separate
  /// entry points was the wrong shape. The individual routes below still
  /// exist and still work; these are the entry points the hub now offers.
  static const limitsAndPerks = '/insights/limits';
  static const rewardsGroup = '/insights/rewards';
  static const paymentsGroup = '/insights/payments';
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

  /// Enforcement side of account_settings_screen.dart's "Biometric lock"
  /// toggle (biometric_lock_screen.dart) — same unbypassable-block shape as
  /// maintenance/forceUpgrade above, checked just after the onboarding
  /// guard (the toggle is unreachable, so never legitimately on, before
  /// onboarding completes) and likewise NOT a member of [preOnboarding].
  static const biometricLock = '/biometric-lock';

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

  /// Design 15/27-29: inserted between Account Choice and Add First Card —
  /// see the "First run, once only" sequence in the design README's
  /// Interactions & behavior section (15 -> 27 -> 28 -> 29 -> 30 -> 31).
  static const permissions = '/onboarding/permissions';
  static const tour = '/onboarding/tour';

  /// Screens shown before onboarding is complete — the redirect guard below
  /// treats this set as its whole "am I in the pre-onboarding flow" check.
  static const preOnboarding = {
    splash,
    welcome,
    accountChoice,
    logIn,
    signUp,
    permissions,
    tour,
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
    // Biometric lock — same reasoning as appStatusProvider above: once
    // biometric_lock_screen.dart flips biometricUnlockedProvider to true,
    // the redirect needs to re-run to actually navigate away from it. This
    // is what lets that screen just update state rather than importing
    // router.dart itself to call context.go (same pattern as
    // MaintenanceScreen, which doesn't navigate on recovery either).
    ref.listen(biometricUnlockedProvider, (_, _) => notifyListeners());
    // biometricLockProvider itself must ALSO be listened to, not just
    // biometricUnlockedProvider above: BiometricLockController starts at
    // AsyncValue.loading() and only resolves once its SharedPreferences
    // read completes. Without this, the redirect's very first evaluation
    // on a cold start can run before that read finishes, read
    // `.valueOrNull ?? false` as "off", and let the app straight through —
    // and since nothing would ever re-trigger the redirect afterward, the
    // lock stayed silently bypassed for that entire session. Confirmed on
    // a real device: with the toggle already on from a previous session,
    // a cold relaunch landed on Home, never on BiometricLockScreen.
    ref.listen(biometricLockProvider, (_, _) => notifyListeners());
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
/// The ShellRoute's own Navigator — every hub-of-a-hub screen (Import Hub,
/// Tools Hub, Travel Mode, Sync & Backup, IMAP connection, etc.) is a plain
/// Navigator.push/context.push on top of THIS Navigator, not a registered
/// route of its own. Switching bottom-nav tabs only tells go_router to swap
/// which of the 4 tab GoRoutes is active — it does NOT know about, and so
/// never pops, anything pushed imperatively on top. Without popping back to
/// this Navigator's base page first, tapping a different tab left whatever
/// was pushed (e.g. Tools & Travel) stuck on screen with a stale AppBar
/// title/tab highlight that didn't match — a confirmed, reproduced bug.
/// `_navButton` below uses this key to unwind that stack before navigating.
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// True while something is pushed on top of the current tab (a card detail,
/// Sign in, Tools, a settings page…).
///
/// The nav pill is drawn by the shell, *above* its child, so it stayed
/// visible over every pushed screen — including full-bleed dark ones like
/// design 06 Sign in, where a translucent slate bar over a slate background
/// read as a rendering fault. No detail screen in the deck carries the tab
/// bar; only the four tab roots do. This lets the shell hide it for exactly
/// as long as something sits on top.
final _shellStackNotEmpty = ValueNotifier<bool>(false);

/// Feeds [_shellStackNotEmpty]. A route with a null `settings.name` and no
/// [Page] is an imperative `Navigator.push` — go_router's own tab pages come
/// through as [Page]-based routes, so counting every route would make the
/// pill vanish on the tabs themselves.
class _ShellStackObserver extends NavigatorObserver {
  int _depth = 0;

  void _sync(int delta) {
    _depth = (_depth + delta).clamp(0, 1 << 30);
    // Deferred: this fires mid-build during a push, and writing to a
    // ValueNotifier a widget is already listening to would rebuild it
    // inside its own build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shellStackNotEmpty.value = _depth > 0;
    });
  }

  bool _isImperative(Route<dynamic> route) => route is! ModalRoute || route.settings is! Page;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isImperative(route)) _sync(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isImperative(route)) _sync(-1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isImperative(route)) _sync(-1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null && _isImperative(oldRoute)) _sync(-1);
    if (newRoute != null && _isImperative(newRoute)) _sync(1);
  }
}

final goRouterProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefreshNotifier(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: AppRoute.splash,
    refreshListenable: refresh,
    // Without this, an unmatched or failed route falls through to
    // go_router's own bare default error page — functional, but off-brand
    // and unhelpful ("Exception: ..." dumped as raw text). A stale deep
    // link, a route built for a since-removed screen, or a redirect bug
    // all land here; "go home" is always a safe recovery for any of them.
    errorBuilder: (context, state) =>
        AppRouteErrorScreen(error: state.error, onGoHome: () => context.go(AppRoute.home)),
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

      // A signed-in session proves onboarding already happened (on this
      // device or another one) — without this, logging into an existing
      // account on a fresh install still bounces through the whole
      // Welcome -> Account Choice -> Add Card funnel, since
      // onboardingCompleteProvider is a per-device SharedPreferences flag
      // with no idea the login above it just succeeded.
      final signedIn = ref.read(accessTokenProvider) != null;
      final complete = (onboarding.valueOrNull ?? false) || signedIn;

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

      // Biometric lock — checked only once onboarding is complete (the
      // toggle lives in Account Settings, unreachable before then, so it
      // can never legitimately be on for a pre-onboarding user). Same
      // "process-lifetime, not persisted" note as biometricUnlockedProvider
      // itself: a fresh cold start always re-locks; this redirect just
      // enforces that by intercepting every route until it flips true.
      final biometricLockOn = ref.read(biometricLockProvider).valueOrNull ?? false;
      final biometricUnlocked = ref.read(biometricUnlockedProvider);
      if (biometricLockOn && !biometricUnlocked) {
        return path == AppRoute.biometricLock ? null : AppRoute.biometricLock;
      }
      if (path == AppRoute.biometricLock) return AppRoute.home; // already unlocked

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
        pageBuilder: (context, state) => const NoTransitionPage(
          child: Scaffold(body: LoginScreen(mode: AuthMode.logIn)),
        ),
      ),
      GoRoute(
        path: AppRoute.signUp,
        pageBuilder: (context, state) => const NoTransitionPage(
          child: Scaffold(body: LoginScreen(mode: AuthMode.signUp)),
        ),
      ),
      // Design 15/27-29: permissions + tour, inserted between Account Choice
      // and Add First Card — same linear-step reasoning as A7/A9/A10 below.
      GoRoute(
        path: AppRoute.permissions,
        pageBuilder: (context, state) => const NoTransitionPage(child: PermissionsScreen()),
      ),
      GoRoute(
        path: AppRoute.tour,
        pageBuilder: (context, state) => const NoTransitionPage(child: TourScreen()),
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
        pageBuilder: (context, state) =>
            NoTransitionPage(child: CardDetailsSetupScreen(userCardIds: state.extra! as List<String>)),
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
      // explicitly). go_router matches in declaration order, not by
      // specificity, so both static siblings below must come BEFORE this
      // '/activity/:id' route — otherwise it swallows them with :id
      // literally bound to "needs-review" / "duplicates" (this was a real,
      // reproduced bug: opening Needs Review 500'd with a Postgres
      // "invalid input syntax for type uuid" error). Same fix applied to
      // cardDetail's '/cards/:id' vs. its own static siblings above.
      GoRoute(path: AppRoute.needsReview, builder: (context, state) => const NeedsReviewScreen()),
      GoRoute(path: AppRoute.duplicateReview, builder: (context, state) => const DuplicateReviewScreen()),
      GoRoute(
        path: AppRoute.transactionDetail,
        builder: (context, state) => TransactionDetailScreen(transactionId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/activity/:id/edit',
        builder: (context, state) => EditTransactionScreen(transactionId: state.pathParameters['id']!),
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
      // These two carry their own Scaffold+AppBar (unlike the tile screens
      // above, which are wrapped here) because both need a floating action
      // button and their own period chips under the title.
      GoRoute(path: AppRoute.spendTrends, builder: (context, state) => const SpendTrendsScreen()),
      GoRoute(path: AppRoute.budgets, builder: (context, state) => const BudgetsScreen()),
      GoRoute(path: AppRoute.subscriptions, builder: (context, state) => const SubscriptionsScreen()),

      // Grouped insights. The tab bodies are the ORIGINAL screens — each was
      // already a plain body the routes above wrap in a Scaffold, so they
      // embed unchanged and the standalone routes keep working.
      GoRoute(
        path: AppRoute.limitsAndPerks,
        builder: (context, state) => const GroupedInsightScreen(
          title: 'Limits & perks',
          tabs: [
            (label: 'Caps', body: CapsScreen()),
            (label: 'Milestones', body: MilestonesScreen()),
            (label: 'Fee waivers', body: FeeWaiversScreen()),
            // A lounge quota is the same shape as a cap — "N visits a year,
            // M used" — so it belongs with the thresholds rather than
            // sitting alone on the grid.
            (label: 'Lounge', body: LoungeAccessScreen()),
          ],
        ),
      ),
      GoRoute(
        path: AppRoute.rewardsGroup,
        builder: (context, state) => const GroupedInsightScreen(
          title: 'Rewards',
          tabs: [
            (label: 'This month', body: MonthlySavingsScreen()),
            (label: 'Missed', body: MissedOpportunitiesScreen(showChrome: false)),
            (label: 'By card', body: PortfolioAuditScreen()),
          ],
        ),
      ),
      GoRoute(
        path: AppRoute.paymentsGroup,
        builder: (context, state) => const GroupedInsightScreen(
          title: 'Payments',
          tabs: [
            (label: 'Due dates', body: DueDateCalendarScreen()),
            (label: 'Interest-free days', body: BillingFloatScreen()),
            (label: 'Utilization', body: CreditUtilizationScreen()),
          ],
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
      // explicitly). go_router matches routes in declaration order, not by
      // specificity, so every static '/cards/...' sibling (pointsExpiry,
      // reportWrongData, requestNewCard, same as benefitsCheatSheet above)
      // must be declared BEFORE this '/cards/:id' route — otherwise it
      // swallows them with :id literally bound to e.g. "points-expiry".
      // (That's exactly what happened here before this fix; see the same
      // bug on the /activity/:id vs. needsReview/duplicateReview routes
      // below, which gets the identical fix.)
      GoRoute(path: AppRoute.pointsExpiry, builder: (context, state) => const PointsExpiryScreen()),
      GoRoute(
        path: AppRoute.reportWrongData,
        builder: (context, state) =>
            ReportWrongDataScreen(cardProductId: state.uri.queryParameters['cardProductId']!),
      ),
      GoRoute(path: AppRoute.requestNewCard, builder: (context, state) => const RequestNewCardScreen()),
      // Same static-before-dynamic ordering requirement as pointsExpiry etc.
      // above — must stay before cardDetail ('/cards/:id').
      GoRoute(
        path: AppRoute.discoverNewCards,
        builder: (context, state) => const DiscoverNewCardsScreen(),
      ),
      GoRoute(
        path: AppRoute.cardDetail,
        builder: (context, state) => CardDetailScreen(userCardId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoute.editCard,
        builder: (context, state) => EditCardScreen(userCardId: state.pathParameters['id']!),
      ),
      // F1 Import Hub already builds its own Scaffold+AppBar (its F2-F7
      // children are reached via plain pushed routes from inside it, not
      // more go_router entries — see AppRoute.importHub's doc-comment).
      GoRoute(path: AppRoute.importHub, builder: (context, state) => const ImportHubScreen()),
      // Group G — same "already builds its own Scaffold+AppBar" shape as
      // importHub above.
      GoRoute(path: AppRoute.toolsHub, builder: (context, state) => const ToolsHubScreen()),
      // G4: reachable with or without a session — see AppRoute.
      // emergencyCardInfo's own doc-comment for why this is a top-level
      // route rather than nested under toolsHub's push chain.
      GoRoute(path: AppRoute.emergencyCardInfo, builder: (context, state) => const EmergencyCardInfoScreen()),
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
      GoRoute(
        path: AppRoute.biometricLock,
        pageBuilder: (context, state) => const NoTransitionPage(child: BiometricLockScreen()),
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        observers: [_ShellStackObserver()],
        builder: (context, state, child) => _AppShell(location: state.uri.path, child: child),
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

  // Labels match the design doc's own nav copy ("02 Wallet" / "05 You")
  // exactly — routes/AppRoute names stay unchanged since those are wired
  // through go_router paths and tests, not user-visible.
  static const _destinations = [
    (AppRoute.home, 'Home', Icons.home_rounded),
    (AppRoute.cards, 'Wallet', Icons.credit_card_rounded),
    (AppRoute.insights, 'Insights', Icons.insights_rounded),
    (AppRoute.account, 'You', Icons.person_rounded),
  ];

  /// Design 03 "Tap to Sniff": the lime circle in the middle of the nav bar
  /// is the *merchant* scanner — point it at a UPI QR or a bill and get a
  /// card recommendation before you pay. It used to open the add-a-card OCR
  /// scanner instead, with merchant-scan demoted to a small app-bar icon,
  /// which inverted the design's whole core loop. Adding a card isn't lost:
  /// it's still on Wallet's own "Scan a card" action and on onboarding's
  /// "Photograph the card" — which is exactly where the deck puts it.
  Future<void> _scanToPay() async {
    setState(() => _scanning = true);
    try {
      final parsed = await Navigator.of(
        context,
      ).push<ParsedUpiQr>(MaterialPageRoute(builder: (_) => const UpiQrScannerScreen()));
      if (parsed != null && mounted) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => ScanResultScreen(parsed: parsed)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start the scanner. ${userFacingErrorMessage(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _scanning = false);
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
    // Plan Phase 1.1/1.2: on each sign-in, pull the account's preference
    // blob down onto this device and hand any guest wallet built before
    // sign-up to the server. Same "read once from the shell" reasoning.
    ref.watch(settingsSyncLifecycleProvider);
    ref.watch(guestMigrationLifecycleProvider);
    // Plan Phase 2.2 — the top of the activation funnel. Fired from the
    // shell's initState (see _appOpenedTracked) rather than build, which
    // runs on every tab switch.
    ref.watch(analyticsLifecycleProvider);
    // Plan Phase 4 — pushes queued local edits and pulls other devices'
    // changes on sign-in and on regaining connectivity.
    ref.watch(syncLifecycleProvider);
    // UA-8.3 (B3) — the trigger sweep for caps/milestones/fee-waivers/bills/
    // points-expiry/monthly-report/needs-review notifications. Same "read
    // once from the shell" reasoning as everything else on this list.
    ref.watch(notificationTriggerLifecycleProvider);
    ref.watch(smsBackgroundFlushProvider);
    // Tell the user their guest wallet moved. Quietly relocating someone's
    // cards is nearly as disconcerting as losing them — and if any card
    // couldn't be carried over (its product was unpublished in the
    // meantime), that has to be said out loud rather than left for them to
    // notice a gap later.
    ref.listen<GuestMigrationResult?>(lastGuestMigrationProvider, (_, result) {
      if (result == null || !result.didAnything) return;
      final moved = result.imported == 1 ? '1 card' : '${result.imported} cards';
      final message = result.skipped > 0
          ? '$moved moved to your account · ${result.skipped} couldn\'t be matched'
          : '$moved moved to your account';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
    final tutorialKeys = ref.watch(tutorialKeysProvider);
    // Task 5: the coach-mark tour only makes sense over Home (that's where
    // every one of its four targets lives) — a user who backs out to
    // another tab mid-tour simply doesn't see it there rather than the
    // overlay trying to follow them to a screen with nothing to point at.
    final showTutorial =
        widget.location == AppRoute.home && !(ref.watch(tutorialSeenProvider).valueOrNull ?? true);
    return Scaffold(
      backgroundColor: BambooInk.paper,
      // No AppBar. Not one of the deck's 32 mockups gives a tab screen a
      // title bar — each one opens straight onto its own content header
      // ("Evening, Aarav" on 01, "Your wallet" on 02, …) drawn on the same
      // continuous background. A shared "PandaPay — Home" chrome strip on
      // top of that reads as a separate app bolted above the design, which
      // is exactly what it looked like.
      //
      // Design (every "01 Home" .. "32 Monthly recap" mockup): the nav is a
      // floating dark glass pill drawn INSIDE each screen's own bottom
      // inset, not a native Scaffold bottomNavigationBar/FAB pairing — the
      // scan button lives inside the bar itself as a raised lime circle,
      // not a docked FAB elevated above a notch. Reserve 128 (bar's ~92
      // total footprint + comfortable clearance) at the bottom of every tab
      // body, same number the mockup uses for its scroll padding.
      body: Stack(
        children: [
          // Full-bleed, NOT inset by the pill's height: the mockups scroll
          // content *under* the bar (hence its backdrop blur), and insetting
          // it left a bare white band between the screen's own background
          // and the bar. Each tab pays the clearance itself as bottom scroll
          // padding — AppShell.navClearance.
          widget.child,
          if (showTutorial) const TutorialOverlay(),
          // `bottom: 26` measured from the physical bottom of the 390×844
          // frame, exactly as the mockup positions it — NOT 26 above the
          // home-indicator inset. Wrapping this in a SafeArea added the
          // device's 34pt bottom inset underneath and floated the bar at
          // 60pt, visibly higher than every mockup.
          Positioned(
            left: 16,
            right: 16,
            bottom: 26,
            child: ValueListenableBuilder<bool>(
              valueListenable: _shellStackNotEmpty,
              builder: (context, pushedOnTop, child) =>
                  pushedOnTop ? const SizedBox.shrink() : child!,
              child: _FloatingNavBar(
                key: const ValueKey('appShellNavBar'),
                destinations: _destinations,
                location: widget.location,
                scanning: _scanning,
                scanKey: tutorialKeys.scanFab,
                onSelect: (path) {
                  _shellNavigatorKey.currentState?.popUntil((route) => route.isFirst);
                  context.go(path);
                },
                onScan: _scanning ? null : _scanToPay,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The floating glass pill nav bar itself — matches the design doc's
/// literal box model (16px side margins, 26px from the bottom, 66pt tall,
/// 24pt corner radius, rgba(43,49,58,0.86) + blur, hairline white border)
/// rather than a Material BottomAppBar, since a BottomAppBar can't float
/// off the screen edge with margins on all four sides or host a raised
/// circular action inline instead of docked above a notch.
class _FloatingNavBar extends StatelessWidget {
  final List<(String, String, IconData)> destinations;
  final String location;
  final bool scanning;
  final Key? scanKey;
  final ValueChanged<String> onSelect;
  final VoidCallback? onScan;

  const _FloatingNavBar({
    super.key,
    required this.destinations,
    required this.location,
    required this.scanning,
    required this.scanKey,
    required this.onSelect,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: 66,
          decoration: BoxDecoration(
            color: BambooInk.slate.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: BambooInk.slate.withValues(alpha: 0.26),
                blurRadius: 34,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _navItem(destinations[0]),
              _navItem(destinations[1]),
              SizedBox(
                width: 60,
                child: Center(
                  child: GestureDetector(
                    key: scanKey,
                    onTap: onScan,
                    child: Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: BambooInk.lime,
                        borderRadius: BorderRadius.circular(19),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: scanning
                          ? const Padding(
                              padding: EdgeInsets.all(15),
                              child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.slate),
                            )
                          : const Icon(Icons.qr_code_scanner_rounded, color: BambooInk.slate, size: 24),
                    ),
                  ),
                ),
              ),
              _navItem(destinations[2]),
              _navItem(destinations[3]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem((String, String, IconData) destination) {
    final (path, label, icon) = destination;
    final selected = location == path;
    final color = selected ? BambooInk.lime : Colors.white.withValues(alpha: 0.74);
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => onSelect(path),
        child: Semantics(
          label: label,
          selected: selected,
          button: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 21),
              const SizedBox(height: 4),
              Text(
                label,
                style: BambooFonts.ui(10, weight: selected ? FontWeight.w600 : FontWeight.w500, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
