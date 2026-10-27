import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/device_permissions.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consents_api.dart';
import '../../data/local/sms_dismissal_outbox.dart';
import '../../data/local/sms_feedback_outbox.dart';
import '../../app/env.dart';
import '../import/gmail_connect_service.dart';

/// H4 Privacy & Permissions (docs/superpowers/plans/2026-08-07-group-h-settings-and-group-a-completion.md).
/// Reached via `Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
/// const PrivacyPermissionsScreen()))` — a plain pushed screen, not a
/// registered go_router route, same pattern as ToolsHubScreen's children.
final _consentsApiProvider = Provider<ConsentsApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return ConsentsApi(
    apiBaseUrl: Env.apiBaseUrl,
    accessToken: token,
    client: ref.read(authenticatedHttpClientProvider),
  );
});

final _consentHistoryProvider = FutureProvider.autoDispose<List<ConsentRecord>>(
  (ref) async {
    final api = ref.watch(_consentsApiProvider);
    if (api == null) return const [];
    return api.fetchHistory();
  },
);

/// These values come from the phone, never from saved onboarding choices.
final _permissionStatusProvider = FutureProvider.autoDispose
    .family<PermissionStatus, Permission>(
      (ref, permission) => readDevicePermissionStatus(permission),
    );

class PrivacyPermissionsScreen extends ConsumerStatefulWidget {
  const PrivacyPermissionsScreen({super.key});

  @override
  ConsumerState<PrivacyPermissionsScreen> createState() =>
      _PrivacyPermissionsScreenState();
}

class _PrivacyPermissionsScreenState
    extends ConsumerState<PrivacyPermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // openAppSettings completes when Settings launches, not when the user
      // returns. Only then is it useful to reread the changed native grants.
      ref.invalidate(_permissionStatusProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(accessTokenProvider) != null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(
          'Privacy & Permissions',
          style: BambooFonts.heading(17, color: BambooInk.ink900),
        ),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'App permissions',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            const _PermissionRow(
              icon: Icons.notifications_none_rounded,
              title: 'Notifications',
              caption: 'bill reminders, reward caps and milestone alerts',
              permission: Permission.notification,
            ),
            const SizedBox(height: AppSpace.sm),
            const _PermissionRow(
              icon: Icons.location_on_outlined,
              title: 'Location',
              caption: 'find nearby merchants while using the app',
              permission: Permission.locationWhenInUse,
            ),
            const SizedBox(height: AppSpace.sm),
            const _PermissionRow(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Camera',
              caption: 'used to scan payment QR codes',
              permission: Permission.camera,
            ),
            const SizedBox(height: AppSpace.sm),
            const _PermissionRow(
              icon: Icons.mic_none_rounded,
              title: 'Microphone',
              caption: 'voice input when you tap the assistant’s mic',
              permission: Permission.microphone,
            ),
            if (Platform.isAndroid) ...[
              const SizedBox(height: AppSpace.sm),
              const _PermissionRow(
                icon: Icons.sms_outlined,
                title: 'SMS',
                caption: 'used to auto-detect transactions from bank messages',
                permission: Permission.sms,
              ),
            ],
            const SizedBox(height: AppSpace.sm),
            const _GmailConnectionRow(),
            const SizedBox(height: AppSpace.xl),
            Text(
              'How your data is handled',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            const _DataHandlingSection(
              title: 'Stays on this phone',
              bullets: [
                'Transaction amounts and exact timestamps are never uploaded.',
                'Your device\'s raw location is only used locally to match nearby merchants.',
              ],
            ),
            const SizedBox(height: AppSpace.md),
            const _DataHandlingSection(
              title: 'Uploaded to sync your account',
              bullets: [
                'Your cards, wallet, and profile settings sync so you can restore them on a new device.',
                'Auth exists for your own benefit (sync, backup) — never to attach identity to shared data.',
              ],
            ),
            const SizedBox(height: AppSpace.md),
            const _DataHandlingSection(
              title: 'Anonymized before it ever leaves your phone',
              bullets: [
                'Merchant records carry no user identity, ever — the row is about the shop, not the shopper.',
                'No amounts and no individual timestamps are included in shared records.',
                'Coordinates are grid-snapped (~50m) before upload — we store "a shop exists near here," never "a person was here."',
              ],
            ),
            const SizedBox(height: AppSpace.xl),
            Text(
              'Crowdsourced contributions',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            if (!signedIn)
              const EmptyState(
                icon: Icons.lock_outline,
                title: 'Sign in to view',
              )
            else
              const _ContributionToggle(),
            const SizedBox(height: AppSpace.xl),
            Text(
              'How your data may be used',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            if (!signedIn)
              const EmptyState(
                icon: Icons.lock_outline,
                title: 'Sign in to view',
              )
            else
              const _PurposeConsents(),
            const SizedBox(height: AppSpace.xl),
            Text(
              'Consent history',
              style: BambooFonts.ui(
                12.5,
                weight: FontWeight.w700,
                color: BambooInk.ink900,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            if (!signedIn)
              const EmptyState(
                icon: Icons.lock_outline,
                title: 'Sign in to view',
              )
            else
              const _ConsentHistoryList(),
          ],
        ),
      ),
    );
  }
}

