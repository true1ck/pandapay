import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Route guard stub for AD-0.2.2: every route below must redirect to a dead
/// end unless the session belongs to an active `admin_users` row. Real
/// session state comes in with AD-0.3 (auth); this wires the shape so no
/// route is ever reachable by accident before that lands.
class ConsoleSession {
  final bool isAdmin;
  const ConsoleSession({required this.isAdmin});
  static const ConsoleSession signedOut = ConsoleSession(isAdmin: false);
}

GoRouter buildConsoleRouter({required ConsoleSession Function() session}) {
  return GoRouter(
    initialLocation: '/catalogue',
    redirect: (context, state) {
      final goingToDeadEnd = state.matchedLocation == '/no-access';
      if (!session().isAdmin && !goingToDeadEnd) return '/no-access';
      return null;
    },
    routes: [
      GoRoute(
        path: '/no-access',
        builder: (context, state) => const _NoAccessScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) => ConsoleShell(child: child),
        routes: [
          GoRoute(path: '/catalogue', builder: (c, s) => const _StubScreen('Catalogue')),
          GoRoute(path: '/alerts', builder: (c, s) => const _StubScreen('Alerts')),
          GoRoute(path: '/queues', builder: (c, s) => const _StubScreen('Queues')),
          GoRoute(path: '/sources', builder: (c, s) => const _StubScreen('Sources')),
          GoRoute(path: '/merchants', builder: (c, s) => const _StubScreen('Merchants')),
          GoRoute(path: '/acceptance', builder: (c, s) => const _StubScreen('Acceptance')),
          GoRoute(path: '/rates', builder: (c, s) => const _StubScreen('Rates')),
          GoRoute(path: '/dashboard', builder: (c, s) => const _StubScreen('Dashboard')),
        ],
      ),
    ],
  );
}

class _NoAccessScreen extends StatelessWidget {
  const _NoAccessScreen();
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('This console is internal-only.')),
    );
  }
}

class _StubScreen extends StatelessWidget {
  final String title;
  const _StubScreen(this.title);
  @override
  Widget build(BuildContext context) => Center(child: Text(title));
}

/// AD-0.2.4 shell: left nav, dense desktop theme, no mobile-style padding.
class ConsoleShell extends StatelessWidget {
  final Widget child;
  const ConsoleShell({super.key, required this.child});

  static const _navItems = [
    ('Catalogue', '/catalogue'),
    ('Alerts', '/alerts'),
    ('Queues', '/queues'),
    ('Sources', '/sources'),
    ('Merchants', '/merchants'),
    ('Acceptance', '/acceptance'),
    ('Rates', '/rates'),
    ('Dashboard', '/dashboard'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 220,
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 12),
                for (final (label, path) in _navItems)
                  ListTile(
                    dense: true,
                    title: Text(label),
                    onTap: () => GoRouter.of(context).go(path),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
