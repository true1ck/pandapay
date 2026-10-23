import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/data/portable_backup/portable_backup.dart';

class _Client extends http.BaseClient {
  final List<int> bytes;

  _Client(String body) : bytes = utf8.encode(body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      200,
      headers: {'content-type': portableBackupExportMediaType},
    );
  }
}

void main() {
  test('streams transport envelopes into verified canonical section files', () async {
    final record = {'id': 'profile-1', 'profile_id': 'account-1', 'amount_inr': '12.50'};
    final section = '${canonicalJsonEncode(record)}\n';
    final digest = sha256.convert(utf8.encode(section)).toString();
    final body = [
      jsonEncode({
        'type': 'header',
        'media_type': portableBackupExportMediaType,
        'format_version': 1,
        'schema_version': 1,
        'backup_id': '11111111-1111-4111-8111-111111111111',
        'account_id': 'account-1',
        'snapshot_at': '2026-10-23T00:00:00.000Z',
        'snapshot_revision': '42',
        'sections': ['profile'],
      }),
      jsonEncode({'type': 'record', 'section': 'profile', 'record': record}),
      jsonEncode({
        'type': 'footer',
        'complete': true,
        'sections': {
          'profile': {'count': 1, 'plaintext_bytes': utf8.encode(section).length, 'sha256': digest},
        },
      }),
    ].join('\n');
    final directory = await Directory.systemTemp.createTemp('portable-http-');
    addTearDown(() => directory.delete(recursive: true));

    final result = await PortableBackupHttpRepository(
      apiBaseUrl: Uri.parse('https://example.test'),
      accessToken: 'token',
      client: _Client(body),
    ).downloadServerSnapshot(stagingDirectory: directory);

    expect(result.manifest.accountBinding, 'account-1');
    expect(result.manifest.sections.single.recordCount, 1);
    expect(await result.sectionFiles['profile']!.readAsString(), section);
  });

  test('missing footer fails instead of producing a usable snapshot', () async {
    final directory = await Directory.systemTemp.createTemp('portable-http-');
    addTearDown(() => directory.delete(recursive: true));
    await expectLater(
      PortableBackupHttpRepository(
        apiBaseUrl: Uri.parse('https://example.test'),
        accessToken: 'token',
        client: _Client(jsonEncode({'type': 'header', 'sections': ['profile']})),
      ).downloadServerSnapshot(stagingDirectory: directory),
      throwsA(isA<PortableBackupHttpException>()),
    );
  });
}
