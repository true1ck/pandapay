import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _deviceInfoChannel = MethodChannel('app.pandapay/device_info');

/// Metadata attached to the session record on OTP verification. The device ID
/// remains the stable per-install identifier; this is only display context.
Future<Map<String, Object?>> loadDeviceMetadata() async {
  final platform = Platform.isAndroid
      ? 'android'
      : Platform.isIOS
      ? 'ios'
      : Platform.operatingSystem;

  String? model;
  String? osVersion;
  if (Platform.isAndroid) {
    try {
      final nativeInfo = await _deviceInfoChannel.invokeMapMethod<String, Object?>(
        'getDeviceInfo',
      );
      model = nativeInfo?['model'] as String?;
      osVersion = nativeInfo?['os_version'] as String?;
    } on PlatformException {
      // Keep sign-in available if native metadata is unavailable.
    } on MissingPluginException {
      // Older app builds can still sign in; the server will store platform.
    }
  } else if (Platform.isIOS) {
    model = 'iOS device';
    osVersion = Platform.operatingSystemVersion;
  }

  String? appVersion;
  try {
    appVersion = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    // App version is optional display metadata, not an authentication input.
  }

  return {
    'platform': platform,
    if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
    if (osVersion != null && osVersion.trim().isNotEmpty)
      'os_version': osVersion.trim(),
    if (appVersion != null && appVersion.trim().isNotEmpty)
      'app_version': appVersion.trim(),
  };
}
