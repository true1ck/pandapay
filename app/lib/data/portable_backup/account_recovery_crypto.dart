import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const accountRecoveryMaxBytes = 5 * 1024 * 1024;
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Random high-entropy archive key. It is escrowed under the user's existing
/// verified account by the repository; no user password/recovery-file is used.
class AccountRecoveryArchiveKey {
  final Uint8List _bytes;
  AccountRecoveryArchiveKey.fromBytes(List<int> bytes)
    : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length != 32) {
      throw const FormatException('Invalid recovery key');
    }
  }
  factory AccountRecoveryArchiveKey.generate() {
    final random = Random.secure();
    return AccountRecoveryArchiveKey.fromBytes(
      List.generate(32, (_) => random.nextInt(256)),
    );
  }
  String encodeForEscrow() => base64Encode(_bytes);
  void destroy() => _bytes.fillRange(0, _bytes.length, 0);
  @override
  String toString() => 'AccountRecoveryArchiveKey(redacted)';
}

class AccountRecoveryCipher {
  const AccountRecoveryCipher();
  List<int> _aad(String account, String snapshot) {
    if (!_uuid.hasMatch(account) || !_uuid.hasMatch(snapshot)) {
      throw const FormatException('Invalid recovery identity');
    }
    return utf8.encode(
      'pandapay-account-recovery-v1\u0000${account.toLowerCase()}\u0000${snapshot.toLowerCase()}',
    );
  }

  Future<Uint8List> encrypt(
    List<int> plaintext, {
    required String accountId,
    required String snapshotId,
    required AccountRecoveryArchiveKey key,
  }) async {
    if (plaintext.isEmpty || plaintext.length > accountRecoveryMaxBytes - 45) {
      throw const FormatException('Recovery snapshot exceeds storage limit');
    }
    final aead = Xchacha20.poly1305Aead();
    final box = await aead.encrypt(
      plaintext,
      secretKey: SecretKey(key._bytes),
      aad: _aad(accountId, snapshotId),
    );
    return Uint8List.fromList([
      ...ascii.encode('PDAR1'),
      ...box.nonce,
      ...box.mac.bytes,
      ...box.cipherText,
    ]);
  }

  Future<Uint8List> decrypt(
    List<int> encrypted, {
    required String accountId,
    required String snapshotId,
    required AccountRecoveryArchiveKey key,
  }) async {
    if (encrypted.length < 46 ||
        encrypted.length > accountRecoveryMaxBytes ||
        ascii.decode(encrypted.take(5).toList(), allowInvalid: true) !=
            'PDAR1') {
      throw const FormatException('Invalid recovery envelope');
    }
    final box = SecretBox(
      encrypted.sublist(45),
      nonce: encrypted.sublist(5, 29),
      mac: Mac(encrypted.sublist(29, 45)),
    );
    return Uint8List.fromList(
      await Xchacha20.poly1305Aead().decrypt(
        box,
        secretKey: SecretKey(key._bytes),
        aad: _aad(accountId, snapshotId),
      ),
    );
  }
}

/// The only account-recovery payload currently supported. Scope metadata must
/// match explicit approval before encryption or transport; phone-only pending
/// queues cannot be hidden behind an unchecked includeUnsynced=false toggle.
void validateAccountRecoveryPayload(
  Uint8List bytes, {
  required String accountId,
  required bool includeReceipts,
  required bool includeUnsynced,
}) {
  if (bytes.length > accountRecoveryMaxBytes - 45) {
    throw const FormatException('Recovery snapshot exceeds limit');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map ||
      value['format'] != 'pandapay-account-local-v1' ||
      value['account_id'] != accountId ||
      value['namespace'] != 'user:${accountId.toLowerCase()}' ||
      value['include_receipts'] != includeReceipts ||
      value['include_unsynced'] != includeUnsynced ||
      value['tables'] is! Map ||
      value['receipts'] is! List ||
      !includeUnsynced ||
      (!includeReceipts && (value['receipts'] as List).isNotEmpty)) {
    throw const FormatException('Recovery account or consent scope mismatch');
  }
}
