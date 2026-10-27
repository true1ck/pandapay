import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/catalogue/catalogue_screen.dart';
import 'features/crowdsource/acceptance_rates_screen.dart';
import 'features/crowdsource/conflicts_screen.dart';
import 'features/crowdsource/merchants_screen.dart';
import 'features/dashboard/anonymization_audit_screen.dart';
import 'features/dashboard/data_quality_dashboard_screen.dart';
import 'features/dashboard/sms_ai_operations_screen.dart';
import 'features/parser_patterns/parser_patterns_screen.dart';
import 'features/queues/card_requests_screen.dart';
import 'features/queues/error_reports_screen.dart';
import 'features/queues/support_tickets_screen.dart';
import 'features/referrals/referral_operations_screen.dart';
import 'features/scraper/scrape_diff_review_screen.dart';
import 'features/scraper/sources_screen.dart';

void main() {
  runApp(const ProviderScope(child: PandaPayConsoleApp()));
}

/// AD-0.3: real auth against auth/'s OTP flow + api/'s requireAdmin check.
/// Gating is a widget-level switch, not a go_router `redirect` — simpler
/// to keep correct with genuinely async admin-status resolution, and this
/// console has no deep-linking requirement (internal tool, single
/// destination list, GAP_ANALYSIS.md §5 confirmed the earlier go_router
/// scaffold in app/router.dart had zero real callers and deleted it rather
/// than force a rewrite of this file's already-working, already-tested
/// nav — see that file's git history if the ShellRoute-based shape is
/// ever wanted again).
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

class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    // Access tokens live for an hour. Refreshing well before expiry keeps an
    // open dashboard usable instead of turning every panel into a 401 error
    // that only a full page reload could fix.
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (_) => _refreshSession());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshSession() async {
    final store = await ref.read(tokenStoreProvider.future);
    final refreshToken = store.refreshToken;
    if (refreshToken == null) return;
    try {
      final tokens = await ref.read(authApiProvider).refresh(refreshToken);
      await store.save(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken);
      if (mounted) ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
    } catch (_) {
      // Keep the current session on a transient network failure; the next
      // attempt or an explicit API 401 will surface a real expiry.
    }
  }

  Future<void> _signOut() async {
    final store = await ref.read(tokenStoreProvider.future);
    await store.clear();
    ref.read(accessTokenProvider.notifier).state = null;
  }

  @override
  Widget build(BuildContext context) {
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
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (err, _) => Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Failed to verify admin access: $err'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => ref.invalidate(isAdminProvider),
                    child: const Text('Retry'),
                  ),
                  TextButton(onPressed: _signOut, child: const Text('Sign out')),
                ],
              ),
            ],
          ),
        ),
      ),
      data: (admin) {
        if (!admin) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('This console is internal-only.'),
                  const SizedBox(height: 12),
                  TextButton(onPressed: _signOut, child: const Text('Sign out')),
                ],
              ),
            ),
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

  /// Screens are built lazily and then kept alive in the IndexedStack. Building
  /// all 15 upfront would fire every provider's request on login; rebuilding
  /// only the selected child would discard scroll position, filters and
  /// half-filled forms on every tab switch.
  final Set<int> _visited = {0};

  static const _destinations = [
    (label: 'Catalogue', screen: CatalogueScreen()),
    (label: 'Card Requests', screen: CardRequestsScreen()),
    (label: 'Error Reports', screen: ErrorReportsScreen()),
    (label: 'Support Tickets', screen: SupportTicketsScreen()),
    (label: 'Policy Alerts', screen: AlertsScreen()),
    (label: 'Merchants', screen: MerchantsScreen()),
    (label: 'Conflicts', screen: ConflictsScreen()),
    (label: 'Acceptance & Rates', screen: AcceptanceRatesScreen()),
    (label: 'Data Quality', screen: DataQualityDashboardScreen()),
    (label: 'SMS AI Operations', screen: SmsAiOperationsScreen()),
    (label: 'Anonymization Audit', screen: AnonymizationAuditScreen()),
    (label: 'Parser Patterns', screen: ParserPatternsScreen()),
    (label: 'Sources', screen: SourcesScreen()),
    (label: 'Scrape Diff Review', screen: ScrapeDiffReviewScreen()),
    (label: 'Referral Operations', screen: ReferralOperationsScreen()),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Chunk 35: the rail grew past 9 destinations (added Parser
          // Patterns) and now genuinely overflows a short/narrow viewport —
          // same overflow class as Chunk 23-25's dropdown/header fixes,
          // caught here by a real test failure, not just eyeballing it.
          // NavigationRail has no built-in scrolling, so wrap it directly;
          // its own `trailing` sign-out button moves into a fixed footer
          // below the scroll area instead, so it stays reachable without
          // scrolling to the very bottom of a long destination list.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      selectedIndex: _selected,
                      onDestinationSelected: (i) => setState(() {
                        _selected = i;
                        _visited.add(i);
                      }),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final d in _destinations)
                          NavigationRailDestination(
                            icon: const Icon(Icons.circle),
                            label: Text(d.label),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
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
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(
              index: _selected,
              children: [
                for (var i = 0; i < _destinations.length; i++)
                  _visited.contains(i) ? _destinations[i].screen : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
