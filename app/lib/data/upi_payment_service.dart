import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'upi_qr_image.dart';

/// Hands a payment to a UPI app the user picked, without sending it a payment link.
///
/// UPI apps decline a payment that another app starts for a shop or a person
/// (an intent, NPCI initiation mode 04; clause 7.9 of NPCI's UPI consolidated
/// circular), while the same QR scanned or shared inside the UPI app goes
/// through. So PandaPay never sends a `upi://pay` link. It lists the UPI apps
/// installed and either shares a QR image into the one the user picked
/// ([shareQr], read like a QR saved in the gallery) or opens it on its home
/// screen ([openApp]) and the user pays there.
///
/// It is deliberately a thin wrapper over a MethodChannel with no third-party
/// UPI plugin: the payment surface of this app has to stay small and
/// auditable.
///
/// iOS cannot list installed apps. [IosUpiPaymentService] asks the system
/// whether each well-known UPI app's own URL scheme is handled (the schemes are
/// declared in Info.plist `LSApplicationQueriesSchemes`), so the same chooser
/// can be shown there. Without it, iOS hands a plain `upi://` link to whichever
/// single app it prefers and the user cannot pick.
@immutable
class UpiApp {
  final String packageName;
  final String name;
  final Uint8List? iconPng;

  /// False for an app that can only be opened on its home screen (no payment
  /// link it is known to accept): the caller copies the UPI ID instead, so the
  /// user can pay to it there.
  final bool prefillsPayment;

  /// A bundled logo, for platforms (iOS) that cannot read another app's icon.
  /// Android supplies the real icon as [iconPng] instead.
  final String? logoAsset;

  const UpiApp({
    required this.packageName,
    required this.name,
    this.iconPng,
    this.prefillsPayment = true,
    this.logoAsset,
  });
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

  /// Opens the UPI app [packageName] with the payment link [uri] (a
  /// `upi://pay` string), so the payee and amount arrive filled in. Returns
  /// false when the app can't take it.
  Future<bool> launchUpiLink({required String packageName, required String uri});

