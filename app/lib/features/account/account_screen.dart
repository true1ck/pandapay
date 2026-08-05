import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../auth/login_screen.dart';

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
