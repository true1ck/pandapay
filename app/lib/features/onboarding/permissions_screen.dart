import 'dart:async';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:permission_handler/permission_handler.dart';

import '../../app/design/app_theme.dart';
import '../../app/device_permissions.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../sms_import/sms_inbox_scanner.dart';
import '../sms_import/ios_sms_import_screen.dart';
import 'entry_brand.dart';
import 'onboarding_back.dart';
import 'permission_art.dart';

enum _SetupPage { sms, importing, imported, options }

/// Two short disclosure steps. The import between them uses the existing
/// durable SMS pipeline; Android, rather than this UI, controls every grant.
class PermissionsScreen extends ConsumerStatefulWidget {
  const PermissionsScreen({super.key});

  @override
  ConsumerState<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends ConsumerState<PermissionsScreen>
    with WidgetsBindingObserver {
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isIos => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get _hasSmsStep => _isAndroid || _isIos;
  late _SetupPage _page;
  final _statuses = <Permission, PermissionStatus>{};
  static const _extraPermissions = [
    Permission.notification,
    Permission.locationWhenInUse,
    Permission.camera,
    Permission.microphone,
  ];
  Permission? _requesting;
  bool _requestingAll = false;
  bool _checkingStatuses = true;
  int _statusRevision = 0;
  String? _message;
  bool _waitingForSmsSettings = false;
  bool _importRunning = false;
  SmsInboxOverview? _overview;

  @override
  void initState() {
    super.initState();
    _page = _hasSmsStep ? _SetupPage.sms : _SetupPage.options;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshStatuses());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatuses());
  }

  Future<void> _refreshStatuses() async {
    if (_requesting != null || _requestingAll) return;
    final revision = ++_statusRevision;
    setState(() {
      _checkingStatuses = true;
      _statuses.clear();
    });
    final statuses = <Permission, PermissionStatus>{};
    for (final permission in [
      if (_isAndroid) Permission.sms,
      ..._extraPermissions,
    ]) {
      try {
        statuses[permission] = await readDevicePermissionStatus(permission);
      } catch (_) {
        // An unavailable platform permission must not block account setup.
      }
    }
    // A lifecycle refresh started before a native dialog must not overwrite
    // its newer grant with an older status when the dialog closes.
    if (!mounted || revision != _statusRevision || _requestingAll) return;
    setState(() {
      _statuses
        ..clear()
        ..addAll(statuses);
      _checkingStatuses = false;
      if (_page == _SetupPage.options && _extrasEnabled) _message = null;
    });
    if (_waitingForSmsSettings && _granted(Permission.sms)) {
      _waitingForSmsSettings = false;
      if (_page == _SetupPage.sms) await _importSms();
    }
  }

  bool _granted(Permission permission) =>
      _statuses[permission]?.isGranted == true ||
      (permission == Permission.notification &&
          _statuses[permission]?.isProvisional == true);
  bool _blocked(Permission permission) =>
      _statuses[permission]?.isPermanentlyDenied ?? false;
  bool get _extrasEnabled => _extraPermissions.every(_granted);

  Future<void> _request(
    Permission permission, {
    bool inSequence = false,
  }) async {
    if (_requesting != null) return;
    _statusRevision++;
    setState(() {
      _requesting = permission;
      _checkingStatuses = false;
      _message = null;
    });
    try {
      final current = await readDevicePermissionStatus(permission);
      if (!mounted) return;
      setState(() => _statuses[permission] = current);
      if (_granted(permission)) {
        if (permission == Permission.sms) unawaited(_importSms());
        return;
      }
      if (current.isRestricted) {
        if (!inSequence) {
          setState(
            () => _message =
                'This permission is restricted on this device. You can continue without it.',
          );
        }
        return;
      }
      if (current.isPermanentlyDenied) {
        // The combined action only opens native prompts. Settings remains an
        // explicit choice on each blocked row rather than interrupting the queue.
        if (inSequence) return;
        if (permission == Permission.sms) _waitingForSmsSettings = true;
        final opened = await openAppSettings();
        if (!opened && mounted) {
          setState(
            () => _message =
                'Open this app’s permissions in your device Settings to enable access.',
          );
        }
        return;
      }
      // Geolocator accepts Android's approximate foreground grant. The
      // combined fine/coarse permission-handler result can report it denied.
      final status = permission == Permission.locationWhenInUse
          ? foregroundLocationPermissionStatus(
              await geo.Geolocator.requestPermission(),
            )
          : await permission.request();
      if (!mounted) return;
      setState(() => _statuses[permission] = status);
      if (status.isGranted) {
        if (permission == Permission.sms) {
          unawaited(_importSms());
        }
      } else {
        setState(
          () => _message = status.isRestricted
              ? 'This permission is restricted on this device. You can continue without it.'
              : 'That’s okay. You can continue without this and enable it later in Settings.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _statuses.remove(permission);
          _message =
              'We couldn’t open that permission. Try again or continue without it.';
        });
      }
    } finally {
      _statusRevision++;
      if (mounted) {
        setState(() => _requesting = null);
        // A resume event can arrive while the native request is still busy.
        // Read again after it finishes instead of losing that refresh.
        if (!inSequence) await _refreshStatuses();
      }
    }
  }

  Future<void> _requestAll() async {
    if (_requestingAll || _requesting != null) return;
    _statusRevision++;
    setState(() {
      _requestingAll = true;
      _message = null;
    });
    try {
      for (final permission in _extraPermissions) {
        if (!mounted || _page != _SetupPage.options) return;
        // Each request rechecks Android, skipping grants already enabled.
        await _request(permission, inSequence: true);
        if (!mounted) return;
        // Paint the Enabled state before showing the next system dialog.
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      if (mounted) {
        setState(() => _requestingAll = false);
        await _refreshStatuses();
        if (mounted) {
          setState(() {
            _message = _extrasEnabled
                ? null
                : 'Some permissions are still off. You can continue for now or enable them later in Settings.';
          });
        }
      }
    }
  }

  void _continueToCards() => context.push(AppRoute.addFirstCard);

  Future<void> _importSms() async {
    if (_importRunning) return;
    setState(() {
      _importRunning = true;
      _page = _SetupPage.importing;
      _message = null;
    });
    final controller = ref.read(smsAutoImportProvider);
    try {
      // Let the progress view paint before the first local database work.
      await WidgetsBinding.instance.endOfFrame;
      if (!await ref.read(smsListenerServiceProvider).hasPermissions()) {
        throw StateError('SMS access is off');
      }
      await controller.start();
      await controller.captureExistingInbox();
      final overview = await controller.inboxOverview();
      // Local capture is sufficient for Spending. Network retries already
      // belong to the shared controller and must not hold up onboarding.
      unawaited(_syncInBackground(controller));
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _importRunning = false;
        if (_page == _SetupPage.importing) _page = _SetupPage.imported;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _importRunning = false;
        _message =
            'We couldn’t finish reading your inbox. Saved alerts are safe; you can retry or set this up later in Import & Sync.';
        if (_page == _SetupPage.importing) _page = _SetupPage.imported;
      });
    }
  }

  Future<void> _syncInBackground(SmsAutoImportController controller) async {
    try {
      await controller.syncPendingMessages();
      final overview = await controller.inboxOverview();
      if (mounted) setState(() => _overview = overview);
    } catch (_) {
      // Capture is durable. The shared outbox retries without blocking setup.
    }
  }

  void _showOptions() => setState(() {
    _page = _SetupPage.options;
    _message = null;
  });

  void _back() {
    if (_page == _SetupPage.options && _hasSmsStep) {
      setState(() {
        _page = _importRunning
            ? _SetupPage.importing
            : _overview != null
            ? _SetupPage.imported
            : _SetupPage.sms;
        _message = null;
      });
    } else if (_page == _SetupPage.imported || _page == _SetupPage.importing) {
      setState(() {
        _page = _SetupPage.sms;
        _message = null;
      });
    } else {
      onboardingBack(context, fallback: AppRoute.welcome);
    }
  }

  @override
  Widget build(BuildContext context) {
    final options = _page == _SetupPage.options;
    return OnboardingBackScope(
      handlesStep: _page != _SetupPage.sms && _hasSmsStep,
      busy: _requestingAll || _requesting != null,
      onBack: _back,
      child: EntryBackdrop(
        waves: options,
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
                          onPressed: _requestingAll || _requesting != null
                              ? null
                              : _back,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const Spacer(),
                        const PandaWordmark(size: 22),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                    child: Row(
                      children: [
                        Expanded(child: _StepLine(active: true)),
                        const SizedBox(width: 6),
                        Expanded(child: _StepLine(active: options)),
                        const SizedBox(width: 12),
                        Text(
                          !_hasSmsStep
                              ? '1 of 1'
                              : options
                              ? '2 of 2'
                              : '1 of 2',
                          style: BambooFonts.ui(12, color: BambooInk.ink700),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      key: ValueKey(_page),
                      padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                      child: switch (_page) {
                        _SetupPage.sms => _smsContent(),
                        _SetupPage.importing => _importContent(),
                        _SetupPage.imported => _resultContent(),
                        _SetupPage.options => _optionsContent(),
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

  Widget _smsContent() => Column(
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
        _isIos
            ? 'On iPhone, Shortcuts passes the messages you choose to PandaPay. iOS does not grant direct SMS inbox access. You can set this up now or later in Import & Sync.'
            : 'Android grants inbox access. You can revoke it at any time in device Settings.',
        small: true,
      ),
    ],
  );

  Widget _importContent() => Column(
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

  Widget _resultContent() {
    final overview = _overview;
    final hasSpends = (overview?.spends ?? 0) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Eyebrow('A GOOD START'),
        const SizedBox(height: 12),
        _Title(
          _message != null
              ? 'We can finish\nthis later.'
              : hasSpends
              ? 'Your spends,\ncoming together.'
              : (overview?.bankAlerts ?? 0) > 0
              ? 'Your bank alerts,\nin one place.'
              : 'Ready for your\nfirst spend.',
        ),
        const SizedBox(height: 12),
        _body(
          _message != null
              ? 'You can keep setting up PandaPay while we leave the rest in your hands.'
              : (overview?.bankAlerts ?? 0) == 0
              ? 'No financial SMS alerts were found in this account’s captured inbox. You can add spends manually or import them later.'
              : 'Recognized spends are available in Spending. Some alerts may need review or a connection before they appear.',
        ),
        const SizedBox(height: 22),
        ImportPermissionArtwork(complete: _message == null),
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
        if (_message != null) _notice(_message!),
      ],
    );
  }

  Widget _optionsContent() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Eyebrow('HELPFUL EXTRAS. YOUR CHOICE.'),
      const SizedBox(height: 12),
      const _Title('A little help.\nOn your terms.'),
      const SizedBox(height: 12),
      _body(
        'Choose what’s useful to you. Each permission has a purpose, and you can change your mind later.',
      ),
      const SizedBox(height: 12),
      const ReminderPermissionArtwork(),
      const SizedBox(height: 12),
      _permissionTile(
        Permission.notification,
        Icons.notifications_none_rounded,
        'Timely reminders',
        'Bill due dates, reward caps and milestone alerts.',
      ),
      const SizedBox(height: 10),
      _permissionTile(
        Permission.locationWhenInUse,
        Icons.near_me_outlined,
        'Nearby merchants',
        'Find merchants near you while using the app.',
      ),
      const SizedBox(height: 10),
      _permissionTile(
        Permission.camera,
        Icons.qr_code_scanner_rounded,
        'Scan, don’t type',
        'Scan UPI QR codes or photograph a card to add it.',
      ),
      const SizedBox(height: 10),
      _permissionTile(
        Permission.microphone,
        Icons.mic_none_rounded,
        'Say it to Panda',
        'Use voice input with the assistant when you tap the mic.',
      ),
      const SizedBox(height: 16),
      _body('Background alerts are a separate opt-in in Nearby.', small: true),
    ],
  );

  Widget _permissionTile(
    Permission permission,
    IconData icon,
    String title,
    String reason,
  ) => _PermissionTile(
    icon: icon,
    title: title,
    reason: reason,
    granted: _granted(permission),
    blocked: _blocked(permission),
    busy: _requesting == permission,
    checking: _checkingStatuses,
    known: _statuses.containsKey(permission),
    onPressed:
        _checkingStatuses ||
            _requestingAll ||
            _requesting != null ||
            _granted(permission)
        ? null
        : () => _request(permission),
  );

  Widget _footer() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_message != null &&
          (_page == _SetupPage.sms || _page == _SetupPage.options))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _message!,
              style: BambooFonts.ui(12, color: BambooInk.ink700, height: 1.4),
            ),
          ),
        ),
      _footerActions(),
    ],
  );

  Widget _footerActions() => switch (_page) {
    _SetupPage.sms => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntryButton(
          label: _isIos
              ? 'Set up SMS Shortcuts'
              : _importRunning
              ? 'View import progress'
              : _granted(Permission.sms)
              ? 'Find my spends'
              : _blocked(Permission.sms)
              ? 'Open SMS settings'
              : 'Allow SMS & find my spends',
          loading:
              !_isIos && (_checkingStatuses || _requesting == Permission.sms),
          onPressed: (!_isIos && _checkingStatuses) || _requesting != null
              ? null
              : _isIos
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const IosSmsImportScreen(),
                  ),
                )
              : _importRunning
              ? () => setState(() => _page = _SetupPage.importing)
              : () => _granted(Permission.sms)
                    ? _importSms()
                    : _request(Permission.sms),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _requesting != null ? null : _showOptions,
          child: Text(
            _isIos ? 'Continue for now' : 'I’ll add spends myself',
            style: BambooFonts.ui(
              14,
              color: BambooInk.ink700,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
    _SetupPage.importing => EntryButton(
      label: 'Continue in background',
      onPressed: _showOptions,
      secondary: true,
    ),
    _SetupPage.imported => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntryButton(label: 'Continue', onPressed: _showOptions),
        if (_message != null)
          TextButton(
            onPressed: _importSms,
            child: const Text('Try SMS import again'),
          ),
      ],
    ),
    _SetupPage.options => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EntryButton(
          label: _extrasEnabled
              ? 'Continue to my cards'
              : _extraPermissions.any(_granted)
              ? 'Allow remaining permissions'
              : 'Allow permissions',
          loading: _checkingStatuses || _requestingAll,
          onPressed: _checkingStatuses || _requestingAll || _requesting != null
              ? null
              : _extrasEnabled
              ? _continueToCards
              : _requestAll,
        ),
        if (!_extrasEnabled)
          TextButton(
            onPressed: _requestingAll || _requesting != null
                ? null
                : _continueToCards,
            child: Text(
              'Continue for now',
              style: BambooFonts.ui(13, color: BambooInk.ink700),
            ),
          ),
      ],
    ),
  };

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