  /// Draws [qrData] (a `upi://pay` string) as a QR image and shares it into the
  /// UPI app [packageName], so that app shows the payee and amount ready to
  /// pay. Returns false when the app can't take a shared image (or there is no
  /// channel on this platform); the caller then falls back to [openApp].
  Future<bool> shareQr({required String packageName, required String qrData});
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
  Future<bool> launchUpiLink({required String packageName, required String uri}) async {
    try {
      return await _channel.invokeMethod<bool>('launchUpiLink', {
            'packageName': packageName,
            'uri': uri,
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> shareQr({required String packageName, required String qrData}) async {
    try {
      return await _channel.invokeMethod<bool>('shareQr', {
            'packageName': packageName,
            'png': renderUpiQrPng(qrData),
          }) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
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

/// A UPI app that iOS can open by its own URL scheme.
@immutable
class IosUpiAppSpec {
  /// Stable id, passed around as [UpiApp.packageName].
  final String id;
  final String name;

  /// URL schemes the app answers to, most current first. Every one must also
  /// be listed in Info.plist `LSApplicationQueriesSchemes`, or `canLaunchUrl`
  /// is always false for it.
  final List<String> schemes;

  /// What follows `scheme://` for a payment link: the query of the `upi://pay`
  /// link is appended to it unchanged. Null when no payment link for the app is
  /// documented anywhere: the app is then only opened (its home screen) and the
  /// UPI ID is copied for the user to pay to.
  final String? path;

  const IosUpiAppSpec({
    required this.id,
    required this.name,
    required this.schemes,
    this.path,
  });

  /// The app's App Store icon, bundled under `assets/upi_apps/`.
  String get logoAsset => 'assets/upi_apps/$id.png';
}

/// The UPI apps offered on iOS, and the card and bank apps the owner pays
/// through. An app that is not installed is not listed.
///
/// Every scheme here is also in Info.plist `LSApplicationQueriesSchemes`, which
/// Apple caps at 25 entries for an app linked against the iOS 27 SDK (50 before).
/// There is room for two more; a new app means dropping a rarely useful one.
/// Each app's icon is its App Store artwork in `assets/upi_apps/<id>.png`, there
/// to identify the app, like the icon Android shows.
///
/// Payment links are documented for Google Pay, PhonePe and Paytm (payment
/// providers' iOS guides). The others have no published link format, so they get
/// no [IosUpiAppSpec.path]: they are opened, and the UPI ID is copied. Schemes
/// come from Razorpay, PayU and Cashfree's iOS integration guides; `tnupi` for
/// Tata Neu appears only in Cashfree's list.
const iosUpiAppSpecs = <IosUpiAppSpec>[
  IosUpiAppSpec(id: 'gpay', name: 'Google Pay', schemes: ['gpay', 'tez'], path: 'upi/pay'),
  IosUpiAppSpec(id: 'phonepe', name: 'PhonePe', schemes: ['phonepe'], path: 'pay'),
  IosUpiAppSpec(id: 'paytm', name: 'Paytm', schemes: ['paytmmp'], path: 'pay'),
  IosUpiAppSpec(id: 'cred', name: 'CRED', schemes: ['credpay'], path: 'upi/pay'),
  IosUpiAppSpec(id: 'bhim', name: 'BHIM', schemes: ['bhim'], path: 'upi/pay'),
  IosUpiAppSpec(id: 'amazonpay', name: 'Amazon Pay', schemes: ['amazonpay']),
  IosUpiAppSpec(id: 'supermoney', name: 'super.money', schemes: ['super']),
  IosUpiAppSpec(id: 'scapia', name: 'Scapia', schemes: ['scapia']),
  IosUpiAppSpec(id: 'tataneu', name: 'Tata Neu', schemes: ['tnupi']),
  IosUpiAppSpec(id: 'kiwi', name: 'Kiwi', schemes: ['kiwi']),
  IosUpiAppSpec(id: 'slice', name: 'slice', schemes: ['slice-upi']),
  IosUpiAppSpec(id: 'jupiter', name: 'Jupiter', schemes: ['jupiter']),
  IosUpiAppSpec(id: 'onecard', name: 'OneCard', schemes: ['omnicard']),
  IosUpiAppSpec(id: 'freecharge', name: 'Freecharge', schemes: ['freecharge']),
  IosUpiAppSpec(id: 'mobikwik', name: 'MobiKwik', schemes: ['mobikwik']),
  IosUpiAppSpec(id: 'navi', name: 'Navi', schemes: ['navi']),
  IosUpiAppSpec(id: 'airtel', name: 'Airtel Thanks', schemes: ['myairtel']),
  IosUpiAppSpec(id: 'payzapp', name: 'PayZapp', schemes: ['payzapp']),
  IosUpiAppSpec(id: 'imobile', name: 'iMobile (ICICI)', schemes: ['imobile']),
  IosUpiAppSpec(id: 'yono', name: 'YONO SBI', schemes: ['sbiyono']),
  IosUpiAppSpec(id: 'myjio', name: 'MyJio', schemes: ['myjio']),
];

/// The "any other UPI app" choice: the plain `upi://pay` link, which iOS gives
/// to the app it prefers. Listed only next to at least one named app, as the
/// way to reach an app that is not in [iosUpiAppSpecs].
const iosOtherUpiAppId = 'upi';

typedef UpiUrlCanLaunch = Future<bool> Function(Uri uri);
typedef UpiUrlLaunch = Future<bool> Function(Uri uri);

class IosUpiPaymentService implements UpiPaymentService {
  IosUpiPaymentService({UpiUrlCanLaunch? canLaunch, UpiUrlLaunch? launch})
    : _canLaunch = canLaunch ?? canLaunchUrl,
      _launch =
          launch ?? ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  final UpiUrlCanLaunch _canLaunch;
  final UpiUrlLaunch _launch;

  Future<bool> _safe(Future<bool> Function() action) async {
    try {
      return await action();
    } on PlatformException {
      return false;
    }
  }

  /// The scheme of [spec] this phone answers to, or null when it is not
  /// installed.
  Future<String?> _installedScheme(IosUpiAppSpec spec) async {
    for (final scheme in spec.schemes) {
      if (await _safe(() => _canLaunch(Uri.parse('$scheme://')))) return scheme;
    }
    return null;
  }

  IosUpiAppSpec? _spec(String id) {
    for (final spec in iosUpiAppSpecs) {
      if (spec.id == id) return spec;
    }
    return null;
  }

  @override
  Future<List<UpiApp>> installedApps() async {
    final apps = <UpiApp>[];
    for (final spec in iosUpiAppSpecs) {
      if (await _installedScheme(spec) != null) {
        apps.add(
          UpiApp(
            packageName: spec.id,
            name: spec.name,
            prefillsPayment: spec.path != null,
            logoAsset: spec.logoAsset,
          ),
        );
      }
    }
    if (apps.isNotEmpty) {
      apps.add(const UpiApp(packageName: iosOtherUpiAppId, name: 'Another UPI app'));
    }
    return apps;
  }

  @override
  Future<bool> launchUpiLink({required String packageName, required String uri}) async {
    if (packageName == iosOtherUpiAppId) {
      return _safe(() => _launch(Uri.parse(uri)));
    }
    final spec = _spec(packageName);
    if (spec == null) return false;
    final scheme = await _installedScheme(spec);
    if (scheme == null) return false;
    final path = spec.path;
    if (path == null) {
      // No payment link this app is known to accept: just open it.
      return _safe(() => _launch(Uri.parse('$scheme://')));
    }
    final query = uri.indexOf('?');
    final link = '$scheme://$path${query < 0 ? '' : uri.substring(query)}';
    return _safe(() => _launch(Uri.parse(link)));
  }

  @override
  Future<bool> openApp(String packageName) async {
    if (packageName == iosOtherUpiAppId) {
      return _safe(() => _launch(Uri.parse('upi://pay')));
    }
    final spec = _spec(packageName);
    if (spec == null) return false;
    final scheme = await _installedScheme(spec);
    if (scheme == null) return false;
    return _safe(() => _launch(Uri.parse('$scheme://')));
  }

  /// iOS cannot hand an image to a chosen app from here.
  @override
  Future<bool> shareQr({required String packageName, required String qrData}) async =>
      false;
}
