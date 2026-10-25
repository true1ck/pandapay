import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'local_database_key_custody.dart';
import 'local_key_provisioning_lease.dart';

/// Independently random receipt key per account/guest namespace. These slots
/// never reuse the install database key or any OTP/JWT/server key. Namespace
/// hashes select secure-store slots; they are identifiers, not key derivation.
final class LocalReceiptKeyCustody {
  final SecureKeyValueStore storage;
  final LocalKeyProvisioningLease? lease;
  LocalReceiptKeyCustody(this.storage, {this.lease});

  Future<LocalReceiptKeyResult> openKey({
    required String installId,
    required String accountNamespace,
    required bool encryptedReceiptsExist,
  }) async {
    if (installId.isEmpty ||
        installId.length > 256 ||
        !RegExp(
          r'^(user|guest):[A-Za-z0-9_-]{1,128}$',
        ).hasMatch(accountNamespace)) {
      return const LocalReceiptKeyResult(LocalKeyStatus.bindingMismatch);
    }
    final identifier = sha256
        .convert(
          utf8.encode('pandapay-receipt-namespace-v1\n$accountNamespace'),
        )
        .toString();
    final result =
        await LocalDatabaseKeyCustody(
          _ReceiptNamespaceStore(
            storage,
            'pandapay.receipt-key.v1.$identifier.',
          ),
          lease: lease,
        ).openKey(
          installId: sha256
              .convert(
                utf8.encode(
                  jsonEncode([
                    'pandapay-receipt-binding-v1',
                    installId,
                    accountNamespace,
                  ]),
                ),
              )
              .toString(),
          encryptedManifestExists: encryptedReceiptsExist,
        );
    return LocalReceiptKeyResult(
      result.status,
      result.handle == null
          ? null
          : LocalReceiptKeyHandle._(result.handle!, accountNamespace),
    );
  }
}

final class LocalReceiptKeyResult {
  final LocalKeyStatus status;
  final LocalReceiptKeyHandle? handle;
  const LocalReceiptKeyResult(this.status, [this.handle]);
}

/// The callback may await encryption/OCR operations. Its owned key is destroyed
/// on success/failure, and cannot be used afterwards. Runtime/library copies
/// cannot be guaranteed to be zeroized. No key material is logged/formatted.
final class LocalReceiptKeyHandle {
  final LocalDatabaseKeyHandle _key;
  final String accountNamespace;
  LocalReceiptKeyHandle._(this._key, this.accountNamespace);
  int get version => _key.version;
  Future<T> withSecretKey<T>(Future<T> Function(SecretKey) operation) async {
    final secret = _key.withKeyBytes(
      (bytes) => SecretKeyData(
        Uint8List.fromList(bytes),
        overwriteWhenDestroyed: true,
      ),
    );
    try {
      return await operation(secret);
    } finally {
      secret.destroy();
    }
  }

  void dispose() => _key.dispose();
  @override
  String toString() => 'LocalReceiptKeyHandle(version: $version, redacted)';
}

final class _ReceiptNamespaceStore implements SecureKeyValueStore {
  final SecureKeyValueStore delegate;
  final String prefix;
  _ReceiptNamespaceStore(this.delegate, this.prefix);
  @override
  Future<String?> read(String key) => delegate.read('$prefix$key');
  @override
  Future<void> write(String key, String value) =>
      delegate.write('$prefix$key', value);
  @override
  Future<bool> writeIfAbsent(String key, String value) =>
      delegate.writeIfAbsent('$prefix$key', value);
  @override
  Future<void> delete(String key) => delegate.delete('$prefix$key');
}
