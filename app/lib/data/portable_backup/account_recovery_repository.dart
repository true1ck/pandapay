import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'account_recovery_crypto.dart';

/// Explicit per-operation approval from the recovery screen. Constructing a
/// repository, opening a receipt or regular sync never performs an upload.
class AccountRecoveryConsent {
  final bool includeReceipts;
  final bool includeUnsynced;
  final bool explicitlyApproved;
  const AccountRecoveryConsent({
    required this.includeReceipts,
    required this.includeUnsynced,
    required this.explicitlyApproved,
  });
}

class AccountRecoverySnapshotInfo {
  final String snapshotId;
  final DateTime createdAt;
  final int encryptedBytes;
  final bool includeReceipts;
  final bool includeUnsynced;
  const AccountRecoverySnapshotInfo({
    required this.snapshotId,
    required this.createdAt,
    required this.encryptedBytes,
    required this.includeReceipts,
    required this.includeUnsynced,
  });

  factory AccountRecoverySnapshotInfo.fromJson(Map value) {
    final id = value['snapshot_id'], bytes = value['encrypted_bytes'];
    final created = DateTime.tryParse('${value['created_at']}');
    if (id is! String ||
        !_snapshotUuid.hasMatch(id) ||
        created == null ||
        bytes is! int ||
        bytes < 46 ||
        bytes > accountRecoveryMaxBytes ||
        value['include_receipts'] is! bool ||
        value['include_unsynced'] is! bool) {
      throw const FormatException('Invalid recovery snapshot metadata');
    }
    return AccountRecoverySnapshotInfo(
      snapshotId: id,
      createdAt: created.toUtc(),
      encryptedBytes: bytes,
      includeReceipts: value['include_receipts'] as bool,
      includeUnsynced: value['include_unsynced'] as bool,
    );
  }
}

