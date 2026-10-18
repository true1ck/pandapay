import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/data/token_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rotation request survives restart and changes only with the credential',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await TokenStore.load();
      await store.save(accessToken: 'access', refreshToken: 'refresh');
      final first = await store.refreshRequestId('refresh');
      final restarted = await TokenStore.load();
      expect(await restarted.refreshRequestId('refresh'), first);
      await restarted.save(
        accessToken: 'next-access',
        refreshToken: 'next-refresh',
      );
      expect(await restarted.refreshRequestId('next-refresh'), isNot(first));
      await restarted.clear();
      expect(await restarted.refreshRequestId('refresh'), isNot(first));
    },
  );

  test('migrates access and refresh credentials from legacy storage', () async {
    SharedPreferences.setMockInitialValues({
      'pandapay_app.access_token': 'legacy-access',
      'pandapay_app.refresh_token': 'legacy-refresh',
    });

    final store = await TokenStore.load();

    expect(store.accessToken, 'legacy-access');
    expect(store.refreshToken, 'legacy-refresh');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('pandapay_app.access_token'), isFalse);
    expect(prefs.containsKey('pandapay_app.refresh_token'), isFalse);
  });

  test(
    'repairs a partial migration without overwriting secure access',
    () async {
      const secure = FlutterSecureStorage();
      await secure.write(
        key: 'pandapay_app.access_token',
        value: 'secure-access',
      );
      SharedPreferences.setMockInitialValues({
        'pandapay_app.access_token': 'stale-legacy-access',
        'pandapay_app.refresh_token': 'legacy-refresh',
      });

      final store = await TokenStore.load();

      expect(store.accessToken, 'secure-access');
      expect(store.refreshToken, 'legacy-refresh');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('pandapay_app.access_token'), isFalse);
      expect(prefs.containsKey('pandapay_app.refresh_token'), isFalse);
    },
  );
}
