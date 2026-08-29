import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Scan-to-pay, targeted-app handoff (RuPay-on-UPI plan, Phase 1).
///
/// The old flow was `launchUrl('upi://pay?...')` — the OS picked the app and
/// gave no result back. This service instead enumerates the UPI apps
/// actually installed and hands the intent to the *one* the user chose,
/// which on Android also returns a real transaction status
/// ([UpiPaymentStatus]). It is deliberately a thin wrapper over a
/// MethodChannel with no third-party UPI plugin: the payment surface of this
/// app has to stay small and auditable, and the maintained-plugin options
/// for this are all discontinued or unmaintained.
///
/// iOS has no way to target a specific UPI app or read a response, so there
/// [installedApps] returns `[]` and the caller falls back to the plain
/// `upi://` scheme launch.
enum UpiPaymentStatus {
  /// The UPI app reported the payment went through.
  success,

  /// The UPI app reported the payment failed or was declined.
  failure,

  /// The app returned control with no conclusive status — the user may or
  /// may not have paid. This is the honest default and maps to the manual
  /// "I've paid — log this spend" confirmation.
  submitted,

  /// The user backed out of the UPI app without attempting a payment.
  cancelled,

  /// No UPI app is installed / enumerable — caller should fall back.
  noAppsAvailable,
}

@immutable
class UpiApp {
  final String packageName;
  final String name;
  final Uint8List? iconPng;

  const UpiApp({required this.packageName, required this.name, this.iconPng});
}

@immutable
class UpiPaymentResult {
  final UpiPaymentStatus status;

  /// The raw `response` extra string from the UPI app, kept for support /
  /// debugging only — never parsed for anything user-facing beyond [status].
  final String? rawResponse;
  final String? approvalRefNo;

  const UpiPaymentResult({required this.status, this.rawResponse, this.approvalRefNo});

  static const noApps = UpiPaymentResult(status: UpiPaymentStatus.noAppsAvailable);
}

abstract class UpiPaymentService {
  /// UPI apps installed on this device, in the OS-reported order. Empty when
  /// the platform can't enumerate them (iOS, or the channel is unavailable
  /// in a test) — the caller then uses the plain-scheme fallback.
  Future<List<UpiApp>> installedApps();

  /// Hands [upiUri] to the app identified by [packageName] and waits for it
  /// to return. [upiUri] must be the output of `buildUpiPayUri`.
  Future<UpiPaymentResult> pay({required String upiUri, required String packageName});

  /// A fresh merchant/order reference for one payment attempt — `PP` + a
  /// millisecond timestamp + 4 random chars. Passed as `tr` when the QR
  /// itself didn't carry one, and echoed into support logs.
  String newTransactionRef();
}

class MethodChannelUpiPaymentService implements UpiPaymentService {
  static const MethodChannel _channel = MethodChannel('app.pandapay/upi');

  final Random _random;

  MethodChannelUpiPaymentService({Random? random}) : _random = random ?? Random();

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
  Future<UpiPaymentResult> pay({required String upiUri, required String packageName}) async {
    try {
      final res = await _channel.invokeMapMethod<String, Object?>('pay', {
        'uri': upiUri,
        'packageName': packageName,
      });
      final statusRaw = (res?['status'] as String? ?? 'submitted').toLowerCase();
      return UpiPaymentResult(
        status: switch (statusRaw) {
          'success' => UpiPaymentStatus.success,
          'failure' => UpiPaymentStatus.failure,
          'cancelled' => UpiPaymentStatus.cancelled,
          _ => UpiPaymentStatus.submitted,
        },
        rawResponse: res?['response'] as String?,
        approvalRefNo: res?['approvalRefNo'] as String?,
      );
    } on MissingPluginException {
      return const UpiPaymentResult(status: UpiPaymentStatus.noAppsAvailable);
    } on PlatformException {
      // The app was launched but the channel couldn't read a clean result —
      // treat exactly like the old fire-and-forget launch.
      return const UpiPaymentResult(status: UpiPaymentStatus.submitted);
    }
  }

  @override
  String newTransactionRef() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final suffix = List.generate(4, (_) => alphabet[_random.nextInt(alphabet.length)]).join();
    return 'PP${DateTime.now().millisecondsSinceEpoch.toRadixString(36).toUpperCase()}$suffix';
  }
}
