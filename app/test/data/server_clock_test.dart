import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_request_headers_client.dart';
import 'package:pandapay/data/server_clock.dart';

void main() {
  final device = DateTime.utc(2026, 11, 13, 10, 0, 0);

  group('ServerClock', () {
    test('with no observation now() is exactly the device clock', () {
      final clock = ServerClock(deviceNow: () => device);
      expect(clock.hasOffset, isFalse);
      expect(clock.offset, Duration.zero);
      expect(clock.now(), device);
      expect(identical(clock.now(), device), isTrue);
    });

    test('offset = server time minus device time', () {
      final clock = ServerClock(deviceNow: () => device);
      // Device is 3 minutes behind the server.
      expect(
        clock.observeServerTime(device.add(const Duration(minutes: 3))),
        isTrue,
      );
      expect(clock.offset, const Duration(minutes: 3));
      expect(clock.now(), device.add(const Duration(minutes: 3)));

      // Device is 2 hours ahead of the server (a fresh clock: one that already
      // issued a later time never goes backwards, see the hardening tests).
      final ahead = ServerClock(deviceNow: () => device);
      ahead.observeServerTime(device.subtract(const Duration(hours: 2)));
      expect(ahead.offset, const Duration(hours: -2));
      expect(ahead.now(), device.subtract(const Duration(hours: 2)));
    });

    test('an offset beyond one day is clamped, not trusted', () {
      final clock = ServerClock(deviceNow: () => device);
      clock.observeServerTime(device.add(const Duration(days: 400)));
      expect(clock.offset, const Duration(days: 1));
      final other = ServerClock(deviceNow: () => device);
      other.observeServerTime(device.subtract(const Duration(days: 400)));
      expect(other.offset, const Duration(days: -1));
    });

    test('sub-two-second skew is treated as no skew', () {
      final clock = ServerClock(deviceNow: () => device);
      clock.observeServerTime(device.add(const Duration(milliseconds: 900)));
      expect(clock.hasOffset, isFalse);
      expect(clock.now(), device);
    });

    test('Date header parsing: valid, missing and garbage', () {
      final clock = ServerClock(deviceNow: () => device);
      expect(clock.observeDateHeader(null), isFalse);
      expect(clock.observeDateHeader(''), isFalse);
      expect(clock.observeDateHeader('not a date'), isFalse);
      expect(clock.hasOffset, isFalse);

      expect(clock.observeDateHeader('Fri, 13 Nov 2026 10:05:00 GMT'), isTrue);
      expect(clock.offset, const Duration(minutes: 5));
    });

    test('reset forgets the offset', () {
      final clock = ServerClock(deviceNow: () => device);
      clock.observeServerTime(device.add(const Duration(minutes: 5)));
      clock.reset();
      expect(clock.hasOffset, isFalse);
      expect(clock.now(), device);
    });
  });

  group('ApiRequestHeadersClient captures the Date header', () {
    final api = Uri.parse('https://api.example.test:8443');

    ApiRequestHeadersClient client(http.Client inner, ServerClock clock) =>
        ApiRequestHeadersClient(
          inner: inner,
          apiBaseUrl: api,
          appVersion: () async => '1.0.0+1',
          serverClock: clock,
        );

    test('2xx API response updates the clock', () async {
      final clock = ServerClock();
      final c = client(
        MockClient(
          (_) async => http.Response(
            '{}',
            200,
            headers: {'date': 'Fri, 13 Nov 2026 10:00:00 GMT'},
          ),
        ),
        clock,
      );
      await c.get(Uri.parse('https://api.example.test:8443/transactions'));
      expect(clock.hasOffset, isTrue);
    });

    test('missing Date header leaves the clock alone', () async {
      final clock = ServerClock();
      final c = client(
        MockClient((_) async => http.Response('{}', 200)),
        clock,
      );
      await c.get(Uri.parse('https://api.example.test:8443/transactions'));
      expect(clock.hasOffset, isFalse);
    });

    test('non-2xx responses and other origins are ignored', () async {
      final clock = ServerClock();
      final hdr = {'date': 'Fri, 13 Nov 2026 10:00:00 GMT'};
      final c = client(
        MockClient((_) async => http.Response('{}', 500, headers: hdr)),
        clock,
      );
      await c.get(Uri.parse('https://api.example.test:8443/transactions'));
      expect(clock.hasOffset, isFalse);

      final other = client(
        MockClient((_) async => http.Response('{}', 200, headers: hdr)),
        clock,
      );
      await other.get(Uri.parse('https://maps.example.test/place'));
      expect(clock.hasOffset, isFalse);
    });

    test('a cached response (Age header) is not a clock sample', () async {
      final clock = ServerClock();
      final c = client(
        MockClient(
          (_) async => http.Response(
            '{}',
            200,
            headers: {'date': 'Fri, 13 Nov 2026 10:00:00 GMT', 'age': '3600'},
          ),
        ),
        clock,
      );
      await c.get(Uri.parse('https://api.example.test:8443/transactions'));
      expect(clock.hasOffset, isFalse);
    });
  });
}
