import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pandapay/app/local_sms_rig_build.dart';
import 'package:pandapay/app/local_sms_rig_http_client.dart';
import 'package:pandapay/features/sms_v2/sync/rule_keys.dart';

// Lane O (security audit LO-05): the local rig trust (a private CA and an
// ephemeral rule-signing key) must be unreachable in a release build. A test
// run is a debug build, so release behaviour is proved three ways: the whole
// permission matrix, the wiring that feeds kReleaseMode into it, and a scan of
// every source file that could reach the trust anchors.

const _testCa = '''-----BEGIN CERTIFICATE-----
MIIBdjCCARygAwIBAgIUaE4Plh01+OLHWIpartvyV+z+lNYwCgYIKoZIzj0EAwIw
IDEeMBwGA1UEAwwVcGFuZGFwYXktdGVzdC1vbmx5LWNhMCAXDTI2MTEwNDIwMDU0
MloYDzIxMjYxMDExMjAwNTQyWjAgMR4wHAYDVQQDDBVwYW5kYXBheS10ZXN0LW9u
bHktY2EwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAARyLUm+2CD+eyyqtKRTFYgt
dQzLT6NzlDIgtpdTaZc3Sa6LhLIx4wwzLJX/DplCR6GyCZSR38JU/jxPVRIe29G4
ozIwMDAdBgNVHQ4EFgQUW7/8usbMM0Xj3+OsnhVwYmtZP60wDwYDVR0TAQH/BAUw
AwEB/zAKBggqhkjOPQQDAgNIADBFAiAVK4FE2NWGz1F4bvKCUwj9+xjhwqxnHOEF
6nMSbKRycAIhAPR2BiEd2/VcaiZCdmks/cwW+zaGxfDOAiJggq/vYLRR
-----END CERTIFICATE-----''';

String _source(String path) => File(path).readAsStringSync();

Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'));

