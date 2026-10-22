import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A deliberately small, independent reader for decrypted portable-backup
/// entries. The archive coordinator can pass the exact plaintext bytes it
/// wrote before encryption; this reader does not share writer counters or
/// digest state, so a self-check catches mismatched counts and section bytes.
class PortableBackupInspectionException implements Exception {
  final String message;

  const PortableBackupInspectionException(this.message);

  @override
  String toString() => message;
}

class PortableBackupSectionInspection {
  final String name;
  final int recordCount;
  final int byteLength;
  final String sha256;

  const PortableBackupSectionInspection({
    required this.name,
    required this.recordCount,
    required this.byteLength,
    required this.sha256,
  });
}

class PortableBackupInspection {
  final int formatVersion;
  final String backupId;
  final bool complete;
  final List<PortableBackupSectionInspection> sections;
  final List<String> declaredExclusions;
  final int totalRecords;

  const PortableBackupInspection({
    required this.formatVersion,
    required this.backupId,
    required this.complete,
    required this.sections,
    required this.declaredExclusions,
    required this.totalRecords,
  });

  int get totalBytes => sections.fold(0, (sum, section) => sum + section.byteLength);
}

/// Validates manifest metadata, exact section bytes, and declared foreign-key
/// relationships. [sectionBytes] maps manifest section names (or paths) to
/// their plaintext NDJSON bytes. The input is untrusted and is never exposed
/// as a raw preview by the export UI.
class PortableBackupInspector {
  const PortableBackupInspector();

  PortableBackupInspection inspect({
    required List<int> manifestBytes,
    required Map<String, List<int>> sectionBytes,
  }) {
    final manifest = _decodeObject(manifestBytes, 'manifest.json');
    final version = _readInt(manifest, const ['format_version', 'formatVersion']);
    if (version != 1) {
      throw PortableBackupInspectionException(
        'Unsupported portable backup format version: $version',
      );
    }
    final backupId = _readString(manifest, const ['backup_id', 'backupId']);
    final complete = manifest['complete'] == true || manifest['completeness'] == 'complete';
    if (!complete) {
      throw const PortableBackupInspectionException(
        'This file is not a complete portable backup.',
      );
    }

    final descriptors = _sectionDescriptors(manifest);
    if (descriptors.isEmpty) {
      throw const PortableBackupInspectionException(
        'Portable backup manifest has no sections.',
      );
    }

    final inspected = <PortableBackupSectionInspection>[];
    final recordsBySection = <String, List<Map<String, dynamic>>>{};
    for (final descriptor in descriptors) {
      final name = _readString(descriptor, const ['name', 'path', 'section']);
      final bytes = sectionBytes[name];
      if (bytes == null) {
        throw PortableBackupInspectionException(
          'Portable backup is missing section $name.',
        );
      }
      final actualDigest = sha256.convert(bytes).toString();
      final expectedDigest = _readString(
        descriptor,
        const ['sha256', 'digest', 'sha_256'],
      );
      if (actualDigest != expectedDigest) {
        throw PortableBackupInspectionException(
          'Portable backup section $name failed its digest check.',
        );
      }
      final expectedLength = _readInt(
        descriptor,
        const ['byte_length', 'byteLength', 'plaintext_bytes'],
      );
      if (bytes.length != expectedLength) {
        throw PortableBackupInspectionException(
          'Portable backup section $name has an unexpected byte length.',
        );
      }

      final records = _decodeNdjson(bytes, name);
      final expectedCount = _readInt(descriptor, const ['count', 'record_count']);
      if (records.length != expectedCount) {
        throw PortableBackupInspectionException(
          'Portable backup section $name has an unexpected record count.',
        );
      }
      recordsBySection[name] = records;
      inspected.add(
        PortableBackupSectionInspection(
          name: name,
          recordCount: records.length,
          byteLength: bytes.length,
          sha256: actualDigest,
        ),
      );
    }

    _verifyRelationships(manifest, recordsBySection);
    return PortableBackupInspection(
      formatVersion: version,
      backupId: backupId,
      complete: complete,
      sections: List.unmodifiable(inspected),
      declaredExclusions: _readStringList(
        manifest,
        const ['declared_exclusions', 'declaredExclusions', 'exclusions'],
      ),
      totalRecords: inspected.fold(0, (sum, section) => sum + section.recordCount),
    );
  }

  Map<String, dynamic> _decodeObject(List<int> bytes, String name) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map<String, dynamic>) return value;
      throw const FormatException('not an object');
    } catch (_) {
      throw PortableBackupInspectionException('$name is not valid JSON.');
    }
  }

  List<Map<String, dynamic>> _decodeNdjson(List<int> bytes, String name) {
    final text = utf8.decode(bytes);
    if (text.isNotEmpty && !text.endsWith('\n')) {
      throw PortableBackupInspectionException(
        'Portable backup section $name is not LF-terminated.',
      );
    }
    final records = <Map<String, dynamic>>[];
    for (final line in text.split('\n')) {
      if (line.isEmpty) continue;
      try {
        final value = jsonDecode(line);
        if (value is! Map<String, dynamic>) throw const FormatException();
        records.add(value);
      } catch (_) {
        throw PortableBackupInspectionException(
          'Portable backup section $name contains invalid NDJSON.',
        );
      }
    }
    return records;
  }

  List<Map<String, dynamic>> _sectionDescriptors(Map<String, dynamic> manifest) {
    final raw = manifest['sections'];
    if (raw is Map) {
      return raw.entries.map((entry) {
        final value = entry.value;
        if (value is! Map) {
          throw const PortableBackupInspectionException(
            'Portable backup section metadata is invalid.',
          );
        }
        return <String, dynamic>{'name': entry.key, ...value.cast<String, dynamic>()};
      }).toList();
    }
    if (raw is List) {
      return raw.whereType<Map>().map((value) => value.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  void _verifyRelationships(
    Map<String, dynamic> manifest,
    Map<String, List<Map<String, dynamic>>> recordsBySection,
  ) {
    final raw = manifest['relationships'];
    if (raw is! List) return;
    for (final item in raw.whereType<Map>()) {
      final relation = item.cast<String, dynamic>();
      final from = _readString(relation, const ['from_section', 'fromSection']);
      final field = _readString(relation, const ['field', 'from_field', 'fromField']);
      final target = _readString(relation, const ['to_section', 'toSection']);
      final targetIds = {
        for (final record in recordsBySection[target] ?? const <Map<String, dynamic>>[])
          if (record['id'] is String) record['id'] as String,
      };
      for (final record in recordsBySection[from] ?? const <Map<String, dynamic>>[]) {
        final value = record[field];
        if (value == null) continue;
        if (value is! String || !targetIds.contains(value)) {
          throw PortableBackupInspectionException(
            'Portable backup relationship $from.$field -> $target is invalid.',
          );
        }
      }
    }
  }

  int _readInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
    }
    throw const PortableBackupInspectionException(
      'Portable backup manifest is missing required metadata.',
    );
  }

  String _readString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.isNotEmpty) return value;
    }
    throw const PortableBackupInspectionException(
      'Portable backup manifest is missing required metadata.',
    );
  }

  List<String> _readStringList(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is List) return value.whereType<String>().toList(growable: false);
    }
    return const [];
  }
}

