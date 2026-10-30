import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

enum DeviceUnlockMethod { face, fingerprint, iris, biometric, deviceLock }

/// Labels come from the OS's enrolled capabilities, never a model-name list.
/// Authentication itself remains with local_auth and the system's fallback.
class DeviceAuthenticationInfo {
  final bool supported;
  final DeviceUnlockMethod method;
  final TargetPlatform platform;

  const DeviceAuthenticationInfo({
    required this.supported,
    required this.method,
    required this.platform,
  });

  static Future<DeviceAuthenticationInfo> read(LocalAuthentication auth) async {
    final supported = await auth.isDeviceSupported();
    var biometrics = <BiometricType>[];
    if (supported) {
      try {
        biometrics = await auth.getAvailableBiometrics();
      } catch (_) {
        // An unavailable capability query must not invent a biometric type or
        // prevent the system from offering an existing device credential.
      }
    }
    final method = biometrics.contains(BiometricType.face)
        ? DeviceUnlockMethod.face
        : biometrics.contains(BiometricType.fingerprint)
        ? DeviceUnlockMethod.fingerprint
        : biometrics.contains(BiometricType.iris)
        ? DeviceUnlockMethod.iris
        : biometrics.isNotEmpty
        ? DeviceUnlockMethod.biometric
        : DeviceUnlockMethod.deviceLock;
    return DeviceAuthenticationInfo(
      supported: supported,
      method: method,
      platform: defaultTargetPlatform,
    );
  }

  String get label => switch (method) {
    DeviceUnlockMethod.face =>
      platform == TargetPlatform.iOS ? 'Face ID' : 'face unlock',
    DeviceUnlockMethod.fingerprint =>
      platform == TargetPlatform.iOS || platform == TargetPlatform.macOS
          ? 'Touch ID'
          : 'fingerprint',
    DeviceUnlockMethod.iris => 'iris recognition',
    DeviceUnlockMethod.biometric => 'biometrics',
    DeviceUnlockMethod.deviceLock => 'device lock',
  };

  IconData get icon => switch (method) {
    DeviceUnlockMethod.face => Icons.face_rounded,
    DeviceUnlockMethod.fingerprint => Icons.fingerprint_rounded,
    DeviceUnlockMethod.iris => Icons.visibility_rounded,
    DeviceUnlockMethod.biometric => Icons.verified_user_rounded,
    DeviceUnlockMethod.deviceLock => Icons.lock_outline_rounded,
  };

  String get enableLabel => 'Enable $label';
  String get unlockReason => 'Use $label to unlock PandaPay';
  String get setupReason => 'Use $label to protect PandaPay';
  String get setupDescription => method == DeviceUnlockMethod.deviceLock
      ? 'Use your device ${platform == TargetPlatform.iOS ? 'passcode' : 'screen lock'} to unlock PandaPay.'
      : 'Use $label to unlock PandaPay. Your biometric data stays on your device.';
}

final deviceAuthenticationProvider =
    FutureProvider.autoDispose<DeviceAuthenticationInfo>(
      (ref) => DeviceAuthenticationInfo.read(LocalAuthentication()),
    );
