import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'local_database_key_custody.dart';
import 'local_key_provisioning_lease.dart';

/// Cipher boundary for durable statement-import batches. Implementations must
/// store only the returned ciphertext in SQLite and preserve rows on errors.
abstract interface class StatementImportBatchCipher {
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  });

  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  });
}

enum StatementImportCipherErrorCode {
  invalidInput,
  plaintextTooLarge,
  malformedCiphertext,
  authenticationFailed,
  keyUnavailable,
  keyMissing,
  keyCorrupt,
  keyBindingMismatch,
  keyStoreBusy,
}

/// Safe, non-payload-bearing error surface for import ciphertext operations.
final class StatementImportCipherException implements Exception {
  final StatementImportCipherErrorCode code;
  const StatementImportCipherException(this.code);

  @override
  String toString() => 'StatementImportCipherException(${code.name})';
}

/// AES-256-GCM codec with account/import/session/row-bound AAD.
///
/// Binary format: `PPIM` magic, version byte, 12-byte nonce, ciphertext, and
/// 16-byte authentication tag. The 33-byte envelope overhead makes the
/// maximum encoded payload 65,569 bytes for a 65,536-byte JSON plaintext.
final class SecureStatementImportBatchCipher
    implements StatementImportBatchCipher {
  static const int formatVersion = 1;
  static const int maxPlaintextBytes = 64 * 1024;
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int headerLength = 17;
  static const int envelopeOverhead = headerLength + tagLength;
  static const int maxCiphertextBytes = maxPlaintextBytes + envelopeOverhead;
  static const List<int> _magic = [0x50, 0x50, 0x49, 0x4d]; // PPIM
  static const String _markerValue = 'statement-import-batches-v1';

  final SecureKeyValueStore _storage;
  final String _installId;
  final Future<bool> Function(String namespace) encryptedBatchesExist;
  final LocalKeyProvisioningLease _lease;
  final Random _random;
  final AesGcm _cipher = AesGcm.with256bits();

  SecureStatementImportBatchCipher({
    required SecureKeyValueStore secureStore,
    required String installId,
    required this.encryptedBatchesExist,
    LocalKeyProvisioningLease? lease,
    Random? random,
  }) : _storage = secureStore,
       _installId = installId,
       _lease = lease ?? SqliteLocalKeyProvisioningLease.applicationSupport(),
       _random = random ?? Random.secure() {
    if (installId.isEmpty || installId.length > 256) {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.invalidInput,
      );
    }
  }

  @override
  Future<Uint8List> encrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List plaintext,
  }) async {
    final aad = _aad(namespace, sessionId, ordinal, importKey);
    _validateJson(plaintext);
    final key = await _openKey(namespace, allowProvision: true);
    final nonce = List<int>.generate(nonceLength, (_) => _random.nextInt(256));
    try {
      final box = await key.withSecretKey(
        (secret) => _cipher.encrypt(
          plaintext,
          secretKey: secret,
          nonce: nonce,
          aad: aad,
        ),
      );
      final result = Uint8List(maxCiphertextBytes);
      result.setRange(0, _magic.length, _magic);
      result[4] = formatVersion;
      result.setRange(5, headerLength, nonce);
      final cipherEnd = headerLength + box.cipherText.length;
      result.setRange(headerLength, cipherEnd, box.cipherText);
      result.setRange(cipherEnd, cipherEnd + tagLength, box.mac.bytes);
      return Uint8List.sublistView(result, 0, cipherEnd + tagLength);
    } finally {
      key.dispose();
    }
  }

  @override
  Future<Uint8List> decrypt({
    required String namespace,
    required String sessionId,
    required int ordinal,
    required String importKey,
    required Uint8List ciphertext,
  }) async {
    final aad = _aad(namespace, sessionId, ordinal, importKey);
    if (ciphertext.length < envelopeOverhead ||
        ciphertext.length > maxCiphertextBytes ||
        !_hasValidHeader(ciphertext)) {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.malformedCiphertext,
      );
    }
    // Decryption never provisions. Missing secure-store state must preserve
    // the ciphertext for repair/recovery rather than replacing its key.
    final key = await _openKey(namespace, allowProvision: false);
    final nonce = ciphertext.sublist(5, headerLength);
    final tagOffset = ciphertext.length - tagLength;
    final box = SecretBox(
      ciphertext.sublist(headerLength, tagOffset),
      nonce: nonce,
      mac: Mac(ciphertext.sublist(tagOffset)),
    );
    try {
      final cleartext = await key.withSecretKey(
        (secret) => _cipher.decrypt(box, secretKey: secret, aad: aad),
      );
      final result = Uint8List.fromList(cleartext);
      try {
        _validateJson(result);
        return result;
      } on StatementImportCipherException {
        result.fillRange(0, result.length, 0);
        throw const StatementImportCipherException(
          StatementImportCipherErrorCode.authenticationFailed,
        );
      }
    } on SecretBoxAuthenticationError {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.authenticationFailed,
      );
    } finally {
      key.dispose();
    }
  }

  Future<StatementImportKeyHandle> _openKey(
    String namespace, {
    required bool allowProvision,
  }) async {
    _validateNamespace(namespace);
    final prefix = _keyPrefix(namespace);
    final scopedStore = _StatementImportNamespaceStore(_storage, prefix);
    try {
      return await _lease.runExclusive(() async {
        // Keep the ciphertext inventory check in the same cross-isolate
        // provisioning lease as key lookup/provisioning. This closes the race
        // where another queue writer could persist ciphertext after the check
        // but before a replacement key is created.
        final marker = await scopedStore.read(_markerName);
        if (marker != null && marker != _markerValue) {
          throw const StatementImportCipherException(
            StatementImportCipherErrorCode.keyCorrupt,
          );
        }
        final markerExists = marker == _markerValue;
        final encryptedDataExists = await encryptedBatchesExist(namespace);
        final result =
            await LocalDatabaseKeyCustody(
              scopedStore,
              lease: const _AlreadyExclusiveLease(),
            ).openKey(
              installId: _bindingInstallId(namespace),
              encryptedManifestExists:
                  !allowProvision || markerExists || encryptedDataExists,
            );
        if (result.handle == null) throw _mapKeyStatus(result.status);
        final handle = StatementImportKeyHandle._(result.handle!);
        try {
          if (allowProvision && !markerExists) {
            final won = await scopedStore.writeIfAbsent(
              _markerName,
              _markerValue,
            );
            if (!won && await scopedStore.read(_markerName) != _markerValue) {
              throw const StatementImportCipherException(
                StatementImportCipherErrorCode.keyCorrupt,
              );
            }
          }
        } on Object {
          handle.dispose();
          rethrow;
        }
        return handle;
      });
    } on SecureKeyStoreUnavailable {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.keyUnavailable,
      );
    } on LocalKeyProvisioningLeaseUnavailable {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.keyUnavailable,
      );
    } on LocalKeyProvisioningLeaseBusy {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.keyStoreBusy,
      );
    } on StatementImportCipherException {
      rethrow;
    } on Object {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.keyUnavailable,
      );
    }
  }

  StatementImportCipherException _mapKeyStatus(LocalKeyStatus status) =>
      switch (status) {
        LocalKeyStatus.missingForEncryptedStore =>
          const StatementImportCipherException(
            StatementImportCipherErrorCode.keyMissing,
          ),
        LocalKeyStatus.bindingMismatch => const StatementImportCipherException(
          StatementImportCipherErrorCode.keyBindingMismatch,
        ),
        LocalKeyStatus.corruptMetadata => const StatementImportCipherException(
          StatementImportCipherErrorCode.keyCorrupt,
        ),
        LocalKeyStatus.busy => const StatementImportCipherException(
          StatementImportCipherErrorCode.keyStoreBusy,
        ),
        LocalKeyStatus.unavailable => const StatementImportCipherException(
          StatementImportCipherErrorCode.keyUnavailable,
        ),
        LocalKeyStatus.provisioned ||
        LocalKeyStatus.existing ||
        LocalKeyStatus.absentBeforeConversion =>
          const StatementImportCipherException(
            StatementImportCipherErrorCode.keyCorrupt,
          ),
      };

  List<int> _aad(
    String namespace,
    String sessionId,
    int ordinal,
    String importKey,
  ) {
    _validateNamespace(namespace);
    if (!_isUuid(sessionId) ||
        ordinal < 0 ||
        ordinal > 0x7fffffff ||
        importKey.isEmpty ||
        utf8.encode(importKey).length > 256) {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.invalidInput,
      );
    }
    final namespaceBytes = utf8.encode(namespace);
    final sessionBytes = utf8.encode(sessionId.toLowerCase());
    final importDigest = sha256.convert(utf8.encode(importKey)).bytes;
    final output = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(formatVersion)
      ..addByte(namespaceBytes.length)
      ..add(namespaceBytes)
      ..addByte(sessionBytes.length)
      ..add(sessionBytes);
    final ordinalBytes = ByteData(4)..setUint32(0, ordinal, Endian.big);
    output.add(ordinalBytes.buffer.asUint8List());
    output.add(importDigest);
    return output.takeBytes();
  }

  static void _validateJson(Uint8List plaintext) {
    if (plaintext.isEmpty || plaintext.length > maxPlaintextBytes) {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.plaintextTooLarge,
      );
    }
    try {
      jsonDecode(utf8.decode(plaintext, allowMalformed: false));
    } on Object {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.invalidInput,
      );
    }
  }

  static bool _hasValidHeader(Uint8List value) {
    for (var index = 0; index < _magic.length; index++) {
      if (value[index] != _magic[index]) return false;
    }
    return value[4] == formatVersion;
  }

  static bool _isUuid(String value) => RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  ).hasMatch(value);

  static void _validateNamespace(String value) {
    if (!RegExp(
      r'^user:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value)) {
      throw const StatementImportCipherException(
        StatementImportCipherErrorCode.invalidInput,
      );
    }
  }

  static String _keyPrefix(String namespace) =>
      'pandapay.statement-import-key.v1.${sha256.convert(utf8.encode('pandapay-statement-import-namespace-v1\n$namespace'))}.';

  String _bindingInstallId(String namespace) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            'pandapay-statement-import-binding-v1',
            _installId,
            namespace,
          ]),
        ),
      )
      .toString();

  static const String _markerName = 'encrypted_batches_v1';
}

