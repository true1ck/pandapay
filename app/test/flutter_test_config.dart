import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// `flutter test` runs on the headless `flutter_tester` harness, which never
/// registers real platform plugins — `FlutterSecureStorage`'s default
/// `MethodChannelFlutterSecureStorage` implementation has nothing on the
/// other end of its channel there, so every read/write would hang or throw.
/// Swapping in a plain in-memory `Map`-backed platform implementation here
/// (once, for the whole suite, via this file's `testExecutable`) is the
/// package's own documented way to make it testable — no per-test-file
/// mocking needed for anything that goes through TokenStore.
class _FakeSecureStoragePlatform extends FlutterSecureStoragePlatform {
  final _values = <String, String>{};

  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) async {
    _values[key] = value;
  }

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async => _values[key];

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async =>
      _values.containsKey(key);

  @override
  Future<void> delete({required String key, required Map<String, String> options}) async {
    _values.remove(key);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map.of(_values);

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    _values.clear();
  }

  void clear() => _values.clear();
}

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final fakeSecureStorage = _FakeSecureStoragePlatform();
  FlutterSecureStoragePlatform.instance = fakeSecureStorage;
  // A single fake instance backs the whole test run (one process, every
  // file) — without resetting it, one test's rotated tokens leak into the
  // next test's "fresh SharedPreferences.setMockInitialValues" setup,
  // since TokenStore.load()'s legacy-migration path only reads the old
  // plaintext values when secure storage is still empty. setUp here is
  // global across every test declared in every file, same as this
  // function wrapping every file's main().
  setUp(fakeSecureStorage.clear);
  return AlchemistConfig.runWithConfig(
    config: const AlchemistConfig(),
    run: testMain,
  );
}
