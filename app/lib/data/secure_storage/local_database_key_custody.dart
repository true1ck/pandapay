import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'local_key_provisioning_lease.dart';

/// Minimal boundary implemented by the platform secure-storage adapter.
/// Values must be protected by Keychain/Keystore backed storage.
abstract interface class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<bool> writeIfAbsent(String key, String value);
  Future<void> delete(String key);
}

/// Adapter signal for a temporarily unavailable or locked secure store.
final class SecureKeyStoreUnavailable implements Exception {
  const SecureKeyStoreUnavailable();
}

enum LocalKeyStatus {
  provisioned,
  existing,
  absentBeforeConversion,
  missingForEncryptedStore,
  bindingMismatch,
  corruptMetadata,
  busy,
  unavailable,
}

/// An owned database-key handle. Access is callback scoped at the API boundary.
/// Buffers are cleared on callback return/disposal on a best-effort basis;
/// Dart/runtime copies cannot be guaranteed to be zeroized.
final class LocalDatabaseKeyHandle {
  final Uint8List _material;
  final int version;
  bool _disposed = false;

  LocalDatabaseKeyHandle._(List<int> material, this.version)
    : _material = Uint8List.fromList(material);

  T withKeyBytes<T>(T Function(List<int> bytes) use) {
    if (_disposed) throw StateError('Database key handle is disposed');
    final copy = Uint8List.fromList(_material);
    try {
      return use(copy);
    } finally {
      copy.fillRange(0, copy.length, 0);
    }
  }

  void dispose() {
    _material.fillRange(0, _material.length, 0);
    _disposed = true;
  }

  @override
  String toString() => 'LocalDatabaseKeyHandle(version: $version, [REDACTED])';
}

final class LocalKeyResult {
  final LocalKeyStatus status;
  final LocalDatabaseKeyHandle? handle;
  const LocalKeyResult(this.status, [this.handle]);
}

/// Stores per-install DB keys as versioned secure-storage slots. The install
/// identifier is an app-generated stable random ID, not a hardware identifier.
/// Metadata is authenticated with the active key and bound only to the
/// app-generated install ID. The key is per-install because one local DB
/// contains guest and multiple account namespaces; account, JWT, phone, and
/// namespace changes never rotate or derive this key. A marked-encrypted
/// database is never repaired by key reset.
final class LocalDatabaseKeyCustody {
  static const _metaKey = 'pandapay.localdb.key_metadata.v1';
  static const _slotPrefix = 'pandapay.localdb.key.v1.';
  final SecureKeyValueStore storage;
  final Random _random;
  final LocalKeyProvisioningLease lease;

  LocalDatabaseKeyCustody(
    this.storage, {
    Random? random,
    LocalKeyProvisioningLease? lease,
  }) : _random = random ?? Random.secure(),
       lease = lease ?? SqliteLocalKeyProvisioningLease.applicationSupport();

  Future<LocalKeyResult> openKey({
    required String installId,
    required bool encryptedManifestExists,
  }) async {
    try {
      return await lease.runExclusive(
        () => _openKeyLocked(
          installId: installId,
          encryptedManifestExists: encryptedManifestExists,
        ),
      );
    } on LocalKeyProvisioningLeaseUnavailable {
      return const LocalKeyResult(LocalKeyStatus.unavailable);
    } on LocalKeyProvisioningLeaseBusy {
      return const LocalKeyResult(LocalKeyStatus.busy);
    }
  }