/// Callback-scoped import key handle backed by independent per-account secure
/// storage. Key bytes never enter this class's public representation.
final class StatementImportKeyHandle {
  final LocalDatabaseKeyHandle _handle;
  StatementImportKeyHandle._(this._handle);

  Future<T> withSecretKey<T>(Future<T> Function(SecretKey) operation) async {
    final key = _handle.withKeyBytes(
      (bytes) => SecretKeyData(
        Uint8List.fromList(bytes),
        overwriteWhenDestroyed: true,
      ),
    );
    try {
      return await operation(key);
    } finally {
      key.destroy();
    }
  }

  void dispose() => _handle.dispose();

  @override
  String toString() =>
      'StatementImportKeyHandle(version: ${_handle.version}, redacted)';
}

final class _StatementImportNamespaceStore implements SecureKeyValueStore {
  final SecureKeyValueStore _delegate;
  final String _prefix;
  const _StatementImportNamespaceStore(this._delegate, this._prefix);

  @override
  Future<String?> read(String key) => _delegate.read('$_prefix$key');
  @override
  Future<void> write(String key, String value) =>
      _delegate.write('$_prefix$key', value);
  @override
  Future<bool> writeIfAbsent(String key, String value) =>
      _delegate.writeIfAbsent('$_prefix$key', value);
  @override
  Future<void> delete(String key) => _delegate.delete('$_prefix$key');
}

/// The outer cipher lease already covers inventory, key custody, and marker
/// writes; prevent LocalDatabaseKeyCustody from acquiring it a second time.
final class _AlreadyExclusiveLease implements LocalKeyProvisioningLease {
  const _AlreadyExclusiveLease();

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) => operation();
}
