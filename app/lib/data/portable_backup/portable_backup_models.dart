import 'dart:convert';

/// The only archive format supported by this implementation.
const int portableBackupFormatVersion = 1;
const String portableBackupMediaType = 'application/vnd.pandapay.backup';
const String portableBackupExtension = '.pandapay-backup';

/// Metadata for one canonical NDJSON section in a portable backup.
class PortableBackupSection {
  final String name;
  final String path;
  final int recordCount;
  final int byteLength;
  final String sha256;
  final bool required;

  const PortableBackupSection({
    required this.name,
    required this.path,
    required this.recordCount,
    required this.byteLength,
    required this.sha256,
    this.required = true,
  });

  Map<String, Object> toJson() => <String, Object>{
        'byte_length': byteLength,
        'name': name,
        'path': path,
        'record_count': recordCount,
        'required': required,
        'sha256': sha256,
      };

  factory PortableBackupSection.fromJson(Map<String, dynamic> json) {
    return PortableBackupSection(
      name: _requiredString(json, 'name'),
      path: _requiredString(json, 'path'),
      recordCount: _nonNegativeInt(json, 'record_count'),
      byteLength: _nonNegativeInt(json, 'byte_length'),
      sha256: _requiredDigest(json, 'sha256'),
      required: json['required'] as bool? ?? true,
    );
  }
}

/// Metadata for an attachment whose bytes are included in the archive.
class PortableBackupAttachment {
  final String id;
  final String path;
  final String transactionId;
  final String fileName;
  final String? mimeType;
  final int byteLength;
  final String sha256;

  const PortableBackupAttachment({
    required this.id,
    required this.path,
    required this.transactionId,
    required this.fileName,
    required this.mimeType,
    required this.byteLength,
    required this.sha256,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'byte_length': byteLength,
        'file_name': fileName,
        'id': id,
        'mime_type': mimeType,
        'path': path,
        'sha256': sha256,
        'transaction_id': transactionId,
      };

  factory PortableBackupAttachment.fromJson(Map<String, dynamic> json) {
    return PortableBackupAttachment(
      id: _requiredString(json, 'id'),
      path: _requiredString(json, 'path'),
      transactionId: _requiredString(json, 'transaction_id'),
      fileName: _requiredString(json, 'file_name'),
      mimeType: json['mime_type'] as String?,
      byteLength: _nonNegativeInt(json, 'byte_length'),
      sha256: _requiredDigest(json, 'sha256'),
    );
  }
}

/// The decrypted manifest. It deliberately contains no credentials or keys.
class PortableBackupManifest {
  final int formatVersion;
  final String schemaVersion;
  final String backupId;
  final String accountBinding;
  final DateTime createdAt;
  final DateTime snapshotAt;
  final String appVersion;
  final String serverVersion;
  final bool complete;
  final String? serverRevision;
  final List<PortableBackupSection> sections;
  final List<PortableBackupAttachment> attachments;
  final List<String> requiredCapabilities;
  final List<String> declaredExclusions;

  const PortableBackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.backupId,
    required this.accountBinding,
    required this.createdAt,
    required this.snapshotAt,
    required this.appVersion,
    required this.serverVersion,
    required this.complete,
    required this.serverRevision,
    required this.sections,
    required this.attachments,
    required this.requiredCapabilities,
    required this.declaredExclusions,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'account_binding': accountBinding,
        'app_version': appVersion,
        'attachments': attachments.map((e) => e.toJson()).toList(growable: false),
        'backup_id': backupId,
        'complete': complete,
        'created_at': _utc(createdAt),
        'declared_exclusions': List<String>.from(declaredExclusions),
        'format_version': formatVersion,
        'required_capabilities': List<String>.from(requiredCapabilities),
        'schema_version': schemaVersion,
        'sections': sections.map((e) => e.toJson()).toList(growable: false),
        'server_revision': serverRevision,
        'server_version': serverVersion,
        'snapshot_at': _utc(snapshotAt),
      };

