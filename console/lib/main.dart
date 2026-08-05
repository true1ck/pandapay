import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/providers.dart';
import 'features/auth/login_screen.dart';
import 'features/catalogue/catalogue_screen.dart';

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

class _ConsoleHome extends StatelessWidget {
  const _ConsoleHome();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          const SizedBox(
            width: 220,
            child: Padding(
              padding: EdgeInsets.only(top: 16, left: 16),
              child: Text('Catalogue', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const VerticalDivider(width: 1),
          const Expanded(child: CatalogueScreen()),
        ],
      ),
    );
  }
}
