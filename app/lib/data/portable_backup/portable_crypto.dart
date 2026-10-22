import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'canonical_ndjson.dart';
import 'portable_archive.dart';
import 'portable_attachments.dart';

/// v1 KDF parameters. The format contract freezes these; the reader rejects
/// envelopes that disagree, because a different parameter set is a different
/// format with different cost assumptions. Device benchmarking remains a
/// Wave 1 gate task recorded in the implementation status file.
class PortableBackupKdfParams {
  final int memoryKiB;
  final int parallelism;
  final int iterations;
  final int hashLength;

  const PortableBackupKdfParams({
    required this.memoryKiB,
    required this.parallelism,
    required this.iterations,
    required this.hashLength,
  });

  static const PortableBackupKdfParams frozenV1 = PortableBackupKdfParams(
    memoryKiB: 16384,
    parallelism: 1,
    iterations: 2,
    hashLength: 32,
  );

  List<int> encode() => _uint32(memoryKiB) +
      _uint32(parallelism) +
      _uint32(iterations) +
      _uint32(hashLength);

  static PortableBackupKdfParams decode(List<int> bytes) {
    final memoryKiB = _readUint32(bytes, 0);
    final parallelism = _readUint32(bytes, 4);
    final iterations = _readUint32(bytes, 8);
    final hashLength = _readUint32(bytes, 12);
    if (hashLength != 32) {
      throw const PortableBackupEnvelopeException('unsupported hash length');
    }
    if (memoryKiB < 8192 || memoryKiB > 262144) {
      throw const PortableBackupEnvelopeException('kdf memory out of range');
    }
    if (parallelism < 1 || parallelism > 8) {
      throw const PortableBackupEnvelopeException('kdf parallelism out of range');
    }
    if (iterations < 1 || iterations > 8) {
      throw const PortableBackupEnvelopeException('kdf iterations out of range');
    }
    return PortableBackupKdfParams(
      memoryKiB: memoryKiB,
      parallelism: parallelism,
      iterations: iterations,
      hashLength: hashLength,
    );
  }
}

/// Header layout (68 bytes plaintext, no account/card/SMS metadata):
///
/// | offset | size | field                                         |
/// | ------ | ---- | --------------------------------------------- |
/// | 0      | 8    | magic `PDBK1` + format version 1 + 2 reserved |
/// | 8      | 4    | plaintext chunk bytes per frame (BE32)        |
/// | 12     | 16   | Argon2id salt                                 |
/// | 28     | 16   | KDF parameters                                |
/// | 44     | 24   | base nonce: 19 random bytes + 5 zero counter bytes |
const int portableEnvelopeHeaderBytes = 68;
const int portableEnvelopeFrameMacBytes = 16;
const int portableEnvelopeNonceBytes = 24;
const int _chunkSize = 64 * 1024;

List<int> _magicFormatV1() => utf8.encode('PDBK1') + [0x01, 0x00, 0x00];

/// Frame nonce: 19-byte base prefix plus a 5-byte big-endian frame counter.
/// Counters are unique per key, so nonces never repeat.
List<int> _frameNonce(List<int> base, int frame) {
  final prefix = base.sublist(0, portableEnvelopeNonceBytes - 5);
  return prefix + _beBytes(frame, 5);
}

/// Frame AAD binds the entire header, the frame counter and the final flag.
List<int> _frameAad(List<int> header, int frame, bool isFinal) =>
    header + _beBytes(frame, 8) + [isFinal ? 1 : 0];

List<int> _beBytes(int value, int length) {
  final out = Uint8List(length);
  for (var i = length - 1; i >= 0; i--) {
    out[i] = value & 0xFF;
    value >>= 8;
  }
  return out;
}

/// Argon2id + chunked XChaCha20-Poly1305 AEAD over the plaintext ZIP.
///
/// The last frame always exists (an empty payload has one empty final frame)
/// and nothing may follow it. Wrong passphrase, truncation, tampering and
/// trailing data fail on first AEAD open, before plaintext reaches callers.
class Argon2idSecretStreamEncryptor implements PortableBackupEncryptor {
  const Argon2idSecretStreamEncryptor();

  @override
  Future<void> encryptFile({
    required File plaintextArchive,
    required File destination,
    required String passphrase,
    Future<bool> Function()? isCancelled,
  }) async {
    final sourceLength = await plaintextArchive.exists() ? await plaintextArchive.length() : 0;
    if (sourceLength == 0) {
      throw const FileSystemException('plaintext archive is empty');
    }
    final input = await plaintextArchive.open();
    RandomAccessFile? output;
    try {
      final salt = await _randomBytes(16);
      final baseNonce = await _randomBytes(portableEnvelopeNonceBytes);
      final header = <int>[
        ..._magicFormatV1(),
        ..._uint32(_chunkSize),
        ...salt,
        ...PortableBackupKdfParams.frozenV1.encode(),
        ...baseNonce,
      ];
      await destination.parent.create(recursive: true);
      output = await destination.open(mode: FileMode.write);
      await output.writeFrom(header);

      final aead = Xchacha20.poly1305Aead();
      final kdf = Argon2id(
        memory: PortableBackupKdfParams.frozenV1.memoryKiB,
        parallelism: PortableBackupKdfParams.frozenV1.parallelism,
        iterations: PortableBackupKdfParams.frozenV1.iterations,
        hashLength: PortableBackupKdfParams.frozenV1.hashLength,
      );
      final derivedKey = await kdf.deriveKeyFromPassword(
        password: passphrase,
        nonce: salt,
      );
      final key = SecretKeyData(await derivedKey.extractBytes());

      var position = 0;
      var frame = 0;
      for (;;) {
        if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
        final remaining = sourceLength - position;
        final length = remaining > _chunkSize ? _chunkSize : remaining;
        final isFinal = position + length == sourceLength;
        await input.setPosition(position);
        final plain = await input.read(length);
        final box = await aead.encrypt(
          plain,
          secretKey: key,
          nonce: _frameNonce(baseNonce, frame),
          aad: _frameAad(header, frame, isFinal),
        );
        await output.writeFrom(box.cipherText + box.mac.bytes);
        position += length;
        frame += 1;
        if (isFinal) break;
      }
      await output.flush();
    } catch (_) {
      await output?.close();
      output = null;
      if (await destination.exists()) {
        await _deleteQuietly(destination);
      }
      rethrow;
    } finally {
      await input.close();
      await output?.close();
    }
  }

