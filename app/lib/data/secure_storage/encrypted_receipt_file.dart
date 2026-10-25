import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as path;

import '../portable_backup/private_temporary_workspace.dart';

/// Versioned AES-256-GCM file format for receipt image bytes.
///
/// The account namespace, attachment ID, key version and fixed format label
/// are authenticated as AAD. The key is deliberately supplied by the caller;
/// this codec does not read a database key, token, or server credential.
final class EncryptedReceiptFileCodec {
  static const formatVersion = 1;
  static const headerLength =
      21; // magic(4), format(1), key version(4), nonce(12)
  static const tagLength = 16;
  static const magic = <int>[0x50, 0x50, 0x52, 0x43]; // PPRC
  static const defaultMaxPlaintextBytes = 20 * 1024 * 1024;

  final int maxPlaintextBytes;
  final Random _random;
  final AesGcm _cipher;

  EncryptedReceiptFileCodec({
    this.maxPlaintextBytes = defaultMaxPlaintextBytes,
    Random? random,
  }) : _random = random ?? Random.secure(),
       _cipher = AesGcm.with256bits() {
    if (maxPlaintextBytes <= 0 || maxPlaintextBytes > 100 * 1024 * 1024) {
      throw ArgumentError.value(maxPlaintextBytes, 'maxPlaintextBytes');
    }
  }

  Future<Uint8List> encrypt({
    required List<int> plaintext,
    required SecretKey key,
    required String accountNamespace,
    required String attachmentId,
    required int keyVersion,
  }) async {
    _validateMetadata(accountNamespace, attachmentId, keyVersion);
    if (plaintext.isEmpty || plaintext.length > maxPlaintextBytes) {
      throw const FormatException('Receipt plaintext is empty or oversized');
    }
    final nonce = List<int>.generate(12, (_) => _random.nextInt(256));
    final aad = _aad(accountNamespace, attachmentId, keyVersion);
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final result = Uint8List(
      headerLength + box.cipherText.length + box.mac.bytes.length,
    );
    result.setRange(0, 4, magic);
    result[4] = formatVersion;
    ByteData.sublistView(result).setUint32(5, keyVersion, Endian.big);
    result.setRange(9, 21, nonce);
    result.setRange(
      headerLength,
      headerLength + box.cipherText.length,
      box.cipherText,
    );
    result.setRange(
      headerLength + box.cipherText.length,
      result.length,
      box.mac.bytes,
    );
    return result;
  }

  Future<Uint8List> decrypt({
    required List<int> encrypted,
    required SecretKey key,
    required String accountNamespace,
    required String attachmentId,
    required int expectedKeyVersion,
  }) async {
    _validateMetadata(accountNamespace, attachmentId, expectedKeyVersion);
    final maxFileBytes = headerLength + maxPlaintextBytes + tagLength;
    if (encrypted.length < headerLength + tagLength ||
        encrypted.length > maxFileBytes) {
      throw const FormatException('Receipt file is truncated or oversized');
    }
    for (var i = 0; i < magic.length; i++) {
      if (encrypted[i] != magic[i]) {
        throw const FormatException('Unknown receipt format');
      }
    }
    if (encrypted[4] != formatVersion) {
      throw const FormatException('Unknown receipt format version');
    }
    final data = ByteData.sublistView(Uint8List.fromList(encrypted));
    final version = data.getUint32(5, Endian.big);
    if (version != expectedKeyVersion) {
      throw const FormatException('Receipt key version mismatch');
    }
    final nonce = encrypted.sublist(9, headerLength);
    final tagAt = encrypted.length - tagLength;
    final box = SecretBox(
      encrypted.sublist(headerLength, tagAt),
      nonce: nonce,
      mac: Mac(encrypted.sublist(tagAt)),
    );
    List<int>? cleartext;
    try {
      cleartext = await _cipher.decrypt(
        box,
        secretKey: key,
        aad: _aad(accountNamespace, attachmentId, version),
      );
      return Uint8List.fromList(cleartext);
    } on SecretBoxAuthenticationError {
      throw const FormatException('Receipt authentication failed');
    } finally {
      // The cryptography package returns a mutable Uint8List for its Dart
      // implementation. Clear that intermediate after copying the caller's
      // explicitly requested plaintext result.
      if (cleartext is Uint8List) cleartext.fillRange(0, cleartext.length, 0);
    }
  }

