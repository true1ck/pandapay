import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'canonical_ndjson.dart';
import 'portable_backup_models.dart';

const String portableBackupExportMediaType =
    'application/vnd.pandapay.portable-backup+ndjson';

class PortableBackupHttpException implements Exception {
  final String message;
  final int? statusCode;

  const PortableBackupHttpException(this.message, {this.statusCode});

  @override
  String toString() => 'PortableBackupHttpException($message)';
}

class PortableServerSnapshot {
  final PortableBackupManifest manifest;
  final Map<String, File> sectionFiles;

  const PortableServerSnapshot({
    required this.manifest,
    required this.sectionFiles,
  });
}

/// Streams the authenticated server export into canonical section files.
/// Nothing in this class buffers the account or sends a report-shaped JSON
/// response through the legacy import pipeline.
class PortableBackupHttpRepository {
  final Uri apiBaseUrl;
  final String accessToken;
  final http.Client client;
  final String appVersion;
  final String serverVersion;

  const PortableBackupHttpRepository({
    required this.apiBaseUrl,
    required this.accessToken,
    required this.client,
    this.appVersion = 'unknown',
    this.serverVersion = 'unknown',
  });

  Future<PortableServerSnapshot> downloadServerSnapshot({
    required Directory stagingDirectory,
    Future<bool> Function()? isCancelled,
  }) async {
    await stagingDirectory.create(recursive: true);
    final request = http.Request(
      'GET',
      apiBaseUrl.resolve('/portable-backups/export-v1'),
    )
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..headers['Accept'] = portableBackupExportMediaType;
    final response = await client.send(request);
    if (response.statusCode != 200) {
      await response.stream.drain();
      throw PortableBackupHttpException(
        'server export failed',
        statusCode: response.statusCode,
      );
    }

    final sinks = <String, IOSink>{};
    final digests = <String, PortableSha256Accumulator>{};
    final counts = <String, int>{};
    final bytes = <String, int>{};
    final files = <String, File>{};
    Map<String, dynamic>? header;
    Map<String, dynamic>? footer;
    try {
      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (await isCancelled?.call() == true) {
          throw const PortableBackupHttpException('export cancelled');
        }
        if (line.isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map<String, dynamic>) {
          throw const PortableBackupHttpException('invalid export envelope');
        }
        switch (decoded['type']) {
          case 'header':
            if (header != null) {
              throw const PortableBackupHttpException('duplicate export header');
            }
            header = decoded;
            final sections = decoded['sections'];
            if (sections is! List || sections.any((value) => value is! String)) {
              throw const PortableBackupHttpException('export sections missing');
            }
            for (final name in sections.cast<String>()) {
              _validateSectionName(name);
              final file = File('${stagingDirectory.path}${Platform.pathSeparator}section-$name.ndjson');
              files[name] = file;
              sinks[name] = file.openWrite();
              digests[name] = PortableSha256Accumulator();
              counts[name] = 0;
              bytes[name] = 0;
            }
          case 'record':
            if (header == null || footer != null) {
              throw const PortableBackupHttpException('record outside export body');
            }
            final name = decoded['section'];
            final record = decoded['record'];
            if (name is! String || record is! Map<String, dynamic> || !sinks.containsKey(name)) {
              throw const PortableBackupHttpException('invalid export record');
            }
            final canonical = '${canonicalJsonEncode(record)}\n';
            final canonicalBytes = utf8.encode(canonical);
            sinks[name]!.write(canonical);
            digests[name]!.add(canonicalBytes);
            counts[name] = counts[name]! + 1;
            bytes[name] = bytes[name]! + canonicalBytes.length;
          case 'footer':
            if (header == null || footer != null || decoded['complete'] != true) {
              throw const PortableBackupHttpException('invalid export footer');
            }
            footer = decoded;
          default:
            throw const PortableBackupHttpException('unknown export envelope');
        }
      }
      if (header == null || footer == null) {
        throw const PortableBackupHttpException('export ended without footer');
      }
      await Future.wait(sinks.values.map((sink) => sink.flush()));
      final footerSections = footer['sections'];
      if (footerSections is! Map<String, dynamic>) {
        throw const PortableBackupHttpException('footer sections missing');
      }
      final manifestSections = <PortableBackupSection>[];
      for (final name in files.keys) {
        final stat = footerSections[name];
        if (stat is! Map<String, dynamic> ||
            stat['count'] != counts[name] ||
            stat['plaintext_bytes'] != bytes[name] ||
            stat['sha256'] != digests[name]!.close()) {
          throw PortableBackupHttpException('section digest mismatch: $name');
        }
        manifestSections.add(PortableBackupSection(
          name: name,
          path: 'sections/$name.ndjson',
          recordCount: counts[name]!,
          byteLength: bytes[name]!,
          sha256: stat['sha256'] as String,
        ));
      }
      final h = header;
      final account = h['account_id'];
      final backupId = h['backup_id'];
      final snapshotAt = DateTime.tryParse('${h['snapshot_at']}');
      if (account is! String || backupId is! String || snapshotAt == null || !snapshotAt.isUtc) {
        throw const PortableBackupHttpException('export identity metadata missing');
      }
      return PortableServerSnapshot(
        manifest: PortableBackupManifest(
          formatVersion: 1,
          schemaVersion: 'portable-v1',
          backupId: backupId,
          accountBinding: account,
          createdAt: DateTime.now().toUtc(),
          snapshotAt: snapshotAt,
          appVersion: appVersion,
          serverVersion: serverVersion,
          complete: true,
          serverRevision: '${h['snapshot_revision']}',
          sections: manifestSections,
          attachments: const [],
          requiredCapabilities: const [],
          declaredExclusions: const [],
        ),
        sectionFiles: files,
      );
    } catch (_) {
      await Future.wait(sinks.values.map((sink) => sink.close()));
      sinks.clear();
      await _deleteFiles(files.values);
      rethrow;
    } finally {
      await Future.wait(sinks.values.map((sink) => sink.close()));
    }
  }

  Future<Map<String, dynamic>> createRestoreSession({
    required PortableBackupManifest manifest,
    required String idempotencyKey,
  }) {
    return _jsonRequest(
      'POST',
      '/portable-backups/restore-sessions',
      body: {
        'backup_id': manifest.backupId,
        'idempotency_key': idempotencyKey,
        'snapshot_revision': manifest.serverRevision,
        'manifest': manifest.toJson(),
      },
      acceptedStatuses: const {200, 201},
    );
  }

  Future<Map<String, dynamic>> uploadRestoreSection({
    required String sessionId,
    required String sectionName,
    required File sectionFile,
  }) async {
    _validateSectionName(sectionName);
    final request = http.StreamedRequest(
      'PUT',
      apiBaseUrl.resolve(
        '/portable-backups/restore-sessions/$sessionId/sections/$sectionName',
      ),
    )
      ..headers['Authorization'] = 'Bearer $accessToken'
      ..headers['Content-Type'] = 'application/x-ndjson';
    request.contentLength = await sectionFile.length();
    await request.sink.addStream(sectionFile.openRead());
    await request.sink.close();
    final response = await client.send(request);
    return _decodeJsonResponse(response, acceptedStatuses: const {200, 201});
  }

  Future<Map<String, dynamic>> previewRestore({required String sessionId}) {
    return _jsonRequest(
      'GET',
      '/portable-backups/restore-sessions/$sessionId/preview',
      acceptedStatuses: const {200},
    );
  }

  Future<Map<String, dynamic>> commitRestore({
    required String sessionId,
    required String previewRevision,
  }) {
    return _jsonRequest(
      'POST',
      '/portable-backups/restore-sessions/$sessionId/commit',
      body: {'preview_revision': previewRevision},
      extraHeaders: {'If-Match': '"$previewRevision"'},
      acceptedStatuses: const {200},
    );
  }

  Future<Map<String, dynamic>> restoreStatus({required String sessionId}) {
    return _jsonRequest(
      'GET',
      '/portable-backups/restore-sessions/$sessionId/status',
      acceptedStatuses: const {200},
    );
  }

  Future<Map<String, dynamic>> cancelRestore({required String sessionId}) {
    return _jsonRequest(
      'DELETE',
      '/portable-backups/restore-sessions/$sessionId',
      acceptedStatuses: const {200},
    );
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String> extraHeaders = const {},
    required Set<int> acceptedStatuses,
  }) async {
    final request = http.Request(method, apiBaseUrl.resolve(path))
      ..headers.addAll({
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
        ...extraHeaders,
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await client.send(request);
    return _decodeJsonResponse(response, acceptedStatuses: acceptedStatuses);
  }

  static Future<Map<String, dynamic>> _decodeJsonResponse(
    http.StreamedResponse response, {
    required Set<int> acceptedStatuses,
  }) async {
    final text = await response.stream.bytesToString();
    if (!acceptedStatuses.contains(response.statusCode)) {
      throw PortableBackupHttpException(
        'restore request failed: $text',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const PortableBackupHttpException('restore response is not JSON');
    }
    return decoded;
  }

  static void _validateSectionName(String value) {
    if (!RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(value)) {
      throw const PortableBackupHttpException('unsafe export section name');
    }
  }

  static Future<void> _deleteFiles(Iterable<File> files) async {
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // Best-effort cleanup; startup cleanup can retry private staging.
      }
    }
  }
}
