import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pandapay/data/token_store.dart';

/// Wraps the suite's in-memory secure storage and "kills the process" (throws)
/// on the first write of [dieOnWriteOf] once armed, so a test can stop
/// `TokenStore.save` between its two token writes. Synthetic tokens only.
class _DyingStorage extends FlutterSecureStoragePlatform {
  _DyingStorage(this.inner);
  final FlutterSecureStoragePlatform inner;
  String? dieOnWriteOf;

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    if (dieOnWriteOf == key) {
      dieOnWriteOf = null;
      throw StateError('process died before writing $key');
    }
    return inner.write(key: key, value: value, options: options);
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) => inner.read(key: key, options: options);

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) => inner.containsKey(key: key, options: options);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) => inner.delete(key: key, options: options);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) => inner.readAll(options: options);

  @override
  Future<void> deleteAll({required Map<String, String> options}) =>
      inner.deleteAll(options: options);
}

const _accessKey = 'pandapay_app.access_token';
const _refreshKey = 'pandapay_app.refresh_token';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FlutterSecureStoragePlatform original;
  late _DyingStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    original = FlutterSecureStoragePlatform.instance;
    storage = _DyingStorage(original);
    FlutterSecureStoragePlatform.instance = storage;
    // Start from an empty keystore.
    await (await TokenStore.load()).clear();
  });

  tearDown(() async {
    FlutterSecureStoragePlatform.instance = original;
    await (await TokenStore.load()).clear();
  });

  test(
    'death between the two writes of a first sign-in still restores the '
    'access token next to the refresh token (L-11)',
    () async {
      final store = await TokenStore.load();
      storage.dieOnWriteOf = _accessKey;

      await expectLater(
        store.save(accessToken: 'access-1', refreshToken: 'refresh-1'),
        throwsStateError,
      );

      // New process: refresh token is there, the access write never landed.
      final restarted = await TokenStore.load();
      expect(restarted.refreshToken, 'refresh-1');
      expect(
        restarted.accessToken,
        'access-1',
        reason: 'without an access token the offline user lands on /welcome',
      );
    },
  );

  test('the recovered access token is promoted and the hint removed', () async {
    final store = await TokenStore.load();
    storage.dieOnWriteOf = _accessKey;
    await expectLater(
      store.save(accessToken: 'access-1', refreshToken: 'refresh-1'),
      throwsStateError,
    );

    await TokenStore.load();
    final values = await storage.readAll(options: const {});
    expect(values[_accessKey], 'access-1');
    expect(
      values.keys.where((k) => k.contains('pending')),
      isEmpty,
      reason: 'no second copy of the token is left behind',
    );
  });

  test('a completed save leaves exactly the two token entries', () async {
    final store = await TokenStore.load();
    await store.save(accessToken: 'access-1', refreshToken: 'refresh-1');

    final values = await storage.readAll(options: const {});
    expect(values[_accessKey], 'access-1');
    expect(values[_refreshKey], 'refresh-1');
    expect(values.keys.where((k) => k.contains('pending')), isEmpty);
  });

  test(
    'death while rotating keeps the old access token next to the new refresh '
    'token, as before',
    () async {
      final store = await TokenStore.load();
      await store.save(accessToken: 'access-1', refreshToken: 'refresh-1');

      storage.dieOnWriteOf = _accessKey;
      await expectLater(
        store.save(accessToken: 'access-2', refreshToken: 'refresh-2'),
        throwsStateError,
      );

      final restarted = await TokenStore.load();
      expect(restarted.refreshToken, 'refresh-2');
      expect(restarted.accessToken, 'access-1');
    },
  );

  test('a leftover hint without a refresh token is discarded, not used', () async {
    final store = await TokenStore.load();
    // Died after writing only the hint (before any token landed).
    storage.dieOnWriteOf = _refreshKey;
    await expectLater(
      store.save(accessToken: 'access-1', refreshToken: 'refresh-1'),
      throwsStateError,
    );

    final restarted = await TokenStore.load();
    expect(restarted.refreshToken, isNull);
    expect(restarted.accessToken, isNull);
    final values = await storage.readAll(options: const {});
    expect(values.keys.where((k) => k.contains('pending')), isEmpty);
  });

  test('clear removes the hint as well (sign-out wipes every copy)', () async {
    final store = await TokenStore.load();
    storage.dieOnWriteOf = _accessKey;
    await expectLater(
      store.save(accessToken: 'access-1', refreshToken: 'refresh-1'),
      throwsStateError,
    );
    // The process lived on (the write failed, not the app): sign out now.
    await store.clear();

    final values = await storage.readAll(options: const {});
    expect(values.keys.where((k) => k.startsWith('pandapay_app.')), isEmpty);
  });
}
