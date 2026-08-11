import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/emergency_contacts_repository.dart';

/// ui-spec.md G4 Emergency Card Info — the one screen in this whole app
/// with a genuine "must work with zero network and zero login" mandate.
///
/// Reachable two ways, deliberately: (1) `AccountScreen`'s Tools section
/// for signed-in users, same as every other G/F tool, and (2) a direct link
/// from `LoginScreen` for signed-out users, because AccountScreen itself
/// shows LoginScreen (not its Tools list) when signed out — without (2),
/// "zero login" would be true of the data layer but false of navigation,
/// since nothing else in this app's Tools section is reachable pre-sign-in
/// either. This screen is registered as a plain top-level go_router route
/// (`AppRoute.emergencyCardInfo`), not nested in the auth-gated shell, so
/// both entry points reach the exact same instance.
///
/// Offline behaviour (the hard part): `emergencyContactsProvider`
/// (app/providers.dart) NEVER throws and NEVER depends on a live call at
/// the moment of use — it tries the network with a short timeout, falls
/// back to whatever was last cached on-device (SharedPreferences), and
/// falls back again to a small bundled dataset compiled into the app itself
/// if nothing was ever cached (the true cold-start-in-airplane-mode case).
/// This screen therefore has no ErrorState path for "offline" — only a
/// visible banner saying which of the three it's showing, per the
/// data-honesty cross-cutting rule.
class EmergencyCardInfoScreen extends ConsumerWidget {
  const EmergencyCardInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(emergencyContactsProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Emergency Card Info', style: BambooFonts.heading(17, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: result.when(
          // Only reachable on a genuine first paint before the provider
          // resolves — resolves near-instantly even fully offline, since the
          // bundled fallback requires no IO at all.
          loading: () => const Center(child: CircularProgressIndicator()),
          // The service is designed to never throw; this path exists only for
          // a genuine unexpected bug, not for "no network" (that's handled,
          // not an error, per the provider's own doc-comment).
          error: (err, _) => ErrorState(
            message: 'Something went wrong loading emergency contacts.',
            onRetry: () => ref.invalidate(emergencyContactsProvider),
          ),
          data: (data) => ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              _SourceBanner(source: data.source, lastSyncedAt: data.lastSyncedAt),
              const SizedBox(height: AppSpace.lg),
              for (final group in _groupByIssuer(data.contacts))
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.lg),
                  child: _IssuerGroup(issuerName: group.$1, contacts: group.$2),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<(String, List<IssuerEmergencyContact>)> _groupByIssuer(List<IssuerEmergencyContact> contacts) {
    final byIssuer = <String, List<IssuerEmergencyContact>>{};
    for (final c in contacts) {
      byIssuer.putIfAbsent(c.issuerName, () => []).add(c);
    }
    final groups = byIssuer.entries.map((e) => (e.key, e.value)).toList();
    for (final g in groups) {
      g.$2.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    }
    return groups;
  }
}

class _SourceBanner extends StatelessWidget {
  final EmergencyContactsSource source;
  final DateTime? lastSyncedAt;
  const _SourceBanner({required this.source, required this.lastSyncedAt});

  @override
  Widget build(BuildContext context) {
    late final String message;
    late final IconData icon;
    late final Color color;
    switch (source) {
      case EmergencyContactsSource.live:
        message = 'Up to date — refreshed just now.';
        icon = Icons.cloud_done_outlined;
        color = BambooInk.jade;
        break;
      case EmergencyContactsSource.cached:
        final synced = lastSyncedAt;
        message = synced == null
            ? 'Showing data saved on this device.'
            : 'Showing data saved on this device on ${_formatDate(synced)} — you appear to be '
                  'offline right now.';
        icon = Icons.offline_bolt_outlined;
        color = BambooInk.ink500;
        break;
      case EmergencyContactsSource.bundled:
        message =
            'No issuer data has synced to this device yet — showing general safety guidance '
            'below instead of your specific banks\' hotlines. Connect to the internet once to '
            'download the real numbers for your cards.';
        icon = Icons.info_outline_rounded;
        color = BambooInk.clay;
        break;
    }
    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(message, style: BambooFonts.ui(12.5, color: BambooInk.ink900)),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _IssuerGroup extends StatelessWidget {
  final String issuerName;
  final List<IssuerEmergencyContact> contacts;
  const _IssuerGroup({required this.issuerName, required this.contacts});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(issuerName, style: BambooFonts.heading(14.5, color: BambooInk.ink900)),
          const SizedBox(height: AppSpace.sm),
          for (final contact in contacts)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: _ContactRow(contact: contact),
            ),
        ],
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final IssuerEmergencyContact contact;
  const _ContactRow({required this.contact});

  @override
  Widget build(BuildContext context) {
    final hasPhone = contact.phone.trim().isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      contact.label,
                      style: BambooFonts.ui(13.5, weight: FontWeight.w600, color: BambooInk.ink900),
                    ),
                  ),
                  if (contact.isInternational)
                    StatusPill(
                      label: 'International',
                      foreground: BambooInk.ink900,
                      background: BambooInk.paperMuted,
                    ),
                ],
              ),
              if (hasPhone) ...[
                const SizedBox(height: 2),
                Text(
                  contact.phone + (contact.isCollectCall ? ' (collect call)' : ''),
                  style: BambooFonts.ui(
                    12.5,
                    color: BambooInk.ink500,
                  ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ],
              if (contact.blockProcedure != null) ...[
                const SizedBox(height: 4),
                Text(contact.blockProcedure!, style: BambooFonts.ui(12.5, color: BambooInk.ink500)),
              ],
            ],
          ),
        ),
        if (hasPhone) ...[const SizedBox(width: AppSpace.sm), _DialButton(phone: contact.phone)],
      ],
    );
  }
}

class _DialButton extends StatelessWidget {
  final String phone;
  const _DialButton({required this.phone});

  Future<void> _dial(BuildContext context) async {
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));
    final launched = await launchUrl(uri);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Couldn\'t open the dialer for $phone.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 48dp minimum touch target (Cross-Cutting accessibility rule).
    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        onPressed: () => _dial(context),
        icon: const Icon(Icons.call_rounded),
        color: BambooInk.jade,
        tooltip: 'Call $phone',
      ),
    );
  }
}