  static Future<List<int>> _randomBytes(int count) async {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }
}

/// Reads a `.pandapay-backup` envelope back to its plaintext ZIP inside
/// app-private staging. The caller owns cleanup of the returned file.
Future<File> readPortableBackupArchive({
  required File backupFile,
  required String passphrase,
  required Directory stagingDirectory,
}) async {
  final size = await backupFile.length();
  if (size < portableEnvelopeHeaderBytes + portableEnvelopeFrameMacBytes) {
    throw const PortableBackupEnvelopeException('envelope is truncated');
  }
  final input = await backupFile.open();
  RandomAccessFile? output;
  File? decryptedFile;
  try {
    final headerBytes = await input.read(portableEnvelopeHeaderBytes);
    final expectedMagic = _magicFormatV1();
    for (var i = 0; i < expectedMagic.length; i++) {
      if (headerBytes[i] != expectedMagic[i]) {
        throw const PortableBackupEnvelopeException('magic mismatch');
      }
    }
    final chunkSize = _readUint32(headerBytes, 8);
    if (chunkSize < 4096 || chunkSize > 4 * 1024 * 1024) {
      throw const PortableBackupEnvelopeException('chunk size out of range');
    }
    final params = PortableBackupKdfParams.decode(headerBytes.sublist(28, 44));
    if (params.memoryKiB != PortableBackupKdfParams.frozenV1.memoryKiB ||
        params.parallelism != PortableBackupKdfParams.frozenV1.parallelism ||
        params.iterations != PortableBackupKdfParams.frozenV1.iterations) {
      throw const PortableBackupEnvelopeException('kdf parameters do not match format v1');
    }
    final salt = headerBytes.sublist(12, 28);
    final baseNonce = headerBytes.sublist(44, 68);

    final aead = Xchacha20.poly1305Aead();
    final kdf = Argon2id(
      memory: params.memoryKiB,
      parallelism: params.parallelism,
      iterations: params.iterations,
      hashLength: params.hashLength,
    );
    final derivedKey = await kdf.deriveKeyFromPassword(password: passphrase, nonce: salt);
    final key = SecretKeyData(await derivedKey.extractBytes());

    await stagingDirectory.create(recursive: true);
    decryptedFile = File(
      '${stagingDirectory.path}${Platform.pathSeparator}'
      'portable-decrypted-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    output = await decryptedFile.open(mode: FileMode.write);
    var position = portableEnvelopeHeaderBytes;
    var frame = 0;
    for (;;) {
      final remaining = size - position;
      if (remaining == 0) {
        throw const PortableBackupEnvelopeException('final frame missing: truncated envelope');
      }
      if (remaining < portableEnvelopeFrameMacBytes) {
        throw const PortableBackupEnvelopeException('truncated final frame');
      }
      final frameLength = remaining <= chunkSize + portableEnvelopeFrameMacBytes
          ? remaining
          : chunkSize + portableEnvelopeFrameMacBytes;
      final isFinal = frameLength == remaining;
      await input.setPosition(position);
      final frameBytes = await input.read(frameLength);
      final cipherText =
          frameBytes.sublist(0, frameBytes.length - portableEnvelopeFrameMacBytes);
      final mac =
          Mac(frameBytes.sublist(frameBytes.length - portableEnvelopeFrameMacBytes));
      List<int> plain;
      try {
        plain = await aead.decrypt(
          SecretBox(cipherText, nonce: _frameNonce(baseNonce, frame), mac: mac),
          secretKey: key,
          aad: _frameAad(headerBytes, frame, isFinal),
        );
      } on SecretBoxAuthenticationError {
        throw const PortableBackupPassphraseError();
      }
      await output.writeFrom(plain);
      position += frameLength;
      frame += 1;
      if (isFinal) break;
    }
    if (position != size) {
      throw const PortableBackupEnvelopeException('trailing unauthenticated bytes');
    }
    await output.flush();
    return decryptedFile;
  } catch (error) {
    await output?.close();
    output = null;
    if (decryptedFile != null) {
      await cleanup([decryptedFile]);
    }
    rethrow;
  } finally {
    await input.close();
    await output?.close();
  }
}

class PortableBackupPassphraseError implements Exception {
  const PortableBackupPassphraseError();

  @override
  String toString() => 'portable backup passphrase is wrong';
}

class PortableBackupEnvelopeException implements Exception {
  final String message;

  const PortableBackupEnvelopeException(this.message);

  @override
  String toString() => 'portable backup envelope error: $message';
}

int _readUint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

List<int> _uint32(int value) => _beBytes(value, 4);

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // Surface the original failure, not a cleanup failure.
  }
}
