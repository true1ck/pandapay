import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../account/account_screen.dart' show AccountTile;
import '../home_widget/widget_settings_screen.dart';
import '../import/import_hub_screen.dart';
import '../sms_import/sms_import_screen.dart';
import 'account_settings_screen.dart';
import 'appearance_screen.dart';
import 'data_storage_screen.dart';
import 'email_phone_screen.dart';
import 'feedback_support_screen.dart';
import 'help_faq_screen.dart';
import 'legal_screen.dart';
import 'linked_devices_screen.dart';
import 'notification_settings_screen.dart';
import 'privacy_permissions_screen.dart';
import 'whats_new_screen.dart';

/// Design 20 "Settings & security" — one screen, grouped, reached from a
/// single row on You.
///
/// The app previously hung ten settings rows straight off the You tab,
/// interleaved with the tools and inboxes the deck puts there. Design 05's
/// You is a short list of things you *do*; design 20 is where everything
/// you *configure* lives, under three headings.
///
/// Deliberately a hub of the existing screens rather than one flat screen
/// that absorbs them. The deck draws design 20 with inline toggles because
/// its mockup only has to show three of them; the real app has a
/// notification screen with per-channel controls and a daily cap, a privacy
/// screen with OS permission round-trips, and a data screen with export and
/// cache management. Flattening those into one scroll would either lose
/// controls or produce a screen far longer than anything in the deck.
/// Grouping is the part of design 20 worth taking; collapsing is not.
///
/// **Linked devices** was previously listed here as unbuildable, on the
/// grounds that "auth/ has no session-enumeration endpoint". That was simply
/// wrong — `GET /users/me/devices` and `DELETE /users/me/devices/:id` have
/// existed in `auth/src/routes/userRoutes.js` the whole time — and the row is
/// real as of plan Phase 1.4. See `linked_devices_screen.dart`.
///
/// One thing design 20 lists that this still cannot: **Face ID to pay** as a
/// payment gate (PandaPay never moves money — the nearest real control is the
/// app-open biometric lock, which lives on Account). Not stubbed here; it
/// stays absent until the thing behind it exists.
class SettingsHubScreen extends ConsumerWidget {
  const SettingsHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(Widget screen) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    }

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Settings & security', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            const _GroupHeader('Security'),
            AccountTile(
              icon: Icons.person_outline_rounded,
              label: 'Account & sign-in',
              onTap: () => open(const AccountSettingsScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.privacy_tip_outlined,
              label: 'Privacy & permissions',
              onTap: () => open(const PrivacyPermissionsScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.devices_outlined,
              label: 'Linked devices',
              onTap: () => open(const LinkedDevicesScreen()),
            ),
            const SizedBox(height: AppSpace.xxl),

            const _GroupHeader('Notifications'),
            AccountTile(
              icon: Icons.notifications_outlined,
              // Named for what it configures, not just "Notifications" — the
              // You tab has a separate row of that name for the inbox, and
              // two identically-labelled rows going to different places was
              // the single most confusing thing on that screen.
              label: 'Notification settings',
              onTap: () => open(const NotificationSettingsScreen()),
            ),
            const SizedBox(height: AppSpace.xxl),

            const _GroupHeader('Account'),
            AccountTile(
              icon: Icons.alternate_email_rounded,
              label: 'Email & phone',
              onTap: () => open(const EmailPhoneScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.sync_outlined,
              label: 'Import & sync',
              onTap: () => open(const ImportHubScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.sms_outlined,
              label: 'SMS transaction import',
              onTap: () => open(const SmsImportScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.storage_outlined,
              label: 'Data & storage',
              onTap: () => open(const DataStorageScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.widgets_outlined,
              label: 'Home-screen widget',
              onTap: () => open(const WidgetSettingsScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.palette_outlined,
              label: 'Appearance',
              onTap: () => open(const AppearanceScreen()),
            ),
            const SizedBox(height: AppSpace.xxl),

            const _GroupHeader('About'),
            AccountTile(
              icon: Icons.help_outline_rounded,
              label: 'Help & FAQ',
              onTap: () => open(const HelpFaqScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.new_releases_outlined,
              label: "What's new",
              onTap: () => open(const WhatsNewScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(icon: Icons.gavel_outlined, label: 'Legal', onTap: () => open(const LegalScreen())),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.feedback_outlined,
              label: 'Feedback & support',
              onTap: () => open(const FeedbackSupportScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Text(
        label.toUpperCase(),
        style: BambooFonts.ui(
          12,
          weight: FontWeight.w700,
          color: BambooInk.ink500,
        ).copyWith(letterSpacing: 1.1),
      ),
    );
  }
}