final _snapshotUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class AccountRecoveryRepository {
  final Uri apiBaseUrl;
  final String accountId;
  final Future<String> Function() accessToken;
  final http.Client client;
  final bool enabled;
  final AccountRecoveryCipher cipher;

  /// Only upload and ciphertext readback use this mode. Escrow key retrieval
  /// always retains the separate recent-OTP endpoint.
  final bool automatic;
  final String? automaticConsentId;
  AccountRecoveryRepository({
    required this.apiBaseUrl,
    required this.accountId,
    required this.accessToken,
    required this.client,
    this.enabled = false,
    this.cipher = const AccountRecoveryCipher(),
    this.automatic = false,
    this.automaticConsentId,
  });

  Uri _uri([String suffix = '']) {
    if (apiBaseUrl.hasQuery ||
        apiBaseUrl.hasFragment ||
        apiBaseUrl.userInfo.isNotEmpty ||
        (apiBaseUrl.scheme != 'https' &&
            !(apiBaseUrl.scheme == 'http' &&
                const {
                  '127.0.0.1',
                  'localhost',
                  '::1',
                }.contains(apiBaseUrl.host)))) {
      throw const FormatException('Invalid account recovery origin');
    }
    return apiBaseUrl.resolve('/account/recovery/snapshots$suffix');
  }

  Uri _automaticUri([String suffix = '']) {
    _uri(); // Reuse strict origin validation.
    return apiBaseUrl.resolve('/account/recovery/automatic$suffix');
  }

  Future<bool?> automaticSettings({
    bool? enable,
    bool includeReceipts = false,
    void Function(String?)? onConsentId,
  }) async {
    _requireEnabled();
    final request =
        http.Request(enable == null ? 'GET' : 'PUT', _automaticUri())
          ..followRedirects = false
          ..headers['Authorization'] = 'Bearer ${await accessToken()}';
    if (enable != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'enabled': enable,
        'include_receipts': includeReceipts,
        'consent_version': 'automatic-account-recovery-v1',
      });
    }
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = await _readBounded(response, 1024);
    if (response.statusCode != 200)
      throw StateError(
        'Automatic recovery settings failed (${response.statusCode})',
      );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value['enabled'] is! bool ||
        value['include_receipts'] is! bool) {
      throw const FormatException('Invalid automatic recovery settings');
    }
    if (enable == null &&
        value['enabled'] == true &&
        (value['consent_id'] is! String ||
            !_snapshotUuid.hasMatch(value['consent_id'] as String))) {
      throw const FormatException(
        'Invalid automatic recovery consent identity',
      );
    }
    onConsentId?.call(value['consent_id'] as String?);
    return value['enabled'] == true ? value['include_receipts'] as bool : null;
  }

  void _requireEnabled() {
    if (!enabled) throw StateError('Account recovery is not enabled');
  }

  /// Metadata only. This never downloads receipt bytes or archive keys.
  Future<List<AccountRecoverySnapshotInfo>> list() async {
    _requireEnabled();
    final request = http.Request('GET', _uri())
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${await accessToken()}';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = await _readBounded(response, 4096);
    if (response.statusCode != 200) {
      throw StateError('Account recovery list failed (${response.statusCode})');
    }
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value['snapshots'] is! List ||
        (value['snapshots'] as List).length > 2) {
      throw const FormatException('Invalid recovery snapshot list');
    }
    final result = <AccountRecoverySnapshotInfo>[];
    for (final item in value['snapshots'] as List) {
      if (item is! Map)
        throw const FormatException('Invalid recovery metadata');
      result.add(AccountRecoverySnapshotInfo.fromJson(item));
    }
    if (result.map((item) => item.snapshotId.toLowerCase()).toSet().length !=
        result.length) {
      throw const FormatException('Duplicate recovery snapshot metadata');
    }
    return List.unmodifiable(result);
  }

  /// Explicitly discards server copies only. It never changes local history.
  Future<int> removeAll({required bool explicitlyApproved}) async {
    _requireEnabled();
    if (!explicitlyApproved)
      throw StateError('Explicit discard approval is required');
    final request = http.Request('DELETE', _uri())
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${await accessToken()}',
        'X-PandaPay-Recovery-Consent': 'discard-recovery-v1',
      });
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = await _readBounded(response, 4096);
    if (response.statusCode != 200)
      throw StateError(
        'Account recovery discard failed (${response.statusCode})',
      );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value['removed'] is! int ||
        value['removed'] < 0 ||
        value['removed'] > 2) {
      throw const FormatException('Invalid recovery discard acknowledgement');
    }
    return value['removed'] as int;
  }

  /// Callers supply a complete, account-isolated archive after a consistent
  /// snapshot. Never relabel the existing drained-outbox portable export as
  /// including unsynced work. Activation still requires full device coverage.
  Future<void> upload({
    required String snapshotId,
    required Uint8List plaintextArchive,
    required AccountRecoveryConsent consent,
  }) async {
    _requireEnabled();
    if (!consent.explicitlyApproved) {
      throw StateError('Explicit account recovery approval is required');
    }
    validateAccountRecoveryPayload(
      plaintextArchive,
      accountId: accountId,
      includeReceipts: consent.includeReceipts,
      includeUnsynced: consent.includeUnsynced,
    );
    final key = AccountRecoveryArchiveKey.generate();
    try {
      final encrypted = await cipher.encrypt(
        plaintextArchive,
        accountId: accountId,
        snapshotId: snapshotId,
        key: key,
      );
      // Verify before any upload; no source data is ever removed by this flow.
      final check = await cipher.decrypt(
        encrypted,
        accountId: accountId,
        snapshotId: snapshotId,
        key: key,
      );
      if (sha256.convert(check).toString() !=
          sha256.convert(plaintextArchive).toString()) {
        throw StateError('Recovery verification failed');
      }
      check.fillRange(0, check.length, 0);
      final metadata = utf8.encode(
        jsonEncode({
          'snapshot_id': snapshotId,
          'archive_key': key.encodeForEscrow(),
          'consent_version': 'account-recovery-v1',
          'include_receipts': consent.includeReceipts,
          'include_unsynced': consent.includeUnsynced,
        }),
      );
      final header = ByteData(4)..setUint32(0, metadata.length);
      final request =
          http.Request('POST', automatic ? _automaticUri('/snapshots') : _uri())
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer ${await accessToken()}',
              'Content-Type':
                  'application/vnd.pandapay.account-recovery+octet-stream',
            })
            ..bodyBytes = Uint8List.fromList([
              ...header.buffer.asUint8List(),
              ...metadata,
              ...encrypted,
            ]);
      if (automatic) {
        if (automaticConsentId == null ||
            !_snapshotUuid.hasMatch(automaticConsentId!))
          throw StateError('Automatic recovery consent is unavailable');
        request.headers['X-PandaPay-Recovery-Consent-Id'] = automaticConsentId!;
      }
      Future<void> verifyStoredCopy() async {
        final recovered = automatic
            ? await _readAutomaticCopy(snapshotId, key)
            : await downloadAndDecrypt(snapshotId);
        try {
          if (sha256.convert(recovered).toString() !=
              sha256.convert(plaintextArchive).toString()) {
            throw StateError('Recovery readback mismatch');
          }
        } finally {
          recovered.fillRange(0, recovered.length, 0);
        }
      }

      http.StreamedResponse response;
      try {
        response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
      } on Object {
        // A lost response may follow a committed upload. Recover the original
        // server-escrowed key and verify the same plaintext before declaring it
        // successful; do not overwrite a prior key or silently retry a write.
        await verifyStoredCopy();
        return;
      }
      final body = await _readBounded(response, 4096);
      if (response.statusCode == 409) {
        // Repeating the same snapshot UUID after process death creates fresh
        // encryption randomness. The retained original is accepted only if
        // account-authenticated recovery proves byte-identical source content.
        await verifyStoredCopy();
        return;
      }
      if (response.statusCode != 201) {
        throw StateError(
          'Account recovery upload failed (${response.statusCode})',
        );
      }
      final result = jsonDecode(utf8.decode(body)) as Map;
      if (result['snapshot_id'] != snapshotId ||
          result['archive_sha256'] != sha256.convert(encrypted).toString()) {
        throw StateError('Recovery acknowledgement mismatch');
      }
      await verifyStoredCopy();
    } finally {
      key.destroy();
    }
  }

  Future<Uint8List> _readAutomaticCopy(
    String snapshotId,
    AccountRecoveryArchiveKey key,
  ) async {
    final request = http.Request('GET', _automaticUri('/snapshots/$snapshotId'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${await accessToken()}';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = await _readBounded(response, 7 * 1024 * 1024 + 4096);
    if (response.statusCode != 200)
      throw StateError(
        'Automatic recovery verification failed (${response.statusCode})',
      );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map ||
        value['account_id'] != accountId ||
        value['snapshot_id'] != snapshotId ||
        value.containsKey('archive_key')) {
      throw const FormatException('Invalid automatic recovery verification');
    }
    final encrypted = base64Decode(value['encrypted_archive'] as String);
    if (sha256.convert(encrypted).toString() != value['archive_sha256'])
      throw StateError('Recovery archive checksum mismatch');
    return cipher.decrypt(
      encrypted,
      accountId: accountId,
      snapshotId: snapshotId,
      key: key,
    );
  }

  /// New-device recovery uses the existing OTP account token to retrieve its
  /// escrowed archive key. The server can recover this encryption; it is not
  /// described as end-to-end encryption against the service operator.
  Future<Uint8List> downloadAndDecrypt(String snapshotId) async {
    _requireEnabled();
    if (!_snapshotUuid.hasMatch(snapshotId)) {
      throw const FormatException('Invalid recovery snapshot identity');
    }
    final request = http.Request('GET', _uri('/$snapshotId'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${await accessToken()}';
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 30));
    final bytes = await _readBounded(response, 7 * 1024 * 1024 + 4096);
    if (response.statusCode != 200) {
      throw StateError(
        'Account recovery download failed (${response.statusCode})',
      );
    }
    final value = jsonDecode(utf8.decode(bytes)) as Map;
    if (value['account_id'] != accountId ||
        value['snapshot_id'] != snapshotId) {
      throw StateError('Recovery account mismatch');
    }
    final encrypted = base64Decode(value['encrypted_archive'] as String);
    if (sha256.convert(encrypted).toString() != value['archive_sha256']) {
      throw StateError('Recovery archive checksum mismatch');
    }
    final key = AccountRecoveryArchiveKey.fromBytes(
      base64Decode(value['archive_key'] as String),
    );
    try {
      return await cipher.decrypt(
        encrypted,
        accountId: accountId,
        snapshotId: snapshotId,
        key: key,
      );
    } finally {
      key.destroy();
    }
  }

  static Future<Uint8List> _readBounded(
    http.StreamedResponse response,
    int limit,
  ) async {
    if ((response.contentLength ?? 0) > limit) {
      throw StateError('Recovery response exceeds limit');
    }
    final output = BytesBuilder();
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (output.length + chunk.length > limit) {
        throw StateError('Recovery response exceeds limit');
      }
      output.add(chunk);
    }
    return output.takeBytes();
  }
}
