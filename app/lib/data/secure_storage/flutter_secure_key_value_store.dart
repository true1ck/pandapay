import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_database_key_custody.dart';

/// Native key-value adapter for local database custody.
///
/// Keychain items are available after the first unlock following reboot and do
/// not migrate to another device. Android storage never resets on a cipher
/// error. A temporarily locked/unavailable platform store maps to an explicit
/// unavailable result in [LocalDatabaseKeyCustody].
final class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  static const _android = AndroidOptions(resetOnError: false);
  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  );

  static Future<void> _tail = Future<void>.value();
  final FlutterSecureStorage _storage;
  final String _prefix;

  FlutterSecureKeyValueStore({
    FlutterSecureStorage? storage,
    String prefix = 'pandapay.localdb.',
  }) : _storage =
           storage ??
           const FlutterSecureStorage(aOptions: _android, iOptions: _ios),
       _prefix = prefix;

  String _key(String key) => '$_prefix$key';

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Never _unavailable(Object error) {
    if (error is PlatformException || error is MissingPluginException) {
      throw const SecureKeyStoreUnavailable();
    }
    Error.throwWithStackTrace(error, StackTrace.current);
  }

  @override
  Future<String?> read(String key) => _serialized(() async {
    try {
      return await _storage.read(
        key: _key(key),
        aOptions: _android,
        iOptions: _ios,
      );
    } on Object catch (error) {
      _unavailable(error);
    }
  });

  @override
  Future<void> write(String key, String value) => _serialized(() async {
    try {
      await _storage.write(
        key: _key(key),
        value: value,
        aOptions: _android,
        iOptions: _ios,
      );
    } on Object catch (error) {
      _unavailable(error);
    }
  });

  /// The plugin exposes no native compare-and-set. Calls are serialized in
  /// this Dart isolate; [LocalDatabaseKeyCustody] holds its independent
  /// cross-isolate SQLite lease across the complete read/provision sequence.
  /// A value already present is never overwritten.
  @override
  Future<bool> writeIfAbsent(String key, String value) => _serialized(() async {
    try {
      final nativeKey = _key(key);
      if (await _storage.read(
            key: nativeKey,
            aOptions: _android,
            iOptions: _ios,
          ) !=
          null) {
        return false;
      }
      await _storage.write(
        key: nativeKey,
        value: value,
        aOptions: _android,
        iOptions: _ios,
      );
      return await _storage.read(
            key: nativeKey,
            aOptions: _android,
            iOptions: _ios,
          ) ==
          value;
    } on Object catch (error) {
      _unavailable(error);
    }
  });

  @override
  Future<void> delete(String key) => _serialized(() async {
    try {
      await _storage.delete(key: _key(key), aOptions: _android, iOptions: _ios);
    } on Object catch (error) {
      _unavailable(error);
    }
  });
}