  String toCanonicalJson() => jsonEncode(toJson());

  factory PortableBackupManifest.fromJson(Map<String, dynamic> json) {
    final formatVersion = _nonNegativeInt(json, 'format_version');
    if (formatVersion != portableBackupFormatVersion) {
      throw FormatException('unsupported portable backup format $formatVersion');
    }
    final sections = _listOfMaps(json, 'sections')
        .map(PortableBackupSection.fromJson)
        .toList(growable: false);
    final paths = <String>{};
    for (final section in sections) {
      if (!paths.add(section.path)) {
        throw FormatException('duplicate archive path ${section.path}');
      }
    }
    final attachments = _listOfMaps(json, 'attachments')
        .map(PortableBackupAttachment.fromJson)
        .toList(growable: false);
    for (final attachment in attachments) {
      if (!paths.add(attachment.path)) {
        throw FormatException('duplicate archive path ${attachment.path}');
      }
    }
    return PortableBackupManifest(
      formatVersion: formatVersion,
      schemaVersion: _requiredString(json, 'schema_version'),
      backupId: _requiredString(json, 'backup_id'),
      accountBinding: _requiredString(json, 'account_binding'),
      createdAt: _parseUtc(json, 'created_at'),
      snapshotAt: _parseUtc(json, 'snapshot_at'),
      appVersion: _requiredString(json, 'app_version'),
      serverVersion: _requiredString(json, 'server_version'),
      complete: json['complete'] == true,
      serverRevision: json['server_revision'] as String?,
      sections: sections,
      attachments: attachments,
      requiredCapabilities: _stringList(json, 'required_capabilities'),
      declaredExclusions: _stringList(json, 'declared_exclusions'),
    );
  }

  void validate({required bool requireComplete}) {
    if (requireComplete && !complete) {
      throw FormatException('portable backup is incomplete');
    }
    if (sections.isEmpty) {
      throw FormatException('portable backup has no sections');
    }
    if (accountBinding.trim().isEmpty || backupId.trim().isEmpty) {
      throw FormatException('portable backup identity is empty');
    }
    for (final section in sections) {
      validatePortableArchivePath(section.path);
    }
    for (final attachment in attachments) {
      validatePortableArchivePath(attachment.path);
    }
  }
}

String _utc(DateTime value) {
  if (!value.isUtc) throw FormatException('timestamps must be UTC');
  return value.toIso8601String();
}

DateTime _parseUtc(Map<String, dynamic> json, String key) {
  final raw = _requiredString(json, key);
  final value = DateTime.tryParse(raw);
  if (value == null || !value.isUtc) throw FormatException('$key must be UTC RFC3339');
  return value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) throw FormatException('$key is required');
  return value;
}

int _nonNegativeInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('$key must be non-negative');
  return value;
}

String _requiredDigest(Map<String, dynamic> json, String key) {
  final value = _requiredString(json, key).toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) throw FormatException('$key must be SHA-256');
  return value;
}

List<Map<String, dynamic>> _listOfMaps(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List) throw FormatException('$key must be an array');
  return [
    for (final item in value)
      if (item is Map<String, dynamic>) item else throw FormatException('$key contains a non-object'),
  ];
}

List<String> _stringList(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$key must be an array of strings');
  }
  return List<String>.from(value);
}

/// Shared archive path validation used before writing and before extraction.
void validatePortableArchivePath(String value, {int maxDepth = 8}) {
  if (value.isEmpty || value.length > 240 || !RegExp(r'^[\x00-\x7F]+$').hasMatch(value)) {
    throw FormatException('archive path is not safe: $value');
  }
  if (value.contains('\\') || value.startsWith('/') || value.contains(':')) {
    throw FormatException('archive path is not relative: $value');
  }
  final parts = value.split('/');
  if (parts.any((part) => part.isEmpty || part == '.' || part == '..') || parts.length > maxDepth) {
    throw FormatException('archive path has unsafe components: $value');
  }
}
