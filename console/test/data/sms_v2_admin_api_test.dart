import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay_console/data/admin_api.dart';

void main() {
  test('SMS admin requests preserve private browser CSRF authority', () async {
    final requests = <http.Request>[];
    final api = AdminApi(
      apiBaseUrl: '/browser/api',
      accessToken: '',
      privateAdmin: true,
      csrfToken: () => 'csrf',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({'ok': true}), 200);
      }),
    );
    await api.smsV2Request(
      'PUT',
      '/admin/sms/v2/rules/TEST/draft',
      body: {'id': 'TEST'},
    );
    expect(
      requests.single.url.toString(),
      '/browser/api/admin/sms/v2/rules/TEST/draft',
    );
    expect(requests.single.headers['X-CSRF-Token'], 'csrf');
    expect(requests.single.headers['X-Admin-Protocol'], '1');
    expect(requests.single.headers.containsKey('Authorization'), isFalse);
    expect(
      () => api.smsV2Request('DELETE', '/admin/sms/v2/rules'),
      throwsArgumentError,
    );
    expect(() => api.smsV2Request('GET', '/admin/other'), throwsArgumentError);
  });
  test(
    'SMS admin transport retains native bearer and sanitizes errors',
    () async {
      final api = AdminApi(
        apiBaseUrl: 'https://api.invalid',
        accessToken: 'native',
        privateAdmin: true,
        client: MockClient((request) async {
          expect(request.headers['Authorization'], 'Bearer native');
          return http.Response('database secret', 403);
        }),
      );
      await expectLater(
        api.smsV2Request('GET', '/admin/sms/v2/rules'),
        throwsA(
          isA<AdminApiException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
    },
  );
}