class _PermissionRow extends ConsumerWidget {
  final IconData icon;
  final String title;
  final String caption;
  final Permission permission;

  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.caption,
    required this.permission,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(_permissionStatusProvider(permission));

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: BambooInk.paperMuted,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: BambooInk.ink900),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
                const SizedBox(height: 4),
                status.when(
                  skipLoadingOnRefresh: false,
                  loading: () => Text(
                    'Checking…',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  error: (_, _) => Text(
                    'Unknown',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  data: (s) => _StatusBadge(status: s),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
            onPressed: () async {
              final opened = await openAppSettings();
              if (!opened && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Open PandaPay’s permissions in device Settings.',
                    ),
                  ),
                );
              }
            },
            child: const Text('Settings'),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final PermissionStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (label, fg, bg) = switch (status) {
      PermissionStatus.granted => (
        'Enabled',
        BambooInk.jade,
        BambooInk.jade.withValues(alpha: 0.12),
      ),
      PermissionStatus.limited => (
        'Limited',
        BambooInk.clay,
        BambooInk.clay.withValues(alpha: 0.12),
      ),
      PermissionStatus.permanentlyDenied => (
        'Denied — set in Settings',
        BambooInk.clay,
        BambooInk.clay.withValues(alpha: 0.12),
      ),
      PermissionStatus.denied => (
        'Not enabled',
        BambooInk.clay,
        BambooInk.clay.withValues(alpha: 0.12),
      ),
      PermissionStatus.restricted => (
        'Restricted',
        BambooInk.clay,
        BambooInk.clay.withValues(alpha: 0.12),
      ),
      PermissionStatus.provisional => (
        'Quiet notifications',
        BambooInk.jade,
        BambooInk.jade.withValues(alpha: 0.12),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: BambooFonts.ui(11, weight: FontWeight.w600, color: fg),
      ),
    );
  }
}

/// On-device Gmail "1-Tap Auto Find" connection (read-only). Shows the
/// connected inbox and a Disconnect that revokes the Google grant. Unlike the
/// permission rows above, this isn't an OS permission — it's an OAuth grant
/// PandaPay holds, so it's managed here rather than in system settings.
class _GmailConnectionRow extends ConsumerWidget {
  const _GmailConnectionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conn = ref.watch(gmailConnectControllerProvider);

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: BambooInk.paperMuted,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.mark_email_read_outlined,
              size: 20,
              color: BambooInk.ink900,
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Gmail',
                  style: BambooFonts.heading(14.5, color: BambooInk.ink900),
                ),
                const SizedBox(height: 2),
                Text(
                  'read-only, used on-device to find cards from bank emails',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                ),
                const SizedBox(height: 4),
                conn.when(
                  loading: () => Text(
                    'Checking…',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  error: (_, _) => Text(
                    'Not connected',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  data: (c) => Text(
                    c == null ? 'Not connected' : 'Connected — ${c.email}',
                    style: BambooFonts.ui(
                      12.5,
                      weight: FontWeight.w600,
                      color: c == null ? BambooInk.ink500 : BambooInk.jade,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (conn.valueOrNull != null)
            TextButton(
              style: TextButton.styleFrom(foregroundColor: BambooInk.clay),
              onPressed: () async {
                await ref
                    .read(gmailConnectControllerProvider.notifier)
                    .disconnect();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Gmail disconnected. Access has been revoked.',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Disconnect'),
            ),
        ],
      ),
    );
  }
}

