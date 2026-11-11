import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/data/device_identity.dart';
import 'package:pandapay/data/secure_storage/secure_storage_options.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The account device id is what the server counts accounts per phone with, so
/// it has to be the same after the app is deleted and installed again, and
/// different only after the phone itself is reset.
const _channel = MethodChannel('app.pandapay/device_info');

void _androidIdIs(Object? Function() answer) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
        if (call.method != 'getHardwareId') throw MissingPluginException();
        final value = answer();
        if (value is Exception) throw value;
        return value;
      });
}

String _hashOf(String raw) =>
    'a2-${sha256.convert(utf8.encode('pandapay-device-v1:$raw')).toString().substring(0, 32)}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const keychain = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: DeviceIdentity.keychainService,
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await keychain.deleteAll();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('iOS', () {
    test('keeps the same id after the app is deleted and installed again', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final first = await DeviceIdentity().accountDeviceId();
      expect(first, startsWith('k2-'));

      // A reinstall empties NSUserDefaults (SharedPreferences) but not the Keychain.
      SharedPreferences.setMockInitialValues({});
      final second = await DeviceIdentity().accountDeviceId();
      expect(second, first);
    });

    test('carries today\'s per-install id into the Keychain, so the phone is not counted as new twice', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final existing = await DeviceIdentity().localDeviceId();
      final id = await DeviceIdentity().accountDeviceId();
      expect(id, 'k2-$existing');
    });

    test('does not touch the per-install id that unlocks the local database', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final before = await DeviceIdentity().localDeviceId();
      await DeviceIdentity().accountDeviceId();
      SharedPreferences.setMockInitialValues({});
      // A reinstall still gives a fresh per-install id; only the account id lasts.
      expect(await DeviceIdentity().localDeviceId(), isNot(before));
    });

    test('is stored where the app\'s fresh-install wipe cannot reach it', () {
      // InstallGuard clears the plugin's default service and the app's default
      // service; the device id must live under neither.
      expect(DeviceIdentity.keychainService, isNot('flutter_secure_storage_service'));
      expect(
        pandaPayIosStorageOptions.toMap()['accountName'],
        isNot(DeviceIdentity.keychainService),
      );
    });
  });

  group('Android', () {
    test('is derived from the phone\'s Android ID, so a reinstall gives the same id', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _androidIdIs(() => 'a1b2c3d4e5f60718');
      final first = await DeviceIdentity().accountDeviceId();
      expect(first, _hashOf('a1b2c3d4e5f60718'));

      SharedPreferences.setMockInitialValues({}); // app data wiped
      expect(await DeviceIdentity().accountDeviceId(), first);
    });

    test('never sends the raw Android ID', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _androidIdIs(() => 'a1b2c3d4e5f60718');
      expect(await DeviceIdentity().accountDeviceId(), isNot(contains('a1b2c3d4e5f60718')));
    });

    test('two different phones give two different ids', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _androidIdIs(() => '1111111111111111');
      final one = await DeviceIdentity().accountDeviceId();
      _androidIdIs(() => '2222222222222222');
      final two = await DeviceIdentity().accountDeviceId();
      expect(one, isNot(two));
    });

    for (final unusable in <Object?>[
      null,
      '',
      '   ',
      '9774d56d682e549c', // the value an old Android bug gave to many phones at once
      PlatformException(code: 'unavailable'),
    ]) {
      test('falls back to the per-install id when the Android ID is $unusable', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        _androidIdIs(() => unusable);
        final fallback = await DeviceIdentity().localDeviceId();
        final id = await DeviceIdentity().accountDeviceId();
        expect(id, fallback);
        expect(id, isNot(startsWith('a2-')));
      });
    }

    test('falls back when the app has no native side for it (older build, test harness)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final id = await DeviceIdentity().accountDeviceId();
      expect(id, await DeviceIdentity().localDeviceId());
    });
  });

  test('other platforms use the per-install id', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(await DeviceIdentity().accountDeviceId(), await DeviceIdentity().localDeviceId());
  });

  test('the id is accepted by the server\'s device id pattern', () async {
    final pattern = RegExp(r'^[A-Za-z0-9:_-]{4,128}$');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(pattern.hasMatch(await DeviceIdentity().accountDeviceId()), isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    _androidIdIs(() => 'a1b2c3d4e5f60718');
    expect(pattern.hasMatch(await DeviceIdentity().accountDeviceId()), isTrue);
  });
}
