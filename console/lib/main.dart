import 'package:flutter/material.dart';

import 'app/router.dart';

void main() {
  runApp(const PandaPayConsoleApp());
}

/// AD-0.2.1 scaffolding: no public route exists. Session is signed-out by
/// default until AD-0.3 wires real Supabase-less JWT auth against the
/// `auth/` service and the console's own admin_users check.
class PandaPayConsoleApp extends StatelessWidget {
  const PandaPayConsoleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final router = buildConsoleRouter(session: () => ConsoleSession.signedOut);
    return MaterialApp.router(
      title: 'PandaPay Console',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        visualDensity: VisualDensity.compact,
      ),
      routerConfig: router,
    );
  }
}