void main() {
  group('permission matrix', () {
    test('no combination of inputs permits local trust in a release build', () {
      const bools = [false, true];
      const environments = ['dev', 'dev_hosted', 'staging', 'prod', ''];
      var checked = 0;
      for (final debug in bools) {
        for (final optIn in bools) {
          for (final web in bools) {
            for (final ca in bools) {
              for (final key in bools) {
                for (final environment in environments) {
                  checked++;
                  expect(
                    LocalSmsRigBuild.permits(
                      isRelease: true,
                      isDebug: debug,
                      profileOptIn: optIn,
                      environment: environment,
                      isWeb: web,
                      hasCa: ca,
                      hasRuleKey: key,
                    ),
                    isFalse,
                    reason:
                        'debug=$debug optIn=$optIn web=$web ca=$ca key=$key env=$environment',
                  );
                }
              }
            }
          }
        }
      }
      expect(checked, 2 * 2 * 2 * 2 * 2 * 5);
    });

    test('only the exact dev environment with both anchors can enable it', () {
      for (final environment in ['prod', 'staging', 'dev_hosted', '', 'DEV', 'dev ']) {
        expect(
          LocalSmsRigBuild.permits(
            isRelease: false,
            isDebug: true,
            profileOptIn: true,
            environment: environment,
            isWeb: false,
            hasCa: true,
            hasRuleKey: true,
          ),
          isFalse,
          reason: environment,
        );
      }
    });
  });

  group('wiring', () {
    test('the build flag feeds the real compile-time mode into the matrix', () {
      final source = _source('lib/app/local_sms_rig_build.dart');
      expect(source, contains('isRelease: kReleaseMode'));
      expect(source, contains('isDebug: kDebugMode'));
      expect(source, contains('isWeb: kIsWeb'));
      expect(source, contains('static bool get controlsEnabled => kDebugMode || enabled;'));
      // Rig-only controls may not hide behind any other switch.
      expect(source, isNot(contains('kProfileMode')));
    });

    test('a test run without rig defines has no local trust at all', () {
      if (LocalSmsRigBuild.encodedCa.isNotEmpty ||
          LocalSmsRigBuild.rulePublicKey.isNotEmpty) {
        return; // the compiled-transport run supplies the defines on purpose
      }
      expect(LocalSmsRigBuild.enabled, isFalse);
      expect(localSmsRigHttpClient(), isNull);
      expect(LocalSmsRigBuild.controlsEnabled, kDebugMode);
    });

    test('the transport factory refuses to build unless the flag is on', () {
      final source = _source('lib/app/local_sms_rig_http_client.dart');
      final factory = source.substring(
        source.indexOf('http.Client? localSmsRigHttpClient()'),
        source.indexOf('/// Trusts a single scratch CA'),
      );
      expect(factory, contains('if (!LocalSmsRigBuild.enabled)'));
      expect(factory.indexOf('LocalSmsRigBuild.enabled'),
          lessThan(factory.indexOf('LocalSmsRigHttpClient(')));
    });

    test('the rig rule key joins the trust map only behind the flag', () {
      final source = _source('lib/features/sms_v2/providers/runtime_provider.dart');
      expect(
        source,
        contains("if (LocalSmsRigBuild.enabled) 'local-rig': LocalSmsRigBuild.rulePublicKey"),
      );
      expect(smsV2RuleKeys.containsKey('local-rig'), isFalse);
      expect(_source('lib/features/sms_v2/sync/rule_keys.dart'), isNot(contains('LocalSmsRig')));
    });

    test('the App Check debug provider is chosen only for debug or rig builds', () {
      final source = _source('lib/features/sms_v2/sync/attestation.dart');
      expect(source, contains('LocalSmsRigBuild.controlsEnabled'));
      expect(source, contains('AndroidPlayIntegrityProvider()'));
      expect(source, contains('AppleAppAttestProvider()'));
      expect(source.split('AndroidDebugProvider').length - 1, 1);
      expect(source.split('AppleDebugProvider').length - 1, 1);
    });
  });

  group('no other path to the trust anchors', () {
    test('rig defines and the rig client are read only by their own files', () {
      final allowedDefines = {
        'lib/app/local_sms_rig_build.dart',
      };
      for (final file in _libFiles()) {
        final text = file.readAsStringSync();
        final path = file.path.replaceAll(r'\', '/');
        if (!allowedDefines.contains(path)) {
          expect(text, isNot(contains('SMS_V2_LOCAL_')), reason: path);
        }
        if (text.contains('LocalSmsRigBuild.rulePublicKey') ||
            text.contains('LocalSmsRigBuild.encodedCa')) {
          expect(
            {
              'lib/app/local_sms_rig_http_client.dart',
              'lib/features/sms_v2/providers/runtime_provider.dart',
            },
            contains(path),
            reason: path,
          );
        }
        if (text.contains('setTrustedCertificatesBytes') ||
            text.contains('badCertificateCallback')) {
          // No certificate-validation override may exist outside the rig client.
          expect(path, 'lib/app/local_sms_rig_http_client.dart');
        }
      }
    });

    test('no release-reachable code disables certificate checks', () {
      for (final file in _libFiles()) {
        final text = file.readAsStringSync();
        expect(text, isNot(contains('badCertificateCallback')), reason: file.path);
        expect(text, isNot(contains('allowLegacyUnsafeRenegotiation')), reason: file.path);
      }
    });
  });

  group('the rig client itself', () {
    final ca = _testCa.codeUnits;

    test('accepts only private IPv4 HTTPS origins', () {
      LocalSmsRigHttpClient client(String api, String auth) => LocalSmsRigHttpClient(
        apiUri: Uri.parse(api),
        authUri: Uri.parse(auth),
        caPem: ca,
      );
      client('https://127.0.0.1:4000', 'https://192.168.1.20:3210').close();
      client('https://10.1.2.3:4000', 'https://172.16.0.9:3210').close();
      for (final bad in [
        'http://127.0.0.1:4000',
        'https://8.8.8.8:4000',
        'https://172.32.0.1:4000',
        'https://localhost:4000',
        'https://api.pandapay.example',
        'https://user:pw@127.0.0.1:4000',
        'https://[::1]:4000',
      ]) {
        expect(
          () => client(bad, 'https://127.0.0.1:3210'),
          throwsArgumentError,
          reason: bad,
        );
      }
    });

    test('refuses a request to any other origin and never follows redirects', () async {
      final rig = LocalSmsRigHttpClient(
        apiUri: Uri.parse('https://127.0.0.1:4000'),
        authUri: Uri.parse('https://127.0.0.1:3210'),
        caPem: ca,
      );
      addTearDown(rig.close);
      for (final outside in [
        'https://api.pandapay.example/ready',
        'http://127.0.0.1:4000/ready',
        'https://127.0.0.1:9999/ready',
        'https://user@127.0.0.1:4000/ready',
      ]) {
        await expectLater(
          rig.send(http.Request('GET', Uri.parse(outside))),
          throwsA(isA<http.ClientException>()),
          reason: outside,
        );
      }
    });
  });
}
