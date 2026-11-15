import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens a UPI app the user picked, without sending it a payment.
///
/// UPI apps decline a payment that another app starts for a shop or a person
/// (an intent, NPCI initiation mode 04; clause 7.9 of NPCI's UPI consolidated
/// circular), while the same QR or UPI ID used inside the UPI app goes through.
/// So PandaPay never sends a `upi://pay` link. It lists the UPI apps installed,
/// opens the one the user picked on its home screen, and the user pays there.
///
/// It is deliberately a thin wrapper over a MethodChannel with no third-party
/// UPI plugin: the payment surface of this app has to stay small and
/// auditable.
///
/// iOS has no way to open a specific UPI app from here, so there
/// [installedApps] returns `[]` and the caller tells the user to open their
/// own UPI app.
@immutable
class UpiApp {
  final String packageName;
  final String name;
  final Uint8List? iconPng;

  const UpiApp({required this.packageName, required this.name, this.iconPng});
}

abstract class UpiPaymentService {
  /// UPI apps installed on this device, in the OS-reported order. Empty when
  /// the platform can't enumerate them (iOS, or the channel is unavailable
  /// in a test).
  Future<List<UpiApp>> installedApps();

  /// Opens the UPI app [packageName] on its home screen, with no payment link.
  /// Returns false when the app could not be opened (not installed, no
  /// launcher screen, or no channel on this platform).
  Future<bool> openApp(String packageName);
}

class MethodChannelUpiPaymentService implements UpiPaymentService {
  static const MethodChannel _channel = MethodChannel('app.pandapay/upi');

  @override
  Future<List<UpiApp>> installedApps() async {
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('getInstalledUpiApps');
      if (raw == null) return const [];
      return raw
          .map((e) {
            final pkg = e['packageName'] as String?;
            final name = e['name'] as String?;
            if (pkg == null || name == null) return null;
            final icon = e['icon'];
            Uint8List? iconBytes;
            if (icon is Uint8List) {
              iconBytes = icon;
            } else if (icon is String && icon.isNotEmpty) {
              iconBytes = base64Decode(icon);
            }
            return UpiApp(packageName: pkg, name: name, iconPng: iconBytes);
          })
          .whereType<UpiApp>()
          .toList(growable: false);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  @override
  Future<bool> openApp(String packageName) async {
    try {
      return await _channel.invokeMethod<bool>('openApp', {'packageName': packageName}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
