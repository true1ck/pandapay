import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/api_exception.dart';
import 'package:pandapay/data/phone_api.dart';

PhoneApi api(MockClient client) => PhoneApi(
  authBaseUrl: 'https://auth.test',
  accessToken: 'token-1',
  client: client,
);

void main() {
  test('status reads whether the account has a phone and whether the lock needs one', () async {
    late http.Request seen;
    final status = await api(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'claimed': false,
            'verified': false,
            'required': true,
            'needs_phone': true,
            'phone_hint': null,
          }),
          200,
        );
      }),
    ).status();
    expect(seen.method, 'GET');
    expect(seen.url.toString(), 'https://auth.test/users/me/phone');
    expect(seen.headers['Authorization'], 'Bearer token-1');
    expect(status.needsPhone, isTrue);
    expect(status.required, isTrue);
    expect(status.hasPhone, isFalse);
  });

  test('a typed phone counts as a phone, and so does an older verified one', () {
    expect(
      PhoneStatus.fromJson({'claimed': true, 'phone_hint': '+91 •••• 3210'}).hasPhone,
      isTrue,
    );
    expect(PhoneStatus.fromJson({'verified': true}).hasPhone, isTrue);
    expect(PhoneStatus.fromJson(const {}).needsPhone, isFalse);
  });

  test('claim sends only the typed number and returns the masked one', () async {
    late http.Request seen;
    final hint = await api(
      MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({'ok': true, 'phone_hint': '+91 •••• 3210'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    ).claim('9876543210');
    expect(seen.method, 'POST');
    expect(jsonDecode(seen.body), {'phone_number': '9876543210'});
    expect(hint, '+91 •••• 3210');
  });

  test('a refusal carries the server code and its plain wording', () async {
    const message =
        "This number can't be used. If it is yours, sign in with the email you first used, or contact support.";
    await expectLater(
      api(
        MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'phone_unavailable', 'message': message}),
            409,
          ),
        ),
      ).claim('9876543210'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.errorCode, 'errorCode', 'phone_unavailable')
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.userMessage, 'userMessage', message),
      ),
    );
  });

  test('a non-JSON failure falls back to generic wording and never shows the body', () async {
    await expectLater(
      api(MockClient((_) async => http.Response('<html>Bad gateway</html>', 502))).status(),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 502)
            .having((e) => e.userMessage, 'userMessage', isNot(contains('html'))),
      ),
    );
  });
}
