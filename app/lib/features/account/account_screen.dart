import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../auth/login_screen.dart';
import '../geofence/nearby_merchants_screen.dart';
import '../home_widget/widget_settings_screen.dart';
import '../sms_import/sms_import_screen.dart';

/// UA-3's "More" tab account section: signed-out shows the login flow,
/// signed-in shows the profile row api/'s GET /profile actually returns
/// (Chunk 1 proved that route's RLS isolation end to end; this is the
/// first screen that actually calls it) plus a sign-out action.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionInit = ref.watch(sessionInitProvider);
    if (sessionInit.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final token = ref.watch(accessTokenProvider);
    if (token == null) return const LoginScreen();

    final profile = ref.watch(profileProvider);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Failed to load profile: $err')),
        data: (profileData) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Account', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            Text('Signed in.'),
            if (profileData != null) ...[
              const SizedBox(height: 8),
              Text('Profile id: ${profileData['id']}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            const SizedBox(height: 24),
            // UA-8 (Chunk 32): foreground-triggered geofencing + home-screen
            // widget entry points — both scoped-down per PROGRESS.md.
            OutlinedButton.icon(
              icon: const Icon(Icons.near_me),
              label: const Text('Nearby merchants'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NearbyMerchantsScreen()),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.widgets_outlined),
              label: const Text('Home-screen widget'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WidgetSettingsScreen()),
              ),
            ),
            const SizedBox(height: 8),
            // UA-5.3 (Chunk 31): built but never wired into any navigation
            // entry point at the time — the building agent's own report
            // flagged this gap explicitly. Fixed here, same pattern as the
            // two UA-8 entries above.
            OutlinedButton.icon(
              icon: const Icon(Icons.sms_outlined),
              label: const Text('SMS transaction import'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SmsImportScreen()),
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: () async {
                final store = await ref.read(tokenStoreProvider.future);
                await store.clear();
                ref.read(accessTokenProvider.notifier).state = null;
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}