class _DataHandlingSection extends StatelessWidget {
  final String title;
  final List<String> bullets;

  const _DataHandlingSection({required this.title, required this.bullets});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.paperMuted,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: BambooFonts.heading(14.5, color: BambooInk.ink900),
          ),
          const SizedBox(height: AppSpace.sm),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '•  ',
                    style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                  ),
                  Expanded(
                    child: Text(
                      b,
                      style: BambooFonts.ui(12.5, color: BambooInk.ink500),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Reuses E12's exact contribution toggle plumbing — same
/// `contributionsOptInProvider` read, same `userCardsRepositoryProvider`
/// call, same `profileProvider` invalidation — see
/// app/lib/features/insights/my_contributions_screen.dart.
class _ContributionToggle extends ConsumerWidget {
  const _ContributionToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final optedIn = ref.watch(contributionsOptInProvider);

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          'Share what you see',
          style: BambooFonts.heading(14.5, color: BambooInk.ink900),
        ),
        subtitle: Text(
          'Anonymously log a merchant name/MCC/rough location (never an amount, exact time, or '
          'your identity) to help other users\' recommendations.',
          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
        ),
        activeTrackColor: BambooInk.jade,
        activeThumbColor: BambooInk.lime,
        value: optedIn,
        onChanged: (v) async {
          final repo = ref.read(userCardsRepositoryProvider);
          if (repo == null) return;
          try {
            await repo.setContributionsOptIn(v);
            ref.invalidate(profileProvider);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(userFacingErrorMessage(e))),
              );
            }
          }
        },
      ),
    );
  }
}

/// Plan Phase 3.2 — the two DPDP purpose-scoped consents added in migration
/// 0031, each independently grantable and revocable, both off unless the user
/// has said otherwise.
///
/// SMS shared learning is a separate purpose from "Share what you see" and
/// from aggregated or partner sharing. It can include corrected transaction
/// fields, so it has its own explicit, default-off choice and policy version.
///
/// The other purpose toggles are recorded independently. Production SMS
/// collection must not be enabled until its purpose-specific policy has been
/// reviewed.
final _latestConsentsProvider =
    FutureProvider.autoDispose<Map<String, ConsentRecord>>((ref) async {
      final api = ref.watch(_consentsApiProvider);
      if (api == null) return const {};
      final latest = await api.fetchLatest();
      return {for (final c in latest) c.purpose: c};
    });

class _PurposeConsents extends ConsumerWidget {
  const _PurposeConsents();

  static const _policyVersion = 'draft-0';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consents = ref.watch(_latestConsentsProvider);

