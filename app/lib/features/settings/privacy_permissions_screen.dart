import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/api_exception.dart';
import '../../data/consents_api.dart';

/// H4 Privacy & Permissions (docs/superpowers/plans/2026-08-07-group-h-settings-and-group-a-completion.md).
/// Reached via `Navigator.of(context).push(MaterialPageRoute(builder: (_) =>
/// const PrivacyPermissionsScreen()))` — a plain pushed screen, not a
/// registered go_router route, same pattern as ToolsHubScreen's children.
///
/// Local-only providers: this screen deliberately does NOT touch
/// app/lib/app/providers.dart (parallel-build collision avoidance across
/// several agents landing sibling H-group screens at once).
final _consentsApiProvider = Provider<ConsentsApi?>((ref) {
  final token = ref.watch(accessTokenProvider);
  if (token == null) return null;
  return ConsentsApi(apiBaseUrl: 'http://localhost:4000', accessToken: token);
});

final _consentHistoryProvider = FutureProvider.autoDispose<List<ConsentRecord>>((ref) async {
  final api = ref.watch(_consentsApiProvider);
  if (api == null) return const [];
  return api.fetchHistory();
});

/// Local device-permission status, refreshable via `ref.invalidate` after
/// returning from `openAppSettings()`.
final _locationStatusProvider = FutureProvider.autoDispose<PermissionStatus>(
  (ref) => Permission.location.status,
);
final _cameraStatusProvider = FutureProvider.autoDispose<PermissionStatus>((ref) => Permission.camera.status);
final _smsStatusProvider = FutureProvider.autoDispose<PermissionStatus>((ref) => Permission.sms.status);

class PrivacyPermissionsScreen extends ConsumerWidget {
  const PrivacyPermissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signedIn = ref.watch(accessTokenProvider) != null;

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Privacy & Permissions', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            Text(
              'App permissions',
              style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            _PermissionRow(
              icon: Icons.location_on_outlined,
              title: 'Location',
              caption: 'used to detect which store you\'re at',
              statusProvider: _locationStatusProvider,
            ),
            const SizedBox(height: AppSpace.sm),
            _PermissionRow(
              icon: Icons.qr_code_scanner_rounded,
              title: 'Camera',
              caption: 'used to scan payment QR codes',
              statusProvider: _cameraStatusProvider,
            ),
            if (Platform.isAndroid) ...[
              const SizedBox(height: AppSpace.sm),
              _PermissionRow(
                icon: Icons.sms_outlined,
                title: 'SMS',
                caption: 'used to auto-detect transactions from bank messages',
                statusProvider: _smsStatusProvider,
              ),
            ],
            const SizedBox(height: AppSpace.xl),
            Text(
              'How your data is handled',
              style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
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
              style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            if (!signedIn)
              const EmptyState(icon: Icons.lock_outline, title: 'Sign in to view')
            else
              const _ContributionToggle(),
            const SizedBox(height: AppSpace.xl),
            Text(
              'Consent history',
              style: BambooFonts.ui(12.5, weight: FontWeight.w700, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            if (!signedIn)
              const EmptyState(icon: Icons.lock_outline, title: 'Sign in to view')
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
  final AutoDisposeFutureProvider<PermissionStatus> statusProvider;

  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.caption,
    required this.statusProvider,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(statusProvider);

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
            decoration: const BoxDecoration(color: BambooInk.paperMuted, shape: BoxShape.circle),
            child: Icon(icon, size: 20, color: BambooInk.ink900),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
                const SizedBox(height: 2),
                Text(caption, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                const SizedBox(height: 4),
                status.when(
                  loading: () => Text('Checking…', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                  error: (_, _) => Text('Unknown', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                  data: (s) => _StatusBadge(status: s),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          status.maybeWhen(
            data: (s) => (s.isDenied || s.isPermanentlyDenied)
                ? TextButton(
                    style: TextButton.styleFrom(foregroundColor: BambooInk.jade),
                    onPressed: () async {
                      await openAppSettings();
                      ref.invalidate(statusProvider);
                    },
                    child: const Text('Open Settings'),
                  )
                : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
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
      PermissionStatus.granted => ('Allowed', BambooInk.jade, BambooInk.jade.withValues(alpha: 0.12)),
      PermissionStatus.limited => ('Limited', BambooInk.clay, BambooInk.clay.withValues(alpha: 0.12)),
      PermissionStatus.permanentlyDenied => (
        'Denied — set in Settings',
        BambooInk.clay,
        BambooInk.clay.withValues(alpha: 0.12),
      ),
      PermissionStatus.denied => ('Not allowed', BambooInk.clay, BambooInk.clay.withValues(alpha: 0.12)),
      _ => ('Unknown', BambooInk.ink500, BambooInk.paperMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: BambooFonts.ui(11, weight: FontWeight.w600, color: fg),
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
          Text(title, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          for (final b in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('•  ', style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
                  Expanded(
                    child: Text(b, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
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
        title: Text('Share what you see', style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
        subtitle: Text(
          'Anonymously log a merchant name/MCC/rough location (never an amount, exact time, or '
          'your identity) to help other users\' recommendations.',
          style: BambooFonts.ui(12.5, color: BambooInk.ink500),
        ),
        activeTrackColor: BambooInk.jade,
        activeColor: BambooInk.lime,
        value: optedIn,
        onChanged: (v) async {
          final repo = ref.read(userCardsRepositoryProvider);
          if (repo == null) return;
          try {
            await repo.setContributionsOptIn(v);
            ref.invalidate(profileProvider);
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(userFacingErrorMessage(e))));
            }
          }
        },
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
          return const EmptyState(icon: Icons.history_outlined, title: 'No consent records yet');
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
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
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
      case 'crowdsource':
        return 'Crowdsource';
      case 'marketing':
        return 'Marketing';
      default:
        return purpose;
    }
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  String _formatDate(DateTime d) {
    return '${d.day} ${_months[d.month - 1]} ${d.year}';
  }
}
