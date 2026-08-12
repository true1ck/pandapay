import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/design/app_theme.dart';
import '../../app/design/widgets.dart';
import '../../app/providers.dart';
import '../../data/analytics.dart';
import '../../data/api_exception.dart';
import '../../data/devices_api.dart';

/// Plan Phase 1.4 — design 20's "Linked devices", finally buildable.
///
/// `settings_hub_screen.dart` previously listed this as one of two rows it
/// deliberately could not build, on the grounds that "auth/ has no
/// session-enumeration endpoint, so there is nothing to list". That was
/// wrong: `GET /users/me/devices` and `DELETE /users/me/devices/:id` have
/// both existed in `auth/src/routes/userRoutes.js` all along, complete with
/// refresh-token revocation and an audit-log entry. Nothing new was needed on
/// the server for this screen.
///
/// It matters more than a settings nicety. Device switching is the thing this
/// whole plan phase is about, and "I got a new phone, is my old one still
/// signed in?" has, until now, had no answer inside the app — for a product
/// holding someone's complete spending history, on a stack where the refresh
/// token has no short expiry (see `TokenStore`'s own comment).
final linkedDevicesProvider = FutureProvider.autoDispose<List<LinkedDevice>>((ref) async {
  final api = ref.watch(devicesApiProvider);
  if (api == null) return const [];
  return api.fetchDevices();
});

class LinkedDevicesScreen extends ConsumerStatefulWidget {
  const LinkedDevicesScreen({super.key});

  @override
  ConsumerState<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  String? _revoking;

  Future<void> _confirmAndRevoke(LinkedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out this device?'),
        // Names the real consequence rather than asking "are you sure": the
        // point of the control is that the other device stops being able to
        // reach the account, and a user reaching for it is usually worried
        // about exactly that.
        content: Text(
          '${device.displayName} will be signed out and will need to verify with an OTP to '
          'get back in. Your data is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _revoking = device.deviceIdentifier);
    try {
      await ref.read(devicesApiProvider)!.revokeDevice(device.deviceIdentifier);
      ref.read(analyticsProvider).track(AnalyticsEvent.deviceRevoked);
      ref.invalidate(linkedDevicesProvider);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('${device.displayName} signed out')));
      }
    } on ApiException catch (e) {
      // StepUpRequiredException is an ApiException, and its userMessage
      // already explains the re-verification requirement — so both cases land
      // here and both say something true and actionable.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.userMessage)));
      }
    } finally {
      if (mounted) setState(() => _revoking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(linkedDevicesProvider);

    return Scaffold(
      backgroundColor: BambooInk.paper,
      appBar: AppBar(
        backgroundColor: BambooInk.paper,
        foregroundColor: BambooInk.ink900,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Linked devices', style: BambooFonts.heading(18, color: BambooInk.ink900)),
      ),
      body: AppBackground(
        child: devices.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpace.lg),
            child: SkeletonList(),
          ),
          error: (e, _) => ErrorState(
            message: e is ApiException ? e.userMessage : 'Could not load your devices.',
            onRetry: () => ref.invalidate(linkedDevicesProvider),
          ),
          data: (list) {
            if (list.isEmpty) {
              return const EmptyState(
                icon: Icons.devices_outlined,
                title: 'No other devices',
                message: 'This is the only device signed in to your account.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(AppSpace.lg),
              itemCount: list.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpace.sm),
              itemBuilder: (context, index) {
                if (index == list.length) return const _DevicesFootnote();
                final device = list[index];
                return _DeviceTile(
                  device: device,
                  busy: _revoking == device.deviceIdentifier,
                  onRevoke: () => _confirmAndRevoke(device),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final LinkedDevice device;
  final bool busy;
  final VoidCallback onRevoke;

  const _DeviceTile({required this.device, required this.busy, required this.onRevoke});

  /// Coarse on purpose. `last_seen_at` updates on every token refresh, so
  /// minute-level precision would imply a tracking fidelity the row does not
  /// have and the user has no reason to want.
  String _lastSeenLabel(DateTime? at) {
    if (at == null) return 'Last seen: unknown';
    final delta = DateTime.now().difference(at);
    if (delta.inMinutes < 60) return 'Active now';
    if (delta.inHours < 24) return 'Last active today';
    if (delta.inDays == 1) return 'Last active yesterday';
    if (delta.inDays < 30) return 'Last active ${delta.inDays} days ago';
    return 'Last active on ${at.day}/${at.month}/${at.year}';
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      if (device.platform != null) device.platform!,
      if (device.appVersion != null) 'app ${device.appVersion}',
    ].join(' · ');

    return Container(
      decoration: BoxDecoration(
        color: BambooInk.glassFillOnPaper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BambooInk.hairlineOnPaper),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
      child: Row(
        children: [
          Icon(
            device.platform?.toLowerCase() == 'ios'
                ? Icons.phone_iphone_rounded
                : Icons.phone_android_rounded,
            size: 20,
            color: BambooInk.ink900,
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.displayName,
                  style: BambooFonts.ui(14.5, weight: FontWeight.w500, color: BambooInk.ink900),
                ),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: BambooFonts.ui(12, color: BambooInk.ink500)),
                Text(
                  _lastSeenLabel(device.lastSeenAt),
                  style: BambooFonts.ui(12, color: BambooInk.ink500),
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          else
            TextButton(onPressed: onRevoke, child: const Text('Sign out')),
        ],
      ),
    );
  }
}

class _DevicesFootnote extends StatelessWidget {
  const _DevicesFootnote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.lg),
      child: Text(
        // Says which device is which is NOT marked, because the app cannot
        // currently tell: the client does not send a stable device identifier
        // it can compare against, so highlighting "this device" would be a
        // guess. Better to say nothing than to point at the wrong row in a
        // security screen.
        'Signing a device out revokes its access immediately. If you see a device you don\'t '
        'recognise, sign it out and change your sign-in number.',
        style: BambooFonts.ui(12, color: BambooInk.ink500),
      ),
    );
  }
}
