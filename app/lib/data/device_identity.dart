import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _localDeviceIdKey = 'local_device_id_v1';

/// Two different identifiers live here, and they must not be mixed up.
///
/// [localDeviceId] is this INSTALL's id. It is made once, kept in
/// SharedPreferences, and a delete-and-reinstall gives a new one. The local
/// database key and the SMS runtime are built from it (a new install starts
/// with a new database), so it must keep behaving exactly like that.
///
/// [accountDeviceId] is this PHONE's id, the one sent to the sign-in server as
/// `device_id`. The server counts the accounts made on one phone with it, to
/// stop one person opening account after account on the same phone for a free
/// trial. It therefore has to be the same after the app is deleted and installed
/// again, and different only after the phone itself is reset.
///
///  * iOS: a random id kept in the Keychain under its own service name. iOS
///    keeps Keychain items after the app is deleted and erases them when the
///    phone is erased; `first_unlock_this_device` keeps it out of backups and
///    iCloud, so it is not copied to another phone. The service name is not
///    the one InstallGuard wipes on a fresh install, on purpose.
///  * Android: the phone's Android ID (Settings.Secure.ANDROID_ID), hashed with
///    a fixed prefix so the raw value never leaves the phone. Android keeps it
///    across uninstall and reinstall of the same app and changes it only on a
///    factory reset. Keystore keys do not survive an uninstall, so a stored
///    random id would not do here.
///
/// Both are client-supplied, so they stop an ordinary person reinstalling to
/// get another trial, not someone who rewrites the app or roots the phone. Play
/// Integrity and App Attest are what would bind it to the hardware.
class DeviceIdentity {
  DeviceIdentity({
    FlutterSecureStorage? keychain,
    MethodChannel? hardwareChannel,
    this._platform,
  }) : _keychain = keychain ?? _defaultKeychain,
       _hardwareChannel = hardwareChannel ?? _defaultHardwareChannel;

  /// Not `flutter_secure_storage_service`, which is what InstallGuard clears.
  static const keychainService = 'app.pandapay.device-identity';
  static const keychainKey = 'account_device_id_v1';

  /// The server treats ids with these prefixes as phone ids; anything else is
  /// an install id from an older build or a fallback.
  static const iosPrefix = 'k2-';
  static const androidPrefix = 'a2-';

  static const _androidHashPrefix = 'pandapay-device-v1:';

  /// Old Android builds gave this one value to many different phones.
  static const _knownBadAndroidId = '9774d56d682e549c';

  static const _defaultKeychain = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: keychainService,
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );
  static const _defaultHardwareChannel = MethodChannel(
    'app.pandapay/device_info',
  );

  final FlutterSecureStorage _keychain;
  final MethodChannel _hardwareChannel;
  final TargetPlatform? _platform;
  Future<String>? _accountId;

  Future<String> localDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_localDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await prefs.setString(_localDeviceIdKey, generated);
    return generated;
  }

  /// The phone's id for the one-phone-many-accounts check. Never throws: if
  /// the Keychain or Android ID cannot be read it falls back to [localDeviceId]
  /// (a weaker id the server does not count as a phone id), so sign-in works.
  Future<String> accountDeviceId() => _accountId ??= _resolveAccountId();

  Future<String> _resolveAccountId() async {
    switch (_platform ?? defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return await _iosId() ?? await localDeviceId();
      case TargetPlatform.android:
        return await _androidId() ?? await localDeviceId();
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return localDeviceId();
    }
  }

  Future<String?> _iosId() async {
    try {
      final stored = await _keychain.read(key: keychainKey);
      if (stored != null && stored.startsWith(iosPrefix)) return stored;
      // First run of a build with this id: carry today's install id into the
      // Keychain, so this phone is not counted as a second new phone.
      final id = '$iosPrefix${await localDeviceId()}';
      try {
        await _keychain.write(key: keychainKey, value: id);
      } on Object {
        // Not saved this time; the same id is made again next launch.
      }
      return id;
    } on Object {
      return null;
    }
  }

  Future<String?> _androidId() async {
    try {
      final raw = (await _hardwareChannel.invokeMethod<String>(
        'getHardwareId',
      ))?.trim();
      if (raw == null || raw.isEmpty || raw.toLowerCase() == _knownBadAndroidId) {
        return null;
      }
      final digest = sha256.convert(utf8.encode('$_androidHashPrefix$raw'));
      return '$androidPrefix${digest.toString().substring(0, 32)}';
    } on Object {
      return null;
    }
  }
}