  static List<int> _aad(String namespace, String id, int keyVersion) {
    final ns = _utf8Bounded(namespace, 'account namespace', 256);
    final attachment = _utf8Bounded(id, 'attachment ID', 256);
    final bytes = BytesBuilder(copy: false)
      ..add([0x50, 0x50, 0x52, 0x43, formatVersion])
      ..addByte(ns.length >> 8)
      ..addByte(ns.length & 0xff)
      ..add(ns)
      ..addByte(attachment.length >> 8)
      ..addByte(attachment.length & 0xff)
      ..add(attachment);
    final version = ByteData(4)..setUint32(0, keyVersion, Endian.big);
    bytes.add(version.buffer.asUint8List());
    return bytes.takeBytes();
  }

  static List<int> _utf8Bounded(String value, String label, int maxBytes) {
    // Metadata identifiers are intentionally ASCII to keep canonical encoding.
    if (value.isEmpty ||
        value.length > maxBytes ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:@/-]*$').hasMatch(value)) {
      throw FormatException('Invalid $label');
    }
    final bytes = utf8.encode(value);
    if (bytes.length > maxBytes) throw FormatException('Invalid $label');
    return bytes;
  }

  static void _validateMetadata(String namespace, String id, int version) {
    _utf8Bounded(namespace, 'account namespace', 256);
    _utf8Bounded(id, 'attachment ID', 256);
    if (version < 1 || version > 0xffffffff) {
      throw const FormatException('Invalid receipt key version');
    }
  }
}

/// File operations around [EncryptedReceiptFileCodec]. Paths are treated as
/// untrusted: static symlink components are rejected, sources are never
/// removed, and destinations are created exclusively. These checks use Dart's
/// path-based APIs and cannot prevent a concurrent symlink replacement between
/// validation and open. Callers must choose resolved app-private destinations
/// and serialize writes; this is not a race-free primitive for arbitrary paths.
/// The source and encrypted copy are bounded before any complete allocation.
final class EncryptedReceiptFileStore {
  final EncryptedReceiptFileCodec codec;
  EncryptedReceiptFileStore({EncryptedReceiptFileCodec? codec})
    : codec = codec ?? EncryptedReceiptFileCodec();

