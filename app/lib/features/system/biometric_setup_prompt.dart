import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/design/app_theme.dart';
import '../settings/account_settings_screen.dart' show biometricLockProvider;

const _biometricPromptSeenKey = 'biometric_setup_prompt_seen_v1';

/// Shows the lightweight enrollment prompt used by the authenticated shell.
///
/// It is deliberately separate from [BiometricLockScreen]: this is an
/// optional invitation to turn the feature on, while the lock screen remains
/// the enforced challenge after the user has opted in.
class BiometricSetupPrompt extends ConsumerStatefulWidget {
  final LocalAuthentication? localAuth;

  const BiometricSetupPrompt({super.key, this.localAuth});

  @override
  ConsumerState<BiometricSetupPrompt> createState() =>
      _BiometricSetupPromptState();
}

class _BiometricSetupPromptState extends ConsumerState<BiometricSetupPrompt> {
  late final _localAuth = widget.localAuth ?? LocalAuthentication();
  bool _checking = false;
  bool _shownThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  Future<void> _maybeShow() async {
    if (!mounted || _checking || _shownThisSession) return;
    final lockState = ref.read(biometricLockProvider);
    if (!lockState.hasValue || lockState.valueOrNull == true) return;

    _checking = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_biometricPromptSeenKey) == true) return;

      // This is only a capability check. The actual user verification is
      // performed after the user explicitly taps Enable.
      if (!await _localAuth.isDeviceSupported() || !mounted) return;
      _shownThisSession = true;

      final choice = await showModalBottomSheet<bool>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => const _BiometricSetupSheet(),
      );
      if (!mounted) return;

      if (choice == true) {
        await _enable(prefs);
      } else if (choice == false) {
        await prefs.setBool(_biometricPromptSeenKey, true);
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> _enable(SharedPreferences prefs) async {
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason:
            'Use your fingerprint or device lock to protect PandaPay',
        biometricOnly: false,
      );
      if (!authenticated) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Biometric lock was not enabled. You can try again from Account settings.',
              ),
            ),
          );
        }
        return;
      }
      await ref.read(biometricLockProvider.notifier).setEnabled(true);
      await prefs.setBool(_biometricPromptSeenKey, true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biometric lock enabled.')),
        );
      }
    } on LocalAuthException catch (error) {
      if (!mounted) return;
      final noCredentials =
          error.code == LocalAuthExceptionCode.noCredentialsSet ||
          error.code == LocalAuthExceptionCode.noBiometricsEnrolled ||
          error.code == LocalAuthExceptionCode.noBiometricHardware;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            noCredentials
                ? 'Set up a fingerprint, face unlock, or device lock first, then try again.'
                : 'Biometric lock was not enabled. You can try again from Account settings.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Biometric lock was not enabled. You can try again from Account settings.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Retry the post-frame check once SharedPreferences-backed state resolves.
    ref.listen(biometricLockProvider, (_, next) {
      if (next.hasValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
      }
    });
    return const SizedBox.shrink();
  }
}

class _BiometricSetupSheet extends StatelessWidget {
  const _BiometricSetupSheet();

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BambooInk.paper,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xl,
          AppSpace.lg,
          AppSpace.xl,
          AppSpace.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: BambooInk.ink300,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            const Icon(
              Icons.fingerprint_rounded,
              size: 42,
              color: BambooInk.slate,
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Protect PandaPay',
              style: BambooFonts.heading(21, color: BambooInk.ink900),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'Use your fingerprint, face unlock, or device lock each time PandaPay opens. Your biometric data stays with Android.',
              style: BambooFonts.ui(14, color: BambooInk.ink500),
            ),
            const SizedBox(height: AppSpace.lg),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: BambooInk.slate,
                  foregroundColor: BambooInk.lime,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text('Enable fingerprint lock'),
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Not now',
                  style: BambooFonts.ui(14, color: BambooInk.ink500),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