    Future<void> set(String purpose, bool granted) async {
      final api = ref.read(_consentsApiProvider);
      if (api == null) return;
      try {
        await api.submit(
          purpose: purpose,
          granted: granted,
          // Every consent row records the policy version it was given
          // against, which is what makes a later policy change detectable as
          // "this person agreed to something older" rather than silently
          // inheriting agreement. 'draft-0' is honest about what they'd be
          // agreeing to right now — see the class doc comment.
          policyVersion: purpose == smsSharedLearningPurpose
              ? smsSharedLearningPolicyVersion
              : _policyVersion,
          sourceScreen: 'privacy_permissions',
        );
        if (purpose == smsSharedLearningPurpose && !granted) {
          final cache = await ref.read(responseCacheProvider.future);
          final namespace = ref.read(cacheNamespaceProvider);
          SmsFeedbackOutbox(
            cache.financialStore.database,
            namespace: namespace,
          ).clear();
          SmsDismissalOutbox(cache.financialStore.database, namespace).clear();
          await ref
              .read(userCardsRepositoryProvider)
              ?.clearSmsLearningFeedbackQueues();
        }
        ref.invalidate(_latestConsentsProvider);
        if (purpose == smsSharedLearningPurpose) {
          ref.invalidate(smsSharedLearningConsentProvider);
        }
        ref.invalidate(_consentHistoryProvider);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: consents.when(
        loading: () => const SkeletonRow(),
        error: (e, _) => ErrorState(
          message: userFacingErrorMessage(e),
          onRetry: () => ref.invalidate(_latestConsentsProvider),
        ),
        data: (granted) => Column(
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Aggregated insights',
                style: BambooFonts.heading(14.5, color: BambooInk.ink900),
              ),
              subtitle: Text(
                'Allow your data to contribute to combined, non-identifying statistics we may '
                'publish or license — things like average reward rates by category. Never your '
                'individual transactions.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              activeTrackColor: BambooInk.jade,
              value: granted['aggregate_insights']?.granted ?? false,
              onChanged: (v) => set('aggregate_insights', v),
            ),
            const Divider(
              height: AppSpace.lg,
              color: BambooInk.hairlineOnPaper,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Sharing with partners',
                style: BambooFonts.heading(14.5, color: BambooInk.ink900),
              ),
              subtitle: Text(
                'Allow your data to be shared with a named commercial partner. Off unless you '
                'turn it on, and you can turn it off again at any time.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              activeTrackColor: BambooInk.jade,
              value: granted['partner_sharing']?.granted ?? false,
              onChanged: (v) => set('partner_sharing', v),
            ),
            const Divider(
              height: AppSpace.lg,
              color: BambooInk.hairlineOnPaper,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Improve shared SMS decisions',
                style: BambooFonts.heading(14.5, color: BambooInk.ink900),
              ),
              subtitle: Text(
                'If enabled, your future confirmations, edits, dismissals, and reversals may contribute generalized SMS patterns and the fields you confirm or change (transaction amount, date, merchant, category; bill amount and due date) to shared rules for other users. The full SMS, account/card identifiers, and exact transaction references are removed on this device. This choice is separate from merchant contributions and can be turned off any time.',
                style: BambooFonts.ui(12.5, color: BambooInk.ink500),
              ),
              activeTrackColor: BambooInk.jade,
              value:
                  granted[smsSharedLearningPurpose]?.granted == true &&
                  granted[smsSharedLearningPurpose]?.policyVersion ==
                      smsSharedLearningPolicyVersion,
              onChanged: (v) => set(smsSharedLearningPurpose, v),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'The SMS learning policy needs review before collection is enabled in a production release.',
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Aggregate insights and partner sharing remain separate purposes.',
                style: BambooFonts.ui(11.5, color: BambooInk.ink500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentHistoryList extends ConsumerWidget {
  const _ConsentHistoryList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(_consentHistoryProvider);

    return history.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.lg),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (err, _) => ErrorState(
        message: userFacingErrorMessage(err),
        onRetry: () => ref.invalidate(_consentHistoryProvider),
      ),
      data: (records) {
        if (records.isEmpty) {
          return const EmptyState(
            icon: Icons.history_outlined,
            title: 'No consent records yet',
          );
        }
        return Column(
          children: [
            for (final r in records)
              Container(
                margin: const EdgeInsets.only(bottom: AppSpace.sm),
                decoration: BoxDecoration(
                  color: BambooInk.glassFillOnPaper,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: BambooInk.hairlineOnPaper),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg,
                  vertical: AppSpace.md,
                ),
                child: Text(
                  '${_purposeLabel(r.purpose)} — ${r.granted ? 'accepted' : 'declined'} ${_formatDate(r.grantedAt)}',
                  style: BambooFonts.ui(13.5, color: BambooInk.ink900),
                ),
              ),
          ],
        );
      },
    );
  }

  String _purposeLabel(String purpose) {
    switch (purpose) {
      case 'terms':
        return 'Terms';
      case 'aggregate_insights':
        return 'Aggregated insights';
      case 'partner_sharing':
        return 'Sharing with partners';
      case 'crowdsource':
        return 'Crowdsource';
      case 'marketing':
        return 'Marketing';
      default:
        return purpose;
    }
  }

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _formatDate(DateTime d) {
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }
}
