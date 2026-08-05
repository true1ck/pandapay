import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/catalogue/catalogue_screen.dart';
import 'features/crowdsource/acceptance_rates_screen.dart';
import 'features/crowdsource/conflicts_screen.dart';
import 'features/crowdsource/merchants_screen.dart';
import 'features/queues/card_requests_screen.dart';
import 'features/queues/error_reports_screen.dart';

void main() {
  runApp(const ProviderScope(child: PandaPayConsoleApp()));
}

/// AD-0.3: real auth against auth/'s OTP flow + api/'s requireAdmin check
/// (not the ConsoleSession.signedOut stub from earlier in the session).
/// Gating is done here as a widget-level switch rather than through
/// go_router's `redirect` (app/router.dart, from before real auth existed)
/// — simpler to keep correct with genuinely async admin-status resolution.
/// app/router.dart's ShellRoute/nav stubs are not wired into this build;
/// left in place as reference for AD-0.2.4's intended nav shape, not dead
/// weight pretending to be load-bearing.
class PandaPayConsoleApp extends StatelessWidget {
  const PandaPayConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PandaPay Console',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        visualDensity: VisualDensity.compact,
      ),
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Chunk 10: wait for a stored refresh token to resolve (or fail) before
    // deciding — otherwise a valid session flashes the login screen first
    // on every reload while sessionInitProvider is still in flight.
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final isAdmin = ref.watch(isAdminProvider);
    return isAdmin.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, _) => Scaffold(body: Center(child: Text('Failed to verify admin access: $err'))),
      data: (admin) {
        if (!admin) {
          return const Scaffold(
            body: Center(child: Text('This console is internal-only.')),
          );
        }
        return const _ConsoleHome();
      },
    );
  }
}

/// AD-2's nav additions on top of AD-1's catalogue: Card Requests and Error
/// Reports as sibling destinations, not separate apps — same left-nav shell.
class _ConsoleHome extends StatefulWidget {
  const _ConsoleHome();

  @override
  State<_ConsoleHome> createState() => _ConsoleHomeState();
}

class _ConsoleHomeState extends State<_ConsoleHome> {
  int _selected = 0;

  static const _destinations = [
    (label: 'Catalogue', screen: CatalogueScreen()),
    (label: 'Card Requests', screen: CardRequestsScreen()),
    (label: 'Error Reports', screen: ErrorReportsScreen()),
    (label: 'Policy Alerts', screen: AlertsScreen()),
    (label: 'Merchants', screen: MerchantsScreen()),
    (label: 'Conflicts', screen: ConflictsScreen()),
    (label: 'Acceptance & Rates', screen: AcceptanceRatesScreen()),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selected,
            onDestinationSelected: (i) => setState(() => _selected = i),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations) NavigationRailDestination(icon: const Icon(Icons.circle), label: Text(d.label)),
            ],
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Consumer(
                    builder: (context, ref, _) => IconButton(
                      icon: const Icon(Icons.logout),
                      tooltip: 'Sign out',
                      onPressed: () async {
                        final store = await ref.read(tokenStoreProvider.future);
                        await store.clear();
                        ref.read(accessTokenProvider.notifier).state = null;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _destinations[_selected].screen),
        ],
      ),
    );
  }
}
