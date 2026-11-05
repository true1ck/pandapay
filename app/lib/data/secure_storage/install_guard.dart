import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage_options.dart';

/// iOS keeps Keychain items after the app is deleted; SharedPreferences
/// (NSUserDefaults) do not survive. A missing marker therefore means a fresh
/// install, so remove every leftover token and key before anything reads them.
///
/// Run it before the first read of secure storage in every entry point that
/// can start the app: `main` before `TokenStore.load()` and the iOS background
/// SMS engine before it opens the database. Without the marker the database
/// file does not exist either (it lives in the app container), so no data is
/// lost by clearing.
class InstallGuard {
  InstallGuard({required this.prefs, required this.clearSecureStorage});

  static const markerKey = 'pandapay.install_marker.v1';
  final SharedPreferences prefs;
  final Future<void> Function() clearSecureStorage;

  /// True when this was the first launch of a fresh install and storage was
  /// cleared. The marker is written only after the clear succeeds, so an
  /// interrupted first launch repeats the clear.
  Future<bool> run() async {
    if (prefs.getBool(markerKey) == true) return false;
    await clearSecureStorage();
    await prefs.setBool(markerKey, true);
    return true;
  }

  static Future<void>? _once;

  /// Runs the default guard once per isolate; every caller awaits the same
  /// run. Does nothing under `flutter test`, which uses fake storage.
  /// A failed run is not cached, so the next caller retries.
  static Future<void> ensure() {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return Future.value();
    return _once ??= runDefault().then<void>((_) {}).catchError((Object error) {
      _once = null;
      throw error;
    });
  }

  /// The default guard for production entry points.
  static Future<bool> runDefault() async => InstallGuard(
    prefs: await SharedPreferences.getInstance(),
    clearSecureStorage: clearAllSecureStorage,
  ).run();

  /// Both option sets, because an iOS delete query includes the accessibility
  /// class: items written with the plugin defaults by an older build are not
  /// matched by a delete that uses only the new options.
  static Future<void> clearAllSecureStorage() async {
    await const FlutterSecureStorage().deleteAll();
    await pandaPaySecureStorage.deleteAll();
  }
}
