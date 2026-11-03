import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/admin_design.dart';
import 'app/providers.dart';
import 'data/admin_api.dart';
import 'data/private_admin_auth.dart';
import 'features/alerts/alerts_screen.dart';
import 'features/sms_rules/sms_rules_screen.dart';
import 'features/sms_rules/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/catalogue/catalogue_screen.dart';
import 'features/crowdsource/acceptance_rates_screen.dart';
import 'features/crowdsource/conflicts_screen.dart';
import 'features/crowdsource/merchants_screen.dart';
import 'features/dashboard/anonymization_audit_screen.dart';
import 'features/dashboard/data_quality_dashboard_screen.dart';
import 'features/dashboard/sms_ai_operations_screen.dart';
import 'features/parser_patterns/parser_patterns_screen.dart';
import 'features/parser_patterns/sms_category_proposals_screen.dart';
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
      theme: adminConsoleTheme(),
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
    _refreshTimer = Timer.periodic(
      const Duration(minutes: 10),
      (_) => _refreshSession(),
    );
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
      await store.save(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      if (mounted) {
        ref.read(accessTokenProvider.notifier).state = tokens.accessToken;
      }
    } catch (_) {
      // Keep the current session on a transient network failure; the next
      // attempt or an explicit API 401 will surface a real expiry.
    }
  }

  Future<void> _signOut() async {
    await _signOutCurrentSession(context, ref);
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
    if (sessionInit.hasError) {
      return const _SessionResumeRetry();
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
                  TextButton(
                    onPressed: _signOut,
                    child: const Text('Sign out'),
                  ),
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
                  TextButton(
                    onPressed: _signOut,
                    child: const Text('Sign out'),
                  ),
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

class _SessionResumeRetry extends ConsumerWidget {
  const _SessionResumeRetry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Your saved session could not be checked right now.'),
              const SizedBox(height: 8),
              const Text('Your sign-in is still saved. Try again in a moment.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => ref.invalidate(sessionInitProvider),
                child: const Text('Retry session'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared responsive shell for the console's operational workspaces.
Future<void> _signOutCurrentSession(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(authApiProvider).logout();
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sign-out could not be completed. Try again.'),
        ),
      );
    }
    return;
  }
  final store = await ref.read(tokenStoreProvider.future);
  await store.clear();
  ref.read(accessTokenProvider.notifier).state = null;
}

class _ConsoleHome extends ConsumerStatefulWidget {
  const _ConsoleHome();

  @override
  ConsumerState<_ConsoleHome> createState() => _ConsoleHomeState();
}

class _ConsoleHomeState extends ConsumerState<_ConsoleHome> {
  int _selected = 0;

  /// Screens are built lazily and then kept alive in the IndexedStack. Building
  /// all 16 upfront would fire every provider's request on login; rebuilding
  /// only the selected child would discard scroll position, filters and
  /// half-filled forms on every tab switch.
  final Set<int> _visited = {0};

  static final _destinations = <_ConsoleDestination>[
    _ConsoleDestination(
      group: 'Card catalogue',
      label: 'Catalogue',
      description:
          'Review card products, correct rule details, and manage what is published to PandaPay users.',
      icon: Icons.credit_card_outlined,
      screen: const CatalogueScreen(),
      refresh: (ref) => ref.invalidate(adminCardsProvider),
    ),
    _ConsoleDestination(
      group: 'Review queues',
      label: 'Card Requests',
      description:
          'See which card products users are asking for and decide what should be researched next.',
      icon: Icons.playlist_add_outlined,
      screen: const CardRequestsScreen(),
      refresh: (ref) => ref.invalidate(cardRequestGroupsProvider),
    ),
    _ConsoleDestination(
      group: 'Review queues',
      label: 'Error Reports',
      description:
          'Compare user-reported card data with the current catalogue before accepting a correction.',
      icon: Icons.fact_check_outlined,
      screen: const ErrorReportsScreen(),
      refresh: (ref) => ref.invalidate(errorReportsProvider),
    ),
    _ConsoleDestination(
      group: 'Review queues',
      label: 'Support Tickets',
      description:
          'Triage user feedback, investigate reports, and record a clear resolution.',
      icon: Icons.support_agent_outlined,
      screen: const SupportTicketsScreen(),
      refresh: (ref) => ref.invalidate(supportTicketsProvider),
    ),
    _ConsoleDestination(
      group: 'Review queues',
      label: 'Policy Alerts',
      description:
          'Review detected issuer policy changes and inspect the evidence behind each alert.',
      icon: Icons.notifications_active_outlined,
      screen: const AlertsScreen(),
      refresh: (ref) => ref.invalidate(alertsProvider),
    ),
    _ConsoleDestination(
      group: 'Merchant data',
      label: 'Merchants',
      description:
          'Search merchant submissions, check confidence and location evidence, and manage publication.',
      icon: Icons.storefront_outlined,
      screen: const MerchantsScreen(),
      refresh: (ref) => ref.invalidate(merchantsProvider),
    ),
    _ConsoleDestination(
      group: 'Merchant data',
      label: 'Conflicts',
      description:
          'Resolve conflicting merchant claims and review abuse signals that need human attention.',
      icon: Icons.gavel_outlined,
      screen: const ConflictsScreen(),
      refresh: (ref) {
        ref.invalidate(merchantConflictsProvider);
        ref.invalidate(abuseSignalsProvider);
      },
    ),
    _ConsoleDestination(
      group: 'Merchant data',
      label: 'Acceptance & Rates',
      description:
          'Inspect reported merchant acceptance and compare observed rewards with published rates.',
      icon: Icons.insights_outlined,
      screen: const AcceptanceRatesScreen(),
      refresh: (ref) {
        ref.invalidate(acceptanceSummaryProvider);
        ref.invalidate(effectiveRateSummaryProvider);
      },
    ),
    _ConsoleDestination(
      group: 'System health',
      label: 'Data Quality',
      description:
          'See the current catalogue, merchant, queue, and scraping health snapshot in one place.',
      icon: Icons.monitor_heart_outlined,
      screen: const DataQualityDashboardScreen(),
      refresh: (ref) => ref.invalidate(dataQualityDashboardProvider),
    ),
    _ConsoleDestination(
      group: 'System health',
      label: 'SMS AI Operations',
      description:
          'Monitor anonymized SMS processing, learning, rule rollout, quotas, and job health.',
      icon: Icons.auto_awesome_outlined,
      screen: const SmsAiOperationsScreen(),
      refresh: (ref) {
        ref.invalidate(smsAiSummaryProvider);
        ref.invalidate(smsAiJobsProvider);
        ref.invalidate(smsAiQuotaProvider);
        ref.invalidate(smsLearningCandidatesProvider);
        ref.invalidate(smsLearningOperationsProvider);
        ref.invalidate(smsRolloutProvider);
        ref.invalidate(smsRuleBundlesProvider);
      },
    ),
    _ConsoleDestination(
      group: 'System health',
      label: 'Anonymization Audit',
      description:
          'Run the privacy checks and inspect their history before sensitive data can reach analytics.',
      icon: Icons.privacy_tip_outlined,
      screen: const AnonymizationAuditScreen(),
      refresh: (ref) => ref.invalidate(anonymizationAuditRunsProvider),
    ),
    _ConsoleDestination(
      group: 'SMS rules',
      label: 'SMS Pipeline Rules',
      description: 'Review v2 rules, run the golden set, publish cohorts and resolve correction cases.',
      icon: Icons.account_tree_outlined,
      screen: const SmsRulesScreen(),
      refresh: (ref) => ref.invalidate(smsV2RulesProvider),
    ),
    _ConsoleDestination(
      group: 'SMS rules',
      label: 'Parser Patterns',
      description:
          'Create and maintain the explicit message patterns used to recognize supported transactions.',
      icon: Icons.rule_folder_outlined,
      screen: const ParserPatternsScreen(),
      refresh: (ref) => ref.invalidate(parserPatternsProvider),
    ),
    _ConsoleDestination(
      group: 'SMS rules',
      label: 'SMS Rule Approvals',
      description:
          'Review category, parser, AI-learning, and correction evidence before any rule is delivered.',
      icon: Icons.rule_outlined,
      screen: const SmsCategoryProposalsScreen(),
      refresh: (ref) {
        ref.invalidate(smsCategoryProposalsProvider);
        ref.invalidate(smsParserProposalsProvider);
        ref.invalidate(smsAiProposalsProvider);
        ref.invalidate(smsCorrectionCasesProvider);
      },
    ),
    _ConsoleDestination(
      group: 'Data collection',
      label: 'Sources',
      description:
          'Record source terms review and control which issuer pages may be collected.',
      icon: Icons.language_outlined,
      screen: const SourcesScreen(),
      refresh: (ref) => ref.invalidate(sourcesProvider),
    ),
    _ConsoleDestination(
      group: 'Data collection',
      label: 'Scrape Diff Review',
      description:
          'Compare recent source snapshots and verify the content that triggered policy alerts.',
      icon: Icons.difference_outlined,
      screen: const ScrapeDiffReviewScreen(),
      refresh: (ref) => ref.invalidate(scrapeRunsProvider),
    ),
    _ConsoleDestination(
      group: 'Growth operations',
      label: 'Referral Operations',
      description:
          'Monitor referral access, campaign delivery, workers, holds, and the recent audit trail.',
      icon: Icons.group_add_outlined,
      screen: const ReferralOperationsScreen(),
      refresh: (ref) => ref.invalidate(referralOperationsProvider),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final destination = _destinations[_selected];
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 1180;
        final isTablet = constraints.maxWidth >= 720;
        final scaffoldKey = GlobalKey<ScaffoldState>();
        return Scaffold(
          key: scaffoldKey,
          backgroundColor: AdminColors.canvas,
          drawer: isTablet
              ? null
              : Drawer(
                  width: 300,
                  child: SafeArea(
                    child: _ConsoleSidebar(
                      selected: _selected,
                      onSelect: (index) {
                        _select(index);
                        Navigator.of(context).pop();
                      },
                      onSignOut: () => _signOutFromShell(context),
                    ),
                  ),
                ),
          body: Row(
            children: [
              if (isDesktop)
                SizedBox(
                  width: 264,
                  child: _ConsoleSidebar(
                    selected: _selected,
                    onSelect: _select,
                    onSignOut: () => _signOutFromShell(context),
                  ),
                )
              else if (isTablet)
                SizedBox(
                  width: 112,
                  child: _CompactNavigation(
                    selected: _selected,
                    onSelect: _select,
                  ),
                ),
              Expanded(
                child: Column(
                  children: [
                    _ConsoleTopBar(
                      destination: destination,
                      compact: !isDesktop,
                      onMenu: isTablet
                          ? null
                          : () => scaffoldKey.currentState?.openDrawer(),
                      onRefresh: destination.refresh,
                      onSignOut: () => _signOutFromShell(context),
                    ),
                    Expanded(
                      child: Material(
                        color: AdminColors.canvas,
                        child: Container(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1680),
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                isDesktop ? 28 : 16,
                                isDesktop ? 22 : 14,
                                isDesktop ? 28 : 16,
                                20,
                              ),
                              child: IndexedStack(
                                index: _selected,
                                children: [
                                  for (var i = 0; i < _destinations.length; i++)
                                    _visited.contains(i)
                                        ? _destinations[i].screen
                                        : const SizedBox.shrink(),
                                ],
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
        );
      },
    );
  }

  void _select(int index) {
    setState(() {
      _selected = index;
      _visited.add(index);
    });
  }

  Future<void> _signOutFromShell(BuildContext context) async {
    await _signOutCurrentSession(context, ref);
  }
}

class _ConsoleDestination {
  const _ConsoleDestination({
    required this.group,
    required this.label,
    required this.description,
    required this.icon,
    required this.screen,
    this.refresh,
  });

  final String group;
  final String label;
  final String description;
  final IconData icon;
  final Widget screen;
  final void Function(WidgetRef ref)? refresh;
}

class _ConsoleSidebar extends StatelessWidget {
  const _ConsoleSidebar({
    required this.selected,
    required this.onSelect,
    required this.onSignOut,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<int>>{};
    for (var i = 0; i < _ConsoleHomeState._destinations.length; i++) {
      final group = _ConsoleHomeState._destinations[i].group;
      groups.putIfAbsent(group, () => []).add(i);
    }
    return ColoredBox(
      color: AdminColors.slate,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 22),
            child: Row(
              children: [
                Image.asset(
                  'assets/brand/pandapay_mark.png',
                  width: 42,
                  height: 42,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'PandaPay',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'OPERATIONS',
                        style: TextStyle(
                          color: AdminColors.onSlateMuted,
                          fontSize: 10,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AdminColors.slateLine, height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
              children: [
                for (final entry in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 12, 8, 6),
                    child: Text(
                      entry.key.toUpperCase(),
                      style: const TextStyle(
                        color: AdminColors.onSlateMuted,
                        fontSize: 10,
                        letterSpacing: 1.15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  for (final index in entry.value)
                    _SidebarDestination(
                      destination: _ConsoleHomeState._destinations[index],
                      selected: selected == index,
                      onTap: () => onSelect(index),
                    ),
                ],
              ],
            ),
          ),
          const Divider(color: AdminColors.slateLine, height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 16),
            child: Consumer(
              builder: (context, ref, _) {
                final auth = ref.read(authApiProvider);
                final target = auth is PrivateAdminAuthApi
                    ? auth.administrator
                    : null;
                final role = (target?['role'] ?? 'Administrator').toString();
                final environment =
                    (target?['environment'] ?? 'Private workspace').toString();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          radius: 17,
                          backgroundColor: AdminColors.slateRaised,
                          child: Icon(
                            Icons.person_outline,
                            color: AdminColors.lime,
                            size: 19,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                role,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                environment,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AdminColors.onSlateMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton.icon(
                        onPressed: onSignOut,
                        icon: const Icon(Icons.logout, size: 18),
                        label: const Text('Sign out'),
                        style: TextButton.styleFrom(
                          foregroundColor: AdminColors.onSlateSubtle,
                          alignment: Alignment.centerLeft,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarDestination extends StatelessWidget {
  const _SidebarDestination({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final _ConsoleDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? AdminColors.slateRaised : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 42),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(11),
              border: selected
                  ? const Border(
                      left: BorderSide(color: AdminColors.lime, width: 3),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  destination.icon,
                  size: 19,
                  color: selected
                      ? AdminColors.lime
                      : AdminColors.onSlateSubtle,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : AdminColors.onSlateSubtle,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactNavigation extends StatelessWidget {
  const _CompactNavigation({required this.selected, required this.onSelect});

  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AdminColors.slate,
      child: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Icon(
                Icons.account_balance_wallet_outlined,
                color: AdminColors.lime,
                size: 26,
              ),
            ),
            const Divider(color: AdminColors.slateLine, height: 1),
            Expanded(
              child: SingleChildScrollView(
                child: IntrinsicHeight(
                  child: NavigationRail(
                    backgroundColor: AdminColors.slate,
                    selectedIndex: selected,
                    onDestinationSelected: onSelect,
                    labelType: NavigationRailLabelType.all,
                    minWidth: 108,
                    groupAlignment: -1,
                    selectedIconTheme: const IconThemeData(
                      color: AdminColors.lime,
                      size: 19,
                    ),
                    unselectedIconTheme: const IconThemeData(
                      color: AdminColors.onSlateSubtle,
                      size: 19,
                    ),
                    selectedLabelTextStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                    unselectedLabelTextStyle: const TextStyle(
                      color: AdminColors.onSlateSubtle,
                      fontSize: 10,
                    ),
                    destinations: [
                      for (final destination in _ConsoleHomeState._destinations)
                        NavigationRailDestination(
                          icon: Icon(destination.icon),
                          label: Text(
                            destination.label,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsoleTopBar extends ConsumerWidget {
  const _ConsoleTopBar({
    required this.destination,
    required this.compact,
    required this.onMenu,
    required this.onRefresh,
    required this.onSignOut,
  });

  final _ConsoleDestination destination;
  final bool compact;
  final VoidCallback? onMenu;
  final void Function(WidgetRef ref)? onRefresh;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.read(authApiProvider);
    final target = auth is PrivateAdminAuthApi ? auth.administrator : null;
    final environment = (target?['environment'] ?? 'Private workspace')
        .toString();
    final role = (target?['role'] ?? 'Admin').toString();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 12,
      ),
      decoration: const BoxDecoration(
        color: AdminColors.paper,
        border: Border(bottom: BorderSide(color: AdminColors.hairline)),
      ),
      child: Row(
        children: [
          if (onMenu != null) ...[
            IconButton(
              onPressed: onMenu,
              icon: const Icon(Icons.menu),
              tooltip: 'Open navigation',
            ),
            const SizedBox(width: 4),
          ],
          Icon(destination.icon, color: AdminColors.jade, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  destination.group,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 3),
                Text(
                  destination.description,
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 16),
            _WorkspaceBadge(environment: environment, role: role),
          ],
          if (onRefresh != null)
            IconButton(
              onPressed: () => onRefresh!(ref),
              tooltip: 'Refresh this section',
              icon: const Icon(Icons.refresh),
            ),
          if (!compact)
            OutlinedButton.icon(
              onPressed: () => _verifySecurityKey(context, auth),
              icon: const Icon(Icons.fingerprint, size: 18),
              label: const Text('Verify key'),
            )
          else
            IconButton(
              tooltip: 'Verify security key',
              onPressed: () => _verifySecurityKey(context, auth),
              icon: const Icon(Icons.fingerprint),
            ),
          PopupMenuButton<String>(
            tooltip: 'Account options',
            onSelected: (value) {
              if (value == 'signout') onSignOut();
            },
            itemBuilder: (context) => [
              PopupMenuItem<String>(
                enabled: false,
                value: 'identity',
                child: Text('$role · $environment'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'signout',
                child: Text('Sign out'),
              ),
            ],
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: CircleAvatar(
                radius: 17,
                backgroundColor: AdminColors.paperMuted,
                child: Icon(
                  Icons.person_outline,
                  color: AdminColors.slate,
                  size: 19,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _verifySecurityKey(BuildContext context, AuthApi auth) async {
    if (auth is! PrivateAdminAuthApi) return;
    try {
      await auth.stepUp();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Security key verified for sensitive actions.'),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Security key verification was not completed.'),
          ),
        );
      }
    }
  }
}

class _WorkspaceBadge extends StatelessWidget {
  const _WorkspaceBadge({required this.environment, required this.role});

  final String environment;
  final String role;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AdminColors.paperMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AdminColors.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 16, color: AdminColors.muted),
          const SizedBox(width: 7),
          Text(
            '$environment · $role',
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}
