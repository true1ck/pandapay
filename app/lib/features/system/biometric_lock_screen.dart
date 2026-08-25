import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/design/app_theme.dart';
import '../../app/providers.dart';
import '../settings/account_settings_screen.dart' show biometricLockProvider;

/// The enforcement half of account_settings_screen.dart's "Biometric lock"
/// toggle — that screen only ever persisted a SharedPreferences bool with
/// nothing reading it (see BiometricLockController's own doc-comment: "a
/// separate follow-up not built here"). router.dart's redirect guard sends
/// every route here, same S5/S6 pattern as MaintenanceScreen/
/// ForcedUpgradeScreen, whenever the toggle is on and this app process
/// hasn't been unlocked yet — [biometricUnlockedProvider] is deliberately
/// plain in-memory state (not persisted), so a fresh cold start always
/// re-locks, matching the toggle's own copy: "Require Face/Touch ID to open
/// the app."
///
/// [LocalAuthentication.authenticate]'s default `biometricOnly: false`
/// lets the OS fall back to the device passcode/PIN/pattern — standard
/// practice for an app-lock feature, and critically what keeps this from
/// permanently locking someone out the moment they remove their last
/// enrolled fingerprint. The one case that fallback can't cover — a device
/// with no lock screen configured at all — gets its own explicit escape
/// hatch below rather than a dead end (same "never brick access to a
/// personal-finance app" reasoning as everywhere else caps/backups/etc. in
/// this codebase refuse to fail closed on a device-state problem that
/// isn't the user's fault).
class BiometricLockScreen extends ConsumerStatefulWidget {
  /// Injectable for tests, same shape as GeofenceMonitorService's optional
  /// FlutterLocalNotificationsPlugin — LocalAuthentication itself talks to
  /// a real platform channel with no test-friendly fake of its own.
  final LocalAuthentication? localAuth;

  const BiometricLockScreen({super.key, this.localAuth});

  @override
  ConsumerState<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends ConsumerState<BiometricLockScreen> {
  late final _localAuth = widget.localAuth ?? LocalAuthentication();
  bool _authenticating = false;
  bool _noDeviceLockAvailable = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attempt());
  }

  Future<void> _attempt() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final supported = await _localAuth.isDeviceSupported();
      if (!supported) {
        setState(() {
          _noDeviceLockAvailable = true;
          _authenticating = false;
        });
        return;
      }
      final ok = await _localAuth.authenticate(
        localizedReason: 'Unlock PandaPay to continue',
      );
      if (ok) {
        _unlock();
        return;
      }
      // authenticate() returns false (not a thrown exception) for a clean
      // user-side failure/cancel — nothing to escalate, just let them retry.
      if (mounted) setState(() => _error = 'Authentication was cancelled.');
    } on LocalAuthException catch (e) {
      final noLockConfigured =
          e.code == LocalAuthExceptionCode.noCredentialsSet ||
          e.code == LocalAuthExceptionCode.noBiometricsEnrolled ||
          e.code == LocalAuthExceptionCode.noBiometricHardware;
      if (mounted) {
        setState(() {
          _noDeviceLockAvailable = noLockConfigured;
          _error = noLockConfigured ? null : 'Could not verify — try again.';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not verify — try again.');
    } finally {
      if (mounted) setState(() => _authenticating = false);
    }
  }

  /// Just flips state — router.dart's _RouterRefreshNotifier listens to
  /// biometricUnlockedProvider and re-runs the redirect on change, which is
  /// what actually navigates away from here. Same "recover via state, not
  /// an explicit navigation call" shape as MaintenanceScreen.
  void _unlock() {
    ref.read(biometricUnlockedProvider.notifier).state = true;
  }

  Future<void> _disableAndContinue() async {
    await ref.read(biometricLockProvider.notifier).setEnabled(false);
    _unlock();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BambooInk.slate,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [BambooInk.slateRaised, BambooInk.slate, BambooInk.slateLow],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.fingerprint_rounded, color: BambooInk.lime, size: 56),
                const SizedBox(height: AppSpace.lg),
                Text(
                  'PandaPay is locked',
                  textAlign: TextAlign.center,
                  style: BambooFonts.heading(22, color: BambooInk.onSlate),
                ),
                const SizedBox(height: AppSpace.sm),
                Text(
                  _noDeviceLockAvailable
                      ? "This device has no fingerprint, face, or screen lock set up, so biometric "
                            "lock can't be enforced here."
                      : (_error ?? 'Verify it\'s you to continue.'),
                  textAlign: TextAlign.center,
                  style: BambooFonts.ui(14.5, color: BambooInk.onSlateMuted),
                ),
                const SizedBox(height: AppSpace.xl),
                if (_noDeviceLockAvailable)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.onSlate,
                      side: const BorderSide(color: BambooInk.onSlateMuted),
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                    ),
                    onPressed: _disableAndContinue,
                    child: const Text('Turn off biometric lock and continue'),
                  )
                else
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: BambooInk.onSlate,
                      side: const BorderSide(color: BambooInk.onSlateMuted),
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      textStyle: BambooFonts.ui(15, weight: FontWeight.w700),
                    ),
                    onPressed: _authenticating ? null : _attempt,
                    child: _authenticating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: BambooInk.onSlate),
                          )
                        : const Text('Try again'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
