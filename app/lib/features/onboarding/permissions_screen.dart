import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io' show Platform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/env.dart';
import '../../app/router.dart';
import '../sms_import/sms_listener_service.dart';

/// Design 15 "Onboarding / permissions" — three optional OS grants, asked
/// up front with plain-language reasons rather than surprising the user with
/// a bare system dialog the first time each feature is touched. All three
/// are genuinely optional: this screen's own "Continue" never blocks on
/// grant state, matching the design's explicit "all three are optional"
/// copy and this app's existing pattern elsewhere (Tracking Setup's "Set up
/// later" is likewise always enabled).
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen> {
  // The prod flavor's manifest (app/android/app/src/prod/AndroidManifest.xml)
  // strips READ_SMS/RECEIVE_SMS entirely — Google Play's SMS/Call Log policy
  // only allows them for a default SMS handler, which this optional
  // convenience feature doesn't qualify as. Showing the "Enable" button on
  // that flavor would request a permission the app never declared, which
  // can only fail.
  bool get _isAndroid => !kIsWeb && Platform.isAndroid && !Env.isProd;

  bool? _smsGranted;
  bool? _notificationsGranted;
  bool? _locationGranted;

  // All three requests below are wrapped in try/catch for the same reason:
  // `permission_handler`'s `.request()` can throw on some OEM builds
  // (a malformed manifest declaration, a request made while another is
  // still in flight), and none of that was caught. Without it, a thrown
  // exception left the toggle at its initial `null` — "checking…" —
  // forever, with no error and no way to tell it hadn't just not finished
  // yet. Resolving to "not granted" on failure is the same non-alarming
  // outcome the UI already shows for an ordinary user-denied grant — these
  // are explicitly optional permissions (this file's own doc-comment),
  // so treating a request failure as gently as a request decline is
  // consistent, not a downgrade.
  Future<void> _requestSms() async {
    bool granted = false;
    try {
      granted = await SmsListenerService().requestPermissions();
    } catch (_) {
      // fall through to "not granted"
    }
    if (mounted) setState(() => _smsGranted = granted);
  }

  Future<void> _requestNotifications() async {
    bool granted = false;
    try {
      granted = (await Permission.notification.request()).isGranted;
    } catch (_) {
      // fall through to "not granted"
    }
    if (mounted) setState(() => _notificationsGranted = granted);
  }

  Future<void> _requestLocation() async {
    bool granted = false;
    try {
      granted = (await Permission.locationWhenInUse.request()).isGranted;
    } catch (_) {
      // fall through to "not granted"
    }
    if (mounted) setState(() => _locationGranted = granted);
  }

  @override
  Widget build(BuildContext context) {
    // Material rather than DecoratedBox: this screen is routed without a
    // Scaffold, and with no Material ancestor every Text below inherited
    // `WidgetsApp._errorTextStyle`, which painted a yellow underline under
    // each line. `color:` fills the same opaque slate the box did.
    return Material(
      color: BambooInk.slate,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpace.md),
              Text('Set up a few permissions', style: BambooFonts.heading(24, color: BambooInk.onSlate)),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Every one of these is optional — skip any you\'re not sure about, you can turn them on later.',
                style: BambooFonts.ui(14, color: BambooInk.onSlateMuted),
              ),
              const SizedBox(height: AppSpace.xl),
              Expanded(
                child: ListView(
                  children: [
                    if (_isAndroid)
                      _PermissionRow(
                        icon: Icons.sms_outlined,
                        title: 'Read bank SMS alerts',
                        reason:
                            'Automatically logs spend from your bank\'s SMS, on-device. '
                            'We never see full card numbers.',
                        granted: _smsGranted,
                        onRequest: _requestSms,
                      ),
                    if (_isAndroid) const SizedBox(height: AppSpace.md),
                    _PermissionRow(
                      icon: Icons.notifications_none_rounded,
                      title: 'Notifications',
                      reason: 'Reward alerts, due-date reminders, and cap warnings.',
                      granted: _notificationsGranted,
                      onRequest: _requestNotifications,
                    ),
                    const SizedBox(height: AppSpace.md),
                    _PermissionRow(
                      icon: Icons.location_on_outlined,
                      title: 'Location',
                      reason: 'Suggests the best card the moment you\'re near a merchant.',
                      granted: _locationGranted,
                      onRequest: _requestLocation,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.md),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.lime,
                  foregroundColor: BambooInk.slate,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                ),
                onPressed: () => context.go(AppRoute.tour),
                child: const Text('Continue'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String reason;
  final bool? granted;
  final VoidCallback onRequest;

  const _PermissionRow({
    required this.icon,
    required this.title,
    required this.reason,
    required this.granted,
    required this.onRequest,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: BambooInk.slateRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BambooInk.slateHairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: BambooInk.slateLow, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: BambooInk.lime, size: 20),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: BambooFonts.heading(15, color: BambooInk.onSlate)),
                const SizedBox(height: 3),
                Text(reason, style: BambooFonts.ui(12.5, color: BambooInk.onSlateMuted)),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          if (granted == true)
            const Icon(Icons.check_circle_rounded, color: BambooInk.lime, size: 22)
          else
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: BambooInk.onSlate,
                side: const BorderSide(color: BambooInk.slateHairline),
                minimumSize: const Size(0, 34),
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              onPressed: onRequest,
              child: const Text('Enable'),
            ),
        ],
      ),
    );
  }
}
