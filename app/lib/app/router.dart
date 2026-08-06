import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/api_exception.dart';
import '../features/account/account_screen.dart';
import '../features/activity/activity_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/cards/cards_screen.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/account_choice_screen.dart';
import '../features/onboarding/splash_screen.dart';
import '../features/onboarding/tutorial_overlay.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/scan/scan_card_screen.dart';
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
  static const activity = '/activity';
  static const account = '/account';

  /// Screens shown before onboarding is complete — the redirect guard below
  /// treats this set as its whole "am I in the pre-onboarding flow" check.
  static const preOnboarding = {splash, welcome, accountChoice, logIn, signUp};
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
      final sessionInit = ref.read(sessionInitProvider);
      final onboarding = ref.read(onboardingCompleteProvider);
      final path = state.uri.path;

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
            pageBuilder: (context, state) => const NoTransitionPage(child: CardsScreen()),
          ),
          GoRoute(
            path: AppRoute.activity,
            pageBuilder: (context, state) => const NoTransitionPage(child: ActivityScreen()),
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
    (AppRoute.activity, 'Activity', Icons.receipt_long_rounded),
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

  @override
  Widget build(BuildContext context) {
    // Runs sessionKeepAliveProvider for the app's whole lifetime — the shell
    // is the one widget guaranteed to stay mounted across every tab.
    ref.watch(sessionKeepAliveProvider);
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
      floatingActionButton: FloatingActionButton.large(
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
