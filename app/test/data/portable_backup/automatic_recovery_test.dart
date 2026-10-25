import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/portable_backup/automatic_recovery_scheduler.dart';
import 'package:pandapay/data/portable_backup/account_recovery_repository.dart';

void main() {
  test(
    'scheduler waits for online activity, coalesces events and spaces attempts',
    () async {
      var canRun = false, calls = 0;
      var now = DateTime.utc(2026, 10, 25);
      final pending = Completer<void>();
      final scheduler = AutomaticRecoveryScheduler(
        canRun: () => canRun,
        now: () => now,
        attempt: () async {
          calls++;
          await pending.future;
        },
      );
      await scheduler.tick();
      expect(calls, 0);
      canRun = true;
      final active = scheduler.tick();
      await scheduler.tick();
      expect(calls, 1);
      pending.complete();
      await active;
      now = now.add(const Duration(minutes: 14));
      await scheduler.tick();
      expect(calls, 1);
      now = now.add(const Duration(minutes: 1));
      await scheduler.tick();
      expect(calls, 2);
      scheduler.dispose();
      now = now.add(const Duration(days: 1));
      await scheduler.tick();
      expect(calls, 2);
    },
  );
  test(
    'scheduler backs off failures without a retry storm and recovers',
    () async {
      var calls = 0, fail = true;
      var now = DateTime.utc(2026, 10, 25);
      final scheduler = AutomaticRecoveryScheduler(
        canRun: () => true,
        now: () => now,
        attempt: () async {
          calls++;
          if (fail) throw StateError('not logged');
        },
      );
      await scheduler.tick();
      now = now.add(const Duration(minutes: 15));
      await scheduler.tick();
      expect(calls, 2);
      now = now.add(const Duration(minutes: 15));
      await scheduler.tick();
      expect(calls, 2);
      now = now.add(const Duration(minutes: 15));
      fail = false;
      await scheduler.tick();
      expect(calls, 3);
      now = now.add(const Duration(minutes: 15));
      await scheduler.tick();
      expect(calls, 4);
    },
  );
  test(
    'automatic copy verifies ciphertext without requesting an escrow key',
    () async {
      const account = '11111111-1111-4111-8111-111111111111',
          snapshot = '22222222-2222-4222-8222-222222222222';
      final source = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': 'pandapay-account-local-v1',
            'account_id': account,
            'namespace': 'user:$account',
            'include_receipts': false,
            'include_unsynced': true,
            'tables': {},
            'receipts': [],
          }),
        ),
      );
      Uint8List? stored;
      final methods = <String>[];
      final client = MockClient((r) async {
        expect(r.followRedirects, isFalse);
        expect(r.headers['Authorization'], 'Bearer current-session');
        methods.add('${r.method} ${r.url.path}');
        if (r.method == 'POST') {
          final length = ByteData.sublistView(r.bodyBytes).getUint32(0);
          stored = Uint8List.fromList(r.bodyBytes.sublist(4 + length));
          return http.Response(
            jsonEncode({
              'snapshot_id': snapshot,
              'archive_sha256': sha256.convert(stored!).toString(),
            }),
            201,
          );
        }
        return http.Response(
          jsonEncode({
            'snapshot_id': snapshot,
            'account_id': account,
            'encrypted_archive': base64Encode(stored!),
            'archive_sha256': sha256.convert(stored!).toString(),
          }),
          200,
        );
      });
      final repository = AccountRecoveryRepository(
        apiBaseUrl: Uri.parse('https://api.example.test'),
        accountId: account,
        accessToken: () async => 'current-session',
        client: client,
        enabled: true,
        automatic: true,
        automaticConsentId: snapshot,
      );
      await repository.upload(
        snapshotId: snapshot,
        plaintextArchive: source,
        consent: const AccountRecoveryConsent(
          includeReceipts: false,
          includeUnsynced: true,
          explicitlyApproved: true,
        ),
      );
      expect(methods, [
        'POST /account/recovery/automatic/snapshots',
        'GET /account/recovery/automatic/snapshots/$snapshot',
      ]);
      expect(stored, isNot(source));
      client.close();
    },
  );
  test(
    'settings default to no consent and bind explicit receipt choice',
    () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        expect(r.url.path, '/account/recovery/automatic');
        if (r.method == 'GET') {
          return http.Response(
            '{"enabled":false,"include_receipts":false}',
            200,
          );
        }
        final body = jsonDecode(r.body);
        expect(body['consent_version'], 'automatic-account-recovery-v1');
        expect(body['enabled'], true);
        expect(body['include_receipts'], true);
        return http.Response('{"enabled":true,"include_receipts":true}', 200);
      });
      final r = AccountRecoveryRepository(
        apiBaseUrl: Uri.parse('https://api.example.test'),
        accountId: 'test',
        accessToken: () async => 'token',
        client: client,
        enabled: true,
      );
      expect(await r.automaticSettings(), isNull);
      expect(
        await r.automaticSettings(enable: true, includeReceipts: true),
        true,
      );
      expect(calls, 2);
      client.close();
    },
  );
}
