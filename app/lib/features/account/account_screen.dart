import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
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
    return profile.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorState(message: userFacingErrorMessage(err), onRetry: () => ref.invalidate(profileProvider)),
      data: (profileData) => ListView(
        padding: const EdgeInsets.all(AppSpace.lg),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpace.lg),
            decoration: BoxDecoration(
              color: AppColors.navy900,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: const Icon(Icons.person_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Signed in', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Colors.white)),
                      if (profileData != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'ID · ${profileData['id']}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white60),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.xxl),
          Text('Tools', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpace.sm),
          // UA-8 (Chunk 32): foreground-triggered geofencing + home-screen
          // widget entry points — both scoped-down per PROGRESS.md.
          _AccountTile(
            icon: Icons.near_me_rounded,
            label: 'Nearby merchants',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NearbyMerchantsScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.widgets_outlined,
            label: 'Home-screen widget',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WidgetSettingsScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          // UA-5.3 (Chunk 31): built but never wired into any navigation
          // entry point at the time — the building agent's own report
          // flagged this gap explicitly. Fixed here, same pattern as the
          // two UA-8 entries above.
          _AccountTile(
            icon: Icons.sms_outlined,
            label: 'SMS transaction import',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SmsImportScreen())),
          ),
          const SizedBox(height: AppSpace.xxl),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: AppColors.error, side: const BorderSide(color: AppColors.errorBg, width: 1.5)),
            icon: const Icon(Icons.logout_rounded, size: 18),
            onPressed: () async {
              final store = await ref.read(tokenStoreProvider.future);
              await store.clear();
              ref.read(accessTokenProvider.notifier).state = null;
            },
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AccountTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(AppRadius.md), border: Border.all(color: AppColors.ink100)),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.navy800),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(label, style: Theme.of(context).textTheme.bodyLarge)),
              const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
