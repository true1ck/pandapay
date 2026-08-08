import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../auth/login_screen.dart';
import '../geofence/nearby_merchants_screen.dart';
import '../home_widget/widget_settings_screen.dart';
import '../import/import_hub_screen.dart';
import '../settings/account_settings_screen.dart';
import '../settings/appearance_screen.dart';
import '../settings/data_storage_screen.dart';
import '../settings/feedback_support_screen.dart';
import '../settings/help_faq_screen.dart';
import '../settings/legal_screen.dart';
import '../settings/notification_settings_screen.dart';
import '../settings/privacy_permissions_screen.dart';
import '../settings/whats_new_providers.dart';
import '../settings/whats_new_screen.dart';
import '../sms_import/sms_import_screen.dart';
import '../tools/tools_hub_screen.dart';

/// H1 Settings Hub. UA-3's "More" tab account section: signed-out shows the
/// login flow, signed-in shows the profile row api/'s GET /profile actually
/// returns (Chunk 1 proved that route's RLS isolation end to end) plus this
/// hub's Tools section (unchanged from before H1) and the 7 new H2-H10
/// settings rows below it. Per the plan: H2 (Account) now owns sign-out and
/// account actions, not this top-level screen — see AccountSettingsScreen.
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
          const SizedBox(height: AppSpace.sm),
          // Group F (Data Import & Sync), F1 Import Hub — per the plan's own
          // navigation finding: Account's Tools section is already the de
          // facto "More" tab, so F1-F7's entry point goes here rather than a
          // new bottom-nav destination (same reasoning as the three tiles
          // above).
          _AccountTile(
            icon: Icons.sync_outlined,
            label: 'Import & sync',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ImportHubScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          // Group G (Tools & Modes) — implementation-plan-group-e-f-g.md §4,
          // same Account "Tools" placement as the F1 entry above. G4
          // Emergency Card Info is ALSO reachable without ever landing on
          // this screen (LoginScreen has its own direct link) — see
          // AppRoute.emergencyCardInfo's doc-comment for why.
          _AccountTile(
            icon: Icons.travel_explore_outlined,
            label: 'Travel & tools',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolsHubScreen())),
          ),
          const SizedBox(height: AppSpace.xxl),
          Text('Settings', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.person_outline_rounded,
            label: 'Account',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountSettingsScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.notifications_outlined,
            label: 'Notifications',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NotificationSettingsScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy & Permissions',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyPermissionsScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.storage_outlined,
            label: 'Data & Storage',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DataStorageScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.palette_outlined,
            label: 'Appearance',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AppearanceScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.help_outline_rounded,
            label: 'Help & FAQ',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HelpFaqScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.gavel_outlined,
            label: 'Legal',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LegalScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _AccountTile(
            icon: Icons.feedback_outlined,
            label: 'Feedback & Support',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeedbackSupportScreen())),
          ),
          const SizedBox(height: AppSpace.sm),
          _WhatsNewTile(ref: ref),
        ],
      ),
    );
  }
}

/// H10's "manual re-read" entry point — the unread-dot lights up using the
/// exact same version comparison `maybeShowWhatsNewSheet` uses, so H1 and
/// the auto-shown sheet never disagree about what counts as "new."
class _WhatsNewTile extends StatelessWidget {
  final WidgetRef ref;
  const _WhatsNewTile({required this.ref});

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(changelogProvider).valueOrNull ?? const [];
    final lastSeen = ref.watch(lastSeenAppVersionProvider).valueOrNull;
    final hasUnseen = entries.isNotEmpty &&
        (lastSeen == null || entries.first.appVersion != lastSeen);
    return _AccountTile(
      icon: Icons.new_releases_outlined,
      label: "What's New",
      trailing: hasUnseen
          ? const StatusPill(label: 'New', foreground: Colors.white, background: AppColors.teal600)
          : null,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WhatsNewScreen())),
    );
  }
}

class _AccountTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  const _AccountTile({required this.icon, required this.label, required this.onTap, this.trailing});

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
              if (trailing != null) ...[trailing!, const SizedBox(width: AppSpace.sm)],
              const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.ink300),
            ],
          ),
        ),
      ),
    );
  }
}
