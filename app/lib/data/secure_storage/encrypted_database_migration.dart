import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

enum EncryptedMigrationPhase { copying, verifying, switched, complete }

/// Durable bounded progress record. Callers advance only after syncing the
/// destination and verifying a complete range; the source remains authoritative
/// until the atomic switch is durably recorded.
final class EncryptedMigrationState {
  final int format;
  final EncryptedMigrationPhase phase;
  final int lastRowid;
  final int copiedRows;
  final String sourceDigest;
  final String destinationDigest;

  const EncryptedMigrationState({
    required this.phase,
    required this.lastRowid,
    required this.copiedRows,
    required this.sourceDigest,
    required this.destinationDigest,
    this.format = 1,
  });

  Map<String, Object> toJson() => {
    'format': format,
    'phase': phase.name,
    'last_rowid': lastRowid,
    'copied_rows': copiedRows,
    'source_digest': sourceDigest,
    'destination_digest': destinationDigest,
  };

  static EncryptedMigrationState parse(String text) {
    if (utf8.encode(text).length > 4096) {
      throw const FormatException('Migration journal exceeds limit');
    }
    final value = jsonDecode(text) as Map<String, dynamic>;
    const keys = {
      'format',
      'phase',
      'last_rowid',
      'copied_rows',
      'source_digest',
      'destination_digest',
    };
    if (value.length != keys.length ||
        value.keys.any((key) => !keys.contains(key))) {
      throw const FormatException('Invalid migration journal fields');
    }
    if (value['format'] != 1) {
      throw const FormatException('Unsupported migration journal');
    }
    final phase = EncryptedMigrationPhase.values.byName(
      value['phase'] as String,
    );
    final last = value['last_rowid'] as int;
    final count = value['copied_rows'] as int;
    if (last < 0 || count < 0) {
      throw const FormatException('Invalid migration cursor');
    }
    final state = EncryptedMigrationState(
      phase: phase,
      lastRowid: last,
      copiedRows: count,
      sourceDigest: value['source_digest'] as String,
      destinationDigest: value['destination_digest'] as String,
    );
    state.validate();
    return state;
  }

  void validate() {
    final digest = RegExp(r'^[a-f0-9]{64}$');
    if (format != 1 ||
        lastRowid < 0 ||
        copiedRows < 0 ||
        lastRowid > 9007199254740991 ||
        copiedRows > 9007199254740991 ||
        !digest.hasMatch(sourceDigest) ||
        (destinationDigest.isNotEmpty && !digest.hasMatch(destinationDigest)) ||
        (phase.index >= EncryptedMigrationPhase.verifying.index &&
            destinationDigest != sourceDigest)) {
      throw const FormatException('Invalid migration state');
    }
  }
}

/// Exclusive, symlink-refusing journal I/O. A single writer must hold the
/// existing database recovery lease while using this file; this class does not
/// claim to fence independent isolates or database writers itself.
final class EncryptedMigrationJournal {
  final File file;
  final String binding;
  final int keyVersion;
  final Uint8List _authenticationKey;
  bool _disposed = false;
  EncryptedMigrationJournal(
    this.file, {
    required List<int> authenticationKey,
    required this.binding,
    required this.keyVersion,
  }) : _authenticationKey = Uint8List.fromList(authenticationKey) {
    if (authenticationKey.length != 32 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(binding) ||
        keyVersion < 1) {
      throw ArgumentError('Invalid migration authentication configuration');
    }
  }

  String _mac(EncryptedMigrationState state) {
    if (_disposed) throw StateError('Migration journal key disposed');
    final separated = Hmac(
      sha256,
      _authenticationKey,
    ).convert(utf8.encode('pandapay-migration-journal-auth-v2')).bytes;
    try {
      return Hmac(sha256, separated)
          .convert(
            utf8.encode(jsonEncode([2, keyVersion, binding, state.toJson()])),
          )
          .toString();
    } finally {
      if (separated is Uint8List) separated.fillRange(0, separated.length, 0);
    }
  }

