import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../account/account_screen.dart' show AccountTile;
import '../auth/recovery_email_reminder.dart';
import '../cards/deleted_cards_screen.dart';
import '../home_widget/widget_settings_screen.dart';
import '../import/import_hub_screen.dart';
import '../sms_import/sms_import_screen.dart';
import 'account_settings_screen.dart';
import 'data_storage_screen.dart';
import 'appearance_screen.dart';
import 'email_phone_screen.dart';
import 'feedback_support_screen.dart';
import 'help_faq_screen.dart';
import 'legal_screen.dart';
import 'linked_devices_screen.dart';
import 'merchant_future_rules_screen.dart';
import 'notification_settings_screen.dart';
import 'privacy_permissions_screen.dart';
import 'transaction_tags_screen.dart';

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
        title: Text(
          'Settings & security',
          style: BambooFonts.heading(18, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            // A recovery of this account is waiting out its 24 hours. Shown first and
            // always, because the owner has until then to stop it.
            if (ref.watch(recoveryPendingProvider).valueOrNull
                case final pending? when pending.pending) ...[
              _RecoveryPendingCard(
                holdUntil: pending.holdUntil,
                onCancel: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref.read(recoveryPendingApiProvider)?.cancel();
                    messenger.showSnackBar(
                      const SnackBar(
                        content: Text('The recovery was cancelled.'),
                      ),
                    );
                  } catch (error) {
                    messenger.showSnackBar(
                      SnackBar(content: Text(userFacingErrorMessage(error))),
                    );
                  } finally {
                    ref.invalidate(recoveryPendingProvider);
                  }
                },
              ),
              const SizedBox(height: AppSpace.xl),
            ],
            // Shown from one hour after sign-up until a recovery email exists.
            if (ref.watch(recoveryEmailNudgeProvider).valueOrNull == true) ...[
              _RecoveryEmailCard(onTap: () => open(const EmailPhoneScreen())),
              const SizedBox(height: AppSpace.xl),
            ],
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

            const _GroupHeader('Cards'),
            AccountTile(
              icon: Icons.delete_outline_rounded,
              label: 'Manage deleted cards',
              onTap: () => open(const DeletedCardsScreen()),
            ),
            const SizedBox(height: AppSpace.xxl),

            const _GroupHeader('Account'),
            AccountTile(
              icon: Icons.label_outline_rounded,
              label: 'Manage tags',
              onTap: () => open(const TransactionTagsScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.auto_fix_high_outlined,
              label: 'Future category rules',
              onTap: () => open(const MerchantFutureRulesScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
            AccountTile(
              icon: Icons.storage_outlined,
              label: 'Data & storage',
              onTap: () => open(const DataStorageScreen()),
            ),
            const SizedBox(height: AppSpace.sm),
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
              icon: Icons.gavel_outlined,
              label: 'Legal',
              onTap: () => open(const LegalScreen()),
            ),
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

/// A nudge to add a recovery email. There is no password, so a lost sign-in email
/// is a lost account unless there is a second way back in.
class _RecoveryEmailCard extends StatelessWidget {
  final VoidCallback onTap;
  const _RecoveryEmailCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.clay.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: BambooInk.clay.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 20,
                color: BambooInk.clay,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add a recovery email',
                      style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'A second way back in if you lose your sign-in email.',
                      style: BambooFonts.ui(
                        12.5,
                        color: BambooInk.ink500,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: BambooInk.ink500),
            ],
          ),
        ),
      ),
    );
  }
}

/// A request to change this account's sign-in email is waiting out its 24 hours.
class _RecoveryPendingCard extends StatelessWidget {
  final DateTime? holdUntil;
  final Future<void> Function() onCancel;
  const _RecoveryPendingCard({required this.holdUntil, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final l10n = MaterialLocalizations.of(context);
    final when = holdUntil == null
        ? 'within 24 hours'
        : 'on ${l10n.formatMediumDate(holdUntil!)} at '
              '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(holdUntil!))}';
    return Container(
      key: const Key('recovery-pending-card'),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.clay.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.clay.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: BambooInk.clay,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  'Someone is changing your sign-in email',
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            'A recovery of this account will finish $when. If this was not you, '
            'cancel it now.',
            style: BambooFonts.ui(12.5, color: BambooInk.ink500, height: 1.4),
          ),
          const SizedBox(height: AppSpace.md),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('recovery-pending-cancel'),
              style: FilledButton.styleFrom(
                backgroundColor: BambooInk.clay,
                foregroundColor: Colors.white,
              ),
              onPressed: onCancel,
              child: const Text('This wasn’t me, cancel it'),
            ),
          ),
        ],
      ),
    );
  }
}
