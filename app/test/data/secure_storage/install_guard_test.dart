import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pandapay/data/secure_storage/install_guard.dart';
import 'package:pandapay/data/secure_storage/secure_storage_options.dart';

void main() {
  test('first launch clears secure storage once and sets the marker', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var clears = 0;
    final guard = InstallGuard(
      prefs: prefs,
      clearSecureStorage: () async => clears++,
    );
    expect(await guard.run(), isTrue);
    expect(await guard.run(), isFalse);
    expect(clears, 1);
    expect(prefs.getBool(InstallGuard.markerKey), isTrue);
  });

  test('an existing marker leaves secure storage untouched', () async {
    SharedPreferences.setMockInitialValues({InstallGuard.markerKey: true});
    final prefs = await SharedPreferences.getInstance();
    var clears = 0;
    final guard = InstallGuard(
      prefs: prefs,
      clearSecureStorage: () async => clears++,
    );
    expect(await guard.run(), isFalse);
    expect(clears, 0);
  });

  test(
    'a failed clear does not set the marker, so the next launch retries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var attempts = 0;
      final guard = InstallGuard(
        prefs: prefs,
        clearSecureStorage: () async {
          if (++attempts == 1) throw StateError('keychain busy');
        },
      );
      await expectLater(guard.run(), throwsStateError);
      expect(prefs.getBool(InstallGuard.markerKey), isNull);
      expect(await guard.run(), isTrue);
      expect(attempts, 2);
      expect(prefs.getBool(InstallGuard.markerKey), isTrue);
    },
  );

  test('leftover tokens and keys are gone after the first launch', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final keychain = {
      'pandapay_app.refresh_token': 'old',
      'pandapay.localdb.key_metadata.v1': 'old',
    };
    final guard = InstallGuard(
      prefs: prefs,
      clearSecureStorage: () async => keychain.clear(),
    );
    await guard.run();
    expect(keychain, isEmpty);
  });

  test(
    'clearAllSecureStorage removes items written with either option set',
    () async {
      await const FlutterSecureStorage().write(
        key: 'pandapay_app.access_token',
        value: 'a',
      );
      await pandaPaySecureStorage.write(
        key: 'pandapay.localdb.key.v1.1',
        value: 'b',
      );
      await InstallGuard.clearAllSecureStorage();
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
      expect(await pandaPaySecureStorage.readAll(), isEmpty);
    },
  );
}