class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title, reason;
  final bool granted, blocked, busy, checking, known;
  final VoidCallback? onPressed;
  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.reason,
    required this.granted,
    required this.blocked,
    required this.busy,
    required this.checking,
    required this.known,
    required this.onPressed,
  });

  Widget _action() => granted
      ? Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: BambooInk.jade,
                size: 16,
              ),
              const SizedBox(width: 5),
              Text(
                'Enabled',
                style: BambooFonts.ui(
                  12,
                  color: BambooInk.jade,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
        )
      : TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: BambooInk.jade,
            minimumSize: const Size(64, 44),
          ),
          child: busy
              ? const SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  checking
                      ? 'Checking…'
                      : blocked
                      ? 'Settings'
                      : known
                      ? 'Enable'
                      : 'Check again',
                  style: BambooFonts.ui(
                    13,
                    color: BambooInk.jade,
                    weight: FontWeight.w700,
                  ),
                ),
        );

  @override
  Widget build(BuildContext context) => _Surface(
    padding: 12,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact =
            constraints.maxWidth >= 300 &&
            MediaQuery.textScalerOf(context).scale(14) <= 18;
        final description = Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: BambooFonts.heading(16, weight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                reason,
                style: BambooFonts.ui(
                  12.5,
                  color: BambooInk.ink700,
                  height: 1.35,
                ),
              ),
            ],
          ),
        );
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F7E8),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, color: BambooInk.jade, size: 20),
            ),
            const SizedBox(width: 11),
            description,
            if (compact) ...[const SizedBox(width: 7), _action()],
          ],
        );
        return compact
            ? row
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row,
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerRight, child: _action()),
                ],
              );
      },
    ),
  );
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: BambooFonts.heading(33, weight: FontWeight.w800, height: 1.08),
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

class _StepLine extends StatelessWidget {
  final bool active;
  const _StepLine({required this.active});
  @override
  Widget build(BuildContext context) => Container(
    height: 4,
    decoration: BoxDecoration(
      color: active ? const Color(0xFFACD967) : const Color(0xFFE9EDE4),
      borderRadius: BorderRadius.circular(10),
    ),
  );
}

class _Surface extends StatelessWidget {
  final Widget child;
  final double padding;
  const _Surface({required this.child, this.padding = 16});
  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(padding),
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
              style: BambooFonts.ui(12.5, color: BambooInk.ink700, height: 1.4),
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
