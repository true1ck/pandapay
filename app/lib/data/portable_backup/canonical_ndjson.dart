import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// A digest/count/byte result for one canonical NDJSON section.
class PortableSectionWriteResult {
  final int recordCount;
  final int byteLength;
  final String sha256;

  const PortableSectionWriteResult({
    required this.recordCount,
    required this.byteLength,
    required this.sha256,
  });
}

/// A chunked SHA-256 accumulator. It never retains the section contents.
class PortableSha256Accumulator {
  Digest? _digest;
  late final ByteConversionSink _sink = sha256.startChunkedConversion(_DigestSink(this));
  bool _closed = false;

  void add(List<int> bytes) {
    if (_closed) throw StateError('digest is already finalized');
    _sink.add(bytes);
  }

  String close() {
    if (!_closed) {
      _closed = true;
      _sink.close();
    }
    return _digest!.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  _DigestSink(this._owner);

  final PortableSha256Accumulator _owner;

  @override
  void add(Digest data) => _owner._digest = data;

  @override
  void close() {}
}

/// Canonical JSON used for every portable section record.
///
/// Object keys are sorted recursively, arrays retain their semantic order,
/// and only JSON scalar values are accepted. This makes the bytes independent
/// of map insertion order while preserving the caller's stable row ordering.
String canonicalJsonEncode(Object? value) {
  return jsonEncode(_canonicalValue(value));
}

Object? _canonicalValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) return value;
  if (value is DateTime) {
    if (!value.isUtc) throw FormatException('timestamps must be UTC');
    return value.toIso8601String();
  }
  if (value is Map) {
    final keys = value.keys.toList(growable: false);
    if (keys.any((key) => key is! String)) throw FormatException('JSON object keys must be strings');
    keys.sort();
    return <String, Object?>{
      for (final key in keys) key as String: _canonicalValue(value[key]),
    };
  }
  if (value is Iterable) return value.map(_canonicalValue).toList(growable: false);
  throw FormatException('unsupported canonical JSON value ${value.runtimeType}');
}

/// Writes rows as UTF-8 NDJSON with exactly one LF after each row.
Future<PortableSectionWriteResult> writeCanonicalNdjson(
  Stream<Map<String, dynamic>> records,
  File destination, {
  void Function(int records, int bytes)? onProgress,
  Future<bool> Function()? isCancelled,
}) async {
  final sink = destination.openWrite();
  final digest = PortableSha256Accumulator();
  var count = 0;
  var bytesWritten = 0;
  try {
    await for (final record in records) {
      if (await isCancelled?.call() == true) throw const PortableBackupCancelled();
      final line = utf8.encode('${canonicalJsonEncode(record)}\n');
      sink.add(line);
      digest.add(line);
      count++;
      bytesWritten += line.length;
      onProgress?.call(count, bytesWritten);
    }
    await sink.flush();
  } finally {
    await sink.close();
  }
  final digestHex = digest.close();
  return PortableSectionWriteResult(
    recordCount: count,
    byteLength: bytesWritten,
    sha256: digestHex,
  );
}

/// Allows callers to report cancellation without depending on Flutter UI.
class PortableBackupCancelled implements Exception {
  const PortableBackupCancelled();

  @override
  String toString() => 'portable backup cancelled';
}
