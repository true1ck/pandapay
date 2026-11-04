// Opt-in smoke against the local synthetic rig. No shared API or user data.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:pandapay/data/auth_api.dart';
import 'package:pandapay/data/local/app_database.dart';
import 'package:pandapay/data/local/financial_store.dart';
import 'package:pandapay/features/sms_import/sms_background_queue.dart';
import 'package:pandapay/features/sms_v2/pipeline/sms_v2_runtime.dart';
import 'package:pandapay/features/sms_v2/storage/ledger_store.dart';
import 'package:pandapay/features/sms_v2/sync/bundle_verifier.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final location = Platform.environment['SMS_V2_LOCAL_RIG'];
  test(
    'app client signs in, verifies rules and round-trips SMS facts',
    () async {
      final root = Directory(location!).resolveSymbolicLinksSync();
      final scratch = Directory('/tmp').resolveSymbolicLinksSync();
      expect(root, startsWith('$scratch/pandapay-sms-rig.'));
      final defines =
          jsonDecode(File('$root/flutter-defines.json').readAsStringSync())
              as Map<String, dynamic>;
      final authUrl = defines['PANDAPAY_AUTH_BASE_URL'] as String;
      final apiUrl = Uri.parse(defines['PANDAPAY_API_BASE_URL'] as String);
      for (final endpoint in [apiUrl, Uri.parse(authUrl)]) {
        expect(endpoint.scheme, 'https');
        expect(
          endpoint.host,
          '127.0.0.1',
          reason: 'Run the test on the default rig',
        );
      }
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('$root/tls/rootCA.pem');
      final client = IOClient(HttpClient(context: context));
      addTearDown(client.close);
      final auth = AuthApi(authBaseUrl: authUrl, client: client);
      const device = 'sms-v2-local-flutter-test';
      await auth.requestEmailOtp('test@example.com');
      final tokens = await auth.verifyEmailOtp(
        'test@example.com',
        '1234',
        device,
      );
      final payload =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(
                    base64Url.normalize(tokens.accessToken.split('.')[1]),
                  ),
                ),
              )
              as Map<String, dynamic>;
      final namespace = 'user:${payload['sub']}';
      final database = AppDatabase.forTesting(sqlite3.openInMemory());
      final financial = FinancialStore(database);
      addTearDown(() {
        financial.dispose();
        database.db.dispose();
      });
      final verifier = BundleVerifier(
        trustedKeys: {
          'local-rig': defines['SMS_V2_LOCAL_RULE_PUBLIC_KEY'] as String,
        },
      );
      Future<Map<String, String>> headers() async => {
        'Authorization': 'Bearer ${tokens.accessToken}',
      };
      final runtime = SmsV2Runtime(
        financial: financial,
        namespace: namespace,
        client: client,
        baseUri: apiUrl,
        deviceId: device,
        appVersion: '2.0.0',
        headers: headers,
        verify: verifier.verify,
        loadShippedBundle: () async =>
            File('assets/sms_rules/baseline_bundle.json').readAsStringSync(),
        accountIsCurrent: () => true,
      );
      final ledger = LedgerStore(database.db, namespace: namespace);
      await runtime.sync();
      expect((await runtime.activeBundle()).bundleVersion, greaterThan(0));
      expect(ledger.list().any((entry) => entry.amountMinor == 49900), isTrue);

      await runtime.capture([
        QueuedSms(
          sender: 'HDFCBK-S(smsft_fi)',
          body:
              'Sent Rs.678.90\nFrom HDFC Bank A/C *1797\nTo VPA '
              '9876543210@ybl\nOn 01/11/25\nRef 412345678910 Avl Bal Rs.12,345.67',
          receivedAt: DateTime.utc(2026, 11, 4),
        ),
      ], backfill: true);
      await runtime.sync();
      final response = await client.get(
        apiUrl.resolve('/sms/v2/sync'),
        headers: await headers(),
      );
      expect(response.statusCode, 200);
      final remote = jsonDecode(response.body) as Map;
      expect(
        (remote['ledger'] as List).any((row) => row['amountMinor'] == 67890),
        isTrue,
      );
      final downloaded = await client.get(
        apiUrl.resolve('/sms/v2/rules?since=0'),
        headers: await headers(),
      );
      expect(downloaded.statusCode, 200);
      final raw = downloaded.bodyBytes;
      final bytes = raw.length > 2 && raw[0] == 31 && raw[1] == 139
          ? gzip.decode(raw)
          : raw;
      final altered = (jsonDecode(utf8.decode(bytes)) as Map)
        ..['bundleVersion'] = 999;
      expect(await verifier.verify(jsonEncode(altered)), isNull);
    },
    skip: location == null ? 'Start the rig and set SMS_V2_LOCAL_RIG' : false,
  );
}