  Future<LocalKeyResult> _openKeyLocked({
    required String installId,
    required bool encryptedManifestExists,
  }) async {
    if (installId.isEmpty || installId.length > 256) {
      return const LocalKeyResult(LocalKeyStatus.bindingMismatch);
    }
    String? encoded;
    try {
      encoded = await storage.read(_metaKey);
    } on SecureKeyStoreUnavailable {
      return const LocalKeyResult(LocalKeyStatus.unavailable);
    }
    if (encoded == null) {
      if (encryptedManifestExists) {
        return const LocalKeyResult(LocalKeyStatus.missingForEncryptedStore);
      }
      // A crash may have persisted the key slot but not its authenticated
      // metadata. Preserve that random key and complete the interrupted write.
      String? orphan;
      try {
        orphan = await storage.read('$_slotPrefix${1}');
      } on SecureKeyStoreUnavailable {
        return const LocalKeyResult(LocalKeyStatus.unavailable);
      }
      if (orphan != null) {
        try {
          if (orphan.length != 44) {
            return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
          }
          final key = base64Decode(orphan);
          if (key.length != 32) {
            return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
          }
          final metadataWon = await storage.writeIfAbsent(
            _metaKey,
            _encodeMetadata(key, 1, installId),
          );
          if (!metadataWon) {
            return _openKeyLocked(
              installId: installId,
              encryptedManifestExists: false,
            );
          }
          return LocalKeyResult(
            LocalKeyStatus.existing,
            LocalDatabaseKeyHandle._(key, 1),
          );
        } on SecureKeyStoreUnavailable {
          return const LocalKeyResult(LocalKeyStatus.unavailable);
        } on Object {
          return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
        }
      }
      return _provision(installId);
    }
    try {
      if (encoded.length > 1024) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> ||
          decoded.length != 5 ||
          decoded.keys.any(
            (key) => !const {
              'format',
              'active_version',
              'previous_version',
              'install',
              'mac',
            }.contains(key),
          )) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      final meta = decoded;
      if (meta['format'] != 1 || meta['previous_version'] != null) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      final version = meta['active_version'];
      final install = meta['install'];
      if (version is! int ||
          version != 1 ||
          install is! String ||
          install.length > 256 ||
          meta['mac'] is! String ||
          (meta['mac'] as String).length != 64) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      if (install != installId) {
        return const LocalKeyResult(LocalKeyStatus.bindingMismatch);
      }
      final value = await storage.read('$_slotPrefix$version');
      if (value == null) {
        return const LocalKeyResult(LocalKeyStatus.missingForEncryptedStore);
      }
      if (value.length != 44) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      final key = base64Decode(value);
      if (key.length != 32) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      final expected = _mac(key, version, install);
      if (meta['mac'] != expected) {
        return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      }
      return LocalKeyResult(
        LocalKeyStatus.existing,
        LocalDatabaseKeyHandle._(key, version),
      );
    } on SecureKeyStoreUnavailable {
      return const LocalKeyResult(LocalKeyStatus.unavailable);
    } on Object {
      return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
    }
  }

  Future<LocalKeyResult> _provision(String install) async {
    final key = List<int>.generate(32, (_) => _random.nextInt(256));
    const version = 1;
    final slot = '$_slotPrefix$version';
    final bool slotWon;
    try {
      slotWon = await storage.writeIfAbsent(slot, base64Encode(key));
      if (!slotWon) return const LocalKeyResult(LocalKeyStatus.corruptMetadata);
      final metadataWon = await storage.writeIfAbsent(
        _metaKey,
        _encodeMetadata(key, version, install),
      );
      if (!metadataWon) {
        return await _openKeyLocked(
          installId: install,
          encryptedManifestExists: false,
        );
      }
    } on SecureKeyStoreUnavailable {
      return const LocalKeyResult(LocalKeyStatus.unavailable);
    }
    return LocalKeyResult(
      LocalKeyStatus.provisioned,
      LocalDatabaseKeyHandle._(key, version),
    );
  }

  String _encodeMetadata(List<int> key, int version, String install) =>
      jsonEncode({
        'format': 1,
        'active_version': version,
        'previous_version': null,
        'install': install,
        'mac': _mac(key, version, install),
      });

  String _mac(List<int> key, int version, String install) => Hmac(
    sha256,
    key,
  ).convert(utf8.encode('pandapay-localdb-key\n$version\n$install')).toString();
}