  String _encode(EncryptedMigrationState state) => jsonEncode({
    'format': 2,
    'binding': binding,
    'key_version': keyVersion,
    'state': state.toJson(),
    'mac': _mac(state),
  });
  EncryptedMigrationState _decode(String text) {
    final value = jsonDecode(text);
    if (value is! Map ||
        value.length != 5 ||
        value.keys.any(
          (k) => !const {
            'format',
            'binding',
            'key_version',
            'state',
            'mac',
          }.contains(k),
        ) ||
        value['format'] != 2 ||
        value['binding'] != binding ||
        value['key_version'] != keyVersion ||
        value['mac'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['mac'] as String)) {
      throw const FormatException('Invalid authenticated migration journal');
    }
    final state = EncryptedMigrationState.parse(jsonEncode(value['state']));
    final expected = _mac(state), actual = value['mac'] as String;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected.codeUnitAt(i) ^ actual.codeUnitAt(i);
    }
    if (difference != 0) {
      throw const FormatException('Migration journal authentication failed');
    }
    return state;
  }

  void dispose() {
    _authenticationKey.fillRange(0, _authenticationKey.length, 0);
    _disposed = true;
  }

  Future<void> create(EncryptedMigrationState initial) async {
    initial.validate();
    if (initial.phase != EncryptedMigrationPhase.copying) {
      throw StateError('Migration must begin by copying');
    }
    await _rejectSymlinkPath(file.absolute);
    await file.create(exclusive: true);
    final handle = await file.open(mode: FileMode.writeOnlyAppend);
    try {
      await handle.writeString('${_encode(initial)}\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<EncryptedMigrationState?> read() => _readFrom(file);

  Future<EncryptedMigrationState?> _readFrom(File source) async {
    await _rejectSymlinkPath(source.absolute);
    if (!await source.exists()) return null;
    final handle = await source.open();
    late String text;
    try {
      if (await handle.length() > 4096) {
        throw const FormatException('Migration journal exceeds limit');
      }
      final bytes = await handle.read(4097);
      if (bytes.length > 4096) {
        throw const FormatException('Migration journal exceeds limit');
      }
      text = utf8.decode(bytes);
    } finally {
      await handle.close();
    }
    final line = text.trim();
    if (line.isEmpty) throw const FormatException('Empty migration journal');
    return _decode(line);
  }

  Future<void> replace(EncryptedMigrationState next) async {
    next.validate();
    final current = await read();
    if (current == null) throw StateError('Migration journal missing');
    if (next.sourceDigest != current.sourceDigest) {
      throw StateError('Migration source identity changed');
    }
    if (next.phase.index < current.phase.index ||
        next.copiedRows < current.copiedRows ||
        (next.phase == current.phase && next.lastRowid < current.lastRowid)) {
      throw StateError('Migration state cannot move backwards');
    }
    if (next.phase.index > current.phase.index + 1) {
      throw StateError('Migration phases must advance one step at a time');
    }
    if (next.phase.index >= EncryptedMigrationPhase.verifying.index &&
        (next.sourceDigest.isEmpty ||
            next.sourceDigest != next.destinationDigest)) {
      throw StateError(
        'Migration verification requires matching non-empty digests',
      );
    }
    final temp = File('${file.path}.next');
    await _rejectSymlinkPath(temp.absolute);
    final pending = await _readFrom(temp);
    if (pending != null) {
      // A crash can leave a flushed, authenticated replacement before rename.
      // Adopt only the exact state this fenced operation requested. Unknown,
      // corrupt or conflicting progress remains untouched for recovery.
      if (jsonEncode(pending.toJson()) != jsonEncode(next.toJson())) {
        throw StateError('Conflicting pending migration state');
      }
      await temp.rename(file.path);
      return;
    }
    await temp.create(exclusive: true);
    final out = await temp.open(mode: FileMode.writeOnlyAppend);
    try {
      await out.writeString(_encode(next));
      await out.flush();
    } finally {
      await out.close();
    }
    await temp.rename(file.path);
  }

  Future<void> _rejectSymlinkPath(File target) async {
    var current = Directory(target.parent.path);
    while (true) {
      final type = await FileSystemEntity.type(
        current.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link &&
          !await _trustedSystemAlias(current)) {
        throw FileSystemException('Symlink path refused', current.path);
      }
      if (current.parent.path == current.path) break;
      current = current.parent;
    }
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw FileSystemException('Symlink file refused', target.path);
    }
  }

  Future<bool> _trustedSystemAlias(Directory directory) async {
    if (!Platform.isMacOS && !Platform.isIOS) return false;
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
}
