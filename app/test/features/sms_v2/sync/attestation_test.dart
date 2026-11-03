import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pandapay/features/sms_v2/sync/attestation.dart';

String token(DateTime expiry) => [
  base64Url.encode(utf8.encode('{}')),
  base64Url.encode(
    utf8.encode(jsonEncode({'exp': expiry.millisecondsSinceEpoch ~/ 1000})),
  ),
  'signature',
].join('.');

void main() {
  final start = DateTime.utc(2026, 11, 20, 10);
  const device = 'ba438d30-e770-4d69-815f-401b04ea3d26';
  test(
    'coalesces requests, caches until near expiry, then forces refresh',
    () async {
      var now = start;
      final refreshes = <bool>[];
      final client = DeviceAttestation(
        deviceId: device,
        now: () => now,
        fetchToken: (refresh) async {
          refreshes.add(refresh);
          return token(now.add(const Duration(hours: 1)));
        },
      );
      final headers = await Future.wait(
        List.generate(20, (_) => client.headers()),
      );
      expect(refreshes, [false]);
      expect(headers.first['X-Sms-Device-Id'], device);
      expect(headers.first['X-Device-Attestation'], isNotEmpty);
      await client.headers();
      expect(refreshes, [false]);
      now = now.add(const Duration(minutes: 56));
      await client.headers();
      expect(refreshes, [false, true]);
    },
  );

  test(
    'missing Firebase or malformed tokens keep the device identifier',
    () async {
      for (final value in [
        null,
        'bad-token',
        token(start.subtract(const Duration(seconds: 1))),
      ]) {
        final client = DeviceAttestation(
          deviceId: device,
          now: () => start,
          fetchToken: (_) async => value,
        );
        expect(await client.headers(), {'X-Sms-Device-Id': device});
      }
      final broken = DeviceAttestation(
        deviceId: device,
        now: () => start,
        fetchToken: (_) async => throw StateError('unconfigured Firebase'),
      );
      expect(await broken.headers(), {'X-Sms-Device-Id': device});
    },
  );

  test('invalid installation IDs are rejected before a request', () {
    expect(() => DeviceAttestation(deviceId: ''), throwsArgumentError);
  });
}
