import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/device_permissions.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../onboarding/entry_brand.dart';
import '../onboarding/permission_art.dart';
import '../sms_import/sms_inbox_scanner.dart';

enum _AutoSmsStage {
  prompt,
  scanning,
  success,
}

/// Auto SMS sync screen matching the onboarding/startup SMS permission,
/// loading scan, and review flows.
class AutoSmsSyncScreen extends ConsumerStatefulWidget {
  const AutoSmsSyncScreen({super.key});

  @override
  ConsumerState<AutoSmsSyncScreen> createState() => _AutoSmsSyncScreenState();
}

class _AutoSmsSyncScreenState extends ConsumerState<AutoSmsSyncScreen>
    with WidgetsBindingObserver {
  bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  _AutoSmsStage _stage = _AutoSmsStage.prompt;
  bool _checkingPermission = true;
  bool _permissionGranted = false;
  bool _requesting = false;
  bool _importRunning = false;
  String? _errorMessage;
  SmsInboxOverview? _overview;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initStage());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _stage == _AutoSmsStage.prompt) {
      unawaited(_checkPermissionAndAdvance());
    }
  }

  Future<void> _initStage() async {
    if (!_isAndroid) {
      if (mounted) {
        setState(() {
          _checkingPermission = false;
          _permissionGranted = false;
          _stage = _AutoSmsStage.prompt;
        });
      }
      return;
    }

    final granted = await _hasSmsPermission();
    if (!mounted) return;

    if (granted) {
      setState(() {
        _checkingPermission = false;
        _permissionGranted = true;
      });
      // Permission already granted: run inbox scan to load & refresh
      await _startInboxScan();
    } else {
      setState(() {
        _checkingPermission = false;
        _permissionGranted = false;
        _stage = _AutoSmsStage.prompt;
      });
    }
  }

  Future<bool> _hasSmsPermission() async {
    if (!_isAndroid) return false;
    try {
      final status = await readDevicePermissionStatus(Permission.sms);
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _checkPermissionAndAdvance() async {
    final granted = await _hasSmsPermission();
    if (!mounted) return;
    setState(() => _permissionGranted = granted);
    if (granted && _stage == _AutoSmsStage.prompt && !_importRunning) {
      await _startInboxScan();
    }
  }

  Future<void> _requestPermission() async {
    if (_requesting || _importRunning) return;
    if (!_isAndroid) {
      setState(() {
        _errorMessage = 'Automatic SMS detection is only supported on Android devices.';
      });
      return;
    }

    setState(() {
      _requesting = true;
      _errorMessage = null;
    });

    try {
      final current = await readDevicePermissionStatus(Permission.sms);
      if (current.isGranted) {
        setState(() {
          _permissionGranted = true;
          _requesting = false;
        });
        await _startInboxScan();
        return;
      }

      if (current.isPermanentlyDenied) {
        final opened = await openAppSettings();
        if (!opened && mounted) {
          setState(() {
            _errorMessage =
                'Open this app’s permissions in your device Settings to enable SMS access.';
          });
        }
        return;
      }

      final status = await Permission.sms.request();
      if (!mounted) return;

      if (status.isGranted) {
        setState(() {
          _permissionGranted = true;
          _requesting = false;
        });
        await _startInboxScan();
      } else {
        setState(() {
          _permissionGranted = false;
          _errorMessage = status.isPermanentlyDenied
              ? 'SMS permission is permanently denied. You can enable it in device Settings.'
              : 'SMS permission was not granted. Tap to try again.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Could not request SMS permission. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _startInboxScan() async {
    if (_importRunning) return;
    setState(() {
      _importRunning = true;
      _stage = _AutoSmsStage.scanning;
      _errorMessage = null;
    });

    final controller = ref.read(smsAutoImportProvider);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final perm = await readDevicePermissionStatus(Permission.sms);
      if (!perm.isGranted) {
        throw StateError('SMS access is off');
      }

      await controller.start();
      await controller.captureExistingInbox();
      final overview = await controller.inboxOverview();
      unawaited(controller.syncPendingMessages());

      if (!mounted) return;
      setState(() {
        _overview = overview;
        _importRunning = false;
        _stage = _AutoSmsStage.success;
      });

      ref.invalidate(smsImportBatchesProvider);
      ref.invalidate(needsReviewCountProvider);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _importRunning = false;
        _errorMessage =
            'We couldn’t finish reading your inbox. Saved alerts are safe; you can retry or check your permissions in Settings.';
        _stage = _AutoSmsStage.success;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_importRunning && !_requesting,
      child: EntryBackdrop(
        waves: _stage == _AutoSmsStage.success,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 24, 0),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back',
                          onPressed: _importRunning || _requesting
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        const PandaWordmark(size: 22),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey(_stage),
                      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                      child: switch (_stage) {
                        _AutoSmsStage.prompt => _promptContent(),
                        _AutoSmsStage.scanning => _scanningContent(),
                        _AutoSmsStage.success => _successContent(),
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                    child: _footer(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _promptContent() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Eyebrow('LESS TYPING. MORE CLARITY.'),
          const SizedBox(height: 12),
          const _Title('Let your spends\nfind their way.'),
          const SizedBox(height: 12),
          _body(
            'Turn bank SMS alerts into spending and bill details, so you don’t have to enter them one by one.',
          ),
          const SizedBox(height: 20),
          const SmsPermissionArtwork(),
          const SizedBox(height: 22),
          const _TrustPoint(
            icon: Icons.phonelink_lock_rounded,
            title: 'Filtered on your phone',
            body:
                'OTP and security-code messages are excluded before capture or sync.',
          ),
          const SizedBox(height: 15),
          const _TrustPoint(
            icon: Icons.cloud_sync_outlined,
            title: 'Connected to your account',
            body:
                'Matching financial SMS text is sent to PandaPay’s server for processing and account sync.',
          ),
          const SizedBox(height: 14),
          _body(
            'Android grants inbox access. You can revoke it at any time in device Settings.',
            small: true,
          ),
        ],
      );

  Widget _scanningContent() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Eyebrow('A LITTLE SORTING, A LOT OF CLARITY'),
          const SizedBox(height: 12),
          const _Title('Panda’s sorting\nthe small print.'),
          const SizedBox(height: 12),
          _body(
            'Finding financial alerts and putting recognized spends into your spending view.',
          ),
          const SizedBox(height: 28),
          const ImportPermissionArtwork(complete: false),
          const SizedBox(height: 28),
          ValueListenableBuilder<SmsInboxScanProgress>(
            valueListenable: ref.read(smsAutoImportProvider).inboxScanProgress,
            builder: (context, progress, _) => Semantics(
              liveRegion: true,
              child: _Surface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      progress.complete
                          ? 'Preparing your spending view…'
                          : 'Checking your SMS inbox…',
                      style: BambooFonts.heading(17, weight: FontWeight.w600),
                    ),
                    const SizedBox(height: 14),
                    const LinearProgressIndicator(
                      color: BambooInk.jade,
                      backgroundColor: Color(0xFFEAF1E2),
                      minHeight: 5,
                      borderRadius: BorderRadius.all(Radius.circular(5)),
                    ),
                    const SizedBox(height: 13),
                    _body(
                      '${progress.checked} messages checked · ${progress.matched} financial alerts found',
                      small: true,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const _TrustPoint(
            icon: Icons.shield_outlined,
            title: 'One step at a time',
            body:
                'Alerts are saved locally first. Account sync can continue in the background, including when you reconnect.',
          ),
        ],
      );

  Widget _successContent() {
    final overview = _overview;
    final hasSpends = (overview?.spends ?? 0) > 0;
    final needsReviewCount =
        ref.watch(needsReviewCountProvider).valueOrNull ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Eyebrow('A GOOD START'),
        const SizedBox(height: 12),
        _Title(
          _errorMessage != null
              ? 'We can finish\nthis later.'
              : hasSpends
                  ? 'Your spends,\ncoming together.'
                  : (overview?.bankAlerts ?? 0) > 0
                      ? 'Your bank alerts,\nin one place.'
                      : 'Auto SMS detection\nis active.',
        ),
        const SizedBox(height: 12),
        _body(
          _errorMessage != null
              ? 'You can keep using PandaPay while we leave the rest in your hands.'
              : (overview?.bankAlerts ?? 0) == 0
                  ? 'No financial SMS alerts were found in this device inbox. New incoming bank alerts will be detected automatically.'
                  : 'Recognized spends are available in Spending. Some alerts may need review or a connection before they appear.',
        ),
        const SizedBox(height: 22),
        ImportPermissionArtwork(complete: _errorMessage == null),
        const SizedBox(height: 20),
        if (overview != null)
          _Surface(
            child: Row(
              children: [
                Expanded(
                  child: _Count(
                    value: overview.bankAlerts,
                    label: 'Bank alerts saved',
                  ),
                ),
                Container(
                  width: 1,
                  height: 52,
                  color: BambooInk.hairlineOnPaper,
                ),
                Expanded(
                  child: _Count(
                    value: overview.spends,
                    label: 'SMS spends available',
                  ),
                ),
              ],
            ),
          ),
        if ((overview?.pendingSync ?? 0) > 0) ...[
          const SizedBox(height: 16),
          _body(
            '${overview!.pendingSync} bank alerts are waiting for account sync. They’re saved on this device.',
            small: true,
          ),
        ],
        if (needsReviewCount > 0) ...[
          const SizedBox(height: 16),
          _Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.mark_email_unread_outlined,
                      color: BambooInk.jade,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        needsReviewCount == 1
                            ? '1 message needs review'
                            : '$needsReviewCount messages need review',
                        style: BambooFonts.heading(15, color: BambooInk.ink900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Some alerts need a quick check to match them to the right card or account.',
                  style: BambooFonts.ui(12.5, color: BambooInk.ink700),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: () => context.push(AppRoute.needsReview),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                  label: Text(
                    'Review alerts now',
                    style: BambooFonts.ui(13, weight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_errorMessage != null) _notice(_errorMessage!),
      ],
    );
  }

  Widget _footer() {
    final needsReviewCount =
        ref.watch(needsReviewCountProvider).valueOrNull ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_errorMessage != null && _stage == _AutoSmsStage.prompt)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _errorMessage!,
                style: BambooFonts.ui(12, color: BambooInk.ink700, height: 1.4),
              ),
            ),
          ),
        switch (_stage) {
          _AutoSmsStage.prompt => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                EntryButton(
                  label: _permissionGranted
                      ? 'Find my spends'
                      : 'Allow SMS & find my spends',
                  loading: _checkingPermission || _requesting,
                  onPressed: _checkingPermission || _requesting
                      ? null
                      : () => _permissionGranted
                          ? _startInboxScan()
                          : _requestPermission(),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _requesting ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    'Maybe later',
                    style: BambooFonts.ui(
                      14,
                      color: BambooInk.ink700,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          _AutoSmsStage.scanning => EntryButton(
              label: 'Continue in background',
              onPressed: () => Navigator.of(context).pop(),
              secondary: true,
            ),
          _AutoSmsStage.success => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (needsReviewCount > 0) ...[
                  EntryButton(
                    label: 'Review $needsReviewCount alert${needsReviewCount == 1 ? '' : 's'}',
                    onPressed: () => context.push(AppRoute.needsReview),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Done for now',
                      style: BambooFonts.ui(
                        14,
                        color: BambooInk.ink700,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ] else ...[
                  EntryButton(
                    label: 'Done',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _importRunning ? null : _startInboxScan,
                    child: Text(
                      'Scan inbox again',
                      style: BambooFonts.ui(
                        13,
                        color: BambooInk.ink700,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
        },
      ],
    );
  }

  Widget _body(String text, {bool small = false}) => Text(
        text,
        style: BambooFonts.ui(
          small ? 12 : 15,
          color: BambooInk.ink700,
          height: 1.45,
        ),
      );

  Widget _notice(String text) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Semantics(
          liveRegion: true,
          child: _Surface(
            child: Text(
              text,
              style: BambooFonts.ui(13, color: BambooInk.ink700, height: 1.4),
            ),
          ),
        ),
      );
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: BambooFonts.heading(30, weight: FontWeight.w800, height: 1.1),
      );
}

class _Eyebrow extends StatelessWidget {
  final String text;
  const _Eyebrow(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: BambooFonts.ui(
          10,
          color: BambooInk.jade,
          weight: FontWeight.w700,
        ).copyWith(letterSpacing: 1.3),
      );
}

class _Surface extends StatelessWidget {
  final Widget child;
  const _Surface({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .93),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFE5E9E1)),
        ),
        child: child,
      );
}

class _TrustPoint extends StatelessWidget {
  final IconData icon;
  final String title, body;
  const _TrustPoint({
    required this.icon,
    required this.title,
    required this.body,
  });
  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: BambooInk.jade),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: BambooFonts.ui(14, weight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                  body,
                  style:
                      BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      );
}

class _Count extends StatelessWidget {
  final int value;
  final String label;
  const _Count({required this.value, required this.label});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          children: [
            Text(
              '$value',
              style: BambooFonts.heading(
                30,
                color: BambooInk.jade,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              textAlign: TextAlign.center,
              style: BambooFonts.ui(12, color: BambooInk.ink700),
            ),
          ],
        ),
      );
}