  Future<String> copyEncrypted({
    required File source,
    required File destination,
    required SecretKey key,
    required String accountNamespace,
    required String attachmentId,
    required int keyVersion,
  }) async {
    await _rejectSymlinkPath(source.absolute);
    await _rejectSymlinkPath(destination.absolute);
    final sourceType = await FileSystemEntity.type(
      source.path,
      followLinks: false,
    );
    if (sourceType != FileSystemEntityType.file) {
      throw FileSystemException('Receipt source is not a regular file');
    }
    final sourceLength = await source.length();
    if (sourceLength <= 0 || sourceLength > codec.maxPlaintextBytes) {
      throw const FormatException('Receipt source is empty or oversized');
    }
    final input = await source.open();
    Uint8List? clear;
    try {
      try {
        if (await input.length() != sourceLength) {
          throw const FileSystemException(
            'Receipt source changed while reading',
          );
        }
        clear = await input.read(sourceLength + 1);
        if (clear.length != sourceLength) {
          throw const FileSystemException(
            'Receipt source changed while reading',
          );
        }
      } finally {
        await input.close();
      }
      final clearBytes = clear;
      final clearDigest = sha256.convert(clearBytes).bytes;
      final encrypted = await codec.encrypt(
        plaintext: clearBytes,
        key: key,
        accountNamespace: accountNamespace,
        attachmentId: attachmentId,
        keyVersion: keyVersion,
      );
      var createdDestination = false;
      try {
        // create(exclusive:true) prevents replacement of an existing file.
        await destination.create(exclusive: true);
        createdDestination = true;
        final output = await destination.open(mode: FileMode.writeOnlyAppend);
        try {
          await output.writeFrom(encrypted);
          await output.flush();
        } finally {
          await output.close();
        }
        await _rejectSymlinkPath(destination.absolute);
        final storedLength = await destination.length();
        if (storedLength != encrypted.length ||
            storedLength >
                EncryptedReceiptFileCodec.headerLength +
                    codec.maxPlaintextBytes +
                    EncryptedReceiptFileCodec.tagLength) {
          throw const FileSystemException(
            'Encrypted receipt destination verification failed',
          );
        }
        final stored = await _readBounded(
          destination,
          codec.maxPlaintextBytes +
              EncryptedReceiptFileCodec.headerLength +
              EncryptedReceiptFileCodec.tagLength,
        );
        final verified = await codec.decrypt(
          encrypted: stored,
          key: key,
          accountNamespace: accountNamespace,
          attachmentId: attachmentId,
          expectedKeyVersion: keyVersion,
        );
        try {
          if (!_constantTimeEqual(
            clearDigest,
            sha256.convert(verified).bytes,
          )) {
            throw const FileSystemException(
              'Encrypted receipt digest verification failed',
            );
          }
        } finally {
          verified.fillRange(0, verified.length, 0);
        }
        return destination.path;
      } catch (_) {
        // Remove only the exclusive file created above, and never follow a link.
        if (createdDestination &&
            await FileSystemEntity.type(destination.path, followLinks: false) ==
                FileSystemEntityType.file) {
          try {
            await destination.delete();
          } on FileSystemException {
            /* preserve uncertain output */
          }
        }
        rethrow;
      }
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  /// Decrypts only into a named file in an already-created private workspace.
  /// Callers own cleanup of the workspace after OCR/viewing completes.
  Future<File> decryptToPrivateWorkspace({
    required File encryptedFile,
    required PrivateTemporaryWorkspace workspace,
    required String filename,
    required SecretKey key,
    required String accountNamespace,
    required String attachmentId,
    required int keyVersion,
  }) async {
    await _rejectSymlinkPath(encryptedFile.absolute);
    final encrypted = await _readBounded(
      encryptedFile,
      codec.maxPlaintextBytes +
          EncryptedReceiptFileCodec.headerLength +
          EncryptedReceiptFileCodec.tagLength,
    );
    final clear = await codec.decrypt(
      encrypted: encrypted,
      key: key,
      accountNamespace: accountNamespace,
      attachmentId: attachmentId,
      expectedKeyVersion: keyVersion,
    );
    File? output;
    var createdOutput = false;
    try {
      output = workspace.file(filename);
      await _rejectSymlinkPath(output.absolute);
      await output.create(exclusive: true);
      createdOutput = true;
      final handle = await output.open(mode: FileMode.writeOnlyAppend);
      try {
        await handle.writeFrom(clear);
        await handle.flush();
      } finally {
        await handle.close();
      }
      return output;
    } catch (_) {
      if (createdOutput &&
          output != null &&
          await FileSystemEntity.type(output.path, followLinks: false) ==
              FileSystemEntityType.file) {
        try {
          await output.delete();
        } on FileSystemException {
          /* preserve uncertain output */
        }
      }
      rethrow;
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  }

  static Future<Uint8List> _readBounded(File file, int maxBytes) async {
    await _rejectSymlinkPath(file.absolute);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FileSystemException('Receipt path is not a regular file');
    }
    final length = await file.length();
    if (length <= 0 || length > maxBytes) {
      throw const FormatException('Receipt file is empty or oversized');
    }
    final handle = await file.open();
    try {
      if (await handle.length() != length) {
        throw const FileSystemException('Receipt file changed while reading');
      }
      final bytes = await handle.read(maxBytes + 1);
      if (bytes.length != length) {
        throw const FileSystemException('Receipt file changed while reading');
      }
      return Uint8List.fromList(bytes);
    } finally {
      await handle.close();
    }
  }

  static Future<void> _rejectSymlinkPath(File target) async {
    var current = Directory(path.normalize(target.parent.path));
    while (true) {
      final type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link &&
          !await _trustedSystemAlias(current)) {
        throw const FileSystemException('Symlink path refused');
      }
      if (current.parent.path == current.path) break;
      current = current.parent;
    }
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FileSystemException('Symlink file refused');
    }
  }

  static Future<bool> _trustedSystemAlias(Directory directory) async {
    if (!Platform.isMacOS) return false;
    final expected = switch (directory.path) {
      '/var' => '/private/var',
      '/tmp' => '/private/tmp',
      _ => null,
    };
    if (expected == null) return false;
    try {
      return await directory.resolveSymbolicLinks() == expected;
    } on FileSystemException {
      return false;
    }
  }

  static bool _constantTimeEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    var diff = 0;
    for (var i = 0; i < left.length; i++) {
      diff |= left[i] ^ right[i];
    }
    return diff == 0;
  }
}
