import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pandapay_domain/pandapay_domain.dart';

import '../data/api_exception.dart';
import '../features/account/account_screen.dart';
import '../features/activity/activity_screen.dart';
import '../features/cards/cards_screen.dart';
import '../features/home/home_screen.dart';
import '../features/scan/scan_card_screen.dart';
import 'providers.dart';

/// Route paths as constants so a typo becomes a compile-time-adjacent grep
/// hit instead of a silent 404 — every `context.go(...)` call in the app
/// should reference these rather than a literal string.
abstract final class AppRoute {
  static const home = '/home';
  static const cards = '/cards';
  static const activity = '/activity';
  static const account = '/account';
}

/// Task 3: replaces the previous int-index `switch (_tab)` shell and raw
/// `MaterialPageRoute` navigation with go_router (declared in pubspec.yaml
/// since the project's start but never actually used until now).
///
/// Deliberately scoped as a pure navigation-shell swap — same four
/// destinations, same FAB, same screens, zero behaviour change. It does NOT
/// yet add an auth/onboarding redirect guard: the target screens for that
/// (splash, welcome, tutorial — Tasks 4-6) don't exist yet, and redirecting
/// into a route that isn't registered would 404 the whole app. Each of the
/// four tab screens already handles signed-out state itself (embeds
/// LoginScreen), which keeps this migration safe to ship on its own.
final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoute.home,
    routes: [
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
    return Scaffold(
      appBar: AppBar(title: Text('PandaPay — $_currentLabel')),
      body: widget.child,
      floatingActionButton: FloatingActionButton.large(
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
