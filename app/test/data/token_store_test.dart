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
      final prefsAfterSave = await SharedPreferences.getInstance();
      expect(prefsAfterSave.getBool(TokenStore.sessionPresenceKey), isTrue);
      final first = await store.refreshRequestId('refresh');
      final restarted = await TokenStore.load();
      expect(await restarted.refreshRequestId('refresh'), first);
      await restarted.save(
        accessToken: 'next-access',
        refreshToken: 'next-refresh',
      );
      expect(await restarted.refreshRequestId('next-refresh'), isNot(first));
      await restarted.clear();
      expect(
        prefsAfterSave.getBool(TokenStore.sessionPresenceKey),
        isFalse,
      );
      expect(await restarted.refreshRequestId('refresh'), isNot(first));
    },
  );

}
